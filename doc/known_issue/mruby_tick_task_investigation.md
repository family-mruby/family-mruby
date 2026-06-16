# mruby_tick_task による VM コンテキスト破壊 — 原因調査結果 (2026-06-02)

`known_issues.md` の「mruby-task: C 関数からの `mrb_raise` 累積でタスクコンテキストが
壊れる」および `mruby_tick_task` 関連の続報。コードを精査した結果、真因をほぼ特定した
ので記録する。

関連: [known_issues.md](known_issues.md)

---

## 結論 (要約)

1. `known_issues.md` の最有力仮説「`task.c` のスケジューラ static 変数が全 VM で共有」は
   **既に解消済み**。現行コードはスケジューラ状態を完全に **VM 単位 (`mrb->task`)** に
   持っている。したがって state 共有は (もはや) 真因ではない。
2. 残る真因は **`mrb_tick()` が VM 実行スレッドとは別の FreeRTOS タスク
   (`mruby_tick_task`) から真に並行実行される**こと。mruby-task は `mrb_tick()` が
   「実行中の VM を割り込むタイマ ISR」である前提で設計されており、この前提が破れている。
3. 排他用の `mrb_task_disable_irq()` は ESP32 ポートでは割り込み禁止ではなく
   **協調フラグ**に再実装されており、明示ブラケットした区間しか守らない。
   スケジューラの read/execute 経路 (`execute_task` / `mrb_task_run`) と
   `mrb_tick` 自身のキュー走査は無防備で、連結リストの torn read により
   `ci->proc == NULL` を引き起こす。
4. ESP32-S3 はデュアルコアのため、仮に本物の割り込み禁止を使っても片コアしか
   マスクできず、ISR ベースの排他は原理的に成立しない。
5. 現状の応急構成 (tick task 無効 + `_spin` 補償) が安定なのは、補償 tick が
   **VM 自身のスレッドから逐次**呼ばれ `mrb_vm_exec` と並行しないため。
6. **対策の本命は案D** (§5): tick タスクは `mrb->task.switching` シグナルと pending tick
   カウントだけを行い (top-half)、`mrb_tick` 本体は全 VM 共通の `mrb_task_run` ループで
   VM 自スレッドが適用する (bottom-half)。元の「`mrb_tick` は VM 自身の実行ユニットでしか
   走らない」不変条件を回復するので、無保護ホットパスを触らず・portMUX も不要で要件
   (1)(2) を満たす。並行 `mrb_tick` を維持する portMUX 案 (案B-改) は重い代替。

---

## 1. スケジューラ状態は既に VM 単位

`task.c` 冒頭のマクロは全て `mrb->task` を参照する:

```c
#define q_dormant_   (mrb->task.queues[MRB_TASK_QUEUE_DORMANT])
#define q_ready_     (mrb->task.queues[MRB_TASK_QUEUE_READY])
#define q_waiting_   (mrb->task.queues[MRB_TASK_QUEUE_WAITING])
#define q_suspended_ (mrb->task.queues[MRB_TASK_QUEUE_SUSPENDED])
#define tick_        (mrb->task.tick)
#define wakeup_tick_ (mrb->task.wakeup_tick)
#define switching_   (mrb->task.switching)
```

`mrb_task_state` は `mrb_state` に埋め込まれている (`mruby.h`):

```c
typedef struct mrb_task_state {
  struct mrb_task *queues[4];      /* dormant, ready, waiting, suspended */
  volatile uint32_t tick;
  volatile uint32_t wakeup_tick;
  volatile mrb_bool switching;
  struct mrb_task *main_task;
  uint8_t scheduler_lock;
} mrb_task_state;
```

→ `known_issues.md` の「根本対応 TODO 候補 1: scheduler state を mrb_state 単位に持たせる」
は実装済み。**state 共有は真因から外れる**。`known_issues.md` 側の記述はこの点で古い。

参考: [task.c:28-34](../../fmruby-core/lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c),
[mruby.h:253-260](../../fmruby-core/components/picoruby-esp32/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby.h)

---

## 2. 真因: `mrb_tick()` の cross-thread 並行実行

### mruby-task の設計前提

mruby-task の排他プリミティブは `mrb_task_disable_irq()` / `mrb_task_enable_irq()`。
本来これは**タイマ割り込みを物理的に止める**もので、キュー操作中に `mrb_tick`(ISR) が
割り込まないことを保証する。つまり想定しているのは **reentrancy (同一実行ユニット上の
割り込み)** であって **parallelism (別スレッドからの並行)** ではない。

### fmrb ESP32 ポートの実態

- `mrb_tick` は ISR ではなく FreeRTOS タスク `mruby_tick_task` (優先度5) から呼ばれる。
  VM 実行スレッドとは**別スレッドで真に並行**。

  ```c
  /* machine.c: mruby_tick_task */
  for (int i = 0; i < FMRB_MRB_MAX_VMS; i++) {
    if (vms[i].active && vms[i].mrb) {
      if (vms[i].in_c_funcall == MRB_C_FUNCALL_EXIT &&
          vms[i].irq == MRB_ENABLE_IRQ) {
        mrb_tick(vms[i].mrb);   /* ← tick スレッドから VM 状態を触る */
      }
    }
  }
  ```

- `mrb_task_disable_irq()` は割り込み禁止ではなく、**VM 単位の協調フラグ** `vms[i].irq` を
  `g_tick_manager.mutex` 下で立てるだけ。tick タスクは配信前にこのフラグを見てスキップする。

  ```c
  /* machine.c: mrb_task_disable_irq (抜粋) */
  xSemaphoreTake(mutex);
  vms[i].irq = MRB_DISABLE_IRQ;   /* フラグを立てるだけ。実際に割り込みは止めない */
  xSemaphoreGive(mutex);
  ```

### 補足: 既存 mutex 方式が「守れている範囲」と「守れていない範囲」

「`mruby_tick_task` は `g_tick_manager.mutex` で排他しているのに、なぜ破壊が起きるのか」
への回答。要点は **mutex が守っているのは `vms[]` フラグ配列であって、タスクキューそのもの
ではない**こと。

`mrb_task_disable_irq()` は上記のとおり **フラグをセットした後 mutex を手放してから**
キュー操作を行う。つまりキュー操作を守るのは mutex ではなく `irq` フラグで、mutex は
そのフラグの読み書きを atomic 化しているだけ。

**ブラケットされた区間 (disable/enable_irq で囲んだキュー操作) は、実は正しく守られている。**
tick タスクが **ループ全体で mutex を保持したまま `mrb_tick` を呼ぶ**ため:

- VM が先に `disable_irq` 到達 → フラグ=DISABLE。tick はフラグを見てこの VM をスキップ。
- tick が先に mutex 保持 → VM の `disable_irq` は `xSemaphoreTake` でブロックし、tick の
  `mrb_tick` 完了まで待つ。

どちらに転んでもキュー操作は重ならない (FreeRTOS mutex はコア間でも効くのでデュアルコアでも
成立)。

**問題は「ロックの種類」ではなく「ロックの適用スコープ」。** 致命的なのは
`disable_irq` を一度も呼ばない = mutex を一切触らないスケジューラのホットパス
(`mrb_task_run` の `t = q_ready_`、`execute_task` 全体) で、これらは mutex の競合に
参加しないため、tick スレッドの `mrb_tick` (wakeup 経路でキューを書換) と**完全に並行**する。

→ 原理的には**この同じ mutex でも read 側まで囲めば直せる**が、(1) 毎キュー操作で
優先度継承付き mutex の take/give + `vms[]` 線形走査はホットパスに重すぎる、(2) どのロック
でも `mrb_vm_exec` は囲めず「lock→head 読む→unlock→実行」の再構成が必須、という理由で
**軽量な portMUX スピンロックが本命** (§5 案B-改)。あわせて「フラグを立てて mutex を
手放してからキュー操作」という間接的な守り方を「キュー操作そのものをロックで囲む」直接的な
形に正せる。

### 補足: 無保護ホットパスは ISR モデルでは正しい。移植が前提を壊した

「`mrb_task_run` の `t = q_ready_` や `execute_task` 全体がロック無しで動くこと自体が
設計欠陥では?」への回答。**結論: あのホットパスは元設計 (ISR モデル) では完全に正しい。**
バグはホットパスが無保護なことではなく、それを正しくしていた前提を移植が壊したこと。

mruby-task の元設計では `mrb_tick` は **ISR (割り込み)**。ISR には2つの効果がある:

1. **書き手のアトミック性がタダで手に入る。** ISR は割り込まれた文脈を凍結したまま実行
   完了まで走るので、`mrb_tick` の wakeup 経路 (`q_delete`/`q_insert`) はメイン文脈から
   見て「まだ発火していない」か「完全に終わっている」かのどちらかで、中間状態を観測でき
   ない。読み手はロック無しでキューを読んでも half-linked を掴まない。
2. **同一コアのメモリ順序。** 同じコア上の逐次実行なので store/load の並べ替えや
   キャッシュコヒーレンシ問題が無い。

だから `disable_irq` が要るのは**メイン文脈が複数ステップのキュー書換を行う間だけ**で、
**読み出しを守る必要は無かった** (書き手がアトミックだから)。`q_ready_` の lock-free
読みや `execute_task` の lock-free 実行は、ISR モデルでは正しい最適化。

`mrb_tick` を ISR から**独立した FreeRTOS タスク (デュアルコア)** に移植した瞬間、上の
2つの保証が**同時に消えた**: 書き手はもう凍結せず途中状態が観測でき、別コアで真に同時
実行されメモリ順序保証も消える。その結果、**元は正しかった lock-free な読みが本物の
データレースに化けた**。`ci->proc==NULL` はその下流症状。

→ 本質は「非並行前提のスケジューラに、真に並行 (マルチコア) な tick ドライバを接ぎ木した
インピーダンスミスマッチ」。直し方は (A) 並行をやめて前提を戻す (§5 案A) か、
(B) 並行を認めて読みパスもロックで覆う (§5 案B-改) の二択で、どちらも「ホットパスをどう
扱うか」の裏返し。なお本プロジェクトでは **CPU-bound タスクの真のプリエンプションと、
`_spin`/FmrbApp に依存しない (FmrbKernel や将来のバックグラウンドアプリを含む) tick 供給が
要件として必要**。これを A 系で満たすのが本命の**案D** (§5): シグナルだけを外部スレッドが
行い、`mrb_tick` 本体は全 VM 共通の `mrb_task_run` で VM 自スレッドが適用する。

### 守られない区間

協調フラグは**明示ブラケットした区間のみ**守る (disable/enable_irq で囲んだキュー操作、
`in_c_funcall` で囲んだ C 関数区間)。以下は無防備:

- **`execute_task()`** — `t->c.ci->proc` を読み、`mrb->c` を差し替え、`mrb_vm_exec` を
  回し、文脈を復元する全工程が disable_irq の外。この `mrb_vm_exec` 中は
  `irq==ENABLE` かつ `in_c_funcall==EXIT` なので **tick タスクは `mrb_tick(mrb)` を
  並行配信する**。
- **`mrb_task_run()`** — `t = q_ready_` を disable_irq 外で読んで参照する。
- **`mrb_tick()` 自身** — wakeup 経路で `q_delete_task` / `q_insert_task` を呼び、
  VM スレッドが並行で読む同じ連結リスト (`mrb->task.queues[*]`, `t->next`) を書き換える。

### 破壊の連鎖

tick スレッドがキューを relink している最中に VM スレッドが `q_ready_` を torn read
→ half-linked / 別物のタスクを掴む → その `t->c.ci->proc` が NULL/ゴミ
→ `task.c` の resume ガードが `"task context corrupted: no proc on resume"` を raise
→ これが `mrb_run` 内で起きると保存 A2=NULL で IllegalInstruction の Guru Meditation。

`known_issues.md` に記録された症状・バックトレースと完全に一致する。

参考: [execute_task / mrb_task_run / mrb_tick](../../fmruby-core/lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c),
[machine.c (tick task / disable_irq)](../../fmruby-core/lib/replace/picoruby-machine/ports/esp32/machine.c)

---

## 3. デュアルコアの追い打ち

ESP32-S3 は2コア。仮に本物の `portDISABLE_INTERRUPTS()` を使っても**現在のコアしか
マスクしない**ため、tick タスクが別コアで走れば割り込み禁止ベースの排他は原理的に
成立しない。実質 `g_tick_manager.mutex` + フラグだけが防御で、それが execute/scheduler
の read 経路をカバーしていない。

---

## 4. なぜ現状の応急構成は安定なのか

`mrb_hal_task_init` を no-op 化 (commit `2e6cdba`) して tick タスクを作らず、残るのは
`_spin` 末尾の補償 `mrb_tick(mrb)` のみ。これは **VM 自身のスレッドから逐次的に**
呼ばれるので `mrb_vm_exec` と並行せず、競合が原理的に起きない。

```c
/* app.c: _spin 末尾 — VM 自身のスレッドで補償 tick */
mrb_int missed_ticks = (elapsed_ms + MRB_TICK_UNIT - 1) / MRB_TICK_UNIT;
for (mrb_int i = 0; i < missed_ticks; i++) {
  mrb_tick(mrb);
}
```

ただし `_spin` を回さない常駐タスク (`fmrb_kernel` / `system_desktop` など) には tick が
供給されないため、そちらで `Task` API を使うと駆動されない (`known_issues.md` 記載どおりの
綱渡り)。

参考: [app.c:589-606 (_spin 補償)](../../fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/app.c),
[machine.c:271-277 (mrb_hal_task_init no-op)](../../fmruby-core/lib/replace/picoruby-machine/ports/esp32/machine.c)

---

## 5. 推奨する根本対応の方向

`known_issues.md` の候補1 (state 分離) は実装済みで不十分、候補3 (tick 廃止) は常駐タスク
問題で却下。本質 (§2 補足) は **「非並行前提のスケジューラに、真に並行な tick ドライバを
接ぎ木したインピーダンスミスマッチ」**。直し方は2系統:

- **(A 系) 並行をやめて前提を戻す** = `mrb_tick` を VM 自スレッドでしか走らせない。
  → 無保護ホットパスが再び正しくなり、ロック不要。
- **(B 系) 並行を認めて読みパスもロックで覆う** = portMUX で cross-core 排他。
  → スケジューラに装置を足す。

実機の前提 (VM タスクは PSRAM・**core 非 pin**、mrb_state/キューは PSRAM 上) を踏まえると、
**A 系を「ISR/タスクは *シグナルだけ*・mrb_tick 本体は VM 自スレッド」という top-half /
bottom-half 分割に仕立てた案D が本命**。要件 (1)(2) を両方満たしつつ、影響が最小。

### 案D (本命): top-half = switching シグナル、bottom-half = `mrb_task_run`

要件 (1) 真のプリエンプションに必要なのは「実行中の VM を命令境界で止める」ことだけで、
それは `mrb->task.switching` を立てれば足りる (vm.c の `RETURN_IF_TASK_STOPPED` が命令毎に
チェックして `mrb_vm_exec` を即 return させる)。キュー操作は不要。

- **top-half (machine.c, 周期シグナル源)**: 毎 tick、各登録 VM に対し
  `pending_ticks++` (**内部 RAM の registry カウンタ**) と `mrb->task.switching = TRUE`
  を行うだけ。キューは一切触らない。
  - これは**ISR である必要はない**。ISR だと PSRAM の `switching_` を直接書けず内部 RAM
    中継 + vm.c 改修が要る上、VM が core 非 pin なので ISR の「同一コア・アトミック」の
    うまみも無い (§案C)。**通常の FreeRTOS タスク (= 今の tick タスクを痩せさせる) なら
    タスク文脈で PSRAM の `switching_` をそのまま書けて簡単。** esp_timer でも可。
- **bottom-half (task.c, `mrb_task_run` / `mrb_task_run_once` のループ)**: ループ先頭
  (idle 分岐含む) で `n = mrb_hal_task_take_pending_ticks(mrb); while (n--) mrb_tick(mrb);`
  を適用。VM 自スレッドなのでキューは単一スレッドアクセス → 競合なし。

全 VM (apps も kernel も) が単一の `mrb_task_run` ([fmrb_app.c:565](../../fmruby-core/main/app/fmrb_app.c)、
kernel も `fmrb_app_spawn`→`app_task_main`→`mrc_create_task`+`mrb_task_run` の同一経路) を
通るため、**bottom-half を `mrb_task_run` に置けば FmrbApp 継承の有無・`_spin` 使用の有無・
メッセージポンプの有無に一切依存せず、全 VM が tick とプリエンプションを受ける**。将来の
「`_spin` を使わないバックグラウンドアプリ」もそのまま動く。

これは元の不変条件 (`mrb_tick` は VM 自身の実行ユニットでしか走らない) を回復するので、
**無保護ホットパスを触らずに再び正しくできる** のが効く。

#### 影響範囲

変更が必要:

| 箇所 | 変更内容 |
|---|---|
| machine.c | tick タスクを `pending_ticks++ + switching_=TRUE` に。`mrb_hal_task_init` 再有効化。`disable_irq`/`enable_irq` → **no-op** (キューは VM 単一スレッドのみ)。registry に `pending_ticks` 追加 |
| task.c | `mrb_task_run` / `mrb_task_run_once` ループに pending tick 適用を追加 (idle 分岐でも → sleeping task の wakeup 確保) |
| task_hal.h + 各 port | `mrb_hal_task_take_pending_ticks(mrb)` (取得&ゼロ化) を追加。esp32 / posix / esp32_linux / rp2040 |
| app.c `_spin` | 補償 `mrb_tick` を削除 (`mrb_task_run` に一本化し二重計上を回避) |

変えなくてよい (案B-改との決定的な差):

- **vm.c**: 無変更 (`switching_` チェック既存)。
- **task.c の `execute_task` / `q_insert` / `q_delete`**: 無変更。lock-free のまま正しくなる。
  **portMUX 不要**。
- **introspection (stat/list/get)**: 無変更 (クロススレッドのキューアクセスが消えるので
  Step1-B の snapshot 化が**丸ごと不要**)。
- **Ruby 全般 (FmrbApp / FmrbKernel / 全アプリ)**: 無変更。

#### 確認点 / リスク / 規律

- `pending_ticks` は signal(write)↔VM(take&zero) の小カウンタ。registry の mutex 流用か
  atomic で保護。
- `switching_` を signal が書く良性レース (単一 volatile 語。VM 側 `execute_task` の
  `switching_=FALSE` クリアと前後しても 1 tick 自己補正)。
- **規律: register する VM は必ず scheduler (`mrb_task_run`) を回すこと。** scheduler を
  回さず `mrb_top_run` だけの VM を register すると、signal の `switching_` で `mrb_vm_exec`
  が誤って途中 return する。現状の登録 VM は全て `mrc_create_task`→`mrb_task_run` 経由なので
  該当なしだが明文化必須。
- timeslice: 毎 tick `switching_` を立てると単一タスクでも ~4ms 毎に yield+resume
  (オーバーヘッド僅少)。3-tick timeslice を維持したいなら signal 側に per-VM カウントダウン
  (内部 RAM int) を入れる小追加。

#### 実装状況 (2026-06-04): 実装 + ESP32/Linux ビルド成功 + Linux 実機で安定確認

案D を実装。`rake build:esp32` / `rake build:linux` ともクリーン通過、Linux 実機
(docker compose) で boot 〜 desktop 動作をクラッシュ無し確認 (下記「回帰と修正」参照)。
ESP32 実機検証は未。

実際に変更したファイル:

- `lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c`:
  `mrb_task_run` / `mrb_task_run_once` のループ先頭で
  `mrb_hal_task_take_pending_ticks()` を drain して `mrb_tick()` を適用 (bottom-half)。
  signal 源用ヘルパ `mrb_task_request_switch(mrb)` (= `switching_ = TRUE`) を追加。
- `lib/replace/picoruby-machine/ports/esp32/machine.c` および
  `.../ports/esp32_linux/hal_freertos.c`: tick タスクを signal-only 化
  (`pending_ticks++` + `mrb_task_request_switch()`)。`mrb_hal_task_take_pending_ticks()`
  を実装。`mrb_task_disable_irq`/`enable_irq` を no-op 化。esp32 は `mrb_hal_task_init`
  の no-op を解除して tick タスク再有効化。registry に `pending_ticks` 追加。
- `lib/replace/picoruby-machine/include/hal.h`: `mrb_task_request_switch` /
  `mrb_hal_task_take_pending_ticks` のプロトタイプ追加。
- `lib/add/picoruby-fmrb-app/ports/esp32/app.c`: `_spin` 末尾の補償 `mrb_tick` を削除
  (mrb_task_run に一本化)。

実装で判明した要点 (当初案からの差分):

- signal 源 (machine.c / hal_freertos.c) は **`mrb->task.switching` を直接書けない**。
  `mrb->task` は `MRB_USE_TASK_SCHEDULER` ガード下で、HAL ポートの翻訳単位ではこのマクロが
  未定義 → `mrb_state` にこのフィールドが見えずコンパイルエラー。そのため task.c 側に
  `mrb_task_request_switch()` を置き、signal 源はそれを呼ぶ (関数越しに 1 volatile 書込)。
- `rake clean` 必須: lib/ 編集後、増分ビルドは picoruby 静的ライブラリ内の task.c を
  再コンパイルせず未定義参照になる。クリーン後は通過。

#### 回帰と修正 (2026-06-04): switching_ の過剰頻度で longjmp 破壊 → timeslice カデンス化

初版 (signal 源が**毎 tick** `switching_` をセット) は Linux 実機 (docker compose) で
`*** longjmp causes uninitialized stack frame ***` で abort。boot 時の
`create_image_from_file` (boot.png ロード、host 往復 + 内部 mrb_funcall 再入) の最中に
`switching_` が当たり、ネストした `mrb_vm_exec` が早期 return して例外/longjmp 文脈を破壊
するため。

原因の本質: **`switching_` を非同期に立てる頻度**。旧コード (tick タスクが full mrb_tick)
は `switching_` を **timeslice 満了時 (~50ms)** にのみ、かつ `in_c_funcall==EXIT` gate
付きでセットしていて安定だった。初版 案D は毎 tick (5ms) = 10倍頻度 + gate 無しにした
ため、再入中の窓に高確率で当たった。

修正: signal 源を旧コードの安全カデンスに合わせた。

- `pending_ticks` は**毎 tick 加算** (時間精度。bottom-half が drain して `mrb_tick` 適用)。
- `switching_` は **per-VM countdown で timeslice カデンス** (`MRB_TIMESLICE_TICK_COUNT`
  ごと) かつ **`in_c_funcall==EXIT` のときだけ**セット (`_spin`/kernel の C ブラケット中は
  preempt しない)。registry に `tick_countdown` 追加。
- キュー処理は引き続き VM 自スレッド (bottom-half) なので ESP32 のキュー破壊修正は維持。

結果: Linux で `create_image_from_file` を通過し、desktop 起動 + 描画継続を 45 秒間
クラッシュ無しで確認 (`rake clean_all && rake build:linux` → `docker compose up`)。

> **注: 上の timeslice カデンス化は不十分だった。** ESP32 実機では desktop 操作中
> (boot 後 ~2分) に同じ `task context corrupted: no proc on resume` が再発した。
> 真因と最終修正は下記。

#### 確定した真因と最終修正 (2026-06-05): async switching はネスト C 再入中に作用させてはいけない

timeslice カデンス版を ESP32 実機に焼いて操作したところ、kernel + system_desktop だけの
状態 (複数アプリ起動前) でも、マウス操作・オーバーレイ開閉の最中に
`task context corrupted: no proc on resume` → Guru Meditation で再発。頻度を下げただけでは
直らなかった。

**確定した真因:** async `switching_` が **ネストした C 再入 (C メソッドが `mrb_funcall` で
VM に再入。例: gfx の host 往復) の最中**に作用すると、ネスト側の `mrb_vm_exec` が
`RETURN_IF_TASK_STOPPED` で**早期 return** し、二重に壊す:

1. **ci スタックが巻き戻されない。** 早期 return は OP_RETURN を経ないので、`mrb_funcall` が
   積んだ ci が pop されず `mrb->c->ci` が深いまま C 側に戻る → 次の resume で
   `ci->proc == NULL` (= "no proc on resume")。
2. **`mrb->jmp` が復元されない。** 正常終了 (OP_STOP) は `mrb->jmp = prev_jmp` を実行するが、
   早期 return はこれをスキップ → `mrb->jmp` がこの mrb_vm_exec フレームの死んだ
   `c_jmp` を指したまま → 後続の例外 longjmp が死んだフレームに飛ぶ
   (Linux の `longjmp causes uninitialized stack frame` はこの症状)。

→ **doc 前半の「クロススレッドのキュー競合」は真因の一部に過ぎなかった。** 案D で
mrb_tick を VM 自スレッドに移してキュー競合は閉じたが、**async `switching_` の作用点**が
未対策だったためクラッシュが残った。Linux と ESP32 の症状 (longjmp / no proc) は同じ根。
ESP32 で確実に出るのは host 往復が UART で **ms〜秒**と長く、再入窓が桁違いに大きいから
(Linux のローカルソケットは µs)。

**最終修正 (vm.c を lib/patch に vendoring):**
`lib/patch/picoruby-mruby/lib/mruby/src/vm.c` の `RETURN_IF_TASK_STOPPED` を改修:

- **最上位バイトコード境界でのみ yield。** `mrb_task_yield_ok()` で ci チェーンを current
  から下に走査し、`cci > 0` (C 境界) が一つでもあれば yield しない。→ ネスト C 再入中の
  async switch は**次の安全点 (C 呼び出しから戻った top-level) まで自動的に遅延**される。
  走査は switching が立っている時だけ・C 境界で即 FALSE なので浅く済む。
- **早期 return 時に `mrb->jmp = prev_jmp` を復元** (stop / switch の両経路)。

この vm.c 修正で **async switching を保ったまま** (= yield しない CPU-bound タスクの
プリエンプション要件を満たしたまま) ci/jmp 破壊を防げる。machine.c/hal_freertos.c の
`in_c_funcall==EXIT` gate は撤去 (vm.c が全 C 境界を自動判定するので不要)。switching は
timeslice カデンス (per-VM `tick_countdown`) のまま。

**検証:** ESP32 実機に焼いて desktop 操作をしばらく続けてもクラッシュ再発せず (2026-06-05)。
`rake build:esp32` / `build:linux` ともクリーン。

補足 (Linux が実機代用にならない理由の精緻化): ESP-IDF の FreeRTOS Linux ポートは各タスクを
pthread で実装するが、**走行中以外のスレッドは `sigwait()` でブロックし、切替は SIG_RESUME
で1つずつ resume する = 実効シングルコア** (WSL2 のコア数に関わらず FreeRTOS タスクは並行
실行されない)。ただし本バグは真の並行を要さない (VM 自スレッドが再入中に switching を観測
すれば足りる) ので、Linux で初版が longjmp で落ちたのは正しい挙動。2回目が落ちなかったのは
(1) 操作を流していない (2) 再入窓が µs と短い、が主因で、並行性の差は二次的。

**残:** 3-tick timeslice カデンスの調整、tick タスクの優先度/コア配置の見直し (現状 prio 5・
アフィニティ無し)、rp2040/posix HAL への `mrb_hal_task_take_pending_ticks` 追加、vendoring した
vm.c の上流追従メンテ。

### 案B-改 (重い代替): `taskENTER_CRITICAL` (portMUX) で cross-core 排他

並行 `mrb_tick` を**維持したい**場合の代替。`mrb_task_disable_irq()` を ESP-IDF の
`portMUX` スピンロック (`taskENTER_CRITICAL`/`taskEXIT_CRITICAL`) に置き換え、tick スレッドと
VM スレッドが触る共有可変状態 (タスクキュー + スケジューラスカラ) を同じ mux 下で操作する。
協調フラグに無かった「別コアでも待つ」保証が得られる。

**決定的な制約:** スコープは**短いキュー操作 + `mrb_tick` 本体だけ**で、`mrb_vm_exec` は
**絶対に囲まない** (割り込み禁止 + 他コアスピンの長時間保持は Interrupt WDT 発火・規約違反)。
スケジューラは `ENTER→head 選択/dequeue→EXIT →(ロック外で)execute→ENTER→状態遷移/再挿入→EXIT`
のパターンになる。

実装上の注意 (Step1 監査済 §6): (1) `mrb_tick` 本体も同じ mux で囲む、(2) portMUX 非再帰
ゆえ disable/enable_irq のネスト不可 (現状クリーン)、(3) critical section 内で
ブロッキング/malloc/ログ禁止、(4) mux 粒度はグローバル spinlock 寄り。

案D に対する欠点: スケジューラへ portMUX を足し、introspection の snapshot 化も要る
(Step1-B)。**案D が成立する以上、本命は案D**。案B-改は「どうしても専用スレッドで並行
`mrb_tick` を回したい」要件が出た場合の保険として記録に残す。

### 案A (案D の不完全版): tick タスクを「シグナルのみ」にする

tick タスクが pending を increment するだけにし、VM が安全点で drain する案。**`switching_`
を立てないと yield しない CPU-bound タスクをプリエンプトできない** (要件1 未達) のが欠点。
→ ここに「signal が `switching_` も立てる」+「bottom-half を `mrb_task_run` に置く」を足した
ものが**案D**。案A は案D の前駆形として記録。

### 案C: per-VM タイマ割り込み (却下)

ISR プリエンプションを再現する案。本実機では **VM タスクが core 非 pin** かつ
**mrb_state/キューが PSRAM 上**のため、(a) ISR からの PSRAM/非 IRAM アクセスは flash
キャッシュ無効窓で不可、(b) ISR と対象 VM が同一コアにいる保証が無く ISR のアトミック性も
成立しない。ISR 化のうまみが無いので却下。`mrb_tick` 本体を外部実行する点は案B-改/現行と
同じ問題を抱える。

---

## 6. Step1 実現性検証: portMUX 化のネスト監査 (2026-06-02)

案B-改 (portMUX スピンロック化) の最大の懸念だった「portMUX 非再帰 → 二重取得デッド
ロック」を、コード変更せず読み取りのみで監査した。対象は
`lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c`。

### A. デッドロック (非再帰ネスト) リスク → クリーン。問題なし

- `disable_irq` / `enable_irq` は task.c 内に **15 ペア (balanced)**。task.c 外からの
  C 呼び出しは**ゼロ** (mruby core の vm.c / gc.c も不使用、`hal.h` のマクロ定義のみ)。
- `q_insert_task` / `q_delete_task` の外部呼び出しも**ゼロ**。
- ロックを取るヘルパは 3 つだけで、いずれも**ロック区間の外からしか呼ばれない**:

  | ヘルパ | 呼び出し元 | 区間との関係 |
  |---|---|---|
  | `task_change_state` | `mrb_task_run`:484 / `run_once`:517 / `suspend_internal`:1311 / `resume_internal`:1344 | 全て区間外 (自身が disable/enable する) |
  | `wake_up_join_waiters` | `execute_task`:395 / `terminate_internal`:1391 | 両方とも `enable_irq` の直後 (区間外) |
  | `task_cleanup_if_stopped` | `run`:475 / `run_once`:508 / `run_one_iteration`:795 | 全てループ先頭 (区間外) |

- `mrb_tick` 本体は `q_delete_task` / `q_insert_task` しか呼ばず、ロック取得ヘルパを
  呼ばない → **本体を丸ごと `taskENTER_CRITICAL` で囲っても再帰しない**。

→ **portMUX 非再帰の制約は現コードのまま満たせる。** 「呼び出し側がロック、ヘルパは
非ロック」という既存規律が portMUX 要件とそのまま整合する。

### B. critical section 内の禁止操作 (alloc / funcall / ログ) → 3 箇所だけ要対応

14/15 のミューテーション区間は「キューポインタ + スカラ操作のみ」で portMUX 適合。
ただし**キューを走査して Ruby オブジェクトを生成する introspection API** が
critical-section ルール (alloc 禁止・短時間) に抵触する:

| 関数 | 現状 | 問題 |
|---|---|---|
| `mrb_task_s_stat` (854-866) | 区間内で `mrb_hash_set` + `mrb_stat_sub` (`mrb_hash_new`/`mrb_ary_new`/`mrb_ary_push`) | 区間内 alloc = portMUX 違反 |
| `mrb_task_s_list` (763-778) | ノーロックでキュー走査 + `mrb_ary_push` | 並行 relink で torn read → 不正 next 参照クラッシュ |
| `mrb_task_s_get` (877-896) | ノーロックでキュー走査 | 同上 |

いずれも `Task.stat` / `Task.list` / `Task.get` のデバッグ/内省系で、クラッシュ経路の
本筋ではない。対応は定型かつ軽微: **ロック下では「カウントとタスクポインタの snapshot を
局所配列に取る」だけにし、Ruby オブジェクト生成はロック解放後に行う**。

### C. mux 粒度: void シグネチャはグローバル spinlock を後押し

`mrb_task_disable_irq(void)` は引数なしで、現状 `fmrb_current()` で VM を引いている。
per-VM mux にすると毎回ルックアップが要る。q 区間は数マイクロ秒で競合も極小なので、
**単一グローバル scheduler spinlock** にすれば `disable_irq(void) → taskENTER_CRITICAL(&g_mux)`
とルックアップ無しで書ける。実装単純さの観点でグローバル寄りが妥当。

### D. critical section の長さ → 許容範囲

`q_insert_task` / `q_delete_task` は優先度順の O(n) 走査、`mrb_tick` の wakeup は
q_waiting_ を 1 周。いずれも n = タスク数 (数個) で μ 秒オーダー。Interrupt WDT に対して
十分短い。

### 結論

**(案B-改の) portMUX 化は実現可能。** デッドロック面はクリーンで、唯一の実装作業は
introspection 系 3 関数 (stat / list / get) の snapshot 化という局所的・定型的な改修。
加えて mux 粒度 (グローバル vs per-VM) を決める判断が 1 点。

> 注: 本 §6 は**案B-改 (重い代替) を採る場合**の実現性監査。現在の本命は**案D** (§5) で、
> 案D ではキューをクロススレッドで触らないため portMUX も snapshot 化も不要。
> この監査結果は案B-改にフォールバックする場合のみ参照。

---

## 7. 追加で裏取りすべき点 (TODO)

- (案D 実装) 全登録 VM が `mrb_task_run` を回すこと (= scheduler を回さない VM を register
  しない規律) の最終確認。host_task 等の C 専用タスクが mruby VM を register していないか。
- (案D 実装) `mrb_hal_task_take_pending_ticks` の atomic 化方式 (registry mutex 流用 or
  volatile + メモリバリア) と、4 ポート (esp32 / posix / esp32_linux / rp2040) の実装。
- (案D 実装) `_spin` の補償 `mrb_tick` 削除と `mrb_task_run` 一本化での tick_ 進行確認
  (二重計上が無いこと、Task.tick / sleep 精度の回帰確認)。
- `mrb_incremental_gc` / `mrb_task_mark_all` がキューを走査する区間と tick の競合経路。
  案D では tick も GC も VM 自スレッドで逐次なので競合しないはずだが、念のため確認。
- (案B-改 にフォールバックする場合のみ) introspection 系 (stat/list/get) の snapshot 化。

---

## 参考ファイル

- スケジューラ本体: `fmruby-core/lib/patch/picoruby-mruby/lib/mruby/mrbgems/mruby-task/src/task.c`
- VM 単位 state 定義: `fmruby-core/components/picoruby-esp32/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby.h` (`mrb_task_state`)
- VM の switching 消費点: `.../mruby-task/.../src/vm.c` の `RETURN_IF_TASK_STOPPED` (命令ディスパッチ毎に `mrb->task.switching` を判定)
- tick タスク / 協調 irq フラグ: `fmruby-core/lib/replace/picoruby-machine/ports/esp32/machine.c`
- `_spin` 補償 tick: `fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/app.c`
- VM 登録: `fmruby-core/main/app/fmrb_app.c` (`hal_register_vm`)

## 関連コミット

- `2e6cdba` (2026-04-18) — tick task 無効化 (`mrb_hal_task_init` を no-op 化)
- `57e61dc` (2026-04-15) — tick task 再有効化 (本バグ顕在化)
- `4f604db` (2026-03-21) — tick task no-op 化 (潜伏期間)
