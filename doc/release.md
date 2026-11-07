# リリースの手順

> 状態: 完了 | 更新: 2026-11-07 | 版の番号の上げ方、タグで動くリリースの CI (Web Installer のファーム 5 つと Linux の .deb)、Web Studio・Web Console・副次の置き場の更新、公開の確認。3.0.0 (2026-11-07) の時点の手順

Family mruby のリリースは、3 つのリポジトリ (直下の family-mruby・fmruby-core・
fmruby-graphics-audio) にタグを打ち、直下のタグで CI を動かして公開する。
**発火 (タグの push) は、ユーザの明示の許可のあとだけ**。準備 (版の番号、
ビルドの確認、main への早送り) と発火を分ける。

## 公開するもの

| もの | 置き場 | 作るもの |
|---|---|---|
| Web Installer | family-mruby-installer リポジトリ (GitHub Pages) | 直下の `.github/workflows/release-installer.yml` |
| ファーム: Retro | NARYAv3 の core (ESP32-S3) と WROVER (fmruby-graphics-audio) | 同上 |
| ファーム: Modern | Tab5 (ESP32-P4) | 同上 |
| ファーム: Headless | StickS3・AtomS3R (ESP32-S3) | 同上 |
| Linux 版 | 直下のリポジトリの GitHub リリースに `.deb` (amd64・arm64) | 同上の linux-deb・github-release ジョブ |
| Web Studio (ブラウザ版) | サイトのリポジトリ family-mruby.github.io の `docs/studio/` | 手元の `rake wasm:site` |
| Web Studio (副次) | 自前の nginx | 手元の `rake wasm:deploy` |
| Web Console | サイトの `docs/console/` | サイトの公開の CI が fmruby-core の **main** の `tool/web` を取り込む |

## 1. 準備

1. develop で `rake regress:full` を流す (34〜47 分)。実機は `rake regress:boot`
   と `rake regress:checkpoint BOARD=<端末>` (fmruby-core/doc/regression/usage.md)。
2. **版の番号を上げる** (3 つのリポジトリ):
   - fmruby-core `components/fmrb_common/include/fmrb.h`: `FMRB_OS_VERSION`、
     `FMRB_GA_VERSION`、`FMRB_LINK_VERSION`
   - fmruby-graphics-audio `main/include/fmrb_ga_version.h`: `FMRB_GA_FW_VERSION`、
     `FMRB_LINK_VERSION`
   - core と GA は版を**厳密に**照らし合わせる (違えばつながらない)。GA に命令を
     足したら、GA の版と link の番号も上げる (上げ忘れると、古い GA が版の確認を
     通って新しい命令を黙って捨てる。3.0.0 で見つかった)。上げたら WROVER の
     書き直しが必須になる。
   - 直下の `.repos`: 2 つのサブリポジトリの `version:` を新しい版にする
     (CI と `rake fetch` が読むのは `.repos`。`repos.yaml` は別物で効かない)。
3. fmruby-core の `.env` の `FMRB_HW_TARGET` を `NARYAv3` にする (リリースの CI の
   最初のビルドがこれを読む。続くビルドは CI が `.github/scripts/select-core-target.sh`
   で書き換える)。
4. 手元で CI と同じ順にビルドして確かめる: fmruby-core で `rake clean_all` →
   `rake build:esp32` (NARYAv3)、`.env` を TAB5 にして同じく、graphics-audio で
   `rake build:esp32`。
5. 各リポジトリで develop を main へ早送りし、develop と main を push する。
   fmruby-core の develop の CI (build.yml) が緑になるのを待つ。
6. **Web Installer のページ** (family-mruby-installer の `index.html`、
   `scripts/stage-firmware.sh`) を変えるときは、タグより先に installer の main へ
   push する (CI はそれを使って置く)。

## 2. 発火 (ユーザの許可のあと)

```
git -C fmruby-core tag -a <ver> -m "Family mruby <ver>" origin/main && git -C fmruby-core push origin <ver>
git -C fmruby-graphics-audio tag -a <ver> -m "Family mruby <ver>" origin/main && git -C fmruby-graphics-audio push origin <ver>
git tag -a <ver> -m "Family mruby <ver>" origin/main && git push origin <ver>   # 直下。これで CI が動く
```

サブリポジトリのタグを先に打つ (CI が `.repos` の版で取りに行く)。直下のタグで
`Release Firmware to Installer` と `Build and Push VNC Desktop Image` が動く。

リリースの CI (35 分前後) がすること:

- build-and-publish: fmruby-core を NARYAv3 → StickS3 → AtomS3R → Tab5 の順に
  作り (各回 `rake clean_all`、出来上がりは `.github/scripts/stash-core-build.sh` で
  退避)、WROVER を作り、installer の `firmware/<ver>/` に置き、`versions.json` の
  既定を新しい版にして installer の main に push する (Deploy Key、secret
  `INSTALLER_DEPLOY_KEY`)。
- linux-deb (amd64・arm64): `rake spinel:gen` → `rake native:deb ARCH=..`
  (パッケージを作るイメージの中。arm64 はクロスコンパイルで、作る途中で arm64 の
  生成器を実行するので qemu を登録する)。配布物の検査 (`native:scan`) も通す。
- github-release: 直下のリポジトリの GitHub リリースを作り、`.deb` を添付する。

ランナーの事情: `gcc-multilib` (checkpoint の表を `-m32` でもう一度コンパイルする)
と qemu (arm64 の生成器) が要る。どちらもワークフローに入っている。手元では
Docker Desktop が qemu を登録しているので、手元で通っても CI で落ちることがある
(3.0.0 の arm64 の `.deb` はこれで落ち、amd64 だけを手で添付した)。

## 3. Web Studio と Web Console

**ファームと一緒に必ず更新する** (3.0.0 で漏れかけた)。

```
source ~/emsdk/emsdk_env.sh
rake spinel:gen && rake wasm:mruby          # wasm のビルドは Spinel の C と libmruby を作り直さない
rake wasm:site FMRB_SITE_DIR=<family-mruby.github.io の checkout>
# サイトのリポジトリで docs/studio をコミットして push (先に fetch して遅れを確かめる)
FMRB_WEB_DEST=<host>:<dir>/ rake wasm:deploy  # 副次の nginx (置き先はここに書かない)
```

- Web Console はサイトの公開の CI (deploy.yml) が、公開のたびに fmruby-core の
  main の `tool/web` を `scripts/sync-console.sh` で取り込む (`docs/console/` は
  gitignore、develop のものは `docs/console-dev/`)。fmruby-core の main をリリースに
  進めたあと、サイトを 1 回公開すれば揃う (Studio の push がそれを兼ねる)。

## 4. 確かめる

- installer: 公開のページ (GitHub Pages の組み立てが終わってから) で、新しい版の
  各 `manifest.json` が 200、既定の版が新しいもの。
- GitHub リリース: `.deb` が添付され、`dpkg-deb -f` の Version が新しい版。
- Web Studio: 公開の `core_web.wasm` が手元の `wasm/build/dist/` のものとバイト単位で
  同じ。中に版の文字列がある。副次の nginx も同じ確かめ方と、COOP/COEP の
  ヘッダ。
- Web Console: 公開の `index.html` が fmruby-core の main の `tool/web/index.html`
  (favicon の 1 行を足したもの) と同じ。
- 実機に焼いて確かめるのは、版の確認 (core と GA) とブートの要約 (crash 0)。

## 関連

- fmruby-core/doc/regression/usage.md (リリースの前の試験)
- fmruby-core/doc/regression/report/ci_develop_20261107.md (CI だけで出た 3 つ)
- fmruby-core/doc/headless_s3/report/welcome_app.md (Headless の端末の起動アプリ)
