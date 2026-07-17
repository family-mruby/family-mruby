#!/usr/bin/env python3
"""Inject synthetic mouse/keyboard events into the Family mruby Linux sim.

Events are sent as pre-framed HID packets ([type u8][len u16 LE][payload],
see fmruby-graphics-audio/main/include/fmrb_hid_event.h) to the Unix DGRAM
socket /var/run/fmrb/fmrb_inject, which the SDL2 display process forwards
into the normal input stream. Coordinates are framebuffer coordinates
(e.g. 0..319 x 0..239), independent of window scaling.

With Docker Desktop the socket volume is only visible inside the containers,
so when the socket path does not exist locally the packets are delivered via
`docker exec fmruby_graphics_audio python3` (one exec per invocation, delays
preserved).

Usage (commands run in sequence, left to right):
  fmrb_input.py move X Y                # mouse motion
  fmrb_input.py click X Y [--button N]  # motion + press + release (default 1=left)
  fmrb_input.py down X Y / up X Y       # press / release separately
  fmrb_input.py key NAME                # key press+release: a-z 0-9 enter esc
                                        # tab space backspace up down left right f1-f12
  fmrb_input.py key shift+NAME          # with shift modifier
  fmrb_input.py text "STRING"           # type a string (ascii)
  fmrb_input.py sleep MS                # pause between commands
  Multiple commands: fmrb_input.py click 30 220 sleep 500 key enter
"""
import struct
import subprocess
import sys
import time

SOCKET_PATH = "/var/run/fmrb/fmrb_inject"
DOCKER_CONTAINER = "fmruby_graphics_audio"

EV_KEY_DOWN = 0x01
EV_KEY_UP = 0x02
EV_MOUSE_BUTTON = 0x10
EV_MOUSE_MOTION = 0x11

KEY_DELAY_MS = 40      # between press and release
CLICK_DELAY_MS = 60    # between motion/press/release of a click

# name -> (SDL scancode, SDL keycode & 0xFF)
SPECIAL_KEYS = {
    "enter": (40, 13), "esc": (41, 27), "backspace": (42, 8),
    "tab": (43, 9), "space": (44, 32),
    "right": (79, 0x4F), "left": (80, 0x50), "down": (81, 0x51), "up": (82, 0x52),
}
for i in range(1, 13):
    SPECIAL_KEYS[f"f{i}"] = (58 + i - 1, 0)

# Punctuation: US scancode + unshifted ascii keycode (SDL reports the
# unshifted sym; the receiver applies its own layout).
PUNCT = {
    "-": 45, "=": 46, "[": 47, "]": 48, "\\": 49, ";": 51, "'": 52,
    "`": 53, ",": 54, ".": 55, "/": 56,
}
# shifted char -> base char (US layout)
SHIFTED = {
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
    '"': "'", "~": "`", "<": ",", ">": ".", "?": "/",
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
}

KMOD_SHIFT = 0x01


def key_lookup(name):
    """Return (scancode, keycode, modifier) for a key name."""
    mod = 0
    if name.startswith("shift+"):
        mod = KMOD_SHIFT
        name = name[len("shift+"):]
    name = name.lower()
    if name in SPECIAL_KEYS:
        sc, kc = SPECIAL_KEYS[name]
        return sc, kc, mod
    if len(name) == 1:
        c = name[0]
        if "a" <= c <= "z":
            return 4 + ord(c) - ord("a"), ord(c), mod
        if c == "0":
            return 39, ord("0"), mod
        if "1" <= c <= "9":
            return 30 + ord(c) - ord("1"), ord(c), mod
        if c in PUNCT:
            return PUNCT[c], ord(c), mod
    raise SystemExit(f"unknown key: {name}")


def pkt(ev_type, payload):
    return struct.pack("<BH", ev_type, len(payload)) + payload


def ev_motion(x, y):
    return pkt(EV_MOUSE_MOTION, struct.pack("<HH", x, y))


def ev_button(button, state, x, y):
    return pkt(EV_MOUSE_BUTTON, struct.pack("<BBHH", button, state, x, y))


def ev_key(ev_type, scancode, keycode, modifier):
    return pkt(ev_type, struct.pack("<BBB", scancode, keycode, modifier))


def parse_commands(argv):
    """Return a list of (delay_before_ms, packet_bytes)."""
    out = []
    i = 0

    def take(n):
        nonlocal i
        vals = argv[i + 1:i + 1 + n]
        if len(vals) < n:
            raise SystemExit(f"{argv[i]}: missing argument")
        i += n
        return vals

    pending_sleep = 0
    while i < len(argv):
        cmd = argv[i]
        if cmd == "sleep":
            pending_sleep += int(take(1)[0])
        elif cmd == "move":
            x, y = map(int, take(2))
            out.append((pending_sleep, ev_motion(x, y))); pending_sleep = 0
        elif cmd in ("click", "down", "up"):
            x, y = map(int, take(2))
            button = 1
            if i + 2 < len(argv) and argv[i + 1] == "--button":
                button = int(argv[i + 2]); i += 2
            if cmd == "click":
                out.append((pending_sleep, ev_motion(x, y))); pending_sleep = 0
                out.append((CLICK_DELAY_MS, ev_button(button, 1, x, y)))
                out.append((CLICK_DELAY_MS, ev_button(button, 0, x, y)))
            else:
                state = 1 if cmd == "down" else 0
                out.append((pending_sleep, ev_button(button, state, x, y)))
                pending_sleep = 0
        elif cmd == "key":
            sc, kc, mod = key_lookup(take(1)[0])
            out.append((pending_sleep, ev_key(EV_KEY_DOWN, sc, kc, mod))); pending_sleep = 0
            out.append((KEY_DELAY_MS, ev_key(EV_KEY_UP, sc, kc, mod)))
        elif cmd == "text":
            for c in take(1)[0]:
                name = c
                mod = 0
                if c.isupper():
                    name = c.lower(); mod = KMOD_SHIFT
                elif c in SHIFTED:
                    name = SHIFTED[c]; mod = KMOD_SHIFT
                elif c == " ":
                    name = "space"
                sc, kc, m = key_lookup(name)
                out.append((max(pending_sleep, KEY_DELAY_MS), ev_key(EV_KEY_DOWN, sc, kc, mod | m)))
                pending_sleep = 0
                out.append((KEY_DELAY_MS, ev_key(EV_KEY_UP, sc, kc, mod | m)))
        else:
            raise SystemExit(f"unknown command: {cmd}")
        i += 1
    return out


SENDER_SNIPPET = r"""
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    delay, hexpkt = line.split(",")
    if int(delay):
        time.sleep(int(delay) / 1000.0)
    s.sendto(bytes.fromhex(hexpkt), "%s")
""" % SOCKET_PATH


def send_events(events):
    feed = "".join(f"{d},{p.hex()}\n" for d, p in events)
    import os
    if os.path.exists(SOCKET_PATH):
        import io
        import socket
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        for d, p in events:
            if d:
                time.sleep(d / 1000.0)
            s.sendto(p, SOCKET_PATH)
        return 0
    r = subprocess.run(
        ["docker", "exec", "-i", DOCKER_CONTAINER, "python3", "-c", SENDER_SNIPPET],
        input=feed.encode())
    return r.returncode


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    events = parse_commands(argv)
    rc = send_events(events)
    if rc == 0:
        print(f"injected {len(events)} event(s)")
    return rc


if __name__ == "__main__":
    sys.exit(main())
