# Family mruby Debug (VSCode) 日本語手順

Family mruby 上で動作中の PicoRuby VM を VSCode からデバッグする拡張。
デバイス側は fmruby-core の `fmrb_debugd` (doc/vm_remote_debug_* 参照)。
Phase 2 時点のトランスポートは TCP (`localhost:5555`、Linux シミュレーション)。

## 仕組み (最初に読む)

これは**アタッチ型**デバッガであり、デバッグ専用の起動モードやビルドは存在しない:

- Family mruby は**いつも通り普通に起動する** (GUI ありのシミュレーション)。
  `fmrb_debugd` は Linux ビルドに常に入っており、起動と同時に TCP 5555 で
  待ち受けを始める。
- VSCode は**あとから**、既に動いているアプリにアタッチする。アタッチするまで
  VM 側のオーバーヘッドはゼロで、切断すればアプリはそのまま走行を続ける。
- ブレークポイントで止まるのはアタッチしたアプリだけ。デスクトップ・他アプリ・
  GUI は停止中も動き続ける。

つまり順序は常に:
**スタック起動 -> GUI で対象アプリを起動 -> VSCode からアタッチ**。

## 事前準備

- 両リポジトリの Linux ビルドが済んでいること (`rake build:linux`、
  ルート README 参照)。
- VSCode を動かすマシンに Python 3 + `msgpack` パッケージ
  (`pip install msgpack`)。
- `vscode-fmrb-debug/` と `fmruby-core/` が兄弟ディレクトリであること
  (既定の adapterPath が相対で解決されるため)。

## 手順 1: Family mruby を起動する (通常の GUI 起動)

WSL のシェルでリポジトリルートから、いつも通り:

```bash
docker compose up          # WSLg で GUI ウィンドウが出る
```

これだけでよい。`docker-compose.yml` が core サービスのデバッグポート
(`5555:5555`) を公開済みで、debugd は fmruby-core のブート時から動いている。
`dev_run_check.sh` は**不要** (あれは自律テスト用のヘッドレス起動スクリプト。
GUI なしで使いたい場合のみ `tools/dev_run_check.sh --keep`)。

debugd に届いているかの確認:

```bash
python3 fmruby-core/tool/debug/fmrb_dbg_client.py localhost:5555 version
python3 fmruby-core/tool/debug/fmrb_dbg_client.py localhost:5555 ps
```

`ps` に出てくる VM (kernel, system_desktop, 起動したアプリ) がアタッチ対象。

## 手順 2: GUI で対象アプリを起動する

Family mruby のランチャーからデバッグしたいアプリ (例: Kamon) を起動する。
VSCode がアタッチする前に、アプリが `ps` に出ている必要がある (名前で
アタッチする場合は都度 `ps` から解決するので、アプリを再起動して pid が
変わっても launch.json の変更は不要)。

## 手順 3: 拡張をインストールする (初回のみ)

Extension Development Host (2 枚目のウィンドウ) は不要。いつも使っている
VSCode ウィンドウ (`family-mruby` か `fmruby-core` を開いているもの) で:

1. コマンドパレット (`Ctrl+Shift+P`) ->
   **"Developer: Install Extension from Location..."** (日本語 UI では
   「開発者: 場所から拡張機能をインストール...」)
2. `family-mruby/vscode-fmrb-debug/` フォルダを選択。

これで拡張は永続的にインストールされる (VSCode 再起動後も有効。拡張側の
コードを更新したら「開発者: ウィンドウの再読み込み」で反映)。

ワークスペースは `family-mruby` ルートでも `fmruby-core` でもよい。拡張が
`fmruby-core` の位置を自動検出して BP のパス変換を設定する。


## 手順 4: アタッチする

1. Run and Debug パネルを開き、構成ドロップダウンから
   **"fmrb: attach (pick app)"** を選んで開始する (launch.json 不要)。
   デバイス上で動作中の VM 一覧 (`ps`) が QuickPick で表示されるので、
   アタッチしたいアプリを選ぶ。
2. `fmruby-core/flash/app/...` 以下のアプリの `.rb` ソース (例:
   `fmruby-core/flash/app/demo/kamon.app.rb`) にブレークポイントを置く。
   ヒットで停止し、コールスタックとローカル変数が見える。ステップ実行・
   pause・continue も通常どおり。
3. 終わったらデバッグを停止 (disconnect)。アプリは走行再開する。
   いつでも再アタッチできる。

毎回同じアプリにアタッチするなら、`.vscode/launch.json` に固定してもよい
(この場合は選択 UI をスキップして直接アタッチ):

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fmrb",
      "request": "attach",
      "name": "fmrb: attach to Kamon",
      "host": "localhost",
      "port": 5555,
      "app": "Kamon"
    }
  ]
}
```

(`app` を省略するとアプリ選択 UI、名前か pid を書くと直接アタッチ。)

## 拡張自体を開発するとき (F5) — 通常は不要

`vscode-fmrb-debug/` を VSCode で開いて F5 すると Extension Development
Host が `fmruby-core/` を開いた状態で起動する (`.vscode/launch.json` 参照)。
注意: VSCode は同じフォルダを 2 つのウィンドウで開けないため、dev host が
開こうとするフォルダが既に別ウィンドウで開いていると新しいウィンドウが
出ない。先にそのウィンドウを閉じるか、引数のフォルダを変えること。

## 終了のしかた

先にデバッグセッションを切断してから (アプリをパークさせたままにしないため)、
いつも通り `Ctrl-C` / `docker compose down` でスタックを落とす。切断を忘れても
TCP 切断を検知して debugd が全 VM を自動 detach するので、スタックは正常に
終了できる。

スタックを再起動した場合は、再アタッチするだけでよい (VSCode 側の変更は不要)。

## 補足

- `app` はアプリ名 (`ps` と照合) または数値 pid。
- 単体アプリ (`flash/app/**.app.rb`) はパス設定不要 (デバイス側が basename で
  BP を照合)。
- 連結アプリ (kernel / `system_*`、`subdir/*.rb` から連結) はビルドが生成する
  `*_combined.map.json` で原本 file:line と連結後の行を相互変換する。
- カーネル VM 自体にもアタッチできるが、BP で停止中はデスクトップ UI ごと
  固まる (パーク方式の仕様)。止めずに観察したい場合は CLI クライアントの
  `ps` / `log_read` を使う。
- `extensionKind: ["ui"]` は Phase 3 (BLE、Windows 側必須) のための設定。
  Phase 2 ではアダプタは `localhost:5555` に繋がるだけ。

## トラブルシューティング

- `version` がタイムアウトする: スタックが起動していないか、core サービスの
  5555 公開が無い (`docker compose ps` と `docker-compose.yml` を確認)。
- attach が NOT_FOUND になる: アプリ名が `ps` の出力と一致していない。
  上記 `ps` コマンドで正確な名前を確認する。
- BP がヒットしない: ファイルの basename が実行中アプリのソースと一致して
  いるか、連結アプリの場合は直近ビルドで `*_combined.map.json` が再生成
  されているかを確認する。

## ステータス

Phase 2 (TCP)。アダプタ (`fmruby-core/tool/debug/fmrb_dap_adapter.py`) は
`test_phase2.py` でヘッドレス検証済み。VSCode GUI 操作 (F5、BP ガター、
変数ペイン、ステップ) の確認は GUI のあるマシンでの手動確認が必要。
