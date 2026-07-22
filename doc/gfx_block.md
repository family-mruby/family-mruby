# GfxBlock 仕様 / Ruby からの使い方

`GfxBlock` は描画コマンド列をバイトコードにコンパイルして WROVER 側で
キャッシュし、以降は変化したパラメータ(レジスタ)だけを送ることで Core
↔ WROVER 間の通信コストを削減するための仕組みです。

実装本体: [`fmruby-core/lib/add/picoruby-fmrb-app/mrblib/gfx_block.rb`](../fmruby-core/lib/add/picoruby-fmrb-app/mrblib/gfx_block.rb)
背景設計: [`tmp/window_roundcorner_and_batch_vm.md`](../tmp/window_roundcorner_and_batch_vm.md) Part B

---

## 1. 動作モデル

```
[Core / Ruby]                              [WROVER / C]
GfxBlock.new(gfx, **kw) { |r, **kw| ... }
   │ 1. ブロックを 2回試行実行 (kwarg 値を変えて差分を検出)
   │ 2. コマンド列をバイトコード化
   │ 3. DEFINE_PROG (bytecode + strtable) を送信  ─────────►  prog 登録
   │ 4. 初回 EXEC_PROG (全レジスタ送信)             ─────────►  描画
   ▼
block.draw(**new_kw)
   │ 5. ブロックを再評価して新しいレジスタ値を計算
   │ 6. 変化したレジスタだけを EXEC_PROG で送信     ─────────►  描画
   ▼
block.destroy
   │ 7. DELETE_PROG                                ─────────►  prog 解放
```

要点:

- **コマンド列は WROVER に常駐**する。再描画時にコマンド列自体は再送
  されない。
- `draw` 時は変化した整数レジスタ(各2バイト)のみ送られる。固定値・
  文字列・色定数はバイトコード内に埋め込まれているため転送不要。
- ブロック評価は Core 側で毎回走る。Ruby 内の三項演算子・算術・閉包
  キャプチャは自由に書けるが、**生成されるコマンド列が毎回同じ構造で
  ある必要がある**(下記制約参照)。

---

## 2. 仕様

### 2.1 制約

| 制約 | 詳細 | 違反時 |
|------|------|--------|
| 同一コマンド列 | コマンド数・opcode・引数個数が呼び出し毎に一致 | `StructureError` |
| kwarg 型 | `Integer` / `Float` / `String` のみ。`Float` は `to_i` で量子化、`String` は new 時に固定 | `UnsupportedKwargError` |
| レジスタ数 | 1 ブロックあたり最大 `GfxBlock::MAX_REGS = 16` | `TooManyRegsError` |
| バイトコード+strtable | 1 UART フレームに収まる必要があり最大 `220 B` (ヘッダ6B 含む) | `PayloadTooLargeError` |
| 不可命令 | `rand` / `Time.now` 等の非決定的式は kwarg 経由でなければ使用しない | 構造ズレ → `StructureError` |

「同一コマンド列」の例:

```ruby
# NG: kwarg n の値で fill_rect の数が変わる -> StructureError
GfxBlock.new(@gfx, n: 3) do |r, n:|
  n.times { |i| r.fill_rect i*8, 0, 6, 6, 0xFF }
end

# OK: kwarg は色や座標を変えるだけ。コマンド数は固定
GfxBlock.new(@gfx, c0: 0, c1: 0, c2: 0) do |r, c0:, c1:, c2:|
  r.fill_rect 0, 0, 6, 6, c0
  r.fill_rect 8, 0, 6, 6, c1
  r.fill_rect 16, 0, 6, 6, c2
end
```

### 2.2 サポート命令(Recorder DSL)

| メソッド | opcode | 引数 |
|---------|--------|------|
| `clear(color)` | `GFXVM_OP_CLEAR` | color |
| `fill_rect(x, y, w, h, color)` | `GFXVM_OP_FILL_RECT` | x, y, w, h, color |
| `draw_rect(x, y, w, h, color)` | `GFXVM_OP_DRAW_RECT` | x, y, w, h, color |
| `fill_round_rect(x, y, w, h, r, color)` | `GFXVM_OP_FILL_ROUND_RECT` | x, y, w, h, r, color |
| `draw_round_rect(x, y, w, h, r, color)` | `GFXVM_OP_DRAW_ROUND_RECT` | x, y, w, h, r, color |
| `draw_line(x0, y0, x1, y1, color)` | `GFXVM_OP_DRAW_LINE` | x0, y0, x1, y1, color |
| `fill_circle(x, y, r, color)` | `GFXVM_OP_FILL_CIRCLE` | x, y, r, color |
| `draw_text(x, y, str, color)` | `GFXVM_OP_DRAW_TEXT` | x, y, str_id, color |

エイリアス: `rect = draw_rect`, `line = draw_line`, `text = draw_text`。

サポートしていないもの:

- 画像系 (`draw_image` / `create_image`)
- スプライト・カーソル系
- ピクセル単位 (`draw_pixel`)
- `present`(ブロック内では呼ばない。`@gfx.present` は呼び出し側で行う)

### 2.3 レジスタ判定

`new` 時に 2回ブロックを実行し、各 op の引数で値が変化した位置を
レジスタとして抽出する。

- 最初のパスは `initial_values` を渡す
- 2 回目は各 kwarg を `+1`(`Float` は `+1.0`)して値を変える
- 同じ kwarg を複数の引数に渡しても、その全ての位置がレジスタになる
- ブロック内でローカル変数や定数として畳まれた値はバイトコード即値に
  なる(レジスタを消費しない)

```ruby
GfxBlock.new(@gfx, x: 10, color: 0xFF) do |r, x:, color:|
  CELL = 8                              # 即値、reg 消費しない
  pad  = 2                              # 即値
  r.fill_rect x,        0, CELL, CELL, color  # x: reg, color: reg
  r.fill_rect x + 8,    0, CELL, CELL, color  # x の派生も追跡される
end
```

### 2.4 文字列 (`draw_text`)

文字列は **`new` 時に strtable に intern される**ため、`draw` 時に
別文字列へ差し替えることは**できない**。

```ruby
# NG: text を kwarg にしても無視される (StructureError には
# ならないが描画される文字列は new 時のもの)
GfxBlock.new(@gfx, label: "0") do |r, label:|
  r.draw_text 0, 0, label, 0xFF
end
```

数値表示など可変テキストは、ブロック外で
`@gfx.fill_rect(...) → @gfx.draw_text(...)` で行う(参考: tetris の
`draw_info`)。

### 2.5 例外型

```
GfxBlock::Error               # 基底クラス (StandardError 継承)
  ├── StructureError          # コマンド列が呼び出し毎にズレた
  ├── TooManyRegsError        # 16 レジスタを超えた
  ├── UnsupportedKwargError   # サポート外型の kwarg
  └── PayloadTooLargeError    # 単一フレーム上限を超過
```

---

## 3. Ruby からの使い方

### 3.1 ライフサイクル

```ruby
class MyApp < FmrbApp
  def on_create
    # ブロックを構築 (DEFINE_PROG + 初回 EXEC が走る)
    @body = GfxBlock.new(@gfx, x: 0, y: 0, color: 0) do |r, x:, y:, color:|
      r.fill_rect 0, 0, @user_area_width, @user_area_height, FmrbGfx::BLACK
      r.fill_circle x, y, 8, color
    end
    @gfx.present
  end

  def on_update
    @body.draw(x: rand(100), y: rand(100), color: rand(0xFF))
    @gfx.present
    33
  end

  def on_destroy
    @body&.destroy   # WROVER 側の prog を解放
  end
end
```

### 3.2 ブロックシグネチャ

PicoRuby には `instance_exec` がないため、ブロックの **第1引数は
`Recorder` インスタンス** (慣例で `r`) を受け取り、kwargs に kw
パラメータを並べる。

```ruby
GfxBlock.new(@gfx, w: 10, h: 20) do |r, w:, h:|
  r.fill_rect 0, 0, w, h, 0xFF
end
```

### 3.3 静的ブロック(kwargs なし)

「絵柄が完全に固定」だが何度も再描画したい場合は kwargs なしで
良い。背景パネル・ラベル群などに有効。

```ruby
@bg_block = GfxBlock.new(@gfx) do |r|
  r.fill_rect 0, 0, 320, 240, 0x29
  r.draw_text 4, 4, "READY", 0xFF
end
@bg_block.draw                         # 引数なしで再実行
```

### 3.4 1ブロックを複数の絵で使い回す

「コマンド列の構造が同じで色や位置だけ違う」用途は同じブロックで OK。

例: tetris の `@piece_block` は active piece, ghost piece の双方で使う
([`flash/app/game/tetris.app.rb`](../fmruby-core/flash/app/game/tetris.app.rb)
の `draw_4cells_at`)。

### 3.5 何を Block 化すべきか

| 適している | 不向き |
|-----------|--------|
| ウィンドウ枠・パネル枠などの静的レイアウト | 描画数が可変 (例: ボード全セル走査) |
| 数フレーム毎に座標/色だけ変わるオブジェクト | 動的文字列 (スコア表示など) |
| 4–10 個程度のプリミティブで構成される塊 | 16 レジスタを超える絵 |
| 何度も同じ絵を再描画する場面 | 一度しか描かない初期化処理 |

### 3.6 上限を超えそうなときの分割パターン

- 16 レジスタ超: 絵を「動かない部分」と「動く部分」に分け、前者を
  別ブロックや `@gfx` 直叩きにする
- 220 B 超: コマンド列が長すぎる。複数ブロックに分割する
- 動的文字列: 文字列だけ Block 外で `fill_rect → draw_text`、それ以外
  を Block 化する

---

## 4. 実装例

### 4.1 ウィンドウ枠 — 静的ブロック

[`fmruby-core/lib/add/picoruby-fmrb-app/mrblib/fmrb-app.rb`](../fmruby-core/lib/add/picoruby-fmrb-app/mrblib/fmrb-app.rb#L88-L106)
の `_build_frame_block`:

```ruby
@frame_block = GfxBlock.new(@gfx, w: @window_width, h: @window_height) do |r, w:, h:|
  r.fill_round_rect 0, 0, w, TITLE_BAR_H, CORNER_R, 0xC5
  r.fill_rect       0, CORNER_R, w, TITLE_BAR_H - CORNER_R, 0xC5
  r.fill_rect       3, 3, 9, 1, 0xFB
  ...
  r.draw_round_rect 0, 0, w, h, CORNER_R, 0x60
end
```

### 4.2 動くオブジェクトの群れ — 8 個のボール

[`fmruby-core/flash/app/demo/mruby.app.rb`](../fmruby-core/flash/app/demo/mruby.app.rb#L268-L289)
の `_build_ball_block`: ボール 8 個 = (x, y) × 8 = 16 レジスタ。

### 4.3 同一ブロックを 2 用途で使い回す — テトリス

[`fmruby-core/flash/app/game/tetris.app.rb`](../fmruby-core/flash/app/game/tetris.app.rb)
の `@piece_block` は 4 セル分の `fill_rect` を持ち、active piece と
ghost piece (色だけ違う) で同じブロックを `draw` し直して使い回す。

---

## 5. デバッグ

- `GfxBlock::StructureError` が出る → ブロック内で kwarg 経由でない
  動的処理(例: `if rand > 0.5 ...`)が混入している。
- `GfxBlock::TooManyRegsError` → 16 レジスタを超えた。固定座標の項目
  はブロック内のローカル変数として閉包キャプチャすれば即値化される。
- WROVER 側で「絵が更新されない」 → `block.draw` の後に
  `@gfx.present` を忘れていないか確認。`draw` は EXEC を発行するが
  最終合成と表示は present 起因。

---

## 6. 参考

- VM 命令定義(C側): [`fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/gfx_block.c`](../fmruby-core/lib/add/picoruby-fmrb-app/ports/esp32/gfx_block.c)
- 単体テストアプリ: [`fmruby-core/flash/app/debug/gfx_block_test.app.rb`](../fmruby-core/flash/app/debug/gfx_block_test.app.rb)
