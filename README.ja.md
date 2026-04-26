# Family mruby

[English](README.md)

## Family mruby とは

マイコン単体でmrubyの開発、実行が可能な開発プラットフォームです。オーディオ・グラフィックス機能を備え、ESP32で動作するように設計されています。

詳細については、以下のブログ記事をご覧ください:
[Family mruby OSーFreeRTOSベースのmicroRubyマルチVM構想](https://blog.silentworlds.info/family-mruby-os-freertosbesunomicrorubymarutivmgou-xiang/)

### デモ動画

[![Family mruby Demo](doc/demo5.gif)](https://www.youtube.com/watch?v=9vkRaOoxJJI)

[LongバージョンはYouTubeで](https://www.youtube.com/watch?v=9vkRaOoxJJI)

## 動作を簡単に試す方法

### VNC デスクトップをDockerで動かして試す

![Family mruby on VNC](doc/vnc.jpg)


ハードウェアやビルド環境なしで Family mruby OS を試すことができます。ビルド済みのDockerイメージにはすべてのバイナリが含まれており、VNCデスクトップとして提供されます。

```bash
docker run --rm -p 6080:6080 ghcr.io/family-mruby/fmruby-desktop:latest
```

ブラウザで http://localhost:6080/vnc.html を開くと、VNCビューア上にFamily mruby OSのデスクトップが表示されます。

Linux、Windows (WSL2) での動作を確認しています。VNCクライアントは不要です -- noVNCによりブラウザだけで利用できます。
ARM64のイメージも準備しているので、Macでも動作すると思いますが、未検証です。

> 注意: VNC環境では音声は対応していません。

## プロジェクトの構成

### fmrb-core

Family mrubyのコア機能を提供するライブラリです。Family mruby OS の実行環境、抽象化レイヤー、システムリソース管理機能が含まれています。
デバッグ用にLinuxでも実行可能です。


[GitHub Repository](https://github.com/family-mruby/fmruby-core)

### fmrb-audio-graphics

ESP32向けに、オーディオ再生とグラフィックス描画機能を提供するファームウェアです。画像表示、音声出力、基本的なマルチメディア処理をサポートします。

[GitHub Repository](https://github.com/family-mruby/fmruby-audio-graphics)

### narya-board

Family mrubyの開発・実行環境として使用される基板です。
KiCADの設計データが含まれています。

[GitHub Repository](https://github.com/family-mruby/narya-board)

![Family mruby Demo](doc/narya_board_dev_r3.jpg)

## ドキュメント

### family-mruby-doc

Family mrubyの使い方、設計情報を含む総合ドキュメントです。
（準備中です）

[https://family-mruby.github.io](https://family-mruby.github.io)

## 開発方法

### セットアップ

初回のみ、fmruby-core と fmruby-graphics-audio を取得します：

```bash
rake fetch
```

### ビルド

fmruby-core (ESP32-S3) と fmruby-graphics-audio (ESP32) の両方をビルドします：

```bash
rake build:esp32
```

開発・テスト用のLinuxビルド（SDL2）：

```bash
rake build:linux
```

### 実機レスでのテスト

ソースからビルドしてSDL2表示でテストする場合は、まずLinuxバイナリをビルドします：

```bash
rake fetch        # 初回のみ
rake build:linux
```

ビルド後、使用する環境を `.env` で選択し、Docker Composeでシミュレーション環境を起動します：

```bash
cp .env.example .env    # 初回のみ。WSL (デフォルト) か Ubuntu かを .env で選択
docker compose up
```

`.env` では `COMPOSE_FILE` によってオーバーライドファイルを切り替えます：

- `docker-compose.yml:docker-compose.wsl.yml` — WSL2 + WSLg（デフォルト）
- `docker-compose.yml:docker-compose.ubuntu.yml` — Ubuntuネイティブデスクトップ（`XAUTHORITY` と `/run/user/$UID` を使用）

sdl2-display、fmruby-graphics-audio、fmruby-core がLinuxシミュレーションモードで起動し、ローカルビルドしたバイナリを使用します。

## 注意事項

- 開発中のため、起動しないアプリケーションや、想定しないエラーが発生する可能性があります。
- あくまでホビー用途を想定しており、安全性が求められる用途での使用は想定していません。
- 本ソフトウェアは GNU General Public License v3 の下で配布されています。無保証（NO WARRANTY）で提供されます。詳細は [LICENSE](LICENSE) をご覧ください。
