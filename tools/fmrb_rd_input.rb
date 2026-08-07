#!/usr/bin/env ruby
# Drive the Tab5 remote desktop: mouse clicks and key chords over /ws.
# Usage: ruby fmrb_rd_input.rb HOST cmd... where cmd is:
#   click X Y | dclick X Y | key NAME | key ctrl+NAME | sleep MS
require "socket"
require "securerandom"
require "base64"

HOST = ARGV.shift or abort "usage: fmrb_rd_input.rb HOST cmds..."

SCAN = { "tab" => 0x2B, "q" => 0x14, "right" => 0x4F, "left" => 0x50,
         "esc" => 0x29, "enter" => 0x28, "space" => 0x2C }
MOD_LCTRL = 0x04
MSG_MOUSE_BUTTON = 0x02
MSG_KEY = 0x03

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

def click(s, x, y)
  ws_send(s, [MSG_MOUSE_BUTTON, x, y, 1, 1].pack("Cs<s<C2"))
  sleep 0.06
  ws_send(s, [MSG_MOUSE_BUTTON, x, y, 1, 0].pack("Cs<s<C2"))
end

def key(s, spec)
  mods = 0
  name = spec.dup
  while name.include?("+")
    prefix, name = name.split("+", 2)
    mods |= MOD_LCTRL if prefix == "ctrl"
  end
  sc = SCAN[name] or abort "unknown key: #{name}"
  ws_send(s, [MSG_KEY, 1, sc, mods].pack("C4"))
  sleep 0.08
  ws_send(s, [MSG_KEY, 0, sc, mods].pack("C4"))
end

s = ws_connect(HOST)
args = ARGV.dup
until args.empty?
  case args.shift
  when "click"  then click(s, args.shift.to_i, args.shift.to_i)
  when "dclick" then x = args.shift.to_i; y = args.shift.to_i
                     click(s, x, y); sleep 0.12; click(s, x, y)
  when "key"    then key(s, args.shift)
  when "sleep"  then sleep(args.shift.to_f / 1000.0)
  else abort "unknown cmd"
  end
  sleep 0.15
end
s.close
puts "done"
