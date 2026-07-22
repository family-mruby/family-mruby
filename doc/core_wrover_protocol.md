# Core ↔ WROVER 通信インタフェース仕様 (hardware-agnostic)

fmruby-core (ESP32-S3 / Linux コンテナ) と fmruby-graphics-audio (ESP32-WROVER / Linux プロセス) 間の通信仕様を、下層のトランスポート (UART / SPI / TCP ソケット) に依存しない形でまとめる。

本ドキュメントはあくまで「論理プロトコル層」の正本であり、各実装側ヘッダ ([fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h](../fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h) と [fmruby-graphics-audio/main/communication/](../fmruby-graphics-audio/main/communication/)) と内容が食い違った場合はソースが優先。

実装差し替え向けの振る舞い契約 (boot/handshake、同期応答の追加 payload、資源上限、GfxBlock VM 意味論、合成順序、音声・ファイル契約など) は [wrover_implementation_contract.md](wrover_implementation_contract.md) を参照。

---

## 1. レイヤ構成

```
+--------------------------------------------------+
| L5  Semantic API   : GfxBlock / Canvas / Sprite  |  Ruby / C API
|                     / FileTransfer / HID / Audio |
+--------------------------------------------------+
| L4  Message        : sub_cmd + packed payload    |  fmrb_link_protocol.h
|                      ( fmrb_link_graphics_*_t  ) |  の C 構造体
+--------------------------------------------------+
| L3  Application    : msgpack [type, seq,         |  msgpack array
|     frame            sub_cmd, payload(bin)]      |
+--------------------------------------------------+
| L2  Framing        : COBS + 0x00 terminator      |  fmrb_link_cobs.*
+--------------------------------------------------+
| L1  Link (HW)      : UART921600 / SPI / TCP      |  fmrb_hal_link_*.c
|                       + CRC16 + seq/ack_seq       |  spi_frame.h / uart_link_frame.h
+--------------------------------------------------+
```

- L4/L5 はハードに依存しない。どのトランスポートでも同じ `[type, seq, sub_cmd, payload]` が届く。
- L1/L2 は実装差を吸収する層。ESP32 実機では UART (921600bps, RTS/CTS) または SPI、Linux 開発環境では TCP ソケット。
- Core 側の送信入口は [fmrb_transport_send()](../fmruby-core/components/fmrb_transport/fmrb_transport.h)、WROVER 側の受信入口は [comm_interface_t.process()](../fmruby-graphics-audio/main/communication/comm_interface.h)。

---

## 2. Application frame (L3)

全メッセージは msgpack 配列 1 要素。

```
[ type(u8), seq(u8), sub_cmd(u8), payload(bin) ]
```

| フィールド | サイズ | 内容 |
|------------|-------|------|
| `type` | 1B | 種別 + フラグ。下記 2.1 参照 |
| `seq` | 1B | 送信側の連番 (0..255 周回)。ACK でエコーされる |
| `sub_cmd` | 1B | `type` 内サブコマンド (0x00-0xFF) |
| `payload` | bin | `type`/`sub_cmd` ごとのバイナリ。C の packed struct |

バイナリのエンディアンは **リトルエンディアン**、アラインメントは `__attribute__((packed))`。

### 2.1 `type` バイトのビット構成

| bit | 名前 | 意味 |
|-----|------|------|
| 7   | `FMRB_LINK_FLAG_CHUNKED` (0x80) | ペイロードがフラグメント |
| 6   | `FMRB_LINK_FLAG_ACK_REQUIRED` (0x40) | 受信側に ACK / レスポンスを要求 |
| 5   | reserved | 0 |
| 4-0 | type 値 | 下表 2.2 |

### 2.2 type 値

| 値 | 名前 | 方向 | 説明 |
|----|------|-----|------|
| 0 | `EMPTY` | — | 予約 (フレーム埋めなど) |
| 1 | `CONTROL` | C→W, W→C | バージョン、ディスプレイ初期化、時刻同期など |
| 2 | `GRAPHICS` | C→W | 描画コマンド (フレーム中最頻) |
| 3 | `AUDIO` | C→W | 音声再生制御 |
| 4 | `FILE_TRANSFER` | C→W | WROVER の LittleFS への転送 / 削除 / 存在確認 |
| 5 | `INPUT` | W→C | キーボード・マウス・ゲームパッドの HID イベント |

### 2.3 応答コード (レスポンス用 type)

| 値 | 名前 | 意味 |
|------|------|------|
| 0xF0 | `RESPONSE_MSG_ACK` | 正常応答。`original_sequence`, `status=0` |
| 0xF1 | `RESPONSE_MSG_NACK` | 異常応答。`status` にエラー |

応答ペイロード (`fmrb_link_ack_t`):

```c
struct { uint16_t original_sequence; uint8_t status; }
```

`status == 0` なら成功、非 0 はエラー。同期コマンド (`DEFINE_PROG`, `CREATE_CANVAS`, `FILE_TRANSFER_STATUS` 等) はこの応答に追加ペイロードを詰めて返す。追加 payload の正確なフォーマットは [wrover_implementation_contract.md §3](wrover_implementation_contract.md#3-同期コマンドの応答-payload) を参照。

---

## 3. サブコマンド定義

下記すべて [fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h](../fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h) に正本あり。

### 3.1 `CONTROL` (type=1)

| sub_cmd | 名前 | 同期/非同期 | ペイロード構造体 |
|---------|------|------------|------------------|
| 0x01 | `VERSION` | 同期 | `fmrb_control_version_req_t` / `_resp_t` |
| 0x02 | `INIT_DISPLAY` | 非同期 | `fmrb_control_init_display_t` |
| 0x03 | `SET_TIME` | 非同期 | `fmrb_control_set_time_t` |

```c
struct fmrb_control_version_req_t  { uint8_t version; };                  // = 1
struct fmrb_control_init_display_t { uint16_t width; uint16_t height;
                                     uint8_t color_depth;                 // 8 = RGB332
                                     uint8_t margin_x, margin_y; };
struct fmrb_control_set_time_t     { int64_t tv_sec; int32_t tv_usec;
                                     char tz[32]; };                      // POSIX TZ
```

### 3.2 `GRAPHICS` (type=2)

全描画コマンドで最初のフィールドは `uint16_t canvas_id` (0 = スクリーン、それ以外 = `CREATE_CANVAS` で発行された ID)。色は RGB332 (`uint8_t`)。

#### 3.2.1 Window/Canvas

| sub_cmd | 名前 | 同期 | 代表フィールド |
|---------|------|-----|----------------|
| 0x01 | `CREATE_WINDOW` | — | 将来用 |
| 0x02 | `SET_WINDOW_ORDER` | 非 | `canvas_id, z_order` |
| 0x03 | `SET_WINDOW_PREF` | 非 | (未使用) |
| 0x04 | `REFRESH_ALL_WINDOWS` | 非 | なし |
| 0x05 | `UPDATE_WINDOW` | 非 | `canvas_id, x, y, width, height` |
| 0x50 | `CREATE_CANVAS` | 同期 | `canvas_id(要求), width, height, z_order, use_transparent, transparent_color` |
| 0x51 | `DELETE_CANVAS` | 非 | `canvas_id` |
| 0x52 | `SET_TARGET` | 非 | `target_id (0=screen)` |
| 0x53 | `PUSH_CANVAS` | 非 | `canvas_id, dest_canvas_id, x, y, transparent_color, use_transparency` |
| 0x54 | `SET_CANVAS_VISIBLE` | 非 | `canvas_id, visible` |

#### 3.2.2 プリミティブ描画

| sub_cmd | 名前 | payload | 備考 |
|---------|------|---------|------|
| 0x10 | `DRAW_PIXEL` | `pixel_t` | |
| 0x11 | `DRAW_LINE` | `line_t` | |
| 0x12 | `DRAW_FAST_VLINE` | `line_t` | x1==x2 の最適化 |
| 0x13 | `DRAW_FAST_HLINE` | `line_t` | y1==y2 の最適化 |
| 0x14 | `DRAW_RECT` | `rect_t` | `filled=0` |
| 0x15 | `FILL_RECT` | `rect_t` | `filled=1` |
| 0x16 | `DRAW_ROUND_RECT` | `round_rect_t` | |
| 0x17 | `FILL_ROUND_RECT` | `round_rect_t` | |
| 0x18 | `DRAW_CIRCLE` | `circle_t` | |
| 0x19 | `FILL_CIRCLE` | `circle_t` | |
| 0x1A | `DRAW_ELLIPSE` | `ellipse_t` | |
| 0x1B | `FILL_ELLIPSE` | `ellipse_t` | |
| 0x1C | `DRAW_TRIANGLE` | `triangle_t` | |
| 0x1D | `FILL_TRIANGLE` | `triangle_t` | |
| 0x1E | `DRAW_ARC` | `arc_t` | `angle` 度 |
| 0x1F | `FILL_ARC` | `arc_t` | |
| 0x68 | `BLEND_RECT` | `blend_rect_t` | `mode`: 0=ADD, 1=XOR |

#### 3.2.3 テキスト / クリア / 出力制御

| sub_cmd | 名前 | payload |
|---------|------|---------|
| 0x20 | `DRAW_STRING` | `text_t` (+文字列本体) |
| 0x21 | `DRAW_CHAR` | `text_t` (text_len=1) |
| 0x22 | `SET_TEXT_SIZE` | `text_size_t` (1-4) |
| 0x23 | `SET_TEXT_COLOR` | 未使用 (将来用) |
| 0x30 | `CLEAR` | `clear_t` |
| 0x31 | `FILL_SCREEN` | `clear_t` |
| 0x32 | `PRESENT` | `present_t` |
| 0x70 | `SET_OUTPUT_LEVEL` | `{uint8_t level;}` |
| 0x71 | `SET_CHROMA_LEVEL` | `{uint8_t level;}` |

#### 3.2.4 画像

| sub_cmd | 名前 | 同期 | payload |
|---------|------|-----|---------|
| 0x06 | `CREATE_IMAGE_FROM_MEM` | 同期 | (未使用) |
| 0x07 | `CREATE_IMAGE_FROM_FILE` | 同期 | `create_image_from_file_t` → `image_created_t` |
| 0x08 | `DELETE_IMAGE` | 非 | `delete_image_t` |
| 0x40 | `DRAW_IMAGE` | 非 | `draw_image_t` (scale fp8) |
| 0x41 | `DRAW_BITMAP` | 非 | (未使用) |

#### 3.2.5 Cursor

| sub_cmd | 名前 | payload |
|---------|------|---------|
| 0x60 | `CURSOR_SET_POSITION` | `{int32_t x, y;}` |
| 0x61 | `CURSOR_SET_VISIBLE` | `{bool visible;}` |

#### 3.2.6 Sprite

| sub_cmd | 名前 | 同期 | payload |
|---------|------|-----|---------|
| 0x80 | `CREATE_SPRITE_IMAGE` | 同期 | → `sprite_image_created_t` |
| 0x81 | `DELETE_SPRITE_IMAGE` | 非 | `image_id` |
| 0x82 | `SET_SPRITE_IMAGE_TARGET` | 非 | `image_id` (0=reset) |
| 0x83 | `LOAD_SPRITE_IMAGE_BMP` | 非 | `image_id, path` |
| 0x88 | `CREATE_SPRITE_INSTANCE` | 同期 | `frame_count, image_ids[8], x, y, z_order` → `instance_id` |
| 0x89 | `DELETE_SPRITE_INSTANCE` | 非 | `instance_id` |
| 0x8A | `SPRITE_INSTANCE_MOVE` | 非 | `instance_id, x, y` |
| 0x8B | `SPRITE_INSTANCE_SET_VISIBLE` | 非 | `instance_id, visible` |
| 0x8C | `SPRITE_INSTANCE_SET_FRAME` | 非 | `instance_id, frame_index` |
| 0x8F | `DELETE_ALL_SPRITES` | 非 | `canvas_id` |

#### 3.2.7 GfxBlock VM

WROVER 側にバイトコードを常駐させ、以降はレジスタ差分だけ送る仕組み。詳細は [gfx_block.md](gfx_block.md)。

| sub_cmd | 名前 | 同期 | payload |
|---------|------|-----|---------|
| 0x90 | `DEFINE_PROG` | 同期 | `canvas_id, bytecode_len, strtable_len` + bytecode + strtable → `prog_id(u8)` (0xFF = 失敗) |
| 0x91 | `EXEC_PROG` | 非 | `canvas_id, prog_id, reg_count, (reg_id,int16)*n` |
| 0x92 | `DELETE_PROG` | 非 | `prog_id` |

### 3.3 `AUDIO` (type=3)

| sub_cmd | 名前 | payload |
|---------|------|---------|
| 0x20 | `PLAY` | `fmrb_link_audio_play_t` (sample_rate, channels, bits_per_sample, data_len + PCM) |
| 0x21 | `STOP` | 空 |
| 0x22 | `PAUSE` | 空 |
| 0x23 | `RESUME` | 空 |
| 0x24 | `SET_VOLUME` | `{uint8_t volume;}` (0-100) |
| 0x25 | `QUEUE_SAMPLES` | (ストリーム再生用、実装に依存) |

### 3.4 `FILE_TRANSFER` (type=4)

| sub_cmd | 名前 | 同期 | payload |
|---------|------|-----|---------|
| 0x01 | `BEGIN` | 非 | `total_size, path_len` + path |
| 0x02 | `DATA` | 非 | `offset, chunk_len` + data |
| 0x03 | `END` | 同期 | `total_size, checksum(CRC32)` |
| 0x04 | `STATUS` | 同期 | path → `{exists, file_size, checksum}` |
| 0x05 | `DELETE` | 同期 | path |

### 3.5 `INPUT` (type=5)

WROVER → Core 向け。HID パケットは以下を msgpack の `payload` として流す。

```c
struct hid_packet_header_t { uint8_t type; uint16_t data_len; };  // L5 header
#define HID_EVENT_KEY_DOWN      0x01
#define HID_EVENT_KEY_UP        0x02
#define HID_EVENT_MOUSE_BUTTON  0x10
#define HID_EVENT_MOUSE_MOTION  0x11
struct hid_keyboard_event_t     { uint8_t scancode, keycode, modifier; };
struct hid_mouse_button_event_t { uint8_t button, state; uint16_t x, y; };
struct hid_mouse_motion_event_t { uint16_t x, y; };
```

### 3.6 チャンク転送 (`CHUNKED` フラグ)

ペイロードが単一 L1 フレーム (UART: 248B / SPI: 248B) に乗らない時、送信側は `type` に `0x80` を立てて `chunk_info` ヘッダを頭に付ける。

```c
struct fmrb_link_chunk_info_t {
    uint8_t  flags;       // START=0x01 / END=0x02 / ERR=0x80
    uint8_t  chunk_id;    // 0-255 (lane)
    uint16_t chunk_len;   // このチャンクの有効バイト数
    uint32_t offset;      // total 内オフセット
    uint32_t total_len;   // 全体長
};
```

受信側はフラグメントマネージャが lane ごとに再構成する ([fmrb_link_fragment](../fmruby-graphics-audio/main/communication/))。ACK (chunk ACK 形式) でクレジット管理することも可能だが、現状の WROVER 実装では受信専用。

### 3.7 同期 vs 非同期の判断基準

- **同期** (ACK_REQUIRED かつ応答に追加データ): ID 採番系 (`CREATE_*`)、`DEFINE_PROG`、`VERSION`、`FILE_TRANSFER_{END,STATUS,DELETE}`。Core 側は `fmrb_transport_send_sync()` でセマフォ待機。
- **非同期**: 描画プリミティブ、EXEC_PROG、FILE DATA、CONTROL の INIT_DISPLAY/SET_TIME など。fire-and-forget で送出し、順序保証は seq と L1 の ACK に任せる。

---

## 4. L2/L1 (下位層) 概要

論理層からは隠蔽される前提だが、実装デバッグ時に必要になるので要点のみ。

### 4.1 UART リンク (ESP32 本番・UART 化以後)

- `UART_NUM_1`、921600 bps、RTS/CTS フロー制御、8N1
- ワイヤフォーマット: `SYNC(0x55)` + `HEADER(6B)` + `DATA(≤248B)` + `CRC16-CCITT(2B)`
- HEADER = `magic(0xA5)` + `seq(1)` + `ack_seq(1)` + `status(1)` + `data_len(u16 LE)`
- `status`: `STS_BOOT=0x00 / STS_RX_OK=0x10 / STS_APP_OK=0x12 / STS_APP_ERR=0x13 / STS_CRC_ERR=0xE1`
- L3 msgpack は COBS エンコードしてから `DATA` へ格納する

詳細: [uart_link_frame.h](../fmruby-core/components/fmrb_hal/platform/esp32/uart_link_frame.h)

### 4.2 SPI リンク (旧構成・予備)

- Master=S3、Slave=WROVER、フレーム長固定 256B、CRC16 付き
- 旧 API は残してあるが、現行はビルド時に UART と切替

詳細: [spi_frame.h](../fmruby-core/components/fmrb_hal/platform/esp32/spi_frame.h)

### 4.3 TCP ソケット (Linux シミュレーション)

- Core コンテナ ↔ 別プロセス SDL2。L2 の COBS + L3 msgpack をそのまま TCP で流す
- 実装: [comm_socket_server.c](../fmruby-graphics-audio/main/communication/comm_socket_server.c)

## 5. 参考

- [fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h](../fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h) — 全 sub_cmd / payload 構造体の正本
- [fmruby-core/components/fmrb_msg/fmrb_gfx_msg.h](../fmruby-core/components/fmrb_msg/fmrb_gfx_msg.h) — Core 内タスク間 GFX メッセージ
- [fmruby-core/components/fmrb_transport/fmrb_transport.h](../fmruby-core/components/fmrb_transport/fmrb_transport.h) — Core 側送信 API
- [fmruby-graphics-audio/main/communication/comm_interface.h](../fmruby-graphics-audio/main/communication/comm_interface.h) — WROVER 側トランスポート抽象
- [fmruby-graphics-audio/main/communication/fmrb_link_msgpack.c](../fmruby-graphics-audio/main/communication/fmrb_link_msgpack.c) — L3 msgpack デコード実装
- [uart_link_frame.h](../fmruby-core/components/fmrb_hal/platform/esp32/uart_link_frame.h) / [spi_frame.h](../fmruby-core/components/fmrb_hal/platform/esp32/spi_frame.h) — L1 wire format
- [gfx_block.md](gfx_block.md) — GfxBlock VM の高レベル仕様
