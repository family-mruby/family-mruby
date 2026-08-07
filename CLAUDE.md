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

## 音の確認 (ヘッドレスでもできる)

**スピーカーに出さなくても、音は数値で確認できる**。経路が 2 つある。

### 内蔵音源 (APU) の音を波形で見る

```
ruby tools/fmrb_audio_probe.rb [--duration 秒] [--dump out.wav]
```

- graphics-audio が共有メモリのリングに書いた合成済みの音を読む。
  ピーク・RMS・音のあった窓数を出す。`--dump` で WAV に落とせば
  周波数解析して音高まで測れる。
- ヘッドレス (SDL dummy) でも読める。**音が鳴っているか / 複数の声が
  同時に出ているか**の判定はこれで足りる。

### 外部 MIDI 出力 (シリアル) をバイト列で見る / GM 音源で鳴らす

```
# 1. 受け皿を先に起動する (FIFO fmruby-core/midi_out.fifo をこのツールが作る)
ruby tools/fmrb_midi_monitor.rb [--hex] [--log out.jsonl] [--duration 秒]

# 2. 別途 sim を起動し、MIDI アプリで出力先を serial に切り替える
tools/dev_run_check.sh --keep
#    -> ランチャーか debugd で /app/demo/midi_apu.app.rb を起動
#    -> 「7 Out」を押すと out: serial に切り替わる (緑になる)
#    -> 「1 Scale」等を押すとモニタにバイト列が出る
```

- 出力例: `note on ch1 C4 vel=100 [90 3C 64]` (到着時刻つき)。
  **テンポや音符間隔はこの到着時刻で実測できる** (波形より正確)。
- **GM 音源で実際に鳴らす**なら `--fluidsynth --soundfont /usr/share/sounds/sf2/FluidR3_GM.sf2`。
  WSL2 では ALSA シーケンサが無いので `ttymidi` + `aconnect` の定番経路は使えず、
  fluidsynth のコマンドシェルに流して PulseAudio で鳴らす形になっている。
  必要なパッケージ (Ubuntu 標準リポジトリ。sudo が要るのでユーザに依頼する):

  ```
  sudo apt-get install -y fluidsynth fluid-soundfont-gm
  ```

  `fluidsynth` が本体、`fluid-soundfont-gm` が `/usr/share/sounds/sf2/FluidR3_GM.sf2`
  (GM 音色、142MB) を入れる。容量を惜しむなら `timgm6mb-soundfont` (約 6MB) でも
  音色の割り当て確認には足りる。
  **ホストに入れたくないなら docker で済む**:
  `docker compose -f docker-compose.yml -f docker-compose.wsl.yml
  -f docker-compose.midi.yml up -d` (midi-gm サービスが同じことをする)。
- 注意: **モニタを起動していなくても core 側は詰まらない** (FIFO は
  O_NONBLOCK で開かれ、パイプバッファに溜まる)。後からモニタを起動すると
  溜まった分が読める。
- 詳細と経緯は `fmruby-core/doc/midi/report/p5s.md`。

## 仕組みと注意

- 画面: graphics-audio が POSIX SHM /fmrb_display に RGB332 ダブルバッファを公開
  (fmruby-graphics-audio/main/common/shm_display.h)。
- 入力: sdl2-display が Unix DGRAM ソケット /var/run/fmrb/fmrb_inject を bind し、
  受信したパケット ([type][len16][payload]、fmrb_hid_event.h) を通常の入力ストリームへ
  転送する。実 SDL イベントと注入イベントは同一経路で直列化される。
- sdl2-display/main.c を変更した場合は `docker compose build sdl2-display` が必要。
- 検証を終えたら `docker compose down` で片付ける (dev_run_check.sh のデフォルトは自動 down)。
- ヘッドレス検証で確認できないもの: **音の善し悪し (官能評価)**、NTSC 実出力、実機挙動。
  これらはユーザが確認する。音が「鳴っているか・何 Hz か・何バイト出たか」は
  上記の音の確認で自律的に取れる。S3 実機の flash とブートログ確認も下記の手順でできる。

# ESP32-S3 実機の自律検証 (flash + シリアルログ)

NARYA (S3) が USB 接続されていれば、Claude Code は flash からブートログの
確認まで自律的に行える。作業ディレクトリは fmruby-core。

## 手順

```
rake check-port                     # 初回のみ: S3 のポートを検出して .serial_port にキャッシュ
FLASH_BAUD=115200 rake flash        # 書き込み (460800 は WSL2 で接続に失敗しやすい)
python3 ../tools/fmrb_serial_capture.py -t 40 boot.log   # リセット → 40 秒ログ採取
```

- capture はデフォルトで RTS パルスのリセットを打つので、ログはブートバナー
  から始まる。稼働中の観測は `--no-reset` (ただし open だけでリセットが
  かかるアダプタもある)。ファイルは採取中でも grep できる。
- ブートの健全性は `grep -c "Guru\|abort"` が 0、周期ダンプの
  `IRAM free:` が想定値であることで判定する。

## ログの読み方 (常設計装)

- `grep "M1|"`: ブートステップごとの内蔵 RAM スナップショット
  (`M1|ラベル|internal=..|largest=..|psram=..`)。隣接行の差分が各ステップの
  消費。アプリ起動ごとに `spawn:<名前>` 行も出る (doc/internal_ram_budget.md)。
- 10 秒周期ダンプ: `fmrb_task:` が各タスクの stack high-water (Free 列、
  単調悪化なので最後の値 = セッション最悪値)、`fmrb_app:` が VM プールと
  Spinel の ExcHW (例外/catch スタック深さ)。
- 入力遅延は `spx: hid_lat` (1000 イベントごと)、GFX は `GFX STATS`。

## 注意

- **シリアルポートは排他**。ユーザのログモニタや自分の capture が掴んで
  いると flash が "device reports readiness to read but returned no data"
  で失敗する。flash 前に capture を止める。逆にユーザがモニタを繋ぐと
  ボードがリセットされる (POWERON リセットとしてログに出る)。
- 実機の UI 操作: **Modern (Tab5) は remote desktop 経由で Claude が自律操作
  できる** (下記「Tab5 実機のリモート UI 操作」参照)。S3 (Retro) は不可
  (debugd が BLE のみ、remote desktop なし)。Retro で操作が要る検証は
  Linux sim で行うか、ユーザに操作を依頼してシリアルで結果を観測する。
- Tab5 (P4) は USB-Serial-JTAG (/dev/ttyACM0) 接続なので、esptool の
  自動ダウンロードモード遷移が効き、**ボタンなしで flash できる**
  (通常の ESP32 フロー。2026-08-07 実測)。ただし flash 後のハードリセットは
  効かないことがある: ログが `boot:0x204 (DOWNLOAD...)` + `waiting for
  download` で止まっていたら DL モード滞留なので、そのときだけユーザに
  ボタンリセットを依頼する (ブートループ等と誤診しない)。USB が列挙される
  前にクラッシュする firmware を焼いた場合も、手動で DL モードに入れて
  もらう必要がある。
- ビルドの罠: lib/ を編集したら `rake clean`、ターゲット切替 (linux⇔esp32)
  は `rake clean_all`。`rake build:linux` は esp32 の build/ が残っていると
  **Xtensa のまま "Linux build complete" と表示する**ので、検証と主張する
  前に `file build/fmruby-core.elf` で x86-64 を確認する。

## Tab5 実機のリモート UI 操作 (remote desktop 経由)

Modern (Tab5) が WiFi に接続していれば、Claude は実機の UI 操作と画面確認を
sim と同様に自律的に行える (シリアル接続すら不要)。

## IP の確認 (毎回変わるので固定値を使わない)

DHCP なので IP はブートごとに変わりうる。次のいずれかで毎回取得する:

```
# 1. mDNS (推奨。WSL からは Windows resolver 経由で引く)
powershell.exe -Command "(Resolve-DnsName fmruby.local -ErrorAction SilentlyContinue | Where-Object Type -eq 'A').IPAddress"

# 2. シリアルが繋がっているならブートログから
#    "rd_http: Remote desktop ready: http://<IP>/" の行

# 3. 取得した IP の確認 (JSON に ip フィールドがある)
curl -s http://<IP>/status
```

## 操作と画面取得

```
ruby tools/fmrb_rd_input.rb <IP> click X Y | dclick X Y | key ctrl+tab | sleep MS ...
ruby tools/fmrb_rd_snap.rb <IP> out.jpg    # MJPEG から 1 フレーム取得
```

- 座標はフレームバッファ系 (426x240)。ウィンドウ拡大とは無関係。
- キーは fmrb_rd_input.rb 冒頭の SCAN 表 (HID Usage ID) に定義があるものだけ。
  足りなければ表に追記する (modifier は ctrl+ プレフィックス、LCTRL=0x04)。
- 実装: /ws WebSocket に rd_input.c のバイナリメッセージを直接送る。
  入力はファームの通常経路 (fmrb_host_send_*) に合流するので、
  Ctrl+Q / Ctrl+Tab などのグローバルホットキーも効く。
- 実績: ランチャーのスクロール込みのアプリ起動、Ctrl+Tab 退避/復帰、
  Ctrl+Q 終了、タイマー挙動の 60 秒実測まで全て遠隔で実施済み (2026-08-07)。
- 注意: 送った操作はユーザが実機を触っているのと同じ扱いになる。ユーザが
  実機を操作中の可能性があるときは、割り込む前に一言確認する。

# 周辺ツールの言語

本プロジェクトの周辺ツール (検証・生成・変換スクリプト) は、**可能なものは
Ruby で書く**。ビルドが Rake で回っており、実機で動く言語も Ruby (mruby /
PicoRuby) なので、道具立てを揃えるほうが読み書きしやすいため。

- 新規ツールは原則 Ruby。既存の Python ツールも、標準ライブラリだけで
  書き直せるものは Ruby へ移す (例: tools/fmrb_input.rb)。
- Python のままにしてよいのは、置き換えに外部ライブラリ相当の実装が要る
  もの: 画像処理 (Pillow を使う PNG 生成・BMP 変換)、既存の Python 資産に
  依存するもの (debugd クライアント tool/debug/fmrb_dbg_client.py とその
  利用ツール)、シリアルの RTS/DTR 制御 (pyserial を使う
  tools/fmrb_serial_capture.py。esptool 経由で pyserial は既にホスト依存)。
- コンテナ内で実行する部分は、そのイメージに入っている言語に合わせる
  (ESP-IDF イメージには python3 はあるが ruby は無い)。

