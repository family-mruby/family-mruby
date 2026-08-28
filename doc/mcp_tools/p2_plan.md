# fmrb-mcp P2 実装計画: Tab5 遠隔操作

作成: 2026-08-29。状態: 計画 (実装セッションへの指示書)。
全体計画は plan.md、P1 の実装と申し送りは report/p1.md。本書は P2 だけで
完結するように書いてある。

## 0. 目的 (P2 の範囲)

Tab5 (Modern / ESP32-P4) の WiFi 遠隔操作を MCP ツール化する。
ツールは 5 つ: tab5_ip / tab5_screenshot / tab5_input / tab5_app / tab5_fs。
sim (P3) と CLAUDE.md の短縮 (P4) はやらない。

コードで守る不変条件:

1. **IP を固定値で使わない** (DHCP でブートごとに変わる)。解決と
   キャッシュと失効をサーバが受け持ち、呼ぶ側は IP を意識しない。
2. スクリーンショットはファイル経由でなく **MCP の image content** で
   返す (取得 → Read の 2 手を 1 手にする)。

P1 との違い: シリアルと違って WiFi の HTTP は排他資源ではないので
**flock は使わない**。P1 の `respond { }` の形と `FMRB_MCP_STATE_DIR` に
そのまま乗る (report/p1.md 申し送り)。

## 1. 前提となる既存ツールの事実 (確認済み 2026-08-29)

- 下回りは全て rd_http の HTTP (port 80)。エンドポイントは
  `POST /app/launch?path=` / `GET /app/list` / `POST /app/kill?pid=` /
  `/fs/list` `/fs/get` `/fs/put` `/fs/del` `/fs/mkdir`、画面は
  `GET /stream` (MJPEG)、入力は `/ws` WebSocket。
- **開発ビルド限定**: `FMRB_DEV_REMOTE_CTL` で囲われ (既定 ON、リリース
  OFF)、無い firmware は **404 を返す**。404 は「壊れた」ではなく
  「この firmware に開発エンドポイントが無い」と診断して返すこと。
  無認証なので「信頼できる LAN 内」前提 (description に明記)。
- `tools/fmrb_rd_snap.rb HOST out.jpg` — /stream から JPEG 1 枚
  (SOI/EOI 切り出し、10 秒 deadline)。成功時 stdout に
  `out.jpg: NNN bytes`、失敗時 `no frame captured` で abort。
- `tools/fmrb_rd_input.rb HOST cmds...` — コマンドは
  `click X Y | dclick X Y | mdown X Y | mup X Y | move X Y |
  drag X1 Y1 X2 Y2 | key NAME | key ctrl+NAME | sleep MS`。
  キーは冒頭の SCAN 表 (HID Usage ID) にあるものだけ:
  a-z / 1-0 / f1-f12 / tab / 矢印 / esc / enter / space など。
  **足りないキーは SCAN 表への追記が公認の拡張** (CLAUDE.md に明記が
  ある。P1 の「CLI 改変禁止」の例外として扱ってよい)。
- `tools/fmrb_rd_launch.rb HOST PATH` — 成功で `pid N` を出力。
  `tools/fmrb_rd_ps.rb HOST` — `PID NAME STATE` の表。
  `tools/fmrb_rd_kill.rb HOST PID` — ユーザアプリのみ (kernel/host/
  system app は firmware 側が 400 で拒否)。
- `tools/fmrb_rd_fs.rb HOST <cmd> ...` — 一括モードは
  `ls|get|put|del|mkdir|pull|push|rmr`。**一括モードの rmr は確認なしで
  木ごと消す** (確認を求めるのは対話モードだけ)。パスは
  `/app` `/home` `/usr/share` `/mnt/sd` の 4 根の外と `..` を 400 で拒否。
  put は端末側 .part → rename なので途中で切れても壊れない。
  実測 put 150KB/s。**大きい転送中は remote desktop の配信が止まる**
  (終われば戻る)。
- IP の取得手段:
  1. mDNS: WSL では
     `powershell.exe -Command "(Resolve-DnsName fmruby.local -ErrorAction SilentlyContinue | Where-Object Type -eq 'A').IPAddress"`
     (native Linux なら avahi の `getent hosts fmruby.local` 等)。
  2. 検証: `GET /status` が JSON を返し `ip` フィールドを持つ。
- 座標は FB 系 **426x240** (窓の拡大率と無関係)。
- **Tab5 のタッチは相対移動** (タップ = カーソル位置)。注入では実タッチの
  問題は見つからないので、実タッチ検証はユーザに渡す。
- **ログはこの経路に載っていない** (クラッシュ時は WiFi ごと落ちる)。
  クラッシュ調査は P1 の serial ツールが受け持つ — 同じサーバに同居して
  いるので、description で相互に案内する。

## 2. 成果物

```
tools/mcp/lib/tab5.rb        # IP 解決 + rd_* ラッパ
tools/mcp/fmrb_mcp_server.rb # ツール 5 つを追加 (P1 の 4 つと同居)
tools/mcp/selftest.rb        # 偽 Tab5 (ローカル HTTP) での追加項目
tools/mcp/README.md          # 追記
```

状態ファイル: `<state_dir>/tab5_ip.json` (ip / 解決時刻 / 解決手段)。

## 3. 設計

### 3.1 IP 解決 (全ツール共通の入口)

- 優先順: ツール引数 `ip` (明示) > キャッシュ (TTL 5 分) > mDNS。
- 解決したら必ず `GET /status` で応答を確かめてからキャッシュする
  (mDNS が古い IP を返すことがあるため)。
- **接続失敗したらキャッシュを破棄して mDNS からやり直す (1 回だけ)**。
  それでも駄目なら「Tab5 に届かない。WiFi 接続とブートを確認。シリアルが
  繋がっているならブートログの `rd_http: Remote desktop ready` に IP が
  出る」と案内して失敗する。
- mDNS の実装は WSL (powershell.exe が PATH にある) と native Linux で
  分岐し、lib/tab5.rb 内に閉じ込める。

### 3.2 各ツールの仕様

**tab5_ip(ip?, refresh?)**
- 解決して返す (ip / 解決手段 / status の中身)。`refresh: true` で
  キャッシュを無視。他ツールが失敗したときの切り分け口。

**tab5_screenshot(ip?)**
- fmrb_rd_snap.rb を state_dir の一時ファイルへ → **image content
  (base64, image/jpeg) で返す**。text content でバイト数とファイルパスも
  添える (pngdiff 等の後工程用)。
- mcp gem (1.4.0) の image content の正確な形 (`type: "image"` /
  `data` / `mimeType`) は **gem の実装を読んで確認する** (この計画書の
  記憶で書かない)。
- description: 描画は present 後に反映されるので、操作直後に 1 枚で
  判断せず、変わらなければもう 1 枚撮る。

**tab5_input(ip?, commands)**
- `commands` は文字列 1 本 ("click 20 5 sleep 500 key enter") をそのまま
  fmrb_rd_input.rb の引数に分解して渡す。検証はツール側の abort
  (`unknown key: X`) を拾って明示エラーにする。
- description に載せる: 座標は FB 系 426x240 / 窓を動かすのは drag
  (click では動かない。掴む前にその窓をクリックしてフォーカス) /
  グローバルホットキー (Ctrl+Q, Ctrl+Tab) も効く / タッチは相対なので
  実タッチ検証はユーザ / **ユーザが実機を操作中の可能性があるときは
  割り込む前に確認する**。

**tab5_app(ip?, action, path?, pid?)**
- action: `launch` (path 必須、pid を返す) / `ps` / `kill` (pid 必須)。
- ps の出力は表のパースではなく、`GET /app/list` を lib/tab5.rb から
  直接叩いて構造化して返してよい (rd_http.rb と同じエンドポイント。
  CLI の表を scrape するより堅い。**これは「CLI 改変」ではなく同じ
  HTTP API の利用**)。launch/kill も同様に直接叩いてよい。
- description: パス起動にランチャー操作は不要 / kill はユーザアプリのみ
  (kernel は firmware が拒否) / put→launch で再 flash なしの開発ループ /
  404 は「開発エンドポイントの無い firmware」。

**tab5_fs(ip?, action, device_path?, local_path?)**
- action: `ls` / `get` / `put` / `push` / `pull` / `mkdir` / `del` / `rmr`。
  fmrb_rd_fs.rb の一括モードへ委譲する。
- `rmr` と `del` は **destructive_hint: true**。description に
  「一括モードの rmr は確認なしで木ごと消える。ユーザの指示なしに
  呼ばない」と明記。
- put/push は 150KB/s 実測なのでタイムアウトはサイズから見積もる
  (最低 60 秒 + 10KB/s 換算の余裕。大転送中は remote desktop が
  止まる旨を notes で返す)。
- パス制約 (4 根 + `..` 禁止) は firmware 側の 400 に任せ、400 の
  ときに制約の説明を添えて返す。

### 3.3 P1 との同居

- サーバは 1 本のまま、tools 配列に 5 つ足す (P1 の申し送りどおり
  `respond { }` に乗せる)。
- serial 系との相互参照を description に入れる: 「Tab5 がクラッシュ
  すると WiFi ごと落ちてこの経路は全滅する。クラッシュ調査は serial_start
  / serial_log (同じサーバ) で」。

## 4. selftest への追加 (実機なしで通す)

**偽 Tab5** をローカルに立てて実経路を通す (P1 の socat と同じ発想。
TCPServer で十分。/status, /app/list, /app/launch, /app/kill, /stream
(JPEG 1 枚を MJPEG 風に返す), /fs/list あたりを最小実装):

1. tab5_ip: 偽 /status から解決・キャッシュされる。キャッシュ後に偽
   サーバを止めると、失効 → 再解決の経路に入る (再解決失敗の案内文まで)
2. tab5_screenshot: image content が返り、base64 を戻すと JPEG マジック
   (FF D8) で始まる
3. tab5_app: launch が pid を返す / ps が構造化される / kill 400 (kernel)
   が明示エラーになる
4. 404 応答が「開発エンドポイントの無い firmware」と診断される
5. stdout 純度 (P1 と同じ確認を 9 ツール構成で再実行)

fmrb_rd_input.rb (WebSocket) と fs の実転送は偽サーバでは深追いしない
(実機受け入れで見る)。unknown key の明示エラー化だけは偽サーバ不要で
確認できる。

## 5. 実機での受け入れ確認 (Tab5 が WiFi 接続済みの環境で)

1. tab5_ip が mDNS から解決し、/status の ip と一致する
2. tab5_screenshot の画像がデスクトップとして読める (426x240)
3. launch → screenshot で画面確認 → kill の一巡が人手ゼロで通る
   (対象は /app/demo/spinel_hello.app.rb など無害なもの)
4. put で /app/ にテストアプリを置き launch する (再 flash なしの
   開発ループ)。終わったら del で片付ける
5. tab5_input で メニュー操作かウィンドウフォーカスが画面に反映される
6. Tab5 の電源を切った状態で任意のツールを呼ぶ → キャッシュ失効 →
   再解決失敗の案内が返る (ハングしない)

## 6. やらないこと

- P3 (sim) / P4 (CLAUDE.md 短縮)
- S3 (Retro) 対応 (remote desktop が無い)
- 認証の追加 (LAN 内前提を description に書くに留める)
- 既存 CLI の改変 (例外は fmrb_rd_input.rb の SCAN 表へのキー追記のみ。
  /app /fs 系は CLI を経由せず同じ HTTP API を直接叩いてよい)
- MJPEG の連続配信・動画 (1 枚取得だけ)

## 7. 引き継ぎメモ

- コミットは family-mruby (親リポジトリ)。メッセージは英語、
  Co-Authored-By トレーラを付ける。
- 実装で判明した計画との差分は doc/mcp_tools/report/p2.md に残す
  (計画書は書き換えない)。
- P1 のとき同様、実機受け入れに Tab5 が要る。WiFi に居るかは
  ユーザに確認してから始める (ユーザが実機操作中かもしれない)。
