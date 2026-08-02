#!/usr/bin/env python3
# Capture the ESP32-S3 serial log to a file, optionally resetting the board
# first so the capture starts at boot.
#
# Python + pyserial (not Ruby) on purpose: the reset needs RTS/DTR modem-line
# control, which Ruby's stdlib cannot do portably, and pyserial is already a
# host dependency via esptool.
#
# Usage:
#   python3 tools/fmrb_serial_capture.py [-p PORT] [-t SECS] [--no-reset] OUT
#
# - Default port: fmruby-core/.serial_port (written by `rake check-port`),
#   falling back to /dev/ttyUSB0.
# - Default: pulse RTS to reset the board (same circuit esptool uses), so the
#   log starts from the boot banner. --no-reset attaches without touching the
#   lines -- note that on some adapters merely opening the port can still
#   glitch DTR/RTS and reset the board.
# - Output is flushed per chunk, so the file can be read (grep'd) while the
#   capture is still running.
# - The port is exclusive: flashing fails with "device reports readiness to
#   read but returned no data" while a capture (or any monitor) holds it.
import argparse
import os
import sys
import time

import serial

DEFAULT_PORT_CACHE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "fmruby-core", ".serial_port")


def default_port():
    try:
        with open(DEFAULT_PORT_CACHE) as f:
            cached = f.read().strip()
        if cached and os.path.exists(cached):
            return cached
    except OSError:
        pass
    return "/dev/ttyUSB0"


def main():
    ap = argparse.ArgumentParser(description="Capture ESP32 serial log")
    ap.add_argument("out", help="output log file")
    ap.add_argument("-p", "--port", default=default_port())
    ap.add_argument("-t", "--secs", type=float, default=40.0,
                    help="capture duration in seconds (default 40)")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("--no-reset", action="store_true",
                    help="attach without pulsing the reset line")
    args = ap.parse_args()

    if args.no_reset:
        s = serial.Serial()
        s.port = args.port
        s.baudrate = args.baud
        s.timeout = 0.5
        # Preload the modem lines so open() itself does not assert them.
        s.dtr = False
        s.rts = False
        s.open()
    else:
        s = serial.Serial(args.port, args.baud, timeout=0.5)
        # esptool-style reset: EN low via RTS, IO0 released via DTR, release.
        s.dtr = False
        s.rts = True
        time.sleep(0.1)
        s.rts = False
        s.reset_input_buffer()

    end = time.time() + args.secs
    with open(args.out, "wb") as f:
        while time.time() < end:
            data = s.read(4096)
            if data:
                f.write(data)
                f.flush()
    s.close()
    print(f"captured {args.secs:.0f}s from {args.port} to {args.out}")


if __name__ == "__main__":
    sys.exit(main())
