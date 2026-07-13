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
python3 tools/fmrb_input.py <コマンド列>
```

- コマンド: `move X Y` / `click X Y [--button N]` / `down X Y` / `up X Y` /
  `key NAME` (a-z 0-9 enter esc tab space backspace up down left right f1-f12) /
  `key shift+NAME` / `text "STRING"` / `sleep MS`。左から順に実行される。
- 座標はフレームバッファ座標 (320x240)。ウィンドウ拡大率とは無関係。
- 例: メニューを開いて Launcher を選択 → アイコンをダブルクリックで起動:
  ```
  python3 tools/fmrb_input.py click 20 5 sleep 500 click 15 17
  python3 tools/fmrb_input.py click 30 55 sleep 120 click 30 55   # ダブルクリック
  python3 tools/fmrb_input.py text "help" key enter
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

