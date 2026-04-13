# RubyKaigi 2026 プレゼンテーション素材メモ

**タイトル**: PicoRuby as a Multi-VM Operating System
**発表者**: Katsuhiko Kageyama (@kishima)
**日時**: Day 1 (4/22) 14:50-15:20 Small Hall

---

## 1. プロジェクト概要

Family mruby は ESP32 マイコン上で動作する FreeRTOS ベースのマルチVM OS。
PicoRuby を中心に、Lua / BASIC / Native C の4種類のVMを同一システム上で管理する。

### ハードウェア構成
- **ESP32-S3-N16R8**: メインCPU (mruby実行、USB Host、カーネル)
- **ESP32-WROVER-E/IE**: グラフィクス・オーディオ専用プロセッサ
- **Naryaボード**: 独自基板

### なぜデュアルMCUか
- 1チップではNTSC映像生成 + APUオーディオ合成 + mruby VM実行のリソースが足りない
- 責務分離: 計算(S3) vs マルチメディア(WROVER)で独立にスケーリング可能
- NTSC/I2Sはリアルタイム性が厳しく、VMのGCポーズ等と共存しにくい

---

## 2. OS としてのアーキテクチャ

### プロセスモデル
```
FREE -> INIT -> RUNNING <-> SUSPENDED
                  |
                STOPPING -> FREE
```
- プロセスごとにVMインスタンス + 専用メモリアロケータ (estalloc)
- FreeRTOSタスクとして動作、優先度・コアアフィニティ制御可能
- 世代カウンタでスロット再利用を安全に管理

### アプリケーション種別
| 種別 | 説明 | 例 |
|------|------|----|
| KERNEL | システムカーネル | カーネルタスク |
| SYSTEM_APP | システムアプリ (プリコンパイル済) | デスクトップ、シェル、エディタ |
| USER_APP | ユーザーアプリ (ファイルから読込) | Rubyスクリプト |

### VM種別
| VM | 用途 |
|----|------|
| FMRB_VM_TYPE_MRUBY | PicoRuby (主力) |
| FMRB_VM_TYPE_LUA | Lua VM |
| FMRB_VM_TYPE_BASIC | BASICインタプリタ |
| FMRB_VM_TYPE_NATIVE | ネイティブC関数 |

### ロードモード
- **BYTECODE**: プリコンパイル済 irep (システムアプリ用、起動が速い)
- **FILE**: ソースファイルから読み込みオンデマンドコンパイル (ユーザーアプリ用)

### 組み込みシステムアプリ
- System Desktop (ウィンドウ管理)
- Shell (対話REPL)
- Editor (テキスト編集)
- Config (システム設定)
- System Overlay (システムUI)

---

## 3. SPI通信プロトコルスタック (4層)

デュアルMCU間の通信を支える独自設計のプロトコル。

### Layer 1: SPI Driver Layer
- 256バイト固定フレーム (6B header + 248B payload + 2B CRC16)
- フルデュプレックス、10MHz
- GPIOハンドシェイク (HANDSHAKE / DATA_READY)

### Layer 2: HAL Link Layer
- COBS (Consistent Overhead Byte Stuffing) エンコーディング
  - 0x00デリミタによるフレーム境界検出
  - オーバーヘッド: 入力長の約0.4%
- CRC16-CCITT (poly 0x1021) による整合性検証
- チャネル抽象化: GRAPHICS (0), AUDIO (1)

### Layer 3: Transport Layer
- シーケンス番号による順序保証
- ACK/NACK + 再送制御 (ACK_REQUIRED フラグ)
- send_async (コールバック) / send_sync (ブロッキング) API
- バッチ送信: 複数メッセージを1 SPIフレームにパッキング
- フラグメンテーション: 大きなペイロードの自動分割・再構築

### Layer 4: Application Layer (MessagePack)
- MessagePackシリアライズによる型安全なメッセージ交換
- メッセージタイプ:
  - CONTROL (0x01): バージョンネゴシエーション、ディスプレイ初期化
  - GRAPHICS (0x02): LovyanGFX互換描画コマンド
  - AUDIO (0x04): NSF/FMSQプレイバック制御
  - FILE_TRANSFER (0x05): ファイル同期 (CRC32チェック + 転送)
  - INPUT (0x80): HIDイベント (Linux環境)

### SPIフレーム構造
```
[magic:1B][seq:1B][ack_seq:1B][status:1B][data_len:2B][data:248B][crc16:2B]
 = 256 bytes
```

### 設計判断のポイント
- なぜCOBS?: ゼロバイトデリミタで確実なフレーム同期。UARTでも流用可能
- なぜMessagePack?: JSONより軽量、型情報付き。組み込みのメモリ制約に適合
- なぜ4層分離?: 各層を独立にテスト・差し替え可能 (ESP32 SPI ↔ POSIX Socket)

---

## 4. hw_proxy: ハードウェア制約がアーキテクチャを決めた例

### 問題
ESP32-S3でPSRAMスタック上のタスクからLittleFS等のファイルI/O (stat, fopen, fread) を呼ぶと **WDTリセット** (ウォッチドッグタイマーによるクラッシュ) が発生。

### 原因
SPI flashのDMA転送は**内部RAM上のバッファ**を要求する。しかしPSRAMスタック上のローカル変数はPSRAMアドレス空間 (0x3C000000~0x3DFFFFFF) にあるため、DMAが正しく動作しない。

### 解決策: hw_proxy タスク
- 内部RAMスタック上 (Core 0) で動作する専用タスク
- ファイルI/Oを代行
- 呼び出し元のスタックポインタアドレスで自動判定:
  - `addr >= 0x3C000000 && addr < 0x3E000000` → PSRAMなのでプロキシへ委譲
  - それ以外 → 直接実行
- Mutex + Semaphore で同期

### 発表での意義
- ハードウェアの物理的制約がソフトウェアアーキテクチャを決定する典型例
- メモリアドレスを見て動的にディスパッチを切り替える設計はWeb開発では出てこない
- 組み込みOS設計ならではの知見

---

## 5. グラフィクスパイプライン

### 描画アーキテクチャ
- **ESP32**: LovyanGFX → CVBS (NTSC-J) 出力
- **Linux**: SDL2 レンダリング (シミュレーション)
- マルチキャンバス + Z-order合成
- ダブルバッファリング (draw_buffer / render_buffer)
- 16x16 マウスカーソルスプライト

### 描画コマンド (Ruby API → SPI → WROVER)
- ウィンドウ管理: CREATE_WINDOW, SET_WINDOW_ORDER
- プリミティブ描画: PIXEL, LINE, RECT, CIRCLE, ARC, TRIANGLE (+ FILL版)
- テキスト: DRAW_STRING, DRAW_CHAR, SET_TEXT_SIZE/COLOR
- キャンバス: CREATE/DELETE_CANVAS, SET_TARGET, PUSH_CANVAS
- 画像: CREATE_IMAGE_FROM_FILE, DRAW_IMAGE

### 設計ポイント
- アプリごとに独立キャンバス → 他のアプリの描画を壊さない
- Z-orderでホストタスクがフレームごとに合成 → ウィンドウシステムの実現

---

## 6. オーディオパイプライン

### アーキテクチャ
- **NES APUエミュレータ** (nofrendo由来) による音声合成
- I2S出力 (ESP32) / SDL2 Audio (Linux)
- NSF (NES Sound Format) / FMSQ (独自フォーマット) 対応

### FMSQ (Family mruby Sequence) フォーマット
- APUレジスタ書き込み (REG_WRITE) + フレーム同期 (WAIT@60Hz) のバイナリシーケンス
- ROMストレージに最適化されたコンパクト表現
- nsf2fmsq変換ツール: game-music-emu + 6502エミュレータで変換

### オーディオ管理の設計
- カーネルがサウンドを排他リソースとして一元管理
- 複数アプリからの再生要求を仲裁
- パイプライン: App(Ruby) → Kernel(Ruby, 排他管理) → Host Task(C) → WROVER(APU)

---

## 7. ファイルシステムとファイル同期

### ストレージ構成 (LittleFS)
```
/boot/    - ブートイメージ
/bin/     - 実行スクリプト
/lib/     - ライブラリ
/etc/     - 設定 (system_conf.toml, hid_devices.toml)
/usr/share/ - データ (サウンド、リソース)
/home/    - ユーザーファイル
/app/     - サンプルアプリ (mruby, Lua, BASIC)
```

### S3 → WROVER ファイル同期
- system_conf.toml の [[sync_files]] で同期対象を定義
- FILE_CMD_STATUS (CRC32チェック) で差分検出
- FILE_CMD_TRANSFER で必要なファイルのみ転送
- ホスト起動完了後に自動実行

---

## 8. Docker シミュレーション環境

### 構成
- **fmruby-graphics-audio コンテナ**: グラフィクス・オーディオシミュレーション (SDL2)
- **fmruby-core コンテナ**: メインOS
- **IPC**: Unixドメインソケット (/var/run/fmrb/)
- X11/PulseAudioフォワーディング (WSL2対応)
- ヘルスチェック: ソケットファイルの存在確認

### Linux環境での差し替え
| ESP32 | Linux |
|-------|-------|
| SPI (GPIO handshake) | Unix domain socket |
| LovyanGFX CVBS | SDL2 window |
| I2S audio | SDL2 audio |
| LittleFS on flash | LittleFS on file |

### 発表での意義
- 同一コードベースでESP32とLinuxの両方をサポート
- HAL層の抽象化が実機なしのデモ・開発・テストを可能にしている
- RubyKaigi会場で実機がなくてもDocker環境でライブデモ可能

---

## 9. PicoRuby統合: mrbgems

ESP32向けにポーティングされたmrbgems:

| gem | 機能 |
|-----|------|
| picoruby-fmrb-app | アプリライフサイクル管理 |
| picoruby-fmrb-kernel | カーネル/OSインターフェース |
| picoruby-fmrb-msgpack | MessagePackシリアライズ |
| picoruby-gpio | GPIO制御 |
| picoruby-spi | SPI通信 |
| picoruby-uart | UART通信 |
| picoruby-i2c | I2C通信 |
| picoruby-pwm | PWM制御 |
| picoruby-rmt | RMT (赤外線等) |
| picoruby-mbedtls | 暗号化 |
| picoruby-machine | RTOS タスク/スレッド管理 |
| picoruby-env | 環境変数 |
| picoruby-io-console | コンソールI/O |

### VM設定
- MRB_TICK_UNIT=5, MRB_TIMESLICE_TICK_COUNT=10 (タイムスライス)
- MRB_INT64 (64ビット整数)
- PICORB_ALLOC_ESTALLOC (専用アロケータ)

---

## 10. AI (Claude) との協業プロセス

### 開発の分担
- **人間 (kishima)**: システム設計、アーキテクチャ決定、ハードウェア選定、要件定義
- **AI (Claude)**: コード実装、デバッグ支援、テスト

### AIツール活用の実態
- 設計判断は全て人間が行い、AIは実装の手を動かす役割
- hw_proxyのようなハードウェア制約に起因する設計は、人間の経験と判断が不可欠だった
- 2026年の個人開発として、AIによる実装加速は現実的なプロジェクト推進手法

---

## 11. 同日の関連発表との対比

### Family mruby の独自性
| 他の発表 | Family mruby との違い |
|---------|---------------------|
| Funicular (hasumikin) - PicoRuby.WASM | PicoRubyのWasm化 vs マイコン上でのOS化 |
| mruby on C# (hadashiA) | C#上のVM再実装 vs ハードウェア上の統合OS |
| mruby on Z80 (yujiyokoo) | 極限環境での移植 vs 実用的なOS設計 |
| Live Coding Engine (asonas) | 音楽生成の話 vs システム全体の設計 |
| Ruby on NES (yhara) | ファミコン上のRuby vs 独自ハードウェアOS |
| Uzumibi (udzura) | mrubyのエッジ再設計 vs マルチVM OS |
| mruby/c Multi-Core (Kazuaki Tanaka) | VM内部のマルチコア vs MCU間のマルチコア |

### 差別化ポイント
1. **OS層の設計**: 他はVM単体の話、Family mrubyはVMを管理するOS層の話
2. **デュアルMCU**: ハードウェアを跨いだシステム設計は唯一
3. **プロトコルスタック**: 自前で4層の通信プロトコルを設計・実装
4. **完成度**: デスクトップ、シェル、エディタを含む統合環境

---

## 12. プロジェクト規模

| 指標 | 数値 |
|------|------|
| 独自C/C++コード (main/) | 約 20,000行 |
| サブモジュール含む全体 | 約 210万行 |
| サブモジュール数 | 15以上 |
| 対応VM数 | 4種 (mruby, Lua, BASIC, Native) |
| リポジトリ構成 | 3 (core, graphics-audio, audio-tools) |
| 通信プロトコル | 4層 独自設計 |
| 描画コマンド数 | 20種以上 |
| mrbgems数 | 13+ |

---

## 発表で伝えるべき核心メッセージ (案)

> PicoRubyは「組み込みでRubyが動く」だけのものではない。
> Family mrubyは、PicoRubyをカーネルとして複数VMとハードウェアリソースを管理するOSとして設計した。
> その過程で直面した、メモリ制約、プロセッサ間通信、リアルタイム性の課題と、それに対する設計判断を共有する。
