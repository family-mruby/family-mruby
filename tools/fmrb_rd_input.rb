#!/usr/bin/env ruby
# Drive the Tab5 remote desktop: mouse clicks and key chords over /ws.
# Usage: ruby fmrb_rd_input.rb HOST cmd... where cmd is:
#   click X Y | rclick X Y | dclick X Y | move X Y | drag X1 Y1 X2 Y2 |
#   wheel N | key NAME | key ctrl+NAME | key alt+NAME | sleep MS
require "socket"
require "securerandom"
require "base64"

HOST = ARGV.shift or abort "usage: fmrb_rd_input.rb HOST cmds..."

SCAN = { "tab" => 0x2B, "right" => 0x4F, "left" => 0x50, "up" => 0x52,
         "down" => 0x51, "esc" => 0x29, "enter" => 0x28, "space" => 0x2C,
         "backspace" => 0x2A, "delete" => 0x4C, "home" => 0x4A, "end" => 0x4D,
         "pageup" => 0x4B, "pagedown" => 0x4E,
         # Function keys. F10 opens the desktop's menu bar; F11 is fullscreen.
         "f1" => 0x3A, "f2" => 0x3B, "f3" => 0x3C, "f4" => 0x3D, "f5" => 0x3E,
         "f6" => 0x3F, "f7" => 0x40, "f8" => 0x41, "f9" => 0x42, "f10" => 0x43,
         "f11" => 0x44, "f12" => 0x45,
         # Symbols, JP layout scancodes (the firmware maps by its configured
         # layout; shift picks the second legend, e.g. shift+, -> '<').
         "," => 0x36, "." => 0x37, "@" => 0x2F, "-" => 0x2D, ";" => 0x33,
         ":" => 0x34, "slash" => 0x38,
         # International1, the key left of the right shift on a JP keyboard.
         # Shifted it is "_", which nothing else can reach.
         "ro" => 0x87 }
# a-z, 1-0 and F1-F12 are each contiguous in the HID usage table.
("a".."z").each_with_index { |c, i| SCAN[c] = 0x04 + i }
(("1".."9").to_a + ["0"]).each_with_index { |c, i| SCAN[c] = 0x1E + i }
(1..12).each { |n| SCAN["f#{n}"] = 0x39 + n }
MOD_LCTRL = 0x04
MOD_LSHIFT = 0x02
# The editor's menu bar letters are Alt-something, so the tool has to be able
# to send it. Values are the HID modifier bits (fmrb_keymap.h): LCTRL 0x01 in
# HID terms is what the firmware calls 0x04, and LALT is 0x10.
MOD_LALT = 0x10
MSG_MOUSE_MOVE = 0x01
MSG_MOUSE_BUTTON = 0x02
MSG_KEY = 0x03
MSG_MOUSE_WHEEL = 0x06

def ws_connect(host)
  s = TCPSocket.new(host, 80)
  key = Base64.strict_encode64(SecureRandom.random_bytes(16))
  s.write("GET /ws HTTP/1.1\r\nHost: #{host}\r\nUpgrade: websocket\r\n" \
          "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\n" \
          "Sec-WebSocket-Version: 13\r\n\r\n")
  line = s.readline
  abort "handshake failed: #{line}" unless line.include?("101")
  loop { break if s.readline.strip.empty? }
  s
end

def ws_send(s, payload)
  mask = SecureRandom.random_bytes(4)
  masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i % 4) }
  s.write([0x82, 0x80 | payload.bytesize].pack("C2") + mask + masked.pack("C*"))
end

# button: 1 = left, 2 = middle, 3 = right (what rd_input.c accepts).
def click(s, x, y, button = 1)
  ws_send(s, [MSG_MOUSE_BUTTON, x, y, button, 1].pack("Cs<s<C2"))
  sleep 0.06
  ws_send(s, [MSG_MOUSE_BUTTON, x, y, button, 0].pack("Cs<s<C2"))
end

# Press and release as separate commands, so the pointer can be held down
# across a `sleep` -- that is how you photograph a widget's pressed look.
def mdown(s, x, y, button = 1)
  ws_send(s, [MSG_MOUSE_BUTTON, x, y, button, 1].pack("Cs<s<C2"))
end

def mup(s, x, y, button = 1)
  ws_send(s, [MSG_MOUSE_BUTTON, x, y, button, 0].pack("Cs<s<C2"))
end

def move(s, x, y)
  ws_send(s, [MSG_MOUSE_MOVE, x, y].pack("Cs<s<"))
end

# Wheel notches, positive away from the user (which scrolls a view towards its
# start). The coordinates are the last ones this command line moved to, so a
# `move` before the `wheel` puts the pointer where the app will read it -- the
# same rule as tools/fmrb_input.rb, so one habit works on both machines.
def wheel(s, notches, x, y)
  ws_send(s, [MSG_MOUSE_WHEEL, x, y, notches].pack("Cs<s<c"))
end

# Press at (x1,y1), walk to (x2,y2) in steps, release. Window title bars
# only follow a pointer that actually moves while the button is held.
def drag(s, x1, y1, x2, y2)
  move(s, x1, y1)
  sleep 0.08
  ws_send(s, [MSG_MOUSE_BUTTON, x1, y1, 1, 1].pack("Cs<s<C2"))
  steps = 12
  1.upto(steps) do |i|
    move(s, x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
    sleep 0.03
  end
  sleep 0.08
  ws_send(s, [MSG_MOUSE_BUTTON, x2, y2, 1, 0].pack("Cs<s<C2"))
end

def key_parse(spec)
  mods = 0
  name = spec.dup
  while name.include?("+") && name.length > 1
    prefix, name = name.split("+", 2)
    mods |= MOD_LCTRL if prefix == "ctrl"
    mods |= MOD_LSHIFT if prefix == "shift"
    mods |= MOD_LALT if prefix == "alt"
  end
  sc = SCAN[name] or abort "unknown key: #{name}"
  [sc, mods]
end

def key(s, spec)
  sc, mods = key_parse(spec)
  ws_send(s, [MSG_KEY, 1, sc, mods].pack("C4"))
  sleep 0.08
  ws_send(s, [MSG_KEY, 0, sc, mods].pack("C4"))
end

# Press and release as separate commands, so a key can be held across a
# `sleep`. `key` taps for 80ms, which is a frame or two -- not enough to make
# an app that only redraws while something moves run at its natural rate, which
# is what you need to measure a frame time rather than the gaps between taps.
#
#   keydown right sleep 5000 keyup right
def keydown(s, spec)
  sc, mods = key_parse(spec)
  ws_send(s, [MSG_KEY, 1, sc, mods].pack("C4"))
end

def keyup(s, spec)
  sc, mods = key_parse(spec)
  ws_send(s, [MSG_KEY, 0, sc, mods].pack("C4"))
end

s = ws_connect(HOST)
args = ARGV.dup
# Where the pointer was last put on this command line, so `wheel` can say
# where it happened without a coordinate of its own.
last_x = 0
last_y = 0
until args.empty?
  case args.shift
  when "click"  then last_x = args.shift.to_i; last_y = args.shift.to_i
                     click(s, last_x, last_y)
  when "rclick" then last_x = args.shift.to_i; last_y = args.shift.to_i
                     click(s, last_x, last_y, 3)
  when "dclick" then last_x = args.shift.to_i; last_y = args.shift.to_i
                     click(s, last_x, last_y); sleep 0.12
                     click(s, last_x, last_y)
  when "mdown"  then last_x = args.shift.to_i; last_y = args.shift.to_i
                     mdown(s, last_x, last_y)
  when "mup"    then last_x = args.shift.to_i; last_y = args.shift.to_i
                     mup(s, last_x, last_y)
  when "move"   then last_x = args.shift.to_i; last_y = args.shift.to_i
                     move(s, last_x, last_y)
  when "wheel"  then wheel(s, args.shift.to_i, last_x, last_y)
  when "drag"   then x1 = args.shift.to_i; y1 = args.shift.to_i
                     last_x = args.shift.to_i; last_y = args.shift.to_i
                     drag(s, x1, y1, last_x, last_y)
  when "key"     then key(s, args.shift)
  when "keydown" then keydown(s, args.shift)
  when "keyup"   then keyup(s, args.shift)
  when "sleep"  then sleep(args.shift.to_f / 1000.0)
  else abort "unknown cmd"
  end
  sleep 0.15
end
s.close
puts "done"
