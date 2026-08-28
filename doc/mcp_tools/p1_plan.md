# fmrb-mcp P1 実装計画: シリアル + flash 管理

作成: 2026-08-28。状態: 計画 (これから実装するセッションへの指示書)。
全体計画は plan.md。本書は P1 だけで完結するように書いてある。

## 0. 目的 (P1 の範囲)

シリアルポートまわりの運用ルールをコードで守る MCP サーバを作る。
ツールは 4 つ: serial_start / serial_log / serial_stop / flash。
Tab5 遠隔 (P2) と sim (P3) は作らない。

守るべき不変条件 (現状は手順書と運用で守られている):

1. **シリアルポートは排他**。capture が掴んでいると flash が
   "device reports readiness to read but returned no data" で失敗する。
2. **ポートを開き直すとボードにリセットがかかる** (--no-reset でも
   アダプタによっては open だけでかかる)。「見たい時だけ開く」は
   偽陰性の温床なので、**開きっぱなしの capture からファイル経由で読む**。
3. flash の前に capture を止め、終わったら --no-reset で再開する。

## 1. 前提となる既存ツールの事実 (確認済み 2026-08-28)

- `tools/fmrb_serial_capture.py` (Python + pyserial):
  `usage: fmrb_serial_capture.py [-p PORT] [-t SECS] [-b BAUD] [--no-reset] out`
  - デフォルトは RTS パルスでリセットしてから採取 (ログがブートバナーから
    始まる)。`--no-reset` はリセット線を触らず attach。
  - `-t` は採取秒数 (デフォルト 40)。**開きっぱなし運用では大きな値
    (例 86400) を渡す**。-t 0 の意味は実装を読んで確認すること。
  - 出力ファイルは採取中でも grep できる (追記書き)。
- fmruby-core の rake タスク:
  - `rake check-port` — ポートを検出して `.serial_port` (fmruby-core 直下)
    にキャッシュする。キャッシュが無い/消えたときに必要。
  - `rake flash` — 書き込み。既定ボー 460800 は **WSL2 で接続失敗しやすい**
    ので `FLASH_BAUD=115200` を常用する。
  - `rake attach` — usbipd で USB を WSL2 へ (VIDPID は fmruby-core/.env。
    Tab5=303a:1001、NARYAv3=1a86:7523)。サーバからは呼ばない
    (Windows 側の sudo 相当が絡むためユーザ操作)。
- ターゲットは fmruby-core/.env の FMRB_HW_TARGET で決まる。flash も
  それに従う。**サーバはターゲットを切り替えない**。
- Tab5 (USB-Serial-JTAG) はボタンなしで flash できるが、flash 後に
  DL モード滞留することがある: ログが `boot:0x204 (DOWNLOAD` +
  `waiting for download` で止まる。**これはブートループではない**。
  検出したら「ボタンリセットをユーザに依頼」と返す。
- `rake flash` は /home 領域を消す (ユーザデータと TTS 鍵が飛ぶ。鍵は
  ビルド時注入)。flash ツールの description に明記する。

## 2. 成果物

```
tools/mcp/
  fmrb_mcp_server.rb     # エントリポイント (MCP stdio サーバ)
  lib/serial_manager.rb  # capture 子プロセスの所有・flash 連携・flock
  selftest.rb            # ハードなしで通る最小確認
  README.md              # 導入手順 (claude mcp add の例)
.mcp.json                # リポジトリルート (無ければ新規作成)
```

- 実装言語は Ruby。MCP は**公式 Ruby SDK (`mcp` gem、
  modelcontextprotocol/ruby-sdk)** を使う。API の正確な形 (Server / Tool /
  stdio transport の書き方) は gem の README を実装時に確認すること
  (この計画書の記憶で書かない)。
- 状態ディレクトリ: `~/.fmrb_mcp/`
  - `<port名をサニタイズ>.lock` — flock 用
  - `capture.log` — シリアルログ (追記)
  - `capture.pid` / `capture.meta.json` — 子プロセスと設定 (port/baud/開始時刻)

## 3. 設計

### 3.1 排他 (flock)

- stdio サーバは Claude セッションごとに 1 プロセス立つ。**プロセス内
  mutex では足りない**。ポート単位のロックファイルに flock (排他・
  ノンブロック) をかけ、取れなければ「他セッションが使用中」を明示
  エラーで返す。**黙って奪わない**。
- ロックは capture 稼働中ずっと保持する。flash も同じロックの中で行う
  (自分が capture を持っているなら追加取得は不要)。
- サーバ終了時 (at_exit / SIGTERM trap) に capture 子プロセスを止めて
  ロックを解放する。孤児プロセスがポートを掴み続けるのが最悪の故障
  モードなので、ここは必ず作る。pid ファイルに残った古い pid は、
  プロセスの生存確認をしてから掃除する。

### 3.2 各ツールの仕様

**serial_start(port?, baud?, reset?)**
- ポート決定: 引数 > fmruby-core/.serial_port のキャッシュ。キャッシュが
  無ければ `rake check-port` を実行してから読む。
- flock 取得 → `fmrb_serial_capture.py -p PORT -t 86400 [--no-reset] capture.log`
  を子プロセスで起動。reset は既定 false (--no-reset を付ける)。
  ブートログを最初から見たいときだけ reset:true。
- 既に自分の capture が生きていれば no-op (その旨を返す)。
- 返り値: port / baud / reset の有無 / ログファイルパス。

**serial_log(grep?, tail?)**
- capture.log から読む。tail は既定 100 行。grep は固定文字列
  (正規表現にするなら Ruby の Regexp.new で例外を握って明示エラー)。
- **ポートには一切触らない**。capture が動いていなくても、ファイルが
  あれば読める (「capture 停止中。最終更新 <時刻>」を添える)。
- 便利系として lines 前後の件数と最終更新時刻を返す。

**serial_stop()**
- 子プロセスを止め (SIGTERM → 猶予 → SIGKILL)、flock を解放。
  ログファイルは消さない。

**flash()**
- 手順:
  1. 自分の capture が動いていれば止める (was_running を記録)。
     他セッションのロックが取れないなら明示エラー。
  2. fmruby-core で `FLASH_BAUD=115200 rake flash` (タイムアウト 5 分)。
  3. 失敗時: 出力に "device reports readiness to read" があれば
     「ポートを他プロセスが掴んでいる」と診断を添える。
  4. was_running なら capture を **--no-reset で再開**。
  5. 数秒待って capture.log の末尾を確認し、要約を返す:
     - `Guru\|abort` の件数 (0 が正常)
     - ブートバナーの有無
     - `boot:0x204` + `waiting for download` があれば
       「DL モード滞留。ユーザにボタンリセットを依頼」(誤診しない)
- description に明記: /home が消える (TTS 鍵含む。鍵はビルド時注入) /
  ボーは 115200 固定 (460800 は WSL2 で失敗しやすい) / ターゲットは
  .env の FMRB_HW_TARGET に従う。

### 3.3 stdio の掟

- **stdout には JSON-RPC 以外を 1 バイトも出さない**。子プロセスの
  stdout/stderr はファイルへ、サーバ自身のログは stderr へ。
  既存 CLI を呼ぶときも popen で確実に捕捉する。

### 3.4 .mcp.json (リポジトリルート)

```json
{
  "mcpServers": {
    "fmrb": {
      "command": "ruby",
      "args": ["tools/mcp/fmrb_mcp_server.rb"]
    }
  }
}
```

パスはリポジトリルート起点の相対。gem の要求 Ruby 版はホストの ruby で
足りるか最初に確認する (`ruby -v` / gemspec)。

## 4. selftest (ハードなしで通す)

`ruby tools/mcp/selftest.rb` で以下を確認する (実機不要):

1. サーバが起動し、initialize 応答と 4 ツールの一覧が返る
2. serial_log が「capture なし・ログなし」を整った形で返す (例外で
   死なない)
3. flock: ロックを別プロセスで先に握った状態で serial_start が
   「他セッションが使用中」エラーになる
4. stdout 汚染が無い (ツール呼び出し中の出力が JSON-RPC として parse
   できる)

## 5. 実機での受け入れ確認 (ユーザ環境で実施)

1. serial_start(reset: true) → ブートバナーからログが取れる
2. serial_log を 5 回連続で呼ぶ → ログに新しい POWERON リセットが
   **現れない** (開き直していない証明)
3. capture 稼働中に flash → 人手ゼロで退避・書き込み・--no-reset 再開・
   ブート要約まで通る
4. 別ターミナルからもう 1 つサーバを立てて serial_start → 明示エラー
5. サーバを kill → capture 子プロセスが残らない (ps で確認)、
   直後の flash がポート排他で失敗しない

## 6. やらないこと

- P2 (Tab5 遠隔) / P3 (sim) のツール
- HTTP transport・常駐 1 プロセス化 (plan.md 7 章の将来項目)
- CLAUDE.md の短縮 (P4 で行う。今回は一切編集しない)
- 既存 CLI (fmrb_serial_capture.py 等) の改変。どうしても足りない
  機能があれば、改変ではなく本計画書に追記して相談する
- rake attach の自動化 (ユーザ操作)

## 7. 引き継ぎメモ

- コミットは family-mruby (親リポジトリ) 側。tools/ と doc/mcp_tools/ と
  .mcp.json が対象。fmruby-core には .serial_port キャッシュ以外触らない。
- コミットメッセージは英語。Claude 主体の作業なので
  Co-Authored-By トレーラを付ける。
- 実装中に判明した計画との差分は doc/mcp_tools/report/p1.md に残す
  (計画書は書き換えず、確定した結論だけ反映する)。
