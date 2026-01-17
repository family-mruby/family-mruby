# Family mruby

[English](README.md)

## Family mruby とは

マイコン単体でmrubyの開発、実行が可能な開発プラットフォームです。オーディオ・グラフィックス機能を備え、ESP32で動作するように設計されています。

詳細については、以下のブログ記事をご覧ください:
[Family mruby OSーFreeRTOSベースのmicroRubyマルチVM構想](https://blog.silentworlds.info/family-mruby-os-freertosbesunomicrorubymarutivmgou-xiang/)

### デモ動画

[![Family mruby Demo](https://img.youtube.com/vi/cJsHcUooq20/0.jpg)](https://www.youtube.com/watch?v=cJsHcUooq20)


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

## ドキュメント

### family-mruby-doc

Family mrubyの使い方、設計情報を含む総合ドキュメントです。
（準備中です）

[https://family-mruby.github.io](https://family-mruby.github.io
)



