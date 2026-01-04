# Family mruby

[日本語](README.ja.md)

## What is Family mruby

A development platform that enables mruby development and execution directly on microcontrollers. It features audio and graphics capabilities and is designed to run on ESP32.

For more details, please refer to the following blog post (Japanese):
[Family mruby OS - FreeRTOS-based microRuby Multi-VM Architecture](https://blog.silentworlds.info/family-mruby-os-freertosbesunomicrorubymarutivmgou-xiang-2/)

### Demo Video

[![Family mruby Demo](https://img.youtube.com/vi/DA_VuB2W5sU/0.jpg)](https://www.youtube.com/watch?v=DA_VuB2W5sU)


## Project Components

### fmrb-core

A library that provides the core functionality of Family mruby. It includes the Family mruby OS runtime environment, abstraction layer, and system resource management features.
It can also run on Linux for debugging purposes.


[GitHub Repository](https://github.com/family-mruby/fmruby-core)

### fmrb-audio-graphics

Firmware for ESP32 that provides audio playback and graphics rendering capabilities. It supports image display, audio output, and basic multimedia processing.

[GitHub Repository](https://github.com/family-mruby/fmruby-audio-graphics)

### narya-board

A circuit board used as the development and execution environment for Family mruby.
Contains KiCAD design data.

[GitHub Repository](https://github.com/family-mruby/narya-board)

## Documentation

### family-mruby-doc

Comprehensive documentation including usage instructions and design information for Family mruby.
(Under preparation)

[https://family-mruby.github.io](https://family-mruby.github.io)



