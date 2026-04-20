# Family mruby

[日本語](README.ja.md)

## What is Family mruby

A development platform that enables mruby development and execution directly on microcontrollers. It features audio and graphics capabilities and is designed to run on ESP32.

For more details, please refer to the following blog post:
[Family mruby OS - FreeRTOS-based microRuby Multi-VM Architecture](https://blog.silentworlds.info/family-mruby-os-freertosbesunomicrorubymarutivmgou-xiang-2/)

### Demo Video

[![Family mruby Demo](doc/demo5.gif)](https://www.youtube.com/watch?v=9vkRaOoxJJI)

[Long version on YouTube](https://www.youtube.com/watch?v=9vkRaOoxJJI)

## Quick Way to Try It Out

### Try with Docker VNC Desktop

![Family mruby on VNC](doc/vnc.jpg)

You can try Family mruby OS without any hardware or build environment. A pre-built Docker image includes all binaries and is provided as a VNC desktop.

```bash
docker run --rm -p 6080:6080 ghcr.io/family-mruby/fmruby-desktop:latest
```

Open http://localhost:6080/vnc.html in your browser. The Family mruby OS desktop will appear in the VNC viewer.

Tested on Linux and Windows (WSL2). No VNC client is required -- everything runs in the browser via noVNC.
An ARM64 image is also available, so it should work on Mac as well, though this has not been verified.

> Note: Audio is not supported in the VNC environment.

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

![Family mruby Demo](doc/narya_board_dev_r3.jpg)

## Documentation

### family-mruby-doc

Comprehensive documentation including usage instructions and design information for Family mruby.
(Under preparation)

[https://family-mruby.github.io](https://family-mruby.github.io)

## Development

### Prerequisites (Ubuntu / Debian)

Install the packages you need based on what you plan to run:

```bash
# Base tools (required for rake fetch / build:linux / build:esp32)
sudo apt install git ruby-rake build-essential cmake

# For rake build:tools (fmrb-audio-tools)
sudo apt install pkg-config libsdl2-dev
```

### Setup

First time only, fetch fmruby-core and fmruby-graphics-audio:

```bash
rake fetch
```

### Building

Build both fmruby-core (ESP32-S3) and fmruby-graphics-audio (ESP32):

```bash
rake build:esp32
```

For development and testing on Linux (SDL2):

```bash
rake build:linux
```

### Testing Without Hardware

To build from source and test with SDL2 display, first build the Linux binaries:

```bash
rake fetch        # First time only
rake build:linux
```

After building, select your environment in `.env` and launch the simulation environment with Docker Compose:

```bash
cp .env.example .env    # First time only. Select WSL (default) or Ubuntu inside .env
docker compose up
```

`.env` selects which override file to apply via `COMPOSE_FILE`:

- `docker-compose.yml:docker-compose.wsl.yml` — WSL2 + WSLg (default)
- `docker-compose.yml:docker-compose.ubuntu.yml` — native Ubuntu desktop (uses `XAUTHORITY` and `/run/user/$UID`)

This will launch sdl2-display, fmruby-graphics-audio, and fmruby-core in Linux simulation mode using the locally built binaries.

## Disclaimer

- This software is under active development. Some applications may not launch, and unexpected errors may occur.
- This software is intended for hobby use and is not designed for safety-critical applications.
- This software is distributed under the GNU General Public License v3. It is provided with NO WARRANTY. See [LICENSE](LICENSE) for details.
