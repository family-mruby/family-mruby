# P5 報告: ブラウザ版 (wasm) の 6 ツール

> 状態: 完了 | 更新: 2026-08-31 | web_up / web_down / web_screenshot / web_input / web_fs / web_reload。ツールは 14 → 20、selftest は 73 → 90 項目

sim と Tab5 は MCP に載っているのにブラウザ版だけ載っておらず、
別セッションや別エージェントからは操作できなかった。

土台は `tools/fmrb_web.rb` (fmruby-core/doc/wasm/report/drive_tool.md)。
sim が `fmrb_input.rb` を呼ぶのと同じで、この層も **CLI を呼ぶだけ**にした。
実装が 2 つに割れないので、人が shell から使う道と、ツールから使う道が
同じ経路を通る。

## 形

```
web_* ツール --> tools/fmrb_web.rb --> rake wasm:serve (中継) <-- ページ (?drive=1)
```

`lib/web.rb` が持つのは、CLI が持っていなかった 2 つ:

- **長生きする 2 つのプロセスの面倒**。開発サーバ (isolation ヘッダ +
  中継役) とブラウザ。`web_up` は足りないものだけ起こし、既にあるものは
  再利用する。
- **誰のものかの記憶**。sim と同じ `started_by_us` の考え方で、
  `server_ours` / `browser_ours` を状態ファイルに持つ。`web_down` は
  自分が開いたものしか閉じない (force で上書きできる)。ユーザが自分で
  開いているページに `web_up` を掛けると、**そのページをそのまま操る**。

## 実装中に見つかったこと

- **機械の最初の 1 フレームは「ページが答える」と同じではない**。ブートは
  ブラウザ本体のスレッドを長く握る (ファームウェアが開くファイルは全部
  そこへ proxy される) ので、直後に投げた命令は 25 秒待って空振りする。
  最初これで `web_reload` の次の `web_fs` が落ちた。
  → `wait_settled`: **続けて 2 回答えるまで待つ**。`web_up` と `web_reload`
  はこれを通ってから画面を返す。CLI 側には `--timeout` を足した。
- 画面は **canvas の中身** = 機械のフレームバッファなので、
  `sim_screenshot` と同じ土俵で比べられる (ページの見た目ではない)。
- `web_fs` の `put` は「PC のファイルを機械に置く」道になる。ブラウザ版に
  外から物を入れる経路はこれが初めてで、`/flash/home` に置いたものは
  リロードを越えて残る (IndexedDB)。

## 確かめたこと

- `selftest_web.rb` (ブラウザ不要、偽の CLI と偽の梱包): 梱包が無いときの
  案内、`text "hello world"` が 1 引数のまま渡ること、`put` / `get` の
  引数の順、未知 action と足りない引数の拒否、ポートの記憶、
  `browser_ours: false` の down 拒否と force、6 ツールが並ぶこと、
  空の `web_input` がプロトコルエラーでなくツールエラーになること。
  全体で 90 項目が通る。
- 実物での通し (受け入れ): `up` (サーバとブラウザを起動) → `status` →
  `put` → `ls` → `input` → `screenshot` → `reload` → **リロード後も
  `/flash/home` のファイルが残っている** → `cat` → `rm` → `down`
  (ブラウザとサーバの両方が止まる)。2 回目の `up` が
  「reused the development server / reused the browser」と報告することも
  確認した。

## 残り

- 新しいツールは**サーバを起動し直すまで見えない** (MCP のツール一覧は
  セッション開始時に読まれる)。
- ユーザが `DIST=1` で別ポートに立てている開発サーバとは無関係に動く
  (既定 8006)。同じポートを使いたいときは `port:` を渡す。
