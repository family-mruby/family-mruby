#!/usr/bin/env ruby
# Inject synthetic mouse/keyboard events into the Family mruby Linux sim.
#
# Events are sent as pre-framed HID packets ([type u8][len u16 LE][payload],
# see fmruby-graphics-audio/main/include/fmrb_hid_event.h) to the Unix DGRAM
# socket /var/run/fmrb/fmrb_inject, which the SDL2 display process forwards
# into the normal input stream. Coordinates are framebuffer coordinates
# (e.g. 0..319 x 0..239), independent of window scaling.
#
# With Docker Desktop the socket volume is only visible inside the containers,
# so when the socket path does not exist locally the packets are delivered by a
# sender running inside fmruby_graphics_audio (delays preserved).
#
# Usage (commands run in sequence, left to right):
#   fmrb_input.rb move X Y                # mouse motion
#   fmrb_input.rb click X Y [--button N]  # motion + press + release (default 1=left)
#   fmrb_input.rb down X Y / up X Y       # press / release separately
#   fmrb_input.rb key NAME                # key press+release: a-z 0-9 enter esc
#                                         # tab space backspace up down left right f1-f12
#                                         # home end pageup pagedown insert delete
#   fmrb_input.rb key shift+NAME          # with shift modifier
#   fmrb_input.rb text "STRING"           # type a string (ascii)
#   fmrb_input.rb --layout jp ...         # keyboard layout for text/key
#                                         # (default: keyboard_layout from
#                                         #  config/system_conf_linux.toml)
#   fmrb_input.rb sleep MS                # pause between commands
#   Multiple commands: fmrb_input.rb click 30 220 sleep 500 key enter

require "socket"

SOCKET_PATH = "/var/run/fmrb/fmrb_inject"
DOCKER_CONTAINER = "fmruby_graphics_audio"

EV_KEY_DOWN = 0x01
EV_KEY_UP = 0x02
EV_MOUSE_BUTTON = 0x10
EV_MOUSE_MOTION = 0x11

KEY_DELAY_MS = 40      # between press and release
CLICK_DELAY_MS = 60    # between motion/press/release of a click

# name -> [SDL scancode, SDL keycode & 0xFF]
SPECIAL_KEYS = {
  "enter" => [40, 13], "esc" => [41, 27], "backspace" => [42, 8],
  "tab" => [43, 9], "space" => [44, 32],
  "right" => [79, 0x4F], "left" => [80, 0x50], "down" => [81, 0x51], "up" => [82, 0x52],
  "home" => [74, 0x4A], "end" => [77, 0x4D],
  "pageup" => [75, 0x4B], "pagedown" => [78, 0x4E],
  "insert" => [73, 0x49], "delete" => [76, 0x4C],
}
(1..12).each { |i| SPECIAL_KEYS["f#{i}"] = [58 + i - 1, 0] }

# Modifier byte values as the Linux sim input path expects them: sdl2-display
# forwards SDL keysym.mod (low byte) and usb_task_linux.c maps SHIFT/CTRL to the
# canonical FMRB_KEYMAP_MOD layout. NOTE: SDL's ALT bit is 0x100, truncated to
# the low byte before it reaches the sim, so alt+ is UNRECOVERABLE in the Linux
# sim (it works on real HW via USB HID). Use mouse clicks for Alt-only menus.
KMOD_SHIFT = 0x01   # SDL KMOD_LSHIFT
KMOD_CTRL  = 0x40   # SDL KMOD_LCTRL
KMOD_ALT   = 0x00   # unrecoverable in the sim (see note above)

# Character to key mapping. The device converts scancode + shift to a character
# with the table in fmruby-core/main/drivers/usb/fmrb_keymap.c, honouring
# keyboard_layout from system_conf. This tool reads that same table and inverts
# it, so `text` types what the device will actually see -- with the layout hard
# coded to US, "PRINT \"X\"" arrived as PRINT *X* on a jp configured system.
HERE = File.dirname(File.expand_path(__FILE__))
KEYMAP_C = File.join(HERE, "..", "fmruby-core", "main", "drivers", "usb", "fmrb_keymap.c")
# The config actually in use is the generated one; config/system_conf_linux.toml
# is only the Retro source for it (a Modern HW target builds the sim from
# config/system_conf_linux_p4.toml instead).
SYSTEM_CONF_CANDIDATES = [
  File.join(HERE, "..", "fmruby-core", "flash", "etc", "system_conf.toml"),
  File.join(HERE, "..", "fmruby-core", "config", "system_conf_linux.toml"),
]

CHAR_LITERALS = {
  "'\\n'" => "\n", "'\\t'" => "\t", "'\\b'" => "\b", "'\\\\'" => "\\", "'\\''" => "'",
}

# One C char literal from the keymap table -> the character, or nil.
def literal(text)
  text = text.strip
  return nil if text == "0"
  return CHAR_LITERALS[text] if CHAR_LITERALS.key?(text)
  return text[1] if text.length == 3 && text[0] == "'" && text[2] == "'"
  nil
end

# {char => [scancode, needs_shift]} for "us" or "jp", from the firmware table.
def load_keymap(layout)
  source = File.read(KEYMAP_C)
  marker = "static const keymap_entry_t #{layout}_keymap[] = {"
  start = source.index(marker)
  return {} unless start
  body = source[(start + marker.length)...source.index("};", start)]
  table = {}
  body.each_line do |line|
    m = /^\s*\[(\d+)\]\s*=\s*\{(.+?),(.+?)\}/.match(line)
    next unless m
    scancode = m[1].to_i
    plain = literal(m[2])
    shifted = literal(m[3])
    table[plain] = [scancode, false] if plain && !table.key?(plain)
    table[shifted] = [scancode, true] if shifted && shifted != plain && !table.key?(shifted)
  end
  table
rescue Errno::ENOENT
  {}
end

# keyboard_layout from the simulation system config, "us" when unset.
def configured_layout
  SYSTEM_CONF_CANDIDATES.each do |path|
    next unless File.exist?(path)
    File.foreach(path) do |line|
      m = /^\s*keyboard_layout\s*=\s*"([a-z]+)"/.match(line)
      return m[1] if m
    end
  end
  "us"
end

$layout = configured_layout
$char_keys = load_keymap($layout)

# [scancode, needs_shift] for a character under the active layout.
def char_key(ch)
  return $char_keys[ch] if $char_keys.key?(ch)
  # Fallback for a checkout without the firmware source: ASCII letters and
  # digits sit at the same scancodes in every layout.
  low = ch.downcase
  return [4 + low.ord - "a".ord, ch != low] if low >= "a" && low <= "z"
  return [39, false] if ch == "0"
  return [30 + ch.ord - "1".ord, false] if ch >= "1" && ch <= "9"
  return [44, false] if ch == " "
  [nil, false]
end

# Return [scancode, keycode, modifier] for a key name.
#
# Accepts stackable modifier prefixes: shift+, ctrl+, alt+ (e.g. ctrl+s,
# alt+d, shift+f11).
def key_lookup(name)
  mod = 0
  loop do
    if name.start_with?("shift+")
      mod |= KMOD_SHIFT
      name = name[6..]
    elsif name.start_with?("ctrl+")
      mod |= KMOD_CTRL
      name = name[5..]
    elsif name.start_with?("alt+")
      mod |= KMOD_ALT
      name = name[4..]
    else
      break
    end
  end
  name = name.downcase
  if SPECIAL_KEYS.key?(name)
    sc, kc = SPECIAL_KEYS[name]
    return [sc, kc, mod]
  end
  if name.length == 1
    sc, shift = char_key(name)
    return [sc, name.ord, mod | (shift ? KMOD_SHIFT : 0)] if sc
  end
  abort "unknown key: #{name}"
end

def pkt(ev_type, payload)
  [ev_type, payload.bytesize].pack("Cv") + payload
end

def ev_motion(x, y)
  pkt(EV_MOUSE_MOTION, [x, y].pack("vv"))
end

def ev_button(button, state, x, y)
  pkt(EV_MOUSE_BUTTON, [button, state, x, y].pack("CCvv"))
end

def ev_key(ev_type, scancode, keycode, modifier)
  pkt(ev_type, [scancode, keycode, modifier].pack("CCC"))
end

# Return a list of [delay_before_ms, packet_bytes].
def parse_commands(argv)
  if (at = argv.index("--layout"))
    $layout = argv[at + 1]
    $char_keys = load_keymap($layout)
    argv.slice!(at, 2)
  end

  out = []
  i = 0
  take = lambda do |n|
    vals = argv[(i + 1), n]
    abort "#{argv[i]}: missing argument" if vals.nil? || vals.length < n
    i += n
    vals
  end

  pending_sleep = 0
  while i < argv.length
    cmd = argv[i]
    case cmd
    when "sleep"
      pending_sleep += take.call(1)[0].to_i
    when "move"
      x, y = take.call(2).map(&:to_i)
      out << [pending_sleep, ev_motion(x, y)]
      pending_sleep = 0
    when "click", "down", "up"
      x, y = take.call(2).map(&:to_i)
      button = 1
      if argv[i + 1] == "--button" && argv[i + 2]
        button = argv[i + 2].to_i
        i += 2
      end
      if cmd == "click"
        out << [pending_sleep, ev_motion(x, y)]
        pending_sleep = 0
        out << [CLICK_DELAY_MS, ev_button(button, 1, x, y)]
        out << [CLICK_DELAY_MS, ev_button(button, 0, x, y)]
      else
        state = cmd == "down" ? 1 : 0
        out << [pending_sleep, ev_button(button, state, x, y)]
        pending_sleep = 0
      end
    when "key"
      sc, kc, mod = key_lookup(take.call(1)[0])
      out << [pending_sleep, ev_key(EV_KEY_DOWN, sc, kc, mod)]
      pending_sleep = 0
      out << [KEY_DELAY_MS, ev_key(EV_KEY_UP, sc, kc, mod)]
    when "text"
      take.call(1)[0].each_char do |c|
        sc, shift = char_key(c)
        abort "cannot type #{c.inspect} with the #{$layout} layout" unless sc
        mod = shift ? KMOD_SHIFT : 0
        # keycode carries the unshifted symbol, as SDL reports it; the device
        # derives the character from scancode + modifier.
        kc = c.match?(/[A-Za-z]/) ? c.downcase.ord : c.ord
        out << [[pending_sleep, KEY_DELAY_MS].max, ev_key(EV_KEY_DOWN, sc, kc, mod)]
        pending_sleep = 0
        out << [KEY_DELAY_MS, ev_key(EV_KEY_UP, sc, kc, mod)]
      end
    else
      abort "unknown command: #{cmd}"
    end
    i += 1
  end
  out
end

# The in-container sender stays Python: the graphics-audio image is the ESP-IDF
# build image, which ships python3 but no ruby.
SENDER_SNIPPET = <<~PYTHON
  import socket, sys, time
  s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
  for line in sys.stdin:
      line = line.strip()
      if not line:
          continue
      delay, hexpkt = line.split(",")
      if int(delay):
          time.sleep(int(delay) / 1000.0)
      s.sendto(bytes.fromhex(hexpkt), "#{SOCKET_PATH}")
PYTHON

def send_events(events)
  if File.exist?(SOCKET_PATH)
    sock = Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM, 0)
    dest = Socket.pack_sockaddr_un(SOCKET_PATH)
    events.each do |delay, packet|
      sleep(delay / 1000.0) if delay > 0
      sock.send(packet, 0, dest)
    end
    return 0
  end

  feed = events.map { |delay, packet| "#{delay},#{packet.unpack1('H*')}\n" }.join
  IO.popen(["docker", "exec", "-i", DOCKER_CONTAINER, "python3", "-c", SENDER_SNIPPET],
           "w") { |io| io.write(feed) }
  $?.exitstatus
end

def main
  argv = ARGV.dup
  if argv.empty? || ["-h", "--help"].include?(argv[0])
    puts File.read(File.expand_path(__FILE__))[/\A(#!.*\n)?((?:#.*\n)+)/, 2].gsub(/^# ?/, "")
    return 0
  end
  events = parse_commands(argv)
  rc = send_events(events)
  puts "injected #{events.length} event(s)" if rc == 0
  rc
end

exit(main) if __FILE__ == $PROGRAM_NAME
