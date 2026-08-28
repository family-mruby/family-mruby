# fmrb-mcp: 開発ツール群の MCP サーバ化 実装計画

作成: 2026-08-28。状態: 計画 (実装未着手)。
対象リポジトリ: family-mruby (tools/ を持つ親リポジトリ)。

## 1. 目的

リモート開発・検証ツール群 (sim 操作、Tab5 遠隔操作、シリアル、flash) を
MCP サーバとして整理する。動機は次の 2 つで、「Claude から呼びやすくする」
こと自体ではない。

1. **手順書でしか守られていない不変条件をコードで守る**。
   - シリアルは排他で、開き直すとリセットがかかる (偽陰性の温床)
   - flash 前に capture を止め、終わったら再開する
   - sim は 3 コンテナまとめて再起動する (core 単独再起動で framebuffer が死ぬ)
   - ターゲット切替直後の 1 回目は前の解像度で上がる
   - Tab5 の IP は毎回変わる (固定値を使わない)
   これらを常駐サーバの状態管理として実装し、手順書の「注意」を減らす。
2. **リポジトリ外への間口**。checkout + CLAUDE.md なしでも、Claude Desktop /
   claude.ai / 他者の環境から同じ操作ができるようにする。

## 2. 方針

- **薄い層にする**。既存の Ruby/Python ツールをそのまま子プロセスとして
  呼ぶ。ツール本体の書き直し・二重実装はしない (ツールはまだ速く進化して
  おり、厚いラッパーは負債になる)。
- 例外はシリアル管理のみ: fmrb_serial_capture.py を**サーバが子プロセス
  として所有・監督**する (ここが状態管理の本体)。
- **網羅しない**。頻度が高く状態が絡む操作だけを載せる。ログの ad-hoc な
  grep、gdb 事後解析、pngdiff、audio probe、MIDI モニタは CLI のまま
  (bash の合成が本領の領域)。
- 手順知識 (かな切替は Ctrl+Space、座標は FB 系、ランチャーの右クリック
  再走査など) は**ツールの description に移す**。CLAUDE.md の該当節は
  最終段で短縮する。
- 実装言語は Ruby (周辺ツールは Ruby の方針どおり)。MCP 公式 Ruby SDK
  (`mcp` gem) + stdio transport。
- **サーバは stdout に何も出さない** (stdio transport の掟)。ログは
  stderr とファイルへ。

## 3. 構成

```
tools/mcp/
  fmrb_mcp_server.rb     # 本体 (エントリポイント)
  lib/serial_manager.rb  # capture 子プロセスの所有・flash 連携
  lib/tab5.rb            # IP 解見 + rd_* ラッパ
  lib/sim.rb             # docker compose ライフサイクル
  selftest.rb            # サーバをインプロセスで叩く最小確認
.mcp.json                # リポジトリルート。Claude Code 向け登録
```

状態ファイルは `~/.fmrb_mcp/` (シリアルの lock、capture ログ、IP キャッシュ)。

### 多重起動への備え

stdio サーバは Claude セッションごとに 1 プロセス立つ。セッションが 2 つ
あるとサーバも 2 つになるため、**排他資源はプロセス内 mutex では足りない**。
シリアルと docker 操作は `~/.fmrb_mcp/` の flock で機体単位に排他する。
取れないときは「他セッションが使用中」を明示エラーで返す (黙って奪わない)。

## 4. ツール一覧

### シリアル + flash (P1)

| tool | 入力 | 動作 |
|---|---|---|
| serial_start | port?, baud? | capture 子プロセスを起動し**開きっぱなしにする**。既に自分が開いていれば no-op。ログは状態ディレクトリのファイルへ追記 |
| serial_log | grep?, tail? | capture ログファイルから読む (**ポートを開き直さない**。これが偽陰性対策の核) |
| serial_stop | - | capture を止める |
| flash | - | capture を止める → `FLASH_BAUD=115200 rake flash` (fmruby-core) → capture を `--no-reset` で再開 → ブートログの健全性 (`Guru\|abort` が 0、ブートバナー) を要約して返す |

- flash は DL モード滞留 (`boot:0x204` + `waiting for download`) を検出
  したら「ボタンリセットが必要」と**誤診せずに**返す (ブートループと
  区別する)。
- `.serial_port` キャッシュが無ければ `rake check-port` を先に実行する。

### Tab5 遠隔 (P2)

| tool | 入力 | 動作 |
|---|---|---|
| tab5_ip | - | mDNS (WSL は powershell.exe 経由) → `/status` で確認。キャッシュ TTL 約 5 分、接続失敗時は破棄して引き直す |
| tab5_screenshot | - | fmrb_rd_snap → **MCP の image content で返す** (ファイル経由不要) |
| tab5_input | commands | fmrb_rd_input へそのまま渡す (`click X Y sleep MS key ctrl+tab ...`) |
| tab5_app | action(launch/ps/kill), path?, pid? | fmrb_rd_launch / ps / kill |
| tab5_fs | action(ls/get/put/push/pull/mkdir/del), 引数 | fmrb_rd_fs へ委譲 |

- description に載せる知見: 座標は FB 系 426x240 / drag は mdown-move-mup /
  タッチは相対移動なので実タッチ検証はユーザ / ユーザが実機操作中の
  可能性があるときは確認してから割り込む / put→launch で再 flash なしの
  開発ループ / 大転送中は remote desktop 配信が止まる。

### Linux sim (P3)

| tool | 入力 | 動作 |
|---|---|---|
| sim_up | gui? | dev_run_check.sh 相当で起動。**PNG サイズを FMRB_HW_TARGET の期待解像度と照合し、不一致なら自動で down/up をもう一周** (解像度持ち越しの罠の吸収) |
| sim_down | - | docker compose down |
| sim_screenshot | wait? | fmrb_screenshot.py → image content |
| sim_input | commands | fmrb_input.rb へ委譲 |
| sim_app | action(launch/ps/kill), path?, pid? | debugd (localhost:5555) の spawn / ps / kill |

- 再起動は常に 3 コンテナまとめて行う (単独 restart を提供しない)。
- description に載せる知見: 新規アプリはランチャー右クリックで再走査 /
  キー判定は scancode / Alt は sim では死んでいる / かな切替は
  Ctrl+Space / 描画反映は 1 テンポ遅れるのでまず撮り直す。

### 載せないもの (CLI のまま)

gdb attach (ハング解析)、fmrb_pngdiff / pngscan、fmrb_audio_probe、
fmrb_midi_monitor、fm_asset_editor、S3 実機 (BLE のみで遠隔経路なし)。

## 5. 実装段階

### P1: シリアル + flash 管理

一番痛い罠 (排他・開きっぱなし・偽陰性) がここに集中しており、単体で
元が取れる。serial_manager と flock、`.mcp.json` 登録、selftest まで。

受け入れ条件:
- capture 稼働中に flash → 自動退避・再開まで人手ゼロで通る
- serial_log を連続で呼んでもボードがリセットされない (POWERON リセットが
  ログに現れないことで確認)
- 2 プロセス目の serial_start が明示エラーになる

### P2: Tab5 遠隔

IP 解決の自前管理と screenshot の image content 化が主眼。

受け入れ条件: CLAUDE.md を読んでいない素の MCP クライアントから
「IP 解決 → アプリ起動 → 画面取得 → kill」の一巡が通る。

### P3: sim ライフサイクル

受け入れ条件: ターゲット切替直後の sim_up が解像度不一致を自動検出して
自己修復する。input + screenshot の往復が通る。

### P4: 知見の移設と手順書の短縮

- 各ツールの description に手順知識を移し終える
- ルート CLAUDE.md の該当節を「MCP ツールを使う。詳細は description」へ
  短縮する (gdb・音・pngdiff など CLI 残留分の記述は残す)
- README (tools/mcp/README.md): 外部利用者向けの導入手順
  (claude mcp add / Claude Desktop の設定例)

## 6. 検証方法

- 各段の受け入れ条件を selftest.rb (サーバをインプロセスで叩く) と
  実機/sim での手動一巡で確認する。
- 「新しい構成は無言の穴を持つ」の教訓どおり、**その構成でしか通らない
  経路を必ず動かす**: flock 衝突 (2 セッション同時)、IP キャッシュ失効、
  解像度不一致の自己修復は、正常系と別に故意に起こして確認する。

## 7. リスクと注意

- **二重メンテ**: ラッパーを薄く保つことで抑える。CLI の引数が変わったら
  委譲部だけ直す。CLI 単体でも従来どおり使えることを壊さない。
- **stdio の多重セッション**: flock で排他するが、「他セッション使用中」
  エラーの体験は悪い。長期的には常駐 1 プロセス + 複数クライアントの
  形態 (HTTP transport) への移行余地を残す (P1 では作らない)。
- **長時間操作**: fs push や flash は分単位でブロックする。MCP クライアント
  側のタイムアウトに合わせ、進捗はログファイルへ、応答には要約だけ返す。
- **WSL 依存**: mDNS 解決が powershell.exe 経由。native Linux では avahi に
  切り替えられるよう lib/tab5.rb 内で吸収する。
- **Asterism との関係**: 網の資源操作は将来 $meta→MCP ブリッジ
  (fmruby-core/doc/ruby_unified/usecases.md 8) が受け持つ可能性があるが、
  flash・シリアル・sim という開発ツール側は Asterism の守備範囲外なので
  競合しない。本サーバは MCP サーバ実装の練習台としてその布石も兼ねる。
