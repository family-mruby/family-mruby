# fmrb-mcp — Family mruby の開発ツールを MCP サーバとして提供する

シリアルと flash (P1)、Tab5 の WiFi 遠隔 (P2)、Linux sim (P3) の 14 ツール。
計画は `doc/mcp_tools/plan.md`、各段の実装報告は `doc/mcp_tools/report/`。

## なぜあるか

シリアルまわりの決まりごとを、手順書ではなくコードで守らせるため。

- シリアルポートは排他。capture が掴んでいると flash が
  "device reports readiness to read but returned no data" で落ちる。
- ポートを開き直すとボードにリセットがかかる。「見たいときだけ開く」は
  偽陰性の温床なので、**開きっぱなしの capture をファイル経由で読む**。
- flash の前に capture を止め、終わったら `--no-reset` で再開する。

この 3 つをサーバが引き受ける。読む側は `serial_log` を何度呼んでも
ボードに触らない。

Tab5 (ESP32-P4) では**ポートを開くだけでチップがリブートする**
(`rst:0x17 (CHIP_USB_UART_RESET)`。USB-Serial-JTAG がチップ内蔵で、ホストの
DTR/RTS がそのままリセットになる。`--no-reset` でも避けられない)。覗くたびに
開き直す運用だと毎回ボードが落ちるので、開きっぱなしの値打ちはこの機種で
いちばん大きい。なお Tab5 では `reset: true` の方が損で、2 回目のリセットの
USB 再列挙で ROM バナーを失う (`reset: false` ならバナーから採れる)。
実測 2026-08-29。

## ツール

| tool | 動作 |
|---|---|
| `serial_start(port?, baud?, reset?)` | capture を起動して開きっぱなしにする。ポートは `fmruby-core/.serial_port`、無ければ `rake check-port` で検出。`reset: true` でリセットしてブートバナーから採る |
| `serial_log(grep?, tail?, regex?)` | ログファイルを読む。**ポートには触らない** |
| `serial_stop()` | capture を止めてポートを解放する |
| `flash(app_only?)` | capture 退避 → `FLASH_BAUD=115200 rake flash` (app_only なら `rake flash:app`) → `--no-reset` で再開 → ブートの要約 |

全体 `flash` は**端末の /home 区画を消す** (ユーザデータと TTS 鍵。鍵はビルド時
注入なので焼き直せば戻る)。ユーザが使っている機体では確認してから叩く。
`app_only: true` は app 区画だけを書き、storage (/home 含む) に触らない。
コードだけの変更を繰り返し焼くときはこちら。ただし flash/ や config/ を
変えた場合は端末側が古いまま**無警告**なので、全体 flash を使う。

`rake attach` (usbipd で USB を WSL2 へ) はサーバからは行わない。Windows 側の
権限が要るのでユーザ操作。

## Tab5 遠隔 (P2)

Modern (Tab5 / ESP32-P4) を WiFi で操作する。**どのツールも IP を必須引数に
しない**。DHCP でブートごとに変わるので、解決 (mDNS) → `/status` で確認 →
5 分キャッシュ → 応答しなくなったら捨てて引き直す、をサーバが持つ。

| tool | 動作 |
|---|---|
| `tab5_ip(ip?, refresh?)` | 住所を解決して `/status` を返す。切り分け用 |
| `tab5_screenshot(ip?)` | 画面 1 枚を **image content で返す** (ファイル経由不要)。JPEG はファイルにも残す |
| `tab5_input(commands, ip?)` | `click X Y` `drag ...` `key ctrl+tab` `sleep MS` などを左から実行 |
| `tab5_app(action, path?, pid?, ip?)` | `launch` (パス起動、pid を返す) / `ps` / `kill` |
| `tab5_fs(action, device_path?, local_path?, force?, ip?)` | `ls get put push pull mkdir del rmr` |

- 座標はフレームバッファ系 **426x240** (窓の拡大率と無関係)。
- `put` → `tab5_app launch` が**再 flash なしの開発ループ**。
- **Retro (S3) は不可** (remote desktop が無い)。
- `/app` `/fs` は開発ビルド限定 (`FMRB_DEV_REMOTE_CTL`)。無い firmware は
  404 を返すので、「壊れた」ではなく「リリースビルド」と診断して返す。
  無認証なので信頼できる LAN 内が前提。
- **クラッシュすると WiFi ごと落ちてこの経路は全滅する**。そのときのログは
  同じサーバの `serial_start` / `serial_log` で採る。

## Linux sim (P3)

docker の 3 コンテナを起動・撮影・操作する。手順書でしか守られていなかった
3 つの罠をサーバが持つ。

| tool | 動作 |
|---|---|
| `sim_up(gui?)` | 起動して**最初の 1 枚を image content で返す**。ELF 検査と解像度の自己修復つき |
| `sim_down(force?)` | スタックごと down。自分が起動したものでなければ force が要る |
| `sim_screenshot(wait?)` | 現在の画面を image content で返す |
| `sim_input(commands)` | `click X Y` `text "hello world"` `key ctrl+space` など |
| `sim_app(action, path?, pid?)` | debugd 経由の `spawn` / `ps` / `kill` |

- **偽グリーンの遮断**: `rake build:linux` は esp32 の build/ が残っていても
  「Linux build complete」と言う。起動前に**両 ELF が本当に x86-64 か**を
  ヘッダで確かめ、違えば起動せずに `rake clean_all && rake build:linux` を案内する。
- **解像度の持ち越しの自己修復**: graphics-audio は画面サイズを覚えていて
  変更は次回起動から効く。期待値 (.env の FMRB_HW_TARGET) と食い違ったら
  **1 回だけ down→up をやり直す**。2 回目も違えば、持ち越しと
  「.env と build の食い違い」の両方を挙げて失敗する。
- **3 コンテナまとめて**。単独 restart のツールは作らない (core だけ
  再起動すると framebuffer が死ぬのに `Up` に見える)。
- **ユーザのスタックを壊さない**: 稼働中なら再利用し、`started_by_us` を
  覚えておく。ユーザ (や別セッション) のものを `sim_down` で黙って
  落とさない。docker は排他資源なので、起動と down の間だけ flock を握る。
- `sim_input` は **Shellwords で分解**する (`text "hello world"` を 1 引数の
  まま渡すため)。

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

サーバを子プロセスとして立て、JSON-RPC で叩く (53 項目)。実機は要らない。

- シリアル側: socat の pty ペアを仮想シリアルにして capture の実経路まで
  通す。ツール一覧、capture なしでの `serial_log`、flock 衝突、区間の繋ぎ、
  **サーバを kill したときに capture の孤児が残らないこと**、stdout が
  JSON-RPC だけであること、ブートログの読み (DL モード滞留をブートループと
  誤診しないこと)、子プロセス実行の失敗・タイムアウト。
- Tab5 側 (`selftest_tab5.rb`): 偽の Tab5 を立てて実経路を通す。住所の
  解決・キャッシュ・失効、image content が本物の JPEG であること、
  `/app` の構造化、kernel kill の拒否、404 の診断、未知キーの明示エラー。
  **`unshare -rn` の中で走らせる** — エンドポイントは port 80 にあり、
  非特権では bind できないため。名前空間の中なら 127.0.0.1:80 は自分の
  ものなので、サーバも rd_* CLI も**無改造のまま**通る。
  ユーザ名前空間が使えない環境では、この節は SKIPPED になる。
- sim 側 (`selftest_sim.rb`): docker 無しで通る分。偽の ELF (RISC-V /
  Xtensa / ELF ですらないもの) で**偽グリーンの遮断**、argv を印字する
  偽 CLI で `text "hello world"` が 1 引数のまま渡ること、debugd への
  `path=` `pid=` の渡し方、`started_by_us: false` の down 拒否、
  解像度の期待値と PNG からのサイズ読み取り。

## 掟

- **stdout には JSON-RPC 以外を 1 バイトも出さない**。サーバのログは stderr、
  子プロセスの出力はファイルへ。
- 既存の CLI (`tools/fmrb_serial_capture.py`、`rake flash`) は改変しない。
  ラッパーは薄く保ち、CLI 単体でも従来どおり使えるようにしておく。
