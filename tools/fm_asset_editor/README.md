# fm_asset_editor

flash/ に入る絵 (スプライト・アイコン・BASIC の文字シート) を編集する
デスクトップアプリ。Ruby + glimmer-dsl-libui で書かれていて、WSL2 では
WSLg にそのまま窓が出る。

```
gem install glimmer-dsl-libui            # 初回のみ (libui 本体を同梱、sudo 不要)
ruby tools/fm_asset_editor/fm_asset_editor.rb fmruby-core/flash/usr/share/sprites/bird_up.bmp
ruby tools/fm_asset_editor/fm_asset_editor.rb --new 24x24   # 空のスプライトから始める
ruby tools/fm_asset_editor/fm_asset_editor.rb --formats     # 何を編集できるか一覧
```

窓が出ない場合は `echo $DISPLAY` を確認する (WSLg なら `:0`)。Wayland 経由で
不具合が出るときは `GDK_BACKEND=x11` を付ける。

WSL2 では `DBUS_SESSION_BUS_ADDRESS` が設定されているのに実体のソケットが
無いことが多く、そのままだと GTK が設定を書くたびに
`dconf-WARNING **: failed to commit changes to dconf` を大量に出す。
**セッションバスが本当に無いときだけ** `GSETTINGS_BACKEND=memory` を
自分で立てて黙らせている (自分で環境変数を指定した場合はそちらを尊重する)。
失われるのは GTK 自身のダイアログの記憶だけで、フォルダの記憶はこの道具が
別に持っている。

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

## テスト

```
ruby tools/fm_asset_editor/test/round_trip_test.rb
```

画面もコンテナも要らない。リポジトリにある BMP を全部開いて書き戻し、
**1 バイトも変わらないこと**を確かめる。ほかに undo/redo、塗りつぶし、
新規スプライトのパレット、大きさの上限も見る。lib/ を触ったらこれを回す。

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

UI 以外 (`bmp.rb` / `rgb332.rb` / `document.rb` / `formats/`) は標準ライブラリ
だけで動くので、他のツールから require して使える。画面を持たない種別
(テキスト形式の設定など) を足すときは、`view` を増やして
`ui/main_window.rb` に対応する見せ方を追加する。
