# fm_asset_editor

flash/ に入る絵 (スプライト・アイコン・BASIC の文字シート) を編集する
デスクトップアプリ。Ruby + glimmer-dsl-libui で書かれていて、WSL2 では
WSLg にそのまま窓が出る。

```
gem install glimmer-dsl-libui            # 初回のみ (libui 本体を同梱、sudo 不要)
ruby tools/fm_asset_editor/fm_asset_editor.rb                # 何を作るか選ぶ画面から
ruby tools/fm_asset_editor/fm_asset_editor.rb 絵か曲のファイル
ruby tools/fm_asset_editor/fm_asset_editor.rb --new 24x24   # 空のスプライトから始める
ruby tools/fm_asset_editor/fm_asset_editor.rb --new mml     # 空の曲から始める
ruby tools/fm_asset_editor/fm_asset_editor.rb --formats     # 何を編集できるか一覧
```

**引数なしで起動すると、何を作るかを選ぶ画面**が出る (スプライトは大きさ指定、
BASIC 文字シート、曲、ファイルを開く)。あとから選び直すときは File > New...。

窓が出ない場合は `echo $DISPLAY` を確認する (WSLg なら `:0`)。Wayland 経由で
不具合が出るときは `GDK_BACKEND=x11` を付ける。

WSL2 では `DBUS_SESSION_BUS_ADDRESS` が設定されているのに実体のソケットが
無いことが多く、そのままだと GTK が設定を書くたびに
`dconf-WARNING **: failed to commit changes to dconf` を大量に出す。
**セッションバスが本当に無いときだけ** `GSETTINGS_BACKEND=memory` を
自分で立てて黙らせている (自分で環境変数を指定した場合はそちらを尊重する)。
失われるのは GTK 自身のダイアログの記憶だけで、フォルダの記憶はこの道具が
別に持っている。

扱えるもの:

- **絵** (スプライト / アイコン / BASIC の文字シート) — 下記
- **曲** (`.mml`、`FmrbMidi::MmlPlayer` が鳴らすもの) — [曲を編集する](#曲を編集する-mml)

## なぜ専用の道具なのか

これらの BMP は、普通の画像編集ソフトが思っている意味とは違う中身を持つ。

| 種類 | 例 | 画素の意味 |
|---|---|---|
| スプライト / アイコン | `usr/share/sprites/*.bmp`, `usr/share/icon/*.bmp`, `app/game/**/*.bmp`, graphics-audio の `flash/sprites/launcher/*.bmp` | **画素の値がそのまま RGB332 の色**。0 は透明。ファイル内のパレットは読み込み側 (`fmruby-graphics-audio/main/common/fmrb_bmp332.c`) が見ていない (閲覧ソフト向けの飾り) |
| BASIC 文字シート | `usr/share/basic/font_b.bmp`, `tile_a.bmp` | 128x128 に 8x8 のマスが 16x16。文字コードは 行*16+列。値は 0〜3 の **色属性の番号** (0 消灯 / 1,2 属性 / 3 が墨。同梱の絵は 3 で描かれている) |

読み込み側が受け付けるのは **8bpp 無圧縮・幅も高さも 256 まで**。汎用ソフトは
書き出し時にパレット番号を並べ替えたり 24bit に昇格したりするので、これらを
黙って壊しうる。この道具は必ず上の形で書き戻す。

**表示は常に RGB332 の正規表から行う**。つまり画面に出ている色は、閲覧ソフトが
見せる色ではなく**実機が出す色**。

## 操作

| | |
|---|---|
| 左ドラッグ | 選択中の色で描く |
| 右クリック | 消す (透明、シートなら 0) |
| 1 / 2 / 3 | 鉛筆 / 塗りつぶし / 色拾い |
| + / - | 拡大・縮小 |
| g | 格子の表示切替 |
| Ctrl+Z / Ctrl+Y | 元に戻す / やり直す |
| Ctrl+S / Ctrl+O | 保存 / 開く |

右側の「Guide」は補助線の間隔。文字シートでは 8 が入っていて、マスの境目が
橙色で出る。タイルシートを編集するときは自分でマス目を入れる。

## 色の指定 (3 通り)

スプライトでは、次の 3 つがいつでも同期している。どれで指定してもよい。

- **パレット**: 256 色すべてが常に見える。スクロールはせず、窓の大きさに
  合わせて並べ方 (列数と一マスの大きさ) を計算し直す。
- **R / G / B の数字**: **実機の段数そのまま**で 0-7 / 0-7 / 0-3。丸めが
  起きないので、狙った色をそのまま置ける。
- **16 進**: `5E` `0x5E` `#5E` は **RGB332 の値そのもの**。
  `#RRGGBB` `RRGGBB` `#RGB` と 6 桁 (3 桁) で書くと **24bit の色として読み、
  最寄りの RGB332 に丸める** (`ff8000` → `0xEC` = R7 G3 B0)。外の絵から色を
  持ってくるときはこちら。

文字シートでは値が色ではなく番号 (0-3) なので、数値入力は無効になり、
4 つの見本だけが出る。

## 開く / 保存のフォルダ

**開くときと保存するときで、それぞれ最後に使ったフォルダから始まる**。
覚えている場所は 2 つ別々で、次のように決まる。

1. そのダイアログを最後に使ったフォルダ
2. 無ければ、今開いているファイルのあるフォルダ
3. それも無ければ、起動したときのフォルダ

記憶は `~/.config/fm_asset_editor/state.json` (`XDG_CONFIG_HOME` に従う) に
入っていて、次に起動したときも残る。消えたフォルダは黙って忘れる。

補足: libui のダイアログには開始フォルダを渡す口が無く、GTK は既定で
「最近使った項目」を開いてしまう。そこで**ダイアログだけ GTK を直接呼んで**
いる (`ui/file_dialog.rb`。GTK の口が見つからない環境では libui のダイアログに
戻り、フォルダの指定だけができなくなる)。

## パレットの正規化

`usr/share/sprites/` の 7 ファイルは、RGB332 を RGB888 に広げるときの丸めが
他の生成物と 1 だけ違うパレットを持っている。**開いて保存しただけで 156 バイトの
差分が出ないよう、ファイルにあったパレットはそのまま書き戻す**。正規の表に
直したいときは Edit > Normalise Palette を実行してから保存する
(実機での見え方は元から変わらない。変わるのは閲覧ソフトでの見え方だけ)。

## 曲を編集する (MML)

```
ruby tools/fm_asset_editor/fm_asset_editor.rb fmruby-core/flash/usr/share/music/round.mml
ruby tools/fm_asset_editor/fm_asset_editor.rb --new mml
```

`.mml` を開くと窓は**曲の面**に変わる (文字を打つ場所と、その下にピアノロール)。

### ファイルの形

```
# 行頭の # は註釈 (パートの中では # は嬰記号なので、行頭だけ)
bpm 120          テンポ。方言にテンポ命令が無いのでファイルが持つ
loop off         最後まで行ったら繰り返すか (既定 off)
velocity 80      これ以降のパートに効く (既定 100)
voice triangle   声の割り当て pulse1 / pulse2 / triangle / noise
duty 1           パルス幅 0-3 (12.5 / 25 / 50 / 75%)
volume 100       チャンネル音量 0-127
program 24       外部 MIDI 音源の音色 (GM 番号)
o5 l4 cegegegc   パート。1 行 1 パートで、上から順にチャンネル 0,1,2...
```

**音色は MML の文字列では選べない**。方言に音色命令が無く、`@1` などと書いても
黙って無視される。音色はチャンネルの性質なので、上の 4 行がその代わりになる
(`velocity` と同じく、それ以降のパートに効く)。省けば実機の既定のまま
(チャンネル 0=pulse1 / 1=pulse2 / 2=triangle / 9=noise)。

パートの中身は `MIDI::MML::Sequence` が読む方言そのもの
(`o` `l` `v` `>` `<` `r` `.` `&` `[...]n`、`c+` `c#` `c-`)。**エディタは
方言を書き直さず、実機と同じパーサ (`fmruby-core/lib/add/picoruby-midi-mml`)
をその場で読み込んで使う**ので、画面に出る音符と長さは実機の解釈と一致する。
core が隣に無いときは、書くことはできるが下の確認機能が止まる。

### エディタが出せること

- **ピアノロール**: パートごとに色を変えて、入りと重なりが見える。
  左端に鍵盤が出て、黒鍵の段はロール全体を薄く塗ってあるので、
  線を数えなくても音程が読める (C の段には `C4` のように名前が付く。
  行の高さに余裕があれば白鍵すべてに付く)
- **再生位置**: 再生中は赤い線が進み、`0:01.6 / 0:04.0` と時間が出る。
  **ロールのどこかを掴めばそこへ飛ぶ** (再生中ならその位置から鳴り直す)
- **数え**: パート数・音数・拍 (clocks)・秒
- **黙って捨てられる文字の指摘**: パーサは知らない文字を**警告なく無視する**
  (打ち間違いが「音が出ない」として現れる) ので、行と桁を出す
- **パートの一覧**: 何がそのパートを鳴らすか (声・デューティ・音量・GM 音色
  とその名前) を Notes 欄に並べる
- **音**: Play で鳴らす。**声とデューティは試聴にも効く** (pulse は指定した幅の
  方形波、triangle は三角波、noise は雑音、volume は音量)。ただし APU の
  似姿であって実機の音そのものではない。`program` は外部音源の話なので
  試聴では鳴り方が変わらず、番号と名前を出すだけ。
  合成は 44.1kHz で、**4 倍に細かく描いてから平均して落とす** (方形波を
  出力の刻みでそのまま作ると、折り返しと縁のずれで音がざらつく)。
  最後に直流分を落とす一次のフィルタを通す (幅の狭いパルスは 0 を中心に
  していないので、そのままだと段差が「ぼこっ」と鳴る)。4 秒の曲で用意に
  0.2 秒ほどかかる。
  Export WAV でファイルにも落とせる。再生には `paplay` / `play` (sox) /
  `ffplay` / `aplay` のどれかを使う
- **BPM と Loop**: 数値入力を触るとテキストのその行だけを書き換える

### 実機で鳴らす

```ruby
player = FmrbMidi::MmlPlayer.new(FmrbMidi.device(self))
player.load_file("/usr/share/music/round.mml")   # bpm も loop もファイルから
player.start
```

`load_file` は読み込みのときに音色の設定も送る (声は transport の
`map_channel`、デューティと音量は control change、音色は program change)。
使い道の無い装置はそれを無視するので、同じファイルが内蔵音源でも外部音源でも
そのまま通る。実装は `lib/add/picoruby-fmrb-midi/mrblib/fmrb-mml.rb`。
ホスト側の検査は `fmruby-core` で `ruby tool/midi/test/mml_test.rb`。

## テスト

```
ruby tools/fm_asset_editor/test/round_trip_test.rb
```

画面もコンテナも要らない。リポジトリにある BMP を全部開いて書き戻し、
**1 バイトも変わらないこと**を確かめる。ほかに undo/redo、塗りつぶし、
新規スプライトのパレット、大きさの上限、`.mml` の読み書きと音の生成、
ダイアログのフォルダ記憶も見る。lib/ を触ったらこれを回す。

## 構成 (BMP 以外を足すとき)

`lib/fm_asset_editor/format.rb` が種別の登録簿。次の受け答えができる
オブジェクトを `Format.register` すれば足せる。

```
label / extensions / detect?(path) / load(path) -> Document / write(doc, path)
view    -> :grid  (窓が今持っている唯一の見せ方)
```

`view` が `:grid` の種別はさらに `swatches` / `color` / `value_label` /
`default_value` / `erase_value` / `cell` に答える。登録順が判定順なので、
広く受け付ける種別 (Sprite332 は 8bpp BMP なら何でも受ける) は後ろに置く。

窓は種別ごとに面を持ち、開いたファイルの `view` に合う面だけを見せる
(今は `:grid` と `:mml`)。面を増やすときは `ui/main_window.rb` に部品一式を
足して `show_pane` の切り替えに加える。**それぞれの面は自分の書類を持ち
続ける**ので、曲を開いてから絵に戻っても絵はそのまま。

UI 以外 (`bmp.rb` / `rgb332.rb` / `document.rb` / `formats/`) は標準ライブラリ
だけで動くので、他のツールから require して使える。画面を持たない種別
(テキスト形式の設定など) を足すときは、`view` を増やして
`ui/main_window.rb` に対応する見せ方を追加する。
