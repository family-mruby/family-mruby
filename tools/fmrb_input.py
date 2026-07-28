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
  fmrb_input.py --layout jp ...          # keyboard layout for text/key
                                        # (default: keyboard_layout from
                                        #  config/system_conf_linux.toml)
  fmrb_input.py sleep MS                # pause between commands
  Multiple commands: fmrb_input.py click 30 220 sleep 500 key enter
"""
import os
import re
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

# Character to key mapping. The device converts scancode + shift to a character
# with the table in fmruby-core/main/drivers/usb/fmrb_keymap.c, honouring
# keyboard_layout from system_conf. This tool reads that same table and inverts
# it, so `text` types what the device will actually see -- with the layout
# hard coded to US, "PRINT \"X\"" arrived as PRINT *X* on a jp configured
# system (B3.5 report #26).
HERE = os.path.dirname(os.path.abspath(__file__))
KEYMAP_C = os.path.join(HERE, "..", "fmruby-core", "main", "drivers", "usb", "fmrb_keymap.c")
SYSTEM_CONF = os.path.join(HERE, "..", "fmruby-core", "config", "system_conf_linux.toml")

_CHAR_LITERAL = {
    "'\\n'": "\n", "'\\t'": "\t", "'\\b'": "\b", "'\\\\'": "\\", "'\\''": "'",
}


def _literal(text):
    """One C char literal from the keymap table -> the character, or None."""
    text = text.strip()
    if text == "0":
        return None
    if text in _CHAR_LITERAL:
        return _CHAR_LITERAL[text]
    if len(text) == 3 and text[0] == "'" and text[2] == "'":
        return text[1]
    return None


def load_keymap(layout):
    """{char: (scancode, needs_shift)} for "us" or "jp", from the firmware table."""
    try:
        source = open(KEYMAP_C, encoding="utf-8").read()
    except OSError:
        return {}
    marker = "static const keymap_entry_t %s_keymap[] = {" % layout
    start = source.find(marker)
    if start < 0:
        return {}
    body = source[start + len(marker):source.find("};", start)]
    table = {}
    for line in body.split("\n"):
        m = re.match(r"\s*\[(\d+)\]\s*=\s*\{(.+?),(.+?)\}", line)
        if not m:
            continue
        scancode = int(m.group(1))
        plain = _literal(m.group(2))
        shifted = _literal(m.group(3))
        if plain is not None and plain not in table:
            table[plain] = (scancode, False)
        if shifted is not None and shifted != plain and shifted not in table:
            table[shifted] = (scancode, True)
    return table


def configured_layout():
    """keyboard_layout from the simulation system config, "us" when unset."""
    try:
        for line in open(SYSTEM_CONF, encoding="utf-8"):
            m = re.match(r'\s*keyboard_layout\s*=\s*"([a-z]+)"', line)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "us"


LAYOUT = configured_layout()
CHAR_KEYS = load_keymap(LAYOUT)

# Modifier byte values as the Linux sim input path expects them: sdl2-display
# forwards SDL keysym.mod (low byte) and usb_task_linux.c maps SHIFT/CTRL to the
# canonical FMRB_KEYMAP_MOD layout. NOTE: SDL's ALT bit is 0x100, truncated to
# the low byte before it reaches the sim, so alt+ is UNRECOVERABLE in the Linux
# sim (it works on real HW via USB HID). Use mouse clicks for Alt-only menus.
KMOD_SHIFT = 0x01   # SDL KMOD_LSHIFT
KMOD_CTRL  = 0x40   # SDL KMOD_LCTRL
KMOD_ALT   = 0x00   # unrecoverable in the sim (see note above)


def key_lookup(name):
    """Return (scancode, keycode, modifier) for a key name.

    Accepts stackable modifier prefixes: shift+, ctrl+, alt+ (e.g. ctrl+s,
    alt+d, shift+f11)."""
    mod = 0
    while True:
        if name.startswith("shift+"):
            mod |= KMOD_SHIFT; name = name[len("shift+"):]
        elif name.startswith("ctrl+"):
            mod |= KMOD_CTRL; name = name[len("ctrl+"):]
        elif name.startswith("alt+"):
            mod |= KMOD_ALT; name = name[len("alt+"):]
        else:
            break
    name = name.lower()
    if name in SPECIAL_KEYS:
        sc, kc = SPECIAL_KEYS[name]
        return sc, kc, mod
    if len(name) == 1:
        sc, shift = char_key(name[0])
        if sc is not None:
            return sc, ord(name[0]), mod | (KMOD_SHIFT if shift else 0)
    raise SystemExit(f"unknown key: {name}")


def char_key(ch):
    """(scancode, needs_shift) for a character under the active layout."""
    if ch in CHAR_KEYS:
        return CHAR_KEYS[ch]
    # Fallback for a checkout without the firmware source: ASCII letters and
    # digits sit at the same scancodes in every layout.
    low = ch.lower()
    if "a" <= low <= "z":
        return 4 + ord(low) - ord("a"), ch.isupper()
    if ch == "0":
        return 39, False
    if "1" <= ch <= "9":
        return 30 + ord(ch) - ord("1"), False
    if ch == " ":
        return 44, False
    return None, False


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
    global LAYOUT, CHAR_KEYS
    if "--layout" in argv:
        at = argv.index("--layout")
        LAYOUT = argv[at + 1]
        CHAR_KEYS = load_keymap(LAYOUT)
        del argv[at:at + 2]
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
                sc, shift = char_key(c)
                if sc is None:
                    raise SystemExit(
                        "cannot type %r with the %s layout" % (c, LAYOUT))
                mod = KMOD_SHIFT if shift else 0
                # keycode carries the unshifted symbol, as SDL reports it; the
                # device derives the character from scancode + modifier.
                kc = ord(c.lower()) if c.isalpha() else ord(c)
                out.append((max(pending_sleep, KEY_DELAY_MS), ev_key(EV_KEY_DOWN, sc, kc, mod)))
                pending_sleep = 0
                out.append((KEY_DELAY_MS, ev_key(EV_KEY_UP, sc, kc, mod)))
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
