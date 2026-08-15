# Family mruby

[日本語](README.ja.md)

## What is Family mruby

A development platform that enables mruby development and execution directly on microcontrollers. It features audio and graphics capabilities and is designed to run on the ESP32 series.

There are two hardware generations:

- **Family mruby Retro** — the NARYA board (two chips: ESP32-S3 + ESP32-WROVER). A retro-style setup that connects to a TV over NTSC video output
- **Family mruby Modern** — the ESP32-P4 variant. Currently runs standalone on the M5Stack Tab5, with a high-resolution touch screen (a dedicated board is under development)

For more details, please refer to the following blog post:
[Family mruby OS - FreeRTOS-based microRuby Multi-VM Architecture](https://blog.silentworlds.info/family-mruby-os-freertosbesunomicrorubymarutivmgou-xiang-2/)

### Demo Video

[![Family mruby Demo](doc/demo5.gif)](https://www.youtube.com/watch?v=9vkRaOoxJJI)

[Long version on YouTube](https://www.youtube.com/watch?v=9vkRaOoxJJI)

## Documentation

### family-mruby-doc

Comprehensive documentation including usage instructions and design information for Family mruby.

[https://family-mruby.github.io](https://family-mruby.github.io)

## Quick Way to Try It Out

### Flash Real Hardware from the Web Installer

If you have the hardware (a NARYA board or an M5Stack Tab5), you can flash the firmware from your browser alone:

[https://family-mruby.github.io/family-mruby-installer/](https://family-mruby.github.io/family-mruby-installer/)

It uses WebSerial, so a desktop Chrome / Edge / Opera browser is required.

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

### fmruby-core

Firmware that provides the core functionality of Family mruby. It includes the Family mruby OS runtime environment, abstraction layer, and system resource management features.
It targets both Retro (ESP32-S3) and Modern (ESP32-P4), and can also run on Linux for debugging purposes.

[GitHub Repository](https://github.com/family-mruby/fmruby-core)

### fmruby-graphics-audio

Firmware for the Retro (NARYA board) sub-microcontroller (ESP32-WROVER). It handles NTSC video output and I2S audio output.
Modern is a single-chip configuration and does not use this firmware.

[GitHub Repository](https://github.com/family-mruby/fmruby-graphics-audio)

### narya-board

The circuit board used as the development and execution environment for Family mruby Retro.
Contains KiCAD design data. Modern runs on the off-the-shelf M5Stack Tab5.

[GitHub Repository](https://github.com/family-mruby/narya-board)

![Family mruby Demo](doc/narya_board_dev_r3.jpg)

## Development

### Prerequisites (Ubuntu / Debian)

Install the packages you need based on what you plan to run:

```bash
# Base tools (required for rake fetch / build:linux / build:esp32)
sudo apt install git ruby-rake ruby-dev build-essential curl

# The firmware itself is compiled inside the ESP-IDF container, so Docker is
# required for every build. See https://docs.docker.com/engine/install/
sudo apt install docker.io   # or Docker Engine / Docker Desktop

# Generating the editor's type database is a host-side step of the build
gem install rbs

# For rake build:tools (fmrb-audio-tools)
sudo apt install cmake pkg-config libsdl2-dev
```

The firmware build is not entirely containerized: parts of the system are Ruby compiled ahead of time to C by the [Spinel](https://github.com/kishima/spinel) compiler, which runs on the host. The first build fetches and builds that compiler automatically -- hence `build-essential` and `curl` -- and `gem install rbs` covers the other host-side step, the type database behind the editor's completion and hover. See [fmruby-core/README.md](https://github.com/family-mruby/fmruby-core/blob/main/README.md#spinel-aot-compiler) for the details and for how to rebuild the compiler when its pin moves.

### Setup

First time only, fetch the repositories listed in `.repos` (fmruby-core, fmruby-graphics-audio and fmrb-audio-tools):

```bash
rake fetch
```

### Building

For Retro, build both fmruby-core (ESP32-S3) and fmruby-graphics-audio (ESP32):

```bash
rake build:esp32
```

For Modern (M5Stack Tab5), build fmruby-core only (single-chip configuration, fmruby-graphics-audio is not needed). The target is selected either on the command line or by editing `FMRB_HW_TARGET` in `fmruby-core/.env`; the command line wins:

```bash
cd fmruby-core
FMRB_HW_TARGET=TAB5 rake build:esp32
```

Switching the target changes the chip, so run `rake clean_all` first when the previous build was for the other one.

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
- Networking (WiFi / BLE) has no access control. The remote desktop (HTTP / WebSocket) accepts any client on the same network and allows full screen viewing and keyboard/mouse control; the BLE debug service uses no pairing or encryption and lets any nearby client inspect running applications and start or stop them. WiFi credentials are stored in plain text on the device. Use these features only on a network you trust, at your own risk, and never expose the device directly to the Internet.
- This software is distributed under the GNU General Public License v3. It is provided with NO WARRANTY. See [LICENSE](LICENSE) for details.
