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
  `key NAME` (a-z 0-9 enter esc tab space backspace up down left right f1-f12 /
  home end pageup pagedown insert delete / zenkaku katakana) /
  `key shift+NAME` / `text "STRING"` / `sleep MS`。左から順に実行される。
- **かな入力の検証**: かなモードの on/off は `key ctrl+space` (どの配列でも
  効く) か `key zenkaku` (半角/全角。**jp 配列のときだけ**。US 配列では
  `` ` `` の実キーなので奪わない)。ひらがな⇔カタカナは `key katakana`
  (0x88。JIS のみ) か、**指示器のクリック**。半角/全角と Ctrl+Space は
  修飾キーを見ない (off へ必ず戻れるようにするため)。
- **注意: sim の GUI で実キーボードの半角/全角・カタカナキーは効かない**。
  X11 がこの 2 キーを「押しっぱなし」のまま扱い、以後の押下がオートリピート
  と区別できなくなるため、sdl2-display で捨てている (押すとその旨のログが
  出る)。**GUI で手で操作するときは Ctrl+Space か指示器のクリック**を使う。
  実機 (USB HID) では普通に効く。上記 `key zenkaku` の注入は別経路なので
  従来どおり動く。
  かなモード中は `text` がそのままローマ字入力になる
  (`text "ka"` → か、`text "kya"` → きゃ)。**ローマ字合成はレイアウトに
  依存しない** (a-z の scancode は US/JP 共通)。
- **モード表示と切替 (クリック)**: エディタのステータス行右端の
  `[A]/[あ]/[ア]` と、デスクトップのメニューバー右 (空きメモリ表示の左) の
  指示器。**どちらもクリックで A→あ→ア→A と巡回する**ので、キーボードに
  かなキーが無くても切り替えられる。指示器は language=ja なら起動時から
  出る (en ではかなモードを一度使うまで出ない)。
  ログで確かめるなら `docker logs fmruby_core | grep "kana mode"`
  (`kana mode=1 (sc=0x2c mod=0x04)` のように、合成層が受け取った
  scancode/修飾キーごと出る)。
- 座標はフレームバッファ座標。ウィンドウ拡大率とは無関係。**sim の解像度は
  .env の FMRB_HW_TARGET に連動する**: Retro 系 (NARYAv3 等) は 320x240、
  Modern 系 (TAB5 / NARYAv4) は 426x240 (Rakefile が
  config/system_conf_linux_p4.toml を選ぶ)。実際の値は
  fmrb_screenshot.py が出す PNG のサイズで確認できる。
  注意: graphics-audio は解像度を flash/etc/display_conf_linux.txt に
  覚えており**変更は次回起動から効く**ので、ターゲットを切り替えた直後の
  1 回目はまだ前の解像度で上がる (もう一度 down/up する)。
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

## sim のハング/クラッシュ調査 (gdb を後から当てる)

core がログを出さなくなった・固まった、というときは**再起動する前に**
ハング中のプロセスへ gdb を当てて全スレッドの backtrace を取る。Linux sim
最大の強み (実機ではできない事後解析) なので、状態を捨てないこと。

```
# 1. コンテナ内の PID を確認 (通常 101。1 と 7 は init/sh)
docker exec fmruby_core bash -c "ps aux | grep fmruby-core.elf"

# 2. 同じ PID 名前空間にデバッグ用コンテナを同居させて attach
docker run --rm -u root --pid=container:fmruby_core --cap-add=SYS_PTRACE \
  -v $(pwd)/fmruby-core:/project ghcr.io/family-mruby/fmruby-esp32-build:v5.5.4 \
  bash -c "gdb -batch -ex 'set pagination off' \
    -ex 'set sysroot /proc/101/root' \
    -ex 'file /project/build/fmruby-core.elf' -ex 'attach 101' \
    -ex 'thread apply all bt 14'"
```

- ptrace はコンテナ内 (root でも) 封じられているため、`--pid=container:` +
  `--cap-add=SYS_PTRACE` の**別コンテナ同居**が唯一の経路。attach は
  非破壊で、detach 後プロセスは続行する。
- **`set sysroot /proc/<PID>/root` が肝**。相手コンテナの libc を /proc
  経由で読ませないとシンボルが出ず、FreeRTOS タスクの巻き戻しが
  0xa5a5... (スタックフィル) で切れる。ELF は `file` で明示する。
- FreeRTOS Linux ポートの読み方: ほぼ全スレッドが event_wait
  (prvSuspendSelf) で眠っているのが正常。見るべきは **FreeRTOS の待ちで
  ないもの** — pthread_mutex / futex / glibc 内部ロックで止まっている
  スレッドと、`<signal handler called>` を挟んで suspend されたスレッド
  (= 何かを保持したまま preempt された疑い)。この組が揃えば優先度逆転
  (実例と機序: fmruby-core/doc/sim_log_deadlock.md)。
- graphics-audio 側も同じ手が使える (`--pid=container:fmruby_graphics_audio`、
  ELF は fmruby-graphics-audio/build のもの)。

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
ruby tools/fmrb_rd_input.rb <IP> click X Y | dclick X Y | mdown X Y | mup X Y |
                                 move X Y | drag X1 Y1 X2 Y2 | key ctrl+tab | sleep MS ...
ruby tools/fmrb_rd_snap.rb <IP> out.jpg    # MJPEG から 1 フレーム取得
```

- 座標はフレームバッファ系 (426x240)。ウィンドウ拡大とは無関係。
- キーは fmrb_rd_input.rb 冒頭の SCAN 表 (HID Usage ID) に定義があるものだけ。
  a-z / 0-9 / 矢印 / tab / esc / enter / space はある。足りなければ表に追記する
  (modifier は ctrl+ プレフィックス、LCTRL=0x04)。
- `drag` は窓の移動用。ボタンを押したまま実際にポインタを動かさないと
  タイトルバーは追従しないので、click では窓は動かせない。
  掴む前にその窓をクリックしてフォーカスを当てること。
- 実装: /ws WebSocket に rd_input.c のバイナリメッセージを直接送る。
  入力はファームの通常経路 (fmrb_host_send_*) に合流するので、
  Ctrl+Q / Ctrl+Tab などのグローバルホットキーも効く。
- 実績: ランチャーのスクロール込みのアプリ起動、Ctrl+Tab 退避/復帰、
  Ctrl+Q 終了、タイマー挙動の 60 秒実測まで全て遠隔で実施済み (2026-08-07)。
- 注意: 送った操作はユーザが実機を触っているのと同じ扱いになる。ユーザが
  実機を操作中の可能性があるときは、割り込む前に一言確認する。

## アプリの起動 / 終了 / 一覧 (WiFi 直接制御)

**アプリを起動するのにランチャーを操作する必要はない**。パス指定で直接起動・
終了・一覧できる (rd_http の開発用エンドポイント。`FMRB_DEV_REMOTE_CTL` で
囲われ既定 ON、リリースは OFF。計画・経緯は
`fmruby-core/doc/dev_remote_ctl/plan.md`)。

```
ruby tools/fmrb_rd_launch.rb <IP> <path>   # 例 /app/demo/spinel_hello.app.rb。pid を返す
ruby tools/fmrb_rd_ps.rb     <IP>          # 稼働アプリ一覧 (pid / name / state)
ruby tools/fmrb_rd_kill.rb   <IP> <pid>    # 終了。kernel(pid 0) は 400 で拒否 (ユーザアプリのみ)
```

- curl でも叩ける: `POST /app/launch?path=` / `GET /app/list` / `POST /app/kill?pid=`。
- 典型手順: `fmrb_rd_ps` で現況 → `fmrb_rd_launch` で目的アプリを起動 →
  `fmrb_rd_snap` で画面確認 → 用が済んだら `fmrb_rd_ps` で pid を見て `fmrb_rd_kill`。
  **ランチャーのスクロール/矢印ナビはもう不要**。
- **ログはこの経路に載っていない**。クラッシュ時は WiFi ごと落ちるため。crash/boot
  ログは、セッション開始時に開いて開きっぱなしにしたシリアルで取る (見たい時だけ
  開くとリセットがかかる)。
- P4 (Modern) 限定。S3 (Retro) は remote desktop が無いので不可。

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

