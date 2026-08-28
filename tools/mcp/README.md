# fmrb-mcp — Family mruby の開発ツールを MCP サーバとして提供する

いまのところ P1 の範囲、シリアルと flash だけ。計画は `doc/mcp_tools/plan.md`
(全体) と `doc/mcp_tools/p1_plan.md` (この段)。

## なぜあるか

シリアルまわりの決まりごとを、手順書ではなくコードで守らせるため。

- シリアルポートは排他。capture が掴んでいると flash が
  "device reports readiness to read but returned no data" で落ちる。
- ポートを開き直すとボードにリセットがかかる。「見たいときだけ開く」は
  偽陰性の温床なので、**開きっぱなしの capture をファイル経由で読む**。
- flash の前に capture を止め、終わったら `--no-reset` で再開する。

この 3 つをサーバが引き受ける。読む側は `serial_log` を何度呼んでも
ボードに触らない。

## ツール

| tool | 動作 |
|---|---|
| `serial_start(port?, baud?, reset?)` | capture を起動して開きっぱなしにする。ポートは `fmruby-core/.serial_port`、無ければ `rake check-port` で検出。`reset: true` でリセットしてブートバナーから採る |
| `serial_log(grep?, tail?, regex?)` | ログファイルを読む。**ポートには触らない** |
| `serial_stop()` | capture を止めてポートを解放する |
| `flash()` | capture 退避 → `FLASH_BAUD=115200 rake flash` → `--no-reset` で再開 → ブートの要約 |

`flash` は**端末の /home 区画を消す** (ユーザデータと TTS 鍵。鍵はビルド時
注入なので焼き直せば戻る)。ユーザが使っている機体では確認してから叩く。

`rake attach` (usbipd で USB を WSL2 へ) はサーバからは行わない。Windows 側の
権限が要るのでユーザ操作。

## 導入

```
gem install mcp          # 公式 Ruby SDK。Ruby 3.1 以上
```

Claude Code はリポジトリ直下の `.mcp.json` を読むので、この checkout で
作業するなら追加設定は要らない (初回に許可を訊かれる)。

リポジトリの外から使う場合:

```
claude mcp add fmrb -- ruby /path/to/family-mruby/tools/mcp/fmrb_mcp_server.rb
```

Claude Desktop の `claude_desktop_config.json` なら:

```json
{
  "mcpServers": {
    "fmrb": {
      "command": "ruby",
      "args": ["/path/to/family-mruby/tools/mcp/fmrb_mcp_server.rb"]
    }
  }
}
```

ホスト側に必要なもの: ruby (mcp gem)、python3 + pyserial (capture)、
docker と rake (flash)。いずれも既存の開発環境にあるもの。

## 状態ファイル

`~/.fmrb_mcp/` (`FMRB_MCP_STATE_DIR` で変更可)。

| ファイル | 中身 |
|---|---|
| `<ポート名>.lock` | flock。**セッションをまたぐ排他はこれ**。stdio サーバは Claude セッションごとに 1 プロセス立つので、プロセス内 mutex では足りない |
| `capture.log` | 終了した capture 区間を追記したもの |
| `current.log` | 稼働中の capture が書いている区間 |
| `capture.pid` / `capture.meta.json` | 子プロセスと設定 |

`fmrb_serial_capture.py` は出力ファイルを `"wb"` で開く (= 切り詰める) ので、
capture を止めるたびに `current.log` を `capture.log` へ移している。これが
無いと flash のたびに直前までのログが消える。`serial_log` は両方を繋いで読む。

ロックが取れないときは「他セッションが使用中」と明示エラーにする。**黙って
奪わない**。サーバが死んだあとに残った capture (孤児) は、ロックを取れた側が
pid とコマンド行を確かめてから始末する。

## 自己確認 (実機不要)

```
ruby tools/mcp/selftest.rb
```

サーバを子プロセスとして立て、JSON-RPC で叩く。socat があれば仮想シリアル
(pty ペア) を作って capture の実経路まで通す。確認するのは、ツール一覧、
capture なしでの `serial_log`、flock 衝突、実際の採取と区間の繋ぎ、
**サーバを kill したときに capture の孤児が残らないこと**、stdout が
JSON-RPC だけであること、ブートログの読み (DL モード滞留をブートループと
誤診しないこと)、子プロセス実行の失敗・タイムアウト。

## 掟

- **stdout には JSON-RPC 以外を 1 バイトも出さない**。サーバのログは stderr、
  子プロセスの出力はファイルへ。
- 既存の CLI (`tools/fmrb_serial_capture.py`、`rake flash`) は改変しない。
  ラッパーは薄く保ち、CLI 単体でも従来どおり使えるようにしておく。
