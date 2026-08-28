# 基本方針

本プロジェクトは、以下の２つのgitリポジトリから構成されている。

- fmruby-core
- frmuby-graphics-audio

ビルドはそれぞれのリポジトリで行う。

## fmruby-core

fmruby-core/CLAUDE.md を参照する

## fmruby-graphics-audio

fmruby-graphics-audio/CLAUDE.md を参照する

# 検証ツール (MCP サーバ fmrb)

sim・実機の検証操作は MCP サーバ **fmrb** (tools/mcp/、リポジトリ直下の
.mcp.json で登録済み) のツールを使う。**手順と注意は各ツールの description に
書いてある**ので、ここには載っていない細部はまずそちらを読む。導入・一覧は
tools/mcp/README.md、経緯は doc/mcp_tools/。

| 対象 | ツール |
|---|---|
| シリアル + flash (S3/Tab5) | serial_start / serial_log / serial_stop / flash |
| Tab5 遠隔 (WiFi) | tab5_ip / tab5_screenshot / tab5_input / tab5_app / tab5_fs |
| Linux sim | sim_up / sim_down / sim_screenshot / sim_input / sim_app |

運用の決まりごと (ポートの排他と開きっぱなし、flash 時の capture 退避、
sim の偽グリーン遮断・3 コンテナ一括・解像度持ち越しの自己修復、Tab5 の
IP 解決) は**サーバがコードで守る**。手でやり直さない。

CLI (tools/ 直下のスクリプト群) は従来どおり残っており、MCP の無い環境や
ad-hoc な組み合わせ (ログの複雑な grep、パイプ) ではそのまま使える。
以下の節は、MCP ツールの description に**載っていない**知識だけを残す。

# Linux シミュレーションの検証

sim_up で起動 (最初の 1 枚が返る) → sim_input / sim_app / sim_screenshot で
操作と確認 → sim_down で片付け。実行前に両リポジトリのビルド
(rake build:linux) が済んでいること (stale な esp32 ビルドは sim_up が
起動前に拒否する)。

## かな入力の検証 (sim 特有の細部)

- かなモードの on/off は `key ctrl+space` (どの配列でも効く) か
  `key zenkaku` (jp 配列のときだけ。US 配列では `` ` `` の実キーなので
  奪わない)。ひらがな⇔カタカナは `key katakana` (0x88。JIS のみ) か
  **指示器のクリック**。半角/全角と Ctrl+Space は修飾キーを見ない
  (off へ必ず戻れるようにするため)。
- **モード表示と切替 (クリック)**: エディタのステータス行右端の
  `[A]/[あ]/[ア]` と、デスクトップのメニューバー右 (空きメモリ表示の左) の
  指示器。**どちらもクリックで A→あ→ア→A と巡回する**。指示器は
  language=ja なら起動時から出る (en ではかなモードを一度使うまで出ない)。
- **sim の GUI で実キーボードの半角/全角・カタカナキーは効かない**。X11 が
  この 2 キーを押しっぱなし扱いにするため sdl2-display で捨てている。
  GUI で手で操作するときは Ctrl+Space か指示器のクリック。実機 (USB HID)
  では普通に効く。注入の `key zenkaku` は別経路なので従来どおり動く。
- かなモード中は `text` がローマ字入力になる (`text "kya"` → きゃ)。
  ローマ字合成はレイアウトに依存しない (a-z の scancode は US/JP 共通)。
  ログで確かめるなら `docker logs fmruby_core | grep "kana mode"`。
- `text` / `key` の文字→キー変換はファームウェアの変換表
  (fmruby-core/main/drivers/usb/fmrb_keymap.c) を読んで逆引きし、配列は
  config/system_conf_linux.toml の `keyboard_layout` に追従する。
  記号を打つときはこれが効く。

## 音の確認 (ヘッドレスでもできる)

**スピーカーに出さなくても、音は数値で確認できる**。経路が 2 つある
(いずれも CLI のまま)。

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
#    (sim_up → sim_app で /app/demo/midi_apu.app.rb を起動 → 「7 Out」で
#     out: serial、「1 Scale」等でモニタにバイト列が出る)
```

- 出力例: `note on ch1 C4 vel=100 [90 3C 64]` (到着時刻つき)。
  **テンポや音符間隔はこの到着時刻で実測できる** (波形より正確)。
- **GM 音源で実際に鳴らす**なら `--fluidsynth --soundfont /usr/share/sounds/sf2/FluidR3_GM.sf2`。
  WSL2 では ALSA シーケンサが無いので fluidsynth のコマンドシェルに流して
  PulseAudio で鳴らす形。パッケージは `sudo apt-get install -y fluidsynth
  fluid-soundfont-gm` (sudo が要るのでユーザに依頼する)。ホストに入れたく
  なければ `docker compose -f docker-compose.yml -f docker-compose.wsl.yml
  -f docker-compose.midi.yml up -d` (midi-gm サービスが同じことをする)。
- **モニタを起動していなくても core 側は詰まらない** (FIFO は O_NONBLOCK。
  後からモニタを起動すると溜まった分が読める)。
- 詳細と経緯は `fmruby-core/doc/midi/report/p5s.md`。

## 仕組みと注意

- 画面: graphics-audio が POSIX SHM /fmrb_display に RGB332 ダブルバッファを公開
  (fmruby-graphics-audio/main/common/shm_display.h)。
- 入力: sdl2-display が Unix DGRAM ソケット /var/run/fmrb/fmrb_inject を bind し、
  受信したパケット ([type][len16][payload]、fmrb_hid_event.h) を通常の入力ストリームへ
  転送する。実 SDL イベントと注入イベントは同一経路で直列化される。
- sdl2-display/main.c を変更した場合は `docker compose build sdl2-display` が必要。
- ヘッドレス検証で確認できないもの: **音の善し悪し (官能評価)**、NTSC 実出力、
  実機挙動、実タッチ (Tab5 のタッチは相対移動)。これらはユーザが確認する。

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

# 実機の検証 (S3 / Tab5)

## flash とシリアルログ

serial_start でシリアルを開きっぱなしにし、serial_log で読む。flash は
ビルド済み firmware を焼き、capture の退避・再開・ブート要約まで自動で行う
(ビルド自体は各リポジトリで rake build:esp32。ターゲットは fmruby-core/.env
の FMRB_HW_TARGET)。

- **シリアルの機種差 (2026-08-29 実測)**: Tab5 (USB-Serial-JTAG 内蔵) は
  **ポートを開くだけでチップがリブートする** (`rst:0x17`。`--no-reset` でも
  避けられない)。よって Tab5 では「稼働中を横から覗く」は不可能で、
  開きっぱなし運用が唯一の観測手段。しかも `reset: false` の方がバナーから
  採れる (`reset: true` は 2 回目のリセットの USB 再列挙でバナーを失う)。
  S3 (外付け USB-UART ブリッジ) は従来どおりで、`--no-reset` なら稼働中に
  attach できる。
- ユーザのログモニタとの排他は残る: サーバは自分の capture しか管理しない
  ので、ユーザがモニタを繋いでいると flash は失敗するし、逆にユーザが
  モニタを繋ぐとボードがリセットされる (POWERON としてログに出る)。
- ボードが /dev に見えないときは usbipd 待ち: fmruby-core で `rake attach`
  (Windows 側権限が要るのでユーザに依頼する)。

## ログの読み方 (常設計装)

- `M1|`: ブートステップごとの内蔵 RAM スナップショット
  (`M1|ラベル|internal=..|largest=..|psram=..`)。隣接行の差分が各ステップの
  消費。アプリ起動ごとに `spawn:<名前>` 行も出る (doc/internal_ram_budget.md)。
- 10 秒周期ダンプ: `fmrb_task:` が各タスクの stack high-water (Free 列、
  単調悪化なので最後の値 = セッション最悪値)、`fmrb_app:` が VM プールと
  Spinel の ExcHW (例外/catch スタック深さ)。
- 入力遅延は `spx: hid_lat` (1000 イベントごと)、GFX は `GFX STATS`。
- ブートの健全性は crash マーカー (`Guru|abort`) 0 件と、周期ダンプの
  `IRAM free:` が想定値であること。

## 注意

- 実機の UI 操作: **Modern (Tab5) は tab5_* ツールで Claude が自律操作
  できる**。S3 (Retro) は不可 (debugd が BLE のみ、remote desktop なし)。
  Retro で操作が要る検証は Linux sim で行うか、ユーザに操作を依頼して
  シリアルで結果を観測する。
- ビルドの罠: lib/ を編集したら `rake clean`、ターゲット切替 (linux⇔esp32)
  は `rake clean_all`。`rake build:linux` は esp32 の build/ が残っていると
  **Xtensa のまま "Linux build complete" と表示する** (sim_up は起動前に
  検査して拒否するが、検証と主張する前に自分でも
  `file build/fmruby-core.elf` で確認する)。

## Tab5 遠隔 (WiFi)

tab5_app でパス起動/一覧/kill、tab5_screenshot で画面、tab5_input で操作、
tab5_fs でファイル転送。IP は tab5_ip が解決する (固定値を使わない)。
put → launch が**再 flash なしの開発ループ**。

MCP に載せていない部分:

- `ruby tools/fmrb_rd_fs.rb <IP>` の**対話モード** (FTP 風:
  cd/lcd/ls/get/put/pull/push/cat/launch/ps。端末側と PC 側に別々の
  カレントディレクトリ。対話モードの rmr は確認を求める)。
- curl 直叩き: `POST /app/launch?path=` / `GET /app/list` /
  `POST /app/kill?pid=`、fs 系は `/fs/list` `/fs/get` `/fs/put` `/fs/del`
  `/fs/mkdir`。いずれも `FMRB_DEV_REMOTE_CTL` 配下 (既定 ON、リリース OFF、
  無認証)。計画・経緯は `fmruby-core/doc/dev_remote_ctl/plan.md`。
- tab5_input のキーが足りないときは fmrb_rd_input.rb 冒頭の SCAN 表
  (HID Usage ID) に追記する (modifier は ctrl+ プレフィックス、LCTRL=0x04)。
- **ログはこの経路に載っていない** (クラッシュ時は WiFi ごと落ちる)。
  crash/boot ログはシリアル (serial_start / serial_log) で取る。

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
