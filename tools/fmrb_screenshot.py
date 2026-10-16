#!/usr/bin/env python3
"""Capture the Family mruby Linux-sim screen from shared memory into a PNG.

The graphics-audio process publishes the composed RGB332 framebuffer in the
POSIX shared memory object /fmrb_display (see
fmruby-graphics-audio/main/common/shm_display.h). The compose services run
with `ipc: host`, so the object is visible on the host at
/dev/shm/fmrb_display and the screen can be captured without any GUI --
this is what lets an agent or CI verify the display headlessly.

Usage: fmrb_screenshot.py [--wait SECONDS] [output.png]
"""
import struct
import subprocess
import sys
import time
import zlib

SHM_PATH = "/dev/shm/fmrb_display"
# With Docker Desktop, `ipc: host` shares the docker-desktop VM's IPC, so the
# SHM object is not visible in the WSL distro's /dev/shm. Fall back to reading
# it from inside a container that mounts it.
DOCKER_CONTAINER = "fmruby_graphics_audio"
# fmrb_shm_t layout 2 (FMRB_SHM_LAYOUT_VERSION in shm_display.h).
READY_MAGIC = 0x464D5232  # "FMR2"
LEGACY_MAGIC_V1 = 0x464D5242  # "FMRB", layout 1 (480x320 slots)
LAYOUT_VERSION = 2
FB_MAX_W = 640
FB_MAX_H = 360
FB_SIZE = FB_MAX_W * FB_MAX_H

# fmrb_shm_t offsets (natural C alignment, no packing):
#   0: u32 ready_magic, 4: u8 display_initialized, 5: u8 shutdown_requested,
#   6: u16 display_width, 8: u16 display_height (the base screen),
#   10..12: u8 depth/scale_x/scale_y, 13: u8 layout_version, 16: u32 shm_size,
#   20: u16 frame_width[2], 24: u16 frame_height[2] (each slot's own size:
#   the screen is 640x360 while a fullscreen app holds the high-resolution
#   screen), 28: u8 framebuf[2][FB_SIZE], then u32 write_index (4-aligned).
LAYOUT_OFF = 13
FRAME_W_OFF = 20
FRAME_H_OFF = 24
FB_OFF = 28
WIDX_OFF = (FB_OFF + 2 * FB_SIZE + 3) & ~3


class LayoutMismatch(Exception):
    pass


def read_shm_bytes():
    try:
        with open(SHM_PATH, "rb") as f:
            return f.read(WIDX_OFF + 8)
    except FileNotFoundError:
        pass
    r = subprocess.run(
        ["docker", "exec", DOCKER_CONTAINER, "head", "-c", str(WIDX_OFF + 8), SHM_PATH],
        capture_output=True)
    if r.returncode != 0 or len(r.stdout) < 8:
        raise FileNotFoundError(SHM_PATH)
    return r.stdout


def read_shm():
    data = read_shm_bytes()
    magic, = struct.unpack_from("<I", data, 0)
    if magic == LEGACY_MAGIC_V1:
        raise LayoutMismatch(
            "the running graphics-audio publishes SHM layout 1; this tool reads "
            "layout %d. Rebuild graphics-audio (rake build:linux) and restart "
            "the stack." % LAYOUT_VERSION)
    if magic != READY_MAGIC or len(data) < WIDX_OFF + 8:
        return None
    if data[LAYOUT_OFF] != LAYOUT_VERSION:
        raise LayoutMismatch("SHM layout %d, this tool reads layout %d"
                             % (data[LAYOUT_OFF], LAYOUT_VERSION))
    write_index, = struct.unpack_from("<I", data, WIDX_OFF)
    # display_shm.cpp: the writer fills framebuf[write_index & 1], records
    # that slot's size and then flips write_index, so the last completed
    # frame is the other slot.
    buf = (write_index & 1) ^ 1
    width, = struct.unpack_from("<H", data, FRAME_W_OFF + 2 * buf)
    height, = struct.unpack_from("<H", data, FRAME_H_OFF + 2 * buf)
    if not (0 < width <= FB_MAX_W and 0 < height <= FB_MAX_H
            and width * height <= FB_SIZE):
        return None
    off = FB_OFF + buf * FB_SIZE
    return width, height, data[off:off + width * height]


def rgb332_to_png(width, height, pixels, path):
    # Pre-computed RGB332 -> RGB888 palette
    palette = []
    for v in range(256):
        r = ((v >> 5) & 0x7) * 255 // 7
        g = ((v >> 2) & 0x7) * 255 // 7
        b = (v & 0x3) * 255 // 3
        palette.append(bytes((r, g, b)))
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # PNG filter: none
        row = pixels[y * width:(y + 1) * width]
        for v in row:
            raw += palette[v]

    def chunk(tag, payload):
        c = tag + payload
        return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    args = sys.argv[1:]
    wait = 0.0
    if args and args[0] == "--wait":
        wait = float(args[1])
        args = args[2:]
    out = args[0] if args else "/tmp/fmrb_screen.png"

    deadline = time.time() + wait
    frame = None
    while True:
        try:
            frame = read_shm()
        except FileNotFoundError:
            frame = None
        except LayoutMismatch as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        if frame:
            break
        if time.time() >= deadline:
            break
        time.sleep(0.2)

    if not frame:
        print(f"error: no ready framebuffer at {SHM_PATH} "
              f"(is the compose stack running?)", file=sys.stderr)
        return 1
    width, height, pixels = frame
    rgb332_to_png(width, height, pixels, out)
    blank = len(set(pixels)) == 1
    print(f"{out}: {width}x{height}{' (blank frame)' if blank else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
