# WROVER 側 実装契約書 (Implementation Contract)

[core_wrover_protocol.md](core_wrover_protocol.md) は wire format (L1-L4) の正本。本書はその上に載る **振る舞い契約** を定義し、「WROVER にあたる部分を別実装に差し替える」ために必要な情報を集約する。

## 1. 目的と互換レベル

### 1.1 目的

fmruby-core から見た WROVER 側 (ESP32-WROVER / LovyanGFX-CVBS + APU エミュレータ) を、同じ protocol を話す別 backend (例: 別ハードの VGA 出力、別 SDL2 実装、Web 側 JS 実装) に差し替えられるようにする。

### 1.2 互換レベル: **画面レイアウト一致レベル**

次の論理挙動が一致していれば OK:

- 解像度 320×240、RGB332 (8bit パレット)
- canvas の z_order / visible に従った合成順
- `transparent_color` + `use_transparent` によるカラーキー合成
- `PRESENT` 後に画面が更新される (フレーム内同期の保証は不要)
- ASCII 文字を等幅で描画できる

### 1.3 非目標

- CVBS アナログ信号レベル (output_level / chroma_level 値の物理単位) の一致
- LovyanGFX と同一のアンチエイリアス / 色変換
- ピクセル完全一致 (フォントグリフや線のアルゴリズム差は許容)
- v-sync / フレーム時刻精度の厳密一致

---

## 2. 起動とハンドシェイク

### 2.1 Boot シーケンス

```
 Core 側                            WROVER 側
 ──────                            ────────
                                    power-on
                                    boot screen 表示
                                    "Waiting for Core..." + カーソル点滅
                                    メッセージ受信ループ開始
 power-on
 fmrb_transport_init
 CONTROL INIT_DISPLAY ──(ACK_REQ)─► 受信 → callback
                                    ディスプレイ物理初期化
                                    canvas pool 確保
                                    boot 設定と比較
 ◄────────── ACK (deferred) ─────── display init 完了後に ACK
 ~1 秒 transition 待ち
 通常描画開始                       通常受付
```

- WROVER は Core の起動を待たず boot screen を出し続ける。Core 到来までメッセージ受信ループは稼働する。
- `INIT_DISPLAY` は **ACK_REQUIRED だが ACK は deferred**。WROVER は `width/height/color_depth/margin_{x,y}` を受け取り、ディスプレイ物理初期化が完了した時点で ACK を返す。これにより Core 側の `fmrb_transport_send_sync()` が待機を解く。
- ACK 返送後、WROVER 側は boot screen → 通常合成モードへ切り替わる (現行実装では ~1 秒の transition)。Core はこの間も描画コマンドを出してよいが、画面に現れるタイミングは保証しない。

### 2.2 `CONTROL VERSION` (optional)

Core は `fmrb_transport_check_version()` で呼ぶこともあるが、起動要件ではない。
- 送信: `fmrb_control_version_req_t { version=1 }`
- 応答: ACK payload に `uint8_t version`。不一致時の扱いは上位任せ (現状 log 出力のみ)

### 2.3 `CONTROL SET_TIME` (optional)

任意タイミングで 1 回以上送られる。fire-and-forget。WROVER は `settimeofday()` と `setenv("TZ")` 相当を適用する。`tz[32]` が空文字なら TZ 変更なし。

### 2.4 リンク層リトライ

Core 側既定 (`fmrb_transport_config_t`):

| 項目 | 値 |
|------|----|
| `timeout_ms` | 1000 |
| `enable_retransmit` | true |
| `max_retries` | 3 |
| バックオフ | 無し (固定間隔) |

WROVER 側で必要な対応: L1 ACK を CRC 検証後すみやかに返すこと。アプリ層 ACK (ACK_REQUIRED フラグ付き) は `send_ack()` で明示的に送る。

---

## 3. 同期コマンドの応答 payload

すべて `fmrb_link_ack_t { uint16_t original_sequence; uint8_t status; }` (3B) の **後ろに追加バイト列** が連結される (`comm->send_ack(type, seq, payload_ptr, payload_len)` の挙動)。

| コマンド | 追加 payload |
|----------|-------------|
| `CONTROL VERSION` (0x01) | `uint8_t version` |
| `GFX CREATE_CANVAS` (0x50) | `uint16_t canvas_id` (0 = 失敗) |
| `GFX CREATE_IMAGE_FROM_FILE` (0x07) | `fmrb_link_graphics_image_created_t { uint16_t image_id; uint16_t width; uint16_t height; }` (image_id=0 で失敗) |
| `GFX CREATE_SPRITE_IMAGE` (0x80) | `uint16_t image_id` (0 = 失敗) |
| `GFX CREATE_SPRITE_INSTANCE` (0x88) | `uint16_t instance_id` (0 = 失敗) |
| `GFX DEFINE_PROG` (0x90) | `uint8_t prog_id` (0xFF = 失敗、プール枯渇) |
| `FILE_TRANSFER STATUS` (0x04) | `fmrb_link_file_transfer_status_resp_t { uint8_t exists; uint32_t file_size; uint32_t checksum; }` |
| `FILE_TRANSFER END` (0x03) | なし (status のみ) |
| `FILE_TRANSFER DELETE` (0x05) | なし (status のみ) |

失敗表現は 2 方式ある: `status != 0` の NACK、または ID 領域の sentinel (`0`, `0xFF`)。再実装は **両方を正しく出す** 必要がある。

---

## 4. リソース上限と ID 規則

| 資源 | 上限 | ID 範囲 | 失敗値 | 定義場所 |
|------|------|---------|--------|----------|
| canvas | 16 同時 | 1..65535 連番、0=screen 予約 | 0 | `MAX_CANVAS_COUNT` (`graphics_handler.cpp`) |
| canvas buffer | (各 canvas ごとに draw/render の 2 面) | — | — | `display_shm.cpp` / `display_cvbs.cpp` |
| sprite image | 64 | 1..65535 連番、0=error | 0 | `SPRITE_MAX_IMAGES` (`sprite_manager.h`) |
| sprite instance | 128 | 1..65535 連番、0=error | 0 | `SPRITE_MAX_INSTANCES` |
| sprite frame | 8 per instance | image_ids[8] | — | `FMRB_SPRITE_MAX_FRAMES` (`fmrb_link_protocol.h`) |
| gfx_vm prog | 16 | 0..15 slot、0xFF=error | 0xFF | `GFX_VM_MAX_PROGS` / `GFX_VM_INVALID_PROG_ID` (`gfx_vm.h`) |
| gfx_vm reg | 16 per prog | 0..15 | — | `GFX_VM_REG_COUNT` |
| gfx_vm bytecode | 384 B per prog | — | — | `GFX_VM_MAX_BYTECODE_SIZE` |
| gfx_vm strtable | 128 B per prog | — | — | `GFX_VM_MAX_STRTABLE_SIZE` |
| text 文字列 | 128 B | — | — | `FMRB_GFX_MAX_TEXT_LEN` (`fmrb_gfx.h`) |

### ID 採番ルール (再実装向け要約)

- canvas_id は単調増加で採番 (WROVER 側 `g_next_canvas_id` がグローバル連番)。DELETE しても再利用しない現行挙動に合わせる
- sprite image/instance 同様に連番払い出し
- prog_id は slot index (0..15)。DELETE で slot 再利用 OK
- ID=0 は「screen (canvas) / エラー (sprite/image)」として多重使用されている。上位 API は必ずコンテキストで区別する

---

## 5. ライフサイクルとカスケード削除

### 5.1 DELETE_CANVAS の義務

`GFX DELETE_CANVAS` 受信時、該当 canvas に紐づく次の資源を **同時に解放** すること:

- その canvas に属する sprite image 全部
- その canvas に属する sprite instance 全部 (`DELETE_ALL_SPRITES` 相当)
- その canvas に属する gfx_vm prog (`gfx_vm_delete_progs_by_canvas`)

現行実装は `canvas_id` をキーに管理している。

### 5.2 Core 切断検知

現状、WROVER 側に「Core 切断を検知して全資源を解放する」ロジックは **ない**。再実装でも必須ではない。ただし bootstrap 時に過去の状態をクリアするのは望ましい (ハード再起動相当で十分)。

### 5.3 画像・スプライトの寿命

- `CREATE_IMAGE_FROM_FILE` で確保された image は `DELETE_IMAGE` まで保持
- `LOAD_SPRITE_IMAGE_BMP` は同じ image_id に対し再ロード可 (置換)
- sprite instance は親 canvas の生存期間にバインド

---

## 6. 描画コンポジション契約

### 6.1 色と画面

- スクリーン: 320×240 固定想定 (INIT_DISPLAY で指定される値に合わせる)
- 色: RGB332 (`RRRGGGBB`)。0xFF は「白」だが慣用的に「transparent-key の不使用 (opaque)」の sentinel として使われることがある (現行コード参照)
- `margin_x/margin_y`: 物理パネルとユーザー描画領域のマージン。`panel = display - margin`、`offset = margin/2` でセンタリング。表示装置が別の場合は同等のマージン適用

### 6.2 canvas 二重バッファ

各 canvas は 2 面:
- `draw_buffer`: Core からの描画コマンドが書き込まれる面
- `render_buffer`: 画面合成に使われる面

`PRESENT(canvas_id)` で `draw_buffer → render_buffer` にコピー (もしくは swap)。合成ループは `render_buffer` だけを参照する。再実装は double buffer 相当を用意すれば良い (同期は PRESENT タイミング基準)。

### 6.3 合成順序

1. visible な canvas を `z_order` 昇順 (小さい方が奥) に並べる
2. ソートは **stable** 推奨 (z_order タイブレークは canvas_id 昇順が無難)
3. `use_transparent=1` かつ pixel==`transparent_color` のピクセルは転送しない (color-key)
4. すべての canvas を描き終えたら画面に出力

### 6.4 PUSH_CANVAS

`canvas_id` の内容を `dest_canvas_id` の (x,y) に貼り付ける。transparent_color / use_transparency は PUSH 固有の値を使う (CREATE_CANVAS 時の値とは独立)。

### 6.5 BLEND_RECT

- mode=0 (`FMRB_BLEND_MODE_ADD`): RGB332 を成分別に飽和加算
- mode=1 (`FMRB_BLEND_MODE_XOR`): 8bit 単位で XOR

### 6.6 フレームタイミング

- `PRESENT` は fire-and-forget、v-sync 保証なし
- 合成ループはソフト 60Hz (target ~16.67ms)。描画が遅れた場合は次フレームへスキップ
- 連続 `PRESENT` を出しても 1 フレーム内に 1 回しか描画されないことがある (ユーザー側は十分)

---

## 7. GfxBlock VM バイトコード

### 7.1 Opcode (1 byte、16bit ワード列の先頭)

| opcode | 名前 | operand 数 |
|--------|------|------------|
| 0x00 | `END` | 0 |
| 0x01 | `CLEAR` | 1 (color) |
| 0x02 | `FILL_RECT` | 5 (x, y, w, h, color) |
| 0x03 | `DRAW_RECT` | 5 |
| 0x04 | `FILL_ROUND_RECT` | 6 (x, y, w, h, r, color) |
| 0x05 | `DRAW_ROUND_RECT` | 6 |
| 0x06 | `DRAW_LINE` | 5 (x0, y0, x1, y1, color) |
| 0x07 | `FILL_CIRCLE` | 4 (x, y, r, color) |
| 0x08 | `DRAW_TEXT` | 4 (x, y, str_id, color) |

`END` に達するまで命令を順次実行する。

### 7.2 Operand エンコード (16bit word)

| bit | 解釈 |
|-----|------|
| bit15 = 0 | **即値** (15bit 符号付き: -16384..+16383)。`GFX_VM_OPERAND_IMM(w) = ((int16_t)((w<<1)))>>1` |
| bit15 = 1 | **レジスタ参照** (bits 3-0 = reg_id, 0..15)。`GFX_VM_OPERAND_REG_ID(w) = w & 0x0F` |

### 7.3 Register 更新プロトコル (EXEC_PROG)

- `EXEC_PROG` の payload: `canvas_id, prog_id, reg_count, [reg_id(u8), value(i16)] * reg_count`
- WROVER は受信後、まず reg 配列を更新 → bytecode を先頭から実行
- 初回の `EXEC_PROG` は全 reg を送る (Core 側は DEFINE_PROG 直後に全送信する)
- 以降は変化した reg のみ差分送信 (reg_count は減る)

### 7.4 strtable と DRAW_TEXT

- `strtable` は NUL 区切りの文字列プール
- `DRAW_TEXT` の `str_id` operand は **strtable 先頭からのバイトオフセット** を即値で持つ
- DEFINE 時点で strtable は固定。EXEC 時に差し替え不可 (文字列は kwarg にしても変わらない)

### 7.5 canvas スコープ

- prog は DEFINE 時の `canvas_id` に紐づく
- EXEC_PROG は `canvas_id, prog_id` ペアで特定する。異なる canvas の prog を呼ぶことはできない
- `DELETE_CANVAS` で該当 prog が一括解放される (§5.1)

---

## 8. 音声契約

### 8.1 現行実装

WROVER 現行実装は **NES APU エミュレータ (nofrendo) を I2S へ流す** 形が主。`AUDIO PLAY` の PCM 経路も存在するが、APU と排他的に切り替える `apuif_use_external_process()` フラグで制御される。

### 8.2 最小互換

再実装は次を満たせば良い:
- `AUDIO PLAY` で受けた PCM データを出力デバイスに流す
- `SET_VOLUME(0-100)` を反映
- `STOP/PAUSE/RESUME` を反映 (単純な enable/disable で可)

### 8.3 フォーマット自由度

`fmrb_link_audio_play_t` は `sample_rate / channels / bits_per_sample` が可変。再実装は自分がサポートするフォーマットのみ受理してよい (その他は log して drop で OK)。現行 WROVER は内部 16bit mono を I2S stereo へ複製している。

### 8.4 レイテンシと backpressure

- レイテンシ SLA なし
- リングバッファ溢れ時は新しいサンプルを drop (backpressure なし)
- Core 側は音声遅延を前提に設計されている (NSF 再生 60Hz 同期が前提)

### 8.5 APU レジスタアクセス

`apuif_write_reg(addr, data)` は WROVER 内部のみで使用。プロトコル上には **露出していない** (AUDIO 系 sub_cmd に定義なし)。再実装は APU を持たなくて良い。

---

## 9. ファイルシステム契約

### 9.1 マウント

- 現行 WROVER: LittleFS で `/flash` にマウント
- パスは `/flash/...` 形式または先頭 `/` なしの相対パス (実装依存で正規化)
- 再実装は任意のローカルストレージで可。パスの整合だけ揃えること

### 9.2 ファイル転送プロトコル

`FILE_TRANSFER` の流れ:
1. `BEGIN { total_size, path }` — 送信開始宣言
2. `DATA { offset, chunk_len, data }` × N — 順次書き込み
3. `END { total_size, crc32 }` — チェックサム確認 (同期応答)

受信側は:
- `BEGIN` で一時ファイルを作成
- `DATA` を offset 位置に書く
- `END` で CRC32 を照合し、OK なら path へ rename、NG なら NACK

### 9.3 画像フォーマット

- `CREATE_IMAGE_FROM_FILE`: PNG / BMP 両対応 (LovyanGFX `drawPng`/`drawBmp` 経由)
- `LOAD_SPRITE_IMAGE_BMP`: BMP のみ
- それ以外のフォーマットはサポート外

再実装は少なくとも BMP サポート必須、PNG は推奨。

---

## 10. フォントとテキスト

### 10.1 責務

フォントラスタライズは **WROVER 側責務**。Core は UTF-8 / ASCII 文字列と座標のみ送る。フォントデータは WROVER 側にバンドル。

### 10.2 互換要件

- ASCII (0x20-0x7E) を等幅で描画できる
- `SET_TEXT_SIZE(1..4)` で整数倍スケール
- `bg_transparent=0` のとき背景を `bg_color` で塗る、`=1` のとき背景透過

日本語等の多バイト文字対応は実装ごとに裁量。現行は LovyanGFX 内蔵フォント (ASCII 中心)。

---

## 11. TCP ソケット バリアント (Linux シミュレーション)

Linux 開発環境では L1 を TCP に置換する。実装上の違い:

- L1 の SYNC バイト / 6B ヘッダ / CRC16 は **なし**
- COBS エンコード済み msgpack フレーム (0x00 終端) をそのまま TCP で送る
- WROVER 相当プロセスは `comm_socket_server.c` で listen する
- 再接続時の状態リセットは実装任せ (現行は受信バッファのみクリア)

---

## 12. 適合 (conformance) チェックリスト

再実装が最低限クリアすべき動作テスト:

### 12.1 ゴールデンパス (必須)

1. **起動**: WROVER 相当がスタート → boot 表示 → Core から `INIT_DISPLAY(320,240,8,*,*)` 受信 → deferred ACK を返す
2. **描画**: Core が `FILL_SCREEN(0x29)` → `CREATE_CANVAS(W,H)` (ACK で canvas_id 受信) → `FILL_RECT(canvas_id, 10,10,50,50, 0xFF)` → `PRESENT(canvas_id)` → 画面に矩形が出る
3. **テキスト**: `DRAW_STRING(canvas_id, 8, 8, "HELLO", color=0xFF, bg_transparent=1)` → "HELLO" が描画される

### 12.2 HID 往復

- キーボードイベントが WROVER から Core へ届き、Ruby の `on_update` でキー判定できる
- マウスモーション / ボタンイベント同様

### 12.3 GfxBlock 差分更新

- `DEFINE_PROG` に bytecode + strtable を送り、ACK で prog_id を受領
- 全 reg を含む `EXEC_PROG` → 描画される
- 差分 reg だけの `EXEC_PROG` → 前回値が保持され、差分だけ更新される

### 12.4 ファイル転送往復

- Core から BMP を `BEGIN`/`DATA`/`END` で転送 → CRC OK で ACK
- `STATUS` で `exists=1`, `file_size`, `checksum` が正しく返る
- `CREATE_IMAGE_FROM_FILE` → image_created_t (image_id!=0, width, height) を返す
- `DRAW_IMAGE` で canvas に描ける

### 12.5 資源上限

- canvas を 16 作成 → 17 個目は `canvas_id=0` (失敗) を返す
- `DELETE_CANVAS` 後に新規作成が成功する
- prog を 16 作成 → 17 個目は `0xFF` を返す
- `DELETE_CANVAS` でその canvas の prog / sprite が解放される

---

## 参考ファイル

- wire format: [core_wrover_protocol.md](core_wrover_protocol.md)
- 高レベル GfxBlock: [gfx_block.md](gfx_block.md)
- L3/L4 正本ヘッダ: [fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h](../fmruby-core/components/fmrb_common/include/fmrb_link_protocol.h)
- L1 UART フレーム: [fmruby-core/components/fmrb_hal/platform/esp32/uart_link_frame.h](../fmruby-core/components/fmrb_hal/platform/esp32/uart_link_frame.h)
- WROVER boot / INIT_DISPLAY: [fmruby-graphics-audio/main/tasks/graphics_task.cpp](../fmruby-graphics-audio/main/tasks/graphics_task.cpp)
- WROVER VERSION / SET_TIME: [fmruby-graphics-audio/main/tasks/message_handler_task.c](../fmruby-graphics-audio/main/tasks/message_handler_task.c)
- WROVER GFX ハンドラ / 同期 ACK: [fmruby-graphics-audio/main/graphics/graphics_handler.cpp](../fmruby-graphics-audio/main/graphics/graphics_handler.cpp)
- GfxBlock VM 実装: [fmruby-graphics-audio/main/graphics/gfx_vm.h](../fmruby-graphics-audio/main/graphics/gfx_vm.h) / [gfx_vm.cpp](../fmruby-graphics-audio/main/graphics/gfx_vm.cpp)
- Sprite manager: [fmruby-graphics-audio/main/graphics/sprite_manager.h](../fmruby-graphics-audio/main/graphics/sprite_manager.h)
- ファイル転送ハンドラ: [fmruby-graphics-audio/main/file_transfer/file_transfer_handler.c](../fmruby-graphics-audio/main/file_transfer/file_transfer_handler.c)
- TCP バリアント: [fmruby-graphics-audio/main/communication/comm_socket_server.c](../fmruby-graphics-audio/main/communication/comm_socket_server.c)
