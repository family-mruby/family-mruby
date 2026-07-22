# Family mruby Debug (VSCode) 日本語手順

Family mruby 上で動作中の PicoRuby VM を VSCode からデバッグする拡張。
デバイス側は fmruby-core の `fmrb_debugd` (doc/vm_remote_debug_* 参照)。
トランスポートは 2 種類:

- **TCP** (`"transport": "tcp"`、既定) — Linux シミュレーション
  (`localhost:5555`)。以下の手順 1-4。
- **BLE** (`"transport": "ble"`) — ESP32 実機を BLE debug GATT サービス経由で
  デバッグする。[実機を BLE でデバッグする](#実機を-ble-でデバッグする) 参照。

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

## 実機を BLE でデバッグする

アタッチの考え方は同じで、デバイス上の debugd に TCP ではなく BLE debug GATT
サービス経由で接続する。検証対象は ESP32-S3 ("Retro")。

### どこで何が動くか

**WSL2 からは Bluetooth にアクセスできない**。そのため拡張は
`extensionKind: ["ui"]` を宣言しており、Remote-WSL 利用時は拡張とそれが起動する
Python アダプタの両方が **Windows 側**で動く。ワークスペースは `\\wsl$\...` の
UNC パス越しになるが、Windows の Python はこのパスのスクリプト実行とファイル
読み込みが可能。TCP デバッグも WSL2 の localhost フォワードでそのまま動く。

### 準備 (初回のみ)

1. **Windows 側**の Python に依存パッケージを入れる (WSL 側ではない):
   ```
   pip install bleak msgpack
   ```
2. Bluetooth が ON で、基板が他のホストと接続中でないことを確認する
   (デバイスは同時 1 接続のみ)。

### アタッチする (launch.json 不要)

1. 基板でデバッグしたいアプリを起動する。
2. Run and Debug パネルの構成ドロップダウンから
   **"fmrb: attach over BLE (pick app)"** を選んで開始する。
   拡張が `Family-mruby-*` デバイスをスキャンして接続し、動作中の VM 一覧が
   QuickPick で出るので、アプリを選べばアタッチ完了。
3. ブレークポイント・ステップ実行・切断は手順 4 と同じ。

`pythonPath` の既定は Windows (UI ホスト) では `py`、それ以外では `python3`。
特定のインタプリタを使いたい場合のみ明示する。

### launch.json に固定する (任意)

毎回同じ基板・同じアプリなら、固定構成で選択 UI をスキップできる:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fmrb",
      "request": "attach",
      "name": "fmrb: attach over BLE",
      "transport": "ble",
      "deviceName": "Family-mruby-c4823e",
      "app": "Kamon"
    }
  ]
}
```

- `deviceName` は省略可。省略時はスキャンし、`Family-mruby-*` が 1 台だけなら
  接続する (複数台/0 台なら候補を含むエラーになる)。MAC アドレス指定も可能で、
  その場合スキャンを省略するのでスキャンが不安定な環境で有効。デバイス名は
  起動ログの `BLE device name:` 行に出る (末尾は MAC 下位 3 バイト)。

### 注意・制限

- 切断 (電波断・VSCode 終了を含む) するとデバイス側が全 VM を自動 detach するので、
  基板がパークしたまま取り残されることはない。
- 自動再接続は無い。切れたらデバッグセッションを開始し直す。
- 接続直後の最初のコマンドは数回リトライする。デバイス側が debugd の
  トランスポート登録を終える前に届いたフレームは仕様上捨てられるため。

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

BLE 固有:

- `bleak` が見つからない: WSL 側の Python に入れてしまっているか、
  `pythonPath` が別のインタプリタを指している。
- 「no Family-mruby-* device found」: Bluetooth OFF、基板の電源断、または
  他のホストが接続を掴んだまま。デバイス名か MAC を明示指定して試す。
- 接続はできるが全コマンドがタイムアウトする: 起動ログに
  `debugd task started` が出ているか確認する。
- `\\wsl$` の UNC パスからのアダプタ起動が不安定な場合は、
  `fmruby-core/tool/debug/` を Windows 側のローカルフォルダにコピーし、
  `adapterPath` でそちらを指す。

## ステータス

TCP (Linux シミュレーション) と BLE (ESP32-S3) の両トランスポートを実装済み。
アダプタ (`fmruby-core/tool/debug/fmrb_dap_adapter.py`) は `test_phase2.py` で
ヘッドレス検証済み、BLE のフレームコーデックはデバイス側 C 実装とバイト単位で
突き合わせ済み。VSCode GUI 操作と BLE 実機 E2E は手動確認が必要。
