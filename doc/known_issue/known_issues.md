# Known Issues

既知の不具合と現状の対処。根本修正ができていないものを記録する。

---

## ESP-IDF i2c_master: `i2c_del_master_bus` 後に同一ポートを再 init するとヒープ破壊

### 症状

- ESP32-S3 実機で発生 (Linux シミュレーション環境では未再現)
- I2C を使うアプリ (例: `flash/app/demo/i2c_kbd.app.rb`) を**起動 → クローズ → 再起動**すると、
  2 回目の `i2c_new_master_bus` 内 `calloc` でカーネルがクラッシュ
- バックトレース末端は ESP-IDF 標準ヒープ (TLSF) 内：

  ```
  PC : insert_free_block at tlsf_control_functions.h:404
  EXCVADDR: 0x0000000d   ← NULL+13 への書き込み = free list 破壊
  Backtrace:
    insert_free_block → tlsf_malloc → multi_heap_malloc_impl
    → heap_caps_calloc → s_i2c_bus_handle_acquire
    → i2c_acquire_bus_handle → i2c_new_master_bus
    → handle_init (hw_proxy_i2c.c)
  ```

- `control->blocks[fl][sl]` が小さな整数値に書き換えられている (= TLSF コントロール構造の corruption)
- 2 回目の I2C bus 確保で必ず再現。右クリックリロードとは無関係 (close ボタン経由でも同様)

### 原因 (推定)

ESP-IDF `i2c_master` ドライバの `i2c_del_master_bus` → 同一ポートで `i2c_new_master_bus` の
サイクルで、ESP-IDF 標準ヒープ (`heap_caps_*` の下層 TLSF) のメタデータが壊れる。
ヒープポイズニングが無効 (`CONFIG_HEAP_POISONING_DISABLED=y`) なので破壊検知ポイントは特定できておらず、
ESP-IDF 側のバグか hw_proxy 側の解放手順誤りかの最終切り分けは未完了。

### 現状の対処 (応急)

[`main/drivers/hw_proxy/hw_proxy_i2c.c`](../../fmruby-core/main/drivers/hw_proxy/hw_proxy_i2c.c) で
**ESP-IDF の I2C bus を一度 `i2c_new_master_bus` で作ったら、以後 `i2c_del_master_bus` を呼ばない**
方針に変更。

- `handle_release_unit` / `hw_proxy_i2c_release`: owner と pin 予約だけ解放、bus 自体は keep alive
- `handle_init`: 既に initialized で owner==NULL なら所有権を引き継ぐ

I2C bus はシステム全体で 1 つしかないリソースなので、永続化しても弊害なし。
別 caller への所有権譲渡もサポート。

### 根本対応 (TODO)

- ESP-IDF i2c_master 側の bus delete → new サイクルの挙動を上流レポート相当の調査
- `CONFIG_HEAP_POISONING_LIGHT=y` を一時有効化して、破壊している側を特定
  (sdkconfig は CLAUDE.md で編集禁止のため、調査時のみ手動で切替)
- 切り分け完了後、bus を永続化したままで問題なければ現状の対処を恒久対処として残す

### 参考ファイル

- `fmruby-core/main/drivers/hw_proxy/hw_proxy_i2c.c`
- `fmruby-core/components/fmrb_hal/platform/esp32/fmrb_hal_i2c_esp32.c`

---

## mruby-task: C 関数からの `mrb_raise` 累積でタスクコンテキストが壊れる

### 症状

- ESP32-S3 実機で発生 (Linux シミュレーション環境では未再現)
- Ruby から呼んだ C 実装メソッドで `mrb_raise` が短時間に複数回発生すると、
  そのタスクの VM コンテキストが破壊される
- 最終的に以下のログを残してカーネルがクラッシュ、`Guru Meditation Error` で再起動:

  ```
  E fmrb_kernel: Exception caught: RuntimeError
  E fmrb_kernel: Message: task context corrupted: no proc on resume
  E fmrb_kernel: Backtrace:
  E fmrb_kernel: (unknown):0
  I fmrb_kernel: Family mruby OS Kernel exit
  Guru Meditation Error: Core 0 panic'ed (IllegalInstruction).
  ```

- PC は `mrb_run` 内部、`A2 = 0x00000000` (NULL) — 保存された
  `ci->proc` が NULL で mruby-task の resume ロジック ([`task.c:364`](../fmruby-core/lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c))
  が `"task context corrupted: no proc on resume"` を raise している

### 再現手順

1. ウィンドウアプリをフルスクリーンでないモードで起動 (例: `mruby.app`)
2. マウスでタイトルバーをつかんで画面外にドラッグする
   (特に左端・上端へ引きずると `x < 0` / `y < 0` になりやすい)
3. 数回繰り返すうちにカーネルがクラッシュする

### 原因 (推定)

- `input_router.rb` のドラッグ処理で、マウスポインタが画面外に出ると
  `new_x = x - @drag_offset_x` が負値になる
- これが C 実装の [`_update_window_position`](../fmruby-core/lib/add/picoruby-fmrb-kernel/ports/esp32/kernel.c)
  に渡されると、範囲チェックで `mrb_raise(..., "Invalid position")` が発生
- Ruby 側 `rescue` で捕捉できるものの、**PicoRuby の mruby-task は C からの
  `mrb_raise` (`longjmp`) を複数回またいだ際に ci スタックを正しく復元できず、
  保存された proc ポインタが NULL になる**ようである

### 現状の対処 (応急)

`input_router.rb` 側でドラッグ座標を 0..65535 に **clamp** してから C 関数を
呼ぶことで、C 側の `mrb_raise` 発生そのものを回避する。

```ruby
# Clamp to the range accepted by the C API (0..65535) to avoid mrb_raise.
new_x = 0 if new_x < 0
new_x = 65535 if new_x > 65535
new_y = 0 if new_y < 0
new_y = 65535 if new_y > 65535
```

### 応急対処後も残る再現パターン (未解決)

clamp で `Invalid position` の raise は消えたが、以下の条件では依然として
同じ `task context corrupted: no proc on resume` でクラッシュすることを確認:

- `mruby.app` (BouncingBallApp) を起動
- `monitor.app` を同時起動 (どちらも非 fullscreen ウィンドウ)
- `mruby.app` のタイトルバーをドラッグし始めてから ~1 秒でクラッシュ

この経路では `Invalid position` ログは出ないので、原因は **別の C raise** か、
あるいは **raise とは無関係な mruby-task スケジューラ上の race** の可能性が高い。
monitor 単独 / mruby.app 単独では安定動作するため、**複数タスクの並行実行時の
コンテキスト切替タイミング**が関係していると思われる。

> **続報 (2026-06-02):** コード精査により真因をほぼ特定。詳細は
> [mruby_tick_task_investigation.md](mruby_tick_task_investigation.md) を参照。
> 要点: 下記「static scheduler 状態の共有」仮説は既に解消済み (state は VM 単位に分離済み)。
> 真因は `mrb_tick()` が別 FreeRTOS タスクから VM 実行スレッドと**並行**実行されること。

### 原因切り分け結果 (2026-04-18)

`mruby_tick_task` (FreeRTOS タスク、`lib/replace/picoruby-machine/ports/esp32/machine.c`)
による 5ms 周期の `mrb_tick()` 配信を**完全に止める**実験を行い、以下を確認:

- Tick task 有効時: 複数 VM 起動 + タイトルバードラッグで数秒〜数十秒でクラッシュ
- Tick task 無効時: 同条件で 1〜2 分操作してもクラッシュ再現せず

したがって **VM コンテキスト破壊の原因は Tick task 経由の並行 `mrb_tick()` 配信** で
確定。

注: Tick task を止めても、[`lib/add/picoruby-fmrb-app/ports/esp32/app.c`](../fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/app.c) の
`_spin` 末尾 (L600-602) に **自 VM 文脈からの補償 `mrb_tick()`** が残っているため、
`_spin` を回しているアプリ (通常のウィンドウアプリ) のスケジューラは引き続き動く。
ただし `_spin` を使わない常駐タスク (`fmrb_kernel` / `system_desktop` など) の
mruby-task スケジューラは止まっている可能性があるので、そちらで `Task` API を
使っていないか別途確認が必要。

### 補償 tick 依存の実機確認 (2026-04-18)

`_spin` 補償 tick も `#if 0` で無効化して Editor アプリを起動した結果、
**キー入力に一切反応しなくなった**。したがって以下が実証された:

- Editor アプリの Ruby `Task` は `_spin` 補償 tick で駆動されている
- Tick task 無効化後の現行システムの Task スケジューラ唯一の駆動源は `_spin` 補償
- 言い換えると「Tick task 無効 + `_spin` 補償を残す」現在の構成は、ウィンドウアプリに
  限れば Task API が機能する綱渡りバランスになっている

### 仮説: `task.c` の static スケジューラ状態が全 VM で共有されている

[`lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c`](../fmruby-core/lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c) の以下の
静的変数はファイルスコープで宣言されており、**複数 mruby VM が動いても 1 セットしか
存在しない**:

- `tick_` (グローバル tick カウンタ)
- `switching_` (コンテキストスイッチ要求フラグ)
- `q_ready_` / `q_waiting_` / `q_dormant_` / `q_suspended_` (task queue)
- `wakeup_tick_`

`mrb_tick()` は引数で `mrb` を受け取るが内部では上記 static を操作するため、VM A
実行中に Tick task 側から VM B の文脈として `mrb_tick(mrb_B)` が呼ばれると、
**A の `q_ready_` や `switching_` が B の state に差し替わる**。次の `mrb_run` での
resume 時に `ci->proc` が NULL になるのはこれが原因と推定。

### 根本対応 (TODO、候補)

1. **task.c の scheduler state を mrb_state 単位に持たせる** (本筋)
   - static → `mrb->scheduler_state->xxx` のように VM 毎に分離
   - 影響範囲は広いが正しい解
2. **Tick task 側でロックを取って `mrb_tick` を直列化**
   - 現状すでに `g_tick_manager.mutex` は取っているが、`mrb_tick` 本体が static
     変数を触るので VM 側の実行中スレッドとは排他できていない
   - `mrb_tick` を呼ぶ前に「当該 VM が今まさに実行中でない」ことを確認する必要あり
3. **Tick task を廃止し、各 VM の `_spin` 補償に一本化**
   - 今回の実験と同じ状態。ただし常駐タスクで `_spin` を使わないものは別途 tick 供給が要る
   - **却下**: kernel / desktop タスクが常駐のため全 VM に `_spin` を強制できない

当面の応急措置として、Tick task は無効化したまま運用する。

### 現在の運用状態 (2026-04-18、RubyKaigi 発表直前)

RubyKaigi 2026 の発表が目前のため、この Tick 問題は Known Issue としてこの状態の
ままとし、発表後に根本対応する。現行コードベースの実情は以下:

- [`lib/replace/picoruby-machine/ports/esp32/machine.c`](../fmruby-core/lib/replace/picoruby-machine/ports/esp32/machine.c) の `mrb_hal_task_init` は
  no-op 化済み (debug コメント付き) → Tick task は作られない
- [`lib/add/picoruby-fmrb-app/ports/esp32/app.c`](../fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/app.c) の `_spin` 補償 tick は**有効**
- この構成で VM クラッシュは発生せず、ウィンドウアプリの Task も動作

調査を続ける場合のポイント:

- `mrb_raise` 以外で `mrb->c->ci->proc` が NULL になる経路はあるか
  (mruby-task の `mrb_vm_exec` 呼出し前後の ci 管理)
- 複数 mruby VM が同時に動いているときの共有リソース (アロケータ、transport)
- PSRAM スタックでのコンテキストスイッチ (PSRAM stack + SPI flash DMA の既知制約との関連)
- UART transport / Host Task の高負荷時にタスクが長時間ブロックする影響

### 根本対応 (TODO)

同種の問題は **他の C 実装メソッドが `mrb_raise` を出すパス全般** で起こりうる。
現状は `input_router.rb` のみ個別に防御しているが、将来的には以下のいずれかの対応が必要:

- mruby-task の resume ロジック側で、C 例外 longjmp 後の ci 復元を正しく行う
- C 実装メソッドで `mrb_raise` を使わず、失敗時は特定の戻り値 (nil / false / 負値)
  を返す方針に統一する
- 例外発生頻度を観測する仕組みを入れ、規定回数を超えたら警告を出す

### 参考ファイル

- ラップ側 (応急対処済み):
  - `fmruby-core/main/prebuild_scripts/kernel/fmrb_kernel/input_router.rb`
  - `fmruby-core/main/prebuild_scripts/kernel/mrb/fmrb_kernel_combined.rb`
- C 側 (`mrb_raise` の発生源):
  - `fmruby-core/lib/add/picoruby-fmrb-kernel/ports/esp32/kernel.c:315`
- mruby-task のエラー発生箇所:
  - `fmruby-core/lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c:364`
- Tick task (2026-04-18 時点で debug 無効化):
  - `fmruby-core/lib/replace/picoruby-machine/ports/esp32/machine.c:271` (`mrb_hal_task_init`)
- 自 VM 文脈からの補償 tick:
  - `fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/app.c:600`

### 関連コミット

- `57e61dc` (2026-04-15) — Tick task を再有効化 (本バグが顕在化したコミット)
- `4f604db` (2026-03-21) — Tick task を no-op 化 (本バグが潜伏していた間)

---

## WROVER 経由の効果音 (note_on/note_off) 連打でアプリ操作の応答性が劣化

### 症状

- ESP32-S3 + WROVER 実機で発生
- ゲームアプリ等で `FmrbAudio#note_on` / `note_off` をキー入力に同期して連打すると、
  キャラクタ移動など視覚的な操作応答が「詰まる」「ワンテンポ遅れる」感じになる
- 具体例: `flash/app/game/flappy.rb` のスペースキー (羽ばたき) で blip 音を鳴らす実装。
  音を鳴らさない実装と比較すると、明らかに反応が悪く感じる
- 鍵盤系 (`flash/app/game/piano.app.rb`) のように 1 音ずつゆっくり鳴らす用途では問題は出にくい

### 原因 (推定)

note_on / note_off の 1 メッセージは以下のホップを経由する:

```
Ruby (FmrbAudio)
  → kernel (audio_handler.rb, msgpack→raw binary 変換)
  → host_task (UART transport)
  → WROVER audio_task (audio_task_note_on / _note_off)
  → APU register write
```

S3 〜 WROVER 間の UART (現状 921600bps) の往復と、WROVER 側 audio_task の
60Hz mixing ループ ([fmruby-graphics-audio/main/tasks/audio_task.c](../../fmruby-graphics-audio/main/tasks/audio_task.c))
の処理スロットが噛み合っていない可能性が高い。とくに 1 操作ごとに
**note_on + 数十 ms 後に note_off** の 2 メッセージを送る方式だと、UART キューが
詰まりやすく、後続の入力イベントや描画メッセージのレイテンシに影響しているように見える。

S3 内部 (Ruby → kernel) の latency 単独ではここまで体感できないので、
WROVER 側のメッセージ処理 (UART RX → audio_task ディスパッチ → APU 書き込み) の
シリアライズかタイミング干渉が支配的と推定。

### 現状の対処 (応急)

短時間効果音は **APU 自身の sweep エンベロープで自動消音させ、note_off メッセージを
省略する** 方針に切り替え。1 操作あたりのメッセージ数を 2 → 1 に削減する。

実装例: [fmruby-core/flash/app/game/flappy.rb](../../fmruby-core/flash/app/game/flappy.rb) の `play_flap`

```ruby
# enable | (period<<4) | negate(0x08=up) | shift
FLAP_SWEEP = 0x80 | (0 << 4) | 0x08 | 2  # ~160ms で自動 mute

def play_flap
  @audio.note_on(0, 880, 8, 1, FLAP_SWEEP)
end
```

これにより羽ばたきの応答性は素のとき (音なし) に近いレベルに改善した。
ただし依然として若干の引っかかりは残るため、根本対応は別途必要。

衝突音のように発生頻度が低く・後続の操作が無いケースは従来通り `note_off`
スケジュールを残してよい (操作応答に影響しないため)。

### 根本対応 (TODO)

- WROVER 側 `audio_task_note_on` / `_note_off` の処理コストの実測
  (UART RX 割込から APU 書き込み完了までの所要時間)
- UART transport のキュー長監視。RX 側で詰まっているのか TX 側か特定
- 効果音を「事前に短い FMSQ パターンとしてロードしておき、再生は `play_slot`
  1 メッセージで完結させる」スキームの検討。FMSQ プレイヤは既に WROVER 側に
  存在する ([audio_task.c:33](../../fmruby-graphics-audio/main/tasks/audio_task.c#L33))
- もしくは「効果音バンク」を WROVER 側に持たせ、Ruby からは
  `play_se(:flap)` 風の最小ペイロード 1 メッセージで起動できる API 追加
- 入力レイテンシが本当に audio 側起因か切り分けるため、note_on を no-op 化して
  視覚応答だけ計測するベンチマーク

### 参考ファイル

- Ruby 側 API: `fmruby-core/lib/add/picoruby-fmrb-app/mrblib/fmrb-audio.rb`
- kernel 側ルータ: `fmruby-core/main/prebuild_scripts/kernel/fmrb_kernel/audio_handler.rb`
- WROVER 側ハンドラ: `fmruby-graphics-audio/main/tasks/audio_task.c` (`audio_task_note_on` / `_note_off`)
- 応急対処の実装例: `fmruby-core/flash/app/game/flappy.rb` (`play_flap`)

### 関連コミット

- `a93eeba` (fmruby-core, 2026-04-19) — Flappy で sweep 自動消音方式に切替、
  起動音にも和音 + sweep を導入
