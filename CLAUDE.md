# 基本方針

本プロジェクトは、以下の２つのgitリポジトリから構成されている。

- fmruby-core
- frmuby-graphics-audio

ビルドはそれぞれのリポジトリで行う。

## fmruby-core

fmruby-core/CLAUDE.md を参照する

## fmruby-graphics-audio

fmruby-graphics-audio/CLAUDE.md を参照する

# 自律検証ツール (Linuxシミュレーション)

Claude Code は GUI なしで Linux シミュレーションの起動・画面確認・入力操作まで自律的に行える。
実行前に両リポジトリのビルド (rake build:linux) が済んでいること。

## 起動 + スクリーンショット

```
tools/dev_run_check.sh [--gui] [--keep] [出力.png]
```

- ヘッドレス (SDL dummy driver、ウィンドウ非表示) で docker compose up -d し、
  core のブートマーカー (`main_loop started`) を待ってから画面を PNG 化する。
- デフォルトは撮影後に down する。`--keep` で起動維持 (続けて操作・撮影する場合)。
- すでにスタックが稼働中 (ユーザが docker compose up 中など) の場合は再利用し、down しない。
- `--gui` で通常の X11 ウィンドウあり起動。

## 画面キャプチャのみ (稼働中スタックから)

```
python3 tools/fmrb_screenshot.py [--wait 秒] 出力.png
```

- 共有メモリ /dev/shm/fmrb_display (RGB332) の完成フレームを PNG 化する。
- Docker Desktop ではホストから SHM が見えないため docker exec 経由に自動フォールバックする。
- ユーザの GUI 実行中に横からキャプチャすることも可能。

## 入力注入 (合成マウス/キーボードイベント)

```
ruby tools/fmrb_input.rb <コマンド列>
```

- コマンド: `move X Y` / `click X Y [--button N]` / `down X Y` / `up X Y` /
  `key NAME` (a-z 0-9 enter esc tab space backspace up down left right f1-f12) /
  `key shift+NAME` / `text "STRING"` / `sleep MS`。左から順に実行される。
- 座標はフレームバッファ座標 (320x240)。ウィンドウ拡大率とは無関係。
- `text` / `key` の文字→キー変換はファームウェアの変換表
  (fmruby-core/main/drivers/usb/fmrb_keymap.c) を読んで逆引きし、配列は
  config/system_conf_linux.toml の `keyboard_layout` に追従する
  (`--layout us|jp` で上書き)。記号を打つときはこれが効く。
- 例: メニューを開いて Launcher を選択 → アイコンをダブルクリックで起動:
  ```
  ruby tools/fmrb_input.rb click 20 5 sleep 500 click 15 17
  ruby tools/fmrb_input.rb click 30 55 sleep 120 click 30 55   # ダブルクリック
  ruby tools/fmrb_input.rb text "help" key enter
  ```
- 操作後は fmrb_screenshot.py で画面を撮って結果を確認する。

## 仕組みと注意

- 画面: graphics-audio が POSIX SHM /fmrb_display に RGB332 ダブルバッファを公開
  (fmruby-graphics-audio/main/common/shm_display.h)。
- 入力: sdl2-display が Unix DGRAM ソケット /var/run/fmrb/fmrb_inject を bind し、
  受信したパケット ([type][len16][payload]、fmrb_hid_event.h) を通常の入力ストリームへ
  転送する。実 SDL イベントと注入イベントは同一経路で直列化される。
- sdl2-display/main.c を変更した場合は `docker compose build sdl2-display` が必要。
- 検証を終えたら `docker compose down` で片付ける (dev_run_check.sh のデフォルトは自動 down)。
- ヘッドレス検証で確認できないもの: 音声出力、NTSC 実出力、実機挙動。これらはユーザが確認する。

## 周辺ツールの言語

本プロジェクトの周辺ツール (検証・生成・変換スクリプト) は、**可能なものは
Ruby で書く**。ビルドが Rake で回っており、実機で動く言語も Ruby (mruby /
PicoRuby) なので、道具立てを揃えるほうが読み書きしやすいため。

- 新規ツールは原則 Ruby。既存の Python ツールも、標準ライブラリだけで
  書き直せるものは Ruby へ移す (例: tools/fmrb_input.rb)。
- Python のままにしてよいのは、置き換えに外部ライブラリ相当の実装が要る
  もの: 画像処理 (Pillow を使う PNG 生成・BMP 変換)、既存の Python 資産に
  依存するもの (debugd クライアント tool/debug/fmrb_dbg_client.py とその
  利用ツール)。
- コンテナ内で実行する部分は、そのイメージに入っている言語に合わせる
  (ESP-IDF イメージには python3 はあるが ruby は無い)。

