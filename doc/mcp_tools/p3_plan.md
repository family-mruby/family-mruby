# fmrb-mcp P3 実装計画: Linux sim ライフサイクル

作成: 2026-08-29。状態: 計画 (実装セッションへの指示書)。
全体計画は plan.md、P1/P2 の実装と申し送りは report/p1.md / report/p2.md。
本書は P3 だけで完結するように書いてある。

## 0. 目的 (P3 の範囲)

Linux sim (docker の 3 コンテナ) の起動・撮影・入力・アプリ操作を
MCP ツール化する。ツールは 5 つ:
sim_up / sim_down / sim_screenshot / sim_input / sim_app。
P4 (CLAUDE.md 短縮) はやらない。

コードで守る不変条件 (現状は手順書と記憶で守られている):

1. **偽グリーンの遮断**: `rake build:linux` は esp32 の build/ が残って
   いても "Linux build complete" と言う。sim_up は起動前に**両 ELF が
   x86-64 であることを file 検査**し、違えば起動せず明示エラーにする
   (「rake clean_all && rake build:linux が要る」と案内)。
2. **再起動は常に 3 コンテナまとめて** (core 単独再起動で framebuffer が
   死ぬ)。単独 restart のツールは提供しない。
3. **解像度の持ち越しの自己修復**: ターゲット切替直後の 1 回目は前の
   解像度で上がる (graphics-audio が flash/etc/display_conf_linux.txt に
   記憶しており、変更は次回起動から)。sim_up は撮影 PNG のサイズを期待値と
   照合し、不一致なら down → up をもう一周する (1 回だけ)。
4. **ユーザのスタックを壊さない**: 稼働中のスタックは再利用し、
   自分が起動したのでなければ sim_down で黙って down しない。

## 1. 前提となる既存ツールの事実 (確認済み 2026-08-29)

- `tools/dev_run_check.sh [--gui] [--keep] [出力.png]`:
  - headless は `docker compose -f docker-compose.yml -f docker-compose.headless.yml up -d`。
    ルートの .env の COMPOSE_FILE (wsl 版) はこのとき明示指定で上書きされる。
  - **fmruby_core が稼働中なら再利用し、down しない** (ユーザの GUI 実行を
    壊さないための既存仕様。この判定を sim_up でも踏襲する)。
  - ブートマーカー `main_loop started` を docker logs で待つ
    (timeout は FMRB_BOOT_TIMEOUT、既定 60 秒)。ブート中に core が
    exit したら最後の 30 行を出して失敗する。
  - マーカー後 3 秒待って `fmrb_screenshot.py --wait 10` で撮影。
    `--keep` なしなら (自分が起動した場合のみ) down する。
- サービス名は `sdl2-display` / `fmruby-graphics-audio` / `fmruby-core`
  (コンテナ名 fmruby_core / fmruby_graphics_audio)。
- `tools/fmrb_screenshot.py [--wait 秒] 出力.png`:
  - /dev/shm/fmrb_display (RGB332) の完成フレームを PNG 化。ホストから
    SHM が見えない環境 (Docker Desktop) は docker exec に自動フォール
    バック。成功時 stdout に `出力.png: WxH`。スタックが無いと
    `error: no ready framebuffer ...` で失敗する。
- `tools/fmrb_input.rb <コマンド列>`:
  - `move X Y | click X Y [--button N] | down X Y | up X Y | key NAME |
    key shift+NAME | text "STRING" | sleep MS | --layout us|jp`。
  - **`text` は空白を含む 1 引数**。コマンド列を単純な空白 split で
    渡すと壊れるので、サーバ側は Shellwords で分解する (P2 の tab5_input
    は split で足りたが、sim には text がある)。
  - 経路は Unix DGRAM /var/run/fmrb/fmrb_inject。ソケットがホストに
    見えなければ fmruby_graphics_audio 内の sender に自動フォールバック。
- アプリ操作は debugd (TCP)。sim では `localhost:5555` に出ている。
  `python3 fmruby-core/tool/debug/fmrb_dbg_client.py --json localhost spawn path=/app/...`
  が `{"pid": N}` を返す。ps / kill も同じクライアント。
  (P2 と違い HTTP でなく独自 TCP。クライアント CLI へ委譲する。)
- 解像度の期待値は fmruby-core/.env の FMRB_HW_TARGET から:
  NARYAv3 / ATOM_DISPLAY → **320x240**、TAB5 / NARYAv4 → **426x240**
  (rakelib/build.rake が p4 系なら config/system_conf_linux_p4.toml を選ぶ)。
  注意: 環境変数がファイルの値を上書きする仕様 (dotenv) なので、
  「.env と違うターゲットで build された」可能性はゼロではない。照合が
  外れたときのエラーには両方の可能性 (解像度持ち越し / .env と build の
  食い違い) を書く。
- ELF の位置: fmruby-core/build/fmruby-core.elf と
  fmruby-graphics-audio/build/fmruby-graphics-audio.elf。x86-64 判定は
  `file` コマンドでよい (ELF ヘッダの e_machine 直読みでも可)。

## 2. 成果物

```
tools/mcp/lib/sim.rb           # ライフサイクル + 委譲
tools/mcp/fmrb_mcp_server.rb   # ツール 5 つ追加 (計 14)
tools/mcp/selftest_sim.rb      # docker なしで通る分
tools/mcp/selftest.rb          # 9 節目として呼ぶ
tools/mcp/README.md            # 追記
```

状態ファイル: `<state_dir>/sim.json` (自分が起動したか / 起動時刻 /
最後に確認した解像度)。

## 3. 設計

### 3.1 排他と「誰が起動したか」

- docker compose はマシン単位の排他資源。**P1 の flock を名前 "sim" で
  再利用**する (report/p1.md 申し送りどおり)。sim_up / sim_down /
  自己修復の down→up の間だけ保持する短期ロックでよい
  (シリアルと違い、稼働中ずっと握る必要はない)。
- sim.json に `started_by_us: true/false` を記録する。
  - sim_up 時に fmruby_core が稼働中なら再利用し `started_by_us: false`。
  - **sim_down は `started_by_us: false` のとき拒否**し、「このスタックは
    ユーザ (または別セッション) が起動したもの。本当に落とすなら
    force: true」と返す。`force: true` で通す。

### 3.2 各ツールの仕様

**sim_up(gui?, keep_default_note?)**
- 手順:
  1. 両 ELF の存在と x86-64 を検査。違えば起動せず
     「stale な esp32 ビルド。cd fmruby-core && rake clean_all &&
     rake build:linux (graphics-audio も同様)」と返す (不変条件 1)。
  2. flock("sim") → `dev_run_check.sh --keep <state_dir>/sim_boot.png`
     を実行 (gui: true なら --gui も)。stdout から再利用したか・
     解像度 (`WxH`) を拾う。
  3. 解像度を .env の期待値と照合。不一致かつ自分が起動した場合は
     down → up をもう一周 (1 回だけ)。再び不一致なら両方の仮説
     (持ち越し / .env と build の食い違い) を並べて失敗にする。
     再利用スタックの不一致は down しない (ユーザのものかもしれない) —
     不一致の旨だけ返す。
  4. 起動時の PNG を image content で返す (ブート直後の画面確認を兼ねる)。
- タイムアウトはブートマーカー待ち (60s) + 余裕で 120s。

**sim_down(force?)**
- 3.1 の判定で `docker compose down`。started_by_us でなければ
  force が要る。down 後に sim.json を消す。

**sim_screenshot(wait?)**
- fmrb_screenshot.py へ委譲 → image content + text (パス / WxH)。
- description: 描画は present 後に 1 テンポ遅れる。操作直後に 1 枚で
  判断せず、変わらなければもう一枚。

**sim_input(commands)**
- **Shellwords.split** で分解して fmrb_input.rb へ (text "STRING" を守る)。
- description に載せる知見: 座標は FB 系 (解像度は sim_up の結果か
  screenshot の WxH) / ダブルクリックは click sleep 120 click /
  キー判定は scancode (keycode は Linux では SDL keysym で実機と違う) /
  **Alt は sim では死んでいる** / かな切替は key ctrl+space (zenkaku は
  jp 配列のみ)、かな中の text はローマ字合成 / **key は長押しにならない**
  (押下/解放 40ms 差。長押し前提のゲームは注入で操作しきれない) /
  新規アプリはランチャー右クリックで再走査 (直接 launch なら不要)。

**sim_app(action, path?, pid?)**
- fmrb_dbg_client.py --json localhost へ委譲 (spawn / ps / kill)。
  spawn は `path=` 形式に注意。--json の出力をそのまま構造化して返す。
- description: パスは端末視点 (/app/...) / スタック未稼働なら接続拒否に
  なるので sim_up が先、と案内。

### 3.3 P1/P2 との整合

- `respond { }` / `Sub.run` / `FMRB_MCP_STATE_DIR` に乗る (support.rb)。
- 相互参照: sim 系の description に「実機 (Tab5) は tab5_*、シリアルは
  serial_*」、逆に serial/tab5 側は触らない (P4 でまとめて見直す)。
- dev_run_check.sh はそのまま使う (改変しない)。down の判定だけ
  サーバ側で行うため、**サーバからは常に --keep で呼び、down は
  sim_down の仕事**にする。

## 4. selftest への追加 (docker なしで通す分)

docker が要る経路は受け入れ (5 章) に回し、ここでは:

1. ELF 検査: 存在しない / ELF でないファイル / (可能なら) 偽の
   RISC-V ヘッダを置いた一時ファイルで、起動前に明示エラーになること
   (`FMRB_MCP_STATE_DIR` と同様に ELF パスも env で差し替えられるように
   しておくとテストしやすい: FMRB_MCP_SIM_CORE_ELF 等)
2. sim_input の分解: `text "hello world"` が 1 引数のまま渡ること
   (Sub.run に渡る argv を検査)、未知コマンドの明示エラー
3. sim_down の拒否: sim.json が started_by_us: false のとき force なしで
   拒否されること
4. 解像度照合ロジック: `WxH` パースと期待値表 (320x240 / 426x240)、
   不一致メッセージに両仮説が入ること
5. 14 ツール構成での stdout 純度

## 5. 受け入れ確認 (docker + Linux ビルドで、実装セッションが自走できる)

P1/P2 と違い実機不要。Linux ビルドが無ければ作るところから
(rake clean_all && rake build:linux を両リポジトリで。数分 x2)。

1. sim_up → 起動画像が返り、解像度が .env の期待値と一致する
2. **偽グリーン遮断**: fmruby-core だけ `rake clean_all && rake build:esp32`
   ... は重いので、ELF を一時退避して非 x86-64 のダミーに差し替え →
   sim_up が起動前に拒否 → 戻す、で代替してよい
3. **解像度の自己修復**: .env の FMRB_HW_TARGET を一時的に切り替えて
   linux を再ビルドし、直後の sim_up が「1 回目不一致 → down/up →
   一致」で上がる (終わったら .env とビルドを元に戻す)。
   時間が惜しければ display_conf_linux.txt を直接書き換えて偽の
   持ち越しを作る手でもよい (どちらでやったか報告に書く)
4. sim_app: spawn /app/demo/kamon.app.rb → ps に出る → screenshot で
   窓が見える → kill
5. sim_input: `text "hello"` を含む列がエディタ等に入る、または
   ランチャー操作が画面に反映される
6. ユーザ保護: 手で `docker compose up -d` したスタックに対し
   sim_up (再利用と報告される) → sim_down が force なしで拒否される
7. 片付け: sim_down (force) まで通し、コンテナが残らないこと

## 6. やらないこと

- P4 (CLAUDE.md 短縮・description の相互見直し)
- gdb 事後解析の自動化 (ハング調査は従来どおり手順書 + CLI。
  ただし sim_app / sim_up の失敗メッセージから「再起動する前に gdb を
  当てる。手順はルート CLAUDE.md」へ誘導する一文は入れる)
- 音 (fmrb_audio_probe) / MIDI モニタ / pngdiff (CLI のまま)
- dev_run_check.sh ほか既存 CLI の改変
- コンテナ単独の restart ツール (不変条件 2 を破る口を作らない)

## 7. 引き継ぎメモ

- コミットは family-mruby (親リポジトリ)。英語、Co-Authored-By 付き。
- 差分は doc/mcp_tools/report/p3.md へ (計画書は書き換えない)。
- 受け入れ 3 (ターゲット切替) をやる場合、**終了時に .env とビルドを
  必ず元 (TAB5 / どのビルドだったか) に戻し、report に戻したことを書く**。
  次のセッションが「いま build/ に何があるか」で迷わないため。
