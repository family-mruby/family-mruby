#!/usr/bin/env ruby
# Drive the browser build of Family mruby from a shell.
#
# The browser cannot be reached from outside, so the page comes and asks: with
# ?drive=1 it polls the development server (rake wasm:serve) for a command,
# carries it out, and posts the answer back. This tool is the other end of
# that relay. Events go into the same ring the real mouse and keyboard use, so
# the machine cannot tell a driven run from a used one.
#
# The vocabulary is the Linux sim's (tools/fmrb_input.rb), and the scancodes
# come from the firmware's own keymap through it, so `text` types what the
# machine will actually see under the configured layout.
#
# Usage:
#   fmrb_web.rb up [--headless] [--url-args S]  # start a browser on the page
#   fmrb_web.rb down                            # close it again
#   fmrb_web.rb status                          # running? frame? /home store?
#   fmrb_web.rb screenshot [OUT.png]            # the framebuffer, not the page
#   fmrb_web.rb move X Y | click X Y [--button N] | down X Y | up X Y
#   fmrb_web.rb key NAME                        # a-z 0-9 enter esc tab space f1..
#   fmrb_web.rb key ctrl+s | shift+NAME | alt+NAME
#   fmrb_web.rb text "STRING"
#   fmrb_web.rb sleep MS
#   fmrb_web.rb ls PATH | cat PATH | get PATH LOCAL | put LOCAL PATH | rm PATH
#   fmrb_web.rb reload                          # reload the page (boots again)
#
# Commands chain left to right, like fmrb_input.rb:
#   fmrb_web.rb click 30 8 sleep 500 key enter sleep 1000 screenshot out.png
#
# Options: --port N (default 8006), --host H (default localhost),
#          --layout us|jp (default: keyboard_layout from system_conf_wasm.toml),
#          --timeout S (how long one command may wait for the page, default 25;
#                       raise it while the machine is still booting)

require "base64"
require "json"
require "net/http"
require "uri"

WEB_HERE = File.dirname(File.expand_path(__FILE__))
require_relative "fmrb_input"     # keymap tables; its main() does not run

ROOT = File.join(WEB_HERE, "..")
CORE = File.join(ROOT, "fmruby-core")
WASM_CONF = File.join(CORE, "config", "system_conf_wasm.toml")
STATE = File.join(CORE, "wasm", "build", "drive_browser.pid")

# The ring's event types (wasm/backend/input_wasm.c) and the firmware's
# modifier bits (main/drivers/usb/fmrb_keymap.h).
RING_KEY_DOWN = 1
RING_KEY_UP = 2
RING_MOUSE_BUTTON = 3
RING_MOUSE_MOVE = 4
MOD_SHIFT = 0x01
MOD_CTRL = 0x04
MOD_ALT = 0x10

KEY_GAP_MS = 40      # between press and release
CLICK_GAP_MS = 60    # between motion, press and release

$port = 8006
$host = "localhost"
# How long one command may wait for the page. The default is generous
# already; right after a boot or a reload the page's own thread is busy
# carrying the machine up and answers late, which is what --timeout is for.
$timeout = 25

def wasm_layout
  return "us" unless File.exist?(WASM_CONF)
  File.foreach(WASM_CONF) do |line|
    m = /^\s*keyboard_layout\s*=\s*"([a-z]+)"/.match(line)
    return m[1] if m
  end
  "us"
end

# [scancode, modifier] for a key name, with stackable shift+ ctrl+ alt+.
# SPECIAL_KEYS and char_key come from fmrb_input.rb; its scancodes are HID
# usage IDs, which is exactly what the ring wants.
def web_key(name)
  mod = 0
  loop do
    if name.start_with?("shift+") then mod |= MOD_SHIFT; name = name[6..]
    elsif name.start_with?("ctrl+") then mod |= MOD_CTRL; name = name[5..]
    elsif name.start_with?("alt+") then mod |= MOD_ALT; name = name[4..]
    else break
    end
  end
  name = name.downcase
  if SPECIAL_KEYS.key?(name)
    return [SPECIAL_KEYS[name][0], mod]
  end
  if name.length == 1
    sc, shift = char_key(name)
    return [sc, mod | (shift ? MOD_SHIFT : 0)] if sc
  end
  abort "unknown key: #{name}"
end

# Post one command and wait for the page to answer it. With soft: true a
# page that is not there (or is still booting) gives nil instead of ending
# the run -- which is how the waiting loops poll.
def request(cmd, timeout: $timeout, soft: false)
  uri = URI("http://#{$host}:#{$port}/wasm/web/drive/cmd")
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = timeout + 10
  post = Net::HTTP::Post.new(uri)
  post["Content-Type"] = "application/json"
  post.body = JSON.dump(cmd.merge("timeout" => timeout))
  begin
    res = http.request(post)
  rescue Errno::ECONNREFUSED
    return nil if soft
    abort "no development server on port #{$port} (rake wasm:serve PORT=#{$port})"
  rescue Net::ReadTimeout
    return nil if soft
    abort "the page did not answer within #{timeout}s"
  end
  body = JSON.parse(res.body) rescue {}
  if res.code != "200"
    return nil if soft
    abort "the page did not answer -- is it open with ?drive=1 ? " \
          "(#{body["error"] || res.code})"
  end
  abort "page: #{body["error"]}" if body["error"]
  body["result"] || {}
end

def send_events(events)
  return if events.empty?
  request({ "op" => "input", "events" => events })
end

# Turn the command line into ring events, one flush per command group so a
# `sleep` between two clicks really waits on the page's side.
def run_commands(argv)
  events = []
  sent = 0
  flush = lambda do
    sent += events.length
    send_events(events)
    events = []
  end
  i = 0
  while i < argv.length
    case (word = argv[i])
    when "move"
      x, y = argv[i + 1].to_i, argv[i + 2].to_i
      events << [RING_MOUSE_MOVE, x, y, 0, 0, 0]
      i += 3
    when "click", "down", "up"
      x, y = argv[i + 1].to_i, argv[i + 2].to_i
      button = 1
      if argv[i + 3] == "--button"
        button = argv[i + 4].to_i
        i += 2
      end
      events << [RING_MOUSE_MOVE, x, y, 0, 0, 0]
      if word != "up"
        events << [RING_MOUSE_BUTTON, x, y, button, 1, CLICK_GAP_MS]
      end
      if word != "down"
        events << [RING_MOUSE_BUTTON, x, y, button, 0, CLICK_GAP_MS]
      end
      i += 3
    when "key"
      sc, mod = web_key(argv[i + 1])
      events << [RING_KEY_DOWN, sc, mod, 0, 0, 0]
      events << [RING_KEY_UP, sc, mod, 0, 0, KEY_GAP_MS]
      i += 2
    when "text"
      argv[i + 1].each_char do |ch|
        if ch == "\n"
          sc, mod = web_key("enter")
        else
          sc, shift = char_key(ch)
          unless sc
            warn "skipping character with no key: #{ch.inspect}"
            next
          end
          mod = shift ? MOD_SHIFT : 0
        end
        events << [RING_KEY_DOWN, sc, mod, 0, 0, 0]
        events << [RING_KEY_UP, sc, mod, 0, 0, KEY_GAP_MS]
      end
      i += 2
    when "sleep"
      ms = argv[i + 1].to_i
      flush.call
      sleep(ms / 1000.0)
      i += 2
    when "screenshot"
      flush.call
      out = argv[i + 1] && !argv[i + 1].start_with?("-") &&
            !%w[move click down up key text sleep screenshot ls cat get put rm
                reload status].include?(argv[i + 1]) ? argv[i + 1] : nil
      shot(out)
      i += out ? 2 : 1
    when "status"
      flush.call
      st = request({ "op" => "status" })
      puts "running=#{st["running"]} #{st["width"]}x#{st["height"]} " \
           "frame=#{st["frame"]} home=#{st["home"]} durable=#{st["durable"].inspect}"
      i += 1
    when "ls"
      flush.call
      entries = request({ "op" => "fs", "action" => "ls", "path" => argv[i + 1] })["entries"]
      entries.each { |e| puts format("%-30s %s", e["name"] + (e["dir"] ? "/" : ""), e["dir"] ? "" : e["size"]) }
      i += 2
    when "cat"
      flush.call
      data = Base64.decode64(request({ "op" => "fs", "action" => "cat", "path" => argv[i + 1] })["base64"])
      $stdout.write(data)
      i += 2
    when "get"
      flush.call
      data = Base64.decode64(request({ "op" => "fs", "action" => "cat", "path" => argv[i + 1] })["base64"])
      File.binwrite(argv[i + 2], data)
      puts "wrote #{argv[i + 2]} (#{data.bytesize} bytes)"
      i += 3
    when "put"
      flush.call
      data = File.binread(argv[i + 1])
      request({ "op" => "fs", "action" => "put", "path" => argv[i + 2],
                "base64" => Base64.strict_encode64(data) })
      puts "put #{data.bytesize} bytes -> #{argv[i + 2]}"
      i += 3
    when "rm"
      flush.call
      request({ "op" => "fs", "action" => "rm", "path" => argv[i + 1] })
      i += 2
    when "reload"
      flush.call
      request({ "op" => "reload" })
      puts "reloading; waiting for the machine to come back"
      wait_running
      i += 1
    else
      abort "unknown command: #{word}"
    end
  end
  flush.call
  puts "injected #{sent} event(s)" if sent > 0
end

def shot(path)
  res = request({ "op" => "screenshot" })
  png = Base64.decode64(res["png"])
  path ||= File.join(CORE, "wasm", "build", "screen.png")
  File.binwrite(path, png)
  puts "#{path} (#{res["width"]}x#{res["height"]}, #{png.bytesize} bytes)"
end

def wait_running(seconds = 60)
  deadline = Time.now + seconds
  loop do
    st = request({ "op" => "status" }, timeout: 5, soft: true)
    return true if st && st["running"] && st["frame"].to_i > 0
    abort "the machine did not come up within #{seconds}s" if Time.now > deadline
    sleep 1
  end
end

# ---- the browser itself ---------------------------------------------------

# Chrome on this machine is the Windows one (WSL); a Linux chrome/chromium is
# used when there is one. Windows Chrome reaches the development server
# through localhost, which WSL forwards.
def chrome_binary
  ENV["FMRB_CHROME"] ||
    ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
     "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe",
     "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"]
      .find { |p| File.exist?(p) } ||
    abort("no chrome found; set FMRB_CHROME")
end

def browser_up(headless, extra_args)
  bin = chrome_binary
  windows = bin.start_with?("/mnt/c/")
  profile_dir = windows ? 'C:\\Users\\Public\\fmrb_drive' :
                          File.join(CORE, "wasm", "build", "drive_profile")
  url = "http://#{$host}:#{$port}/wasm/web/index.html?autostart=1&drive=1" +
        (extra_args ? "&" + extra_args : "")
  args = [bin, "--user-data-dir=#{profile_dir}", "--no-first-run",
          "--no-default-browser-check", "--disable-gpu"]
  args << "--headless=new" if headless
  args << url
  pid = Process.spawn(*args, out: "/dev/null", err: "/dev/null")
  Process.detach(pid)
  File.write(STATE, "#{pid}\n#{windows ? "windows" : "linux"}\n")
  puts "browser started (pid #{pid}), waiting for the machine"
  wait_running
  puts "ready"
end

def browser_down
  unless File.exist?(STATE)
    puts "no browser started by this tool"
    return
  end
  pid, kind = File.read(STATE).split("\n")
  begin
    Process.kill("TERM", pid.to_i)
  rescue Errno::ESRCH
    # already gone
  end
  if kind == "windows"
    # Killing the WSL side does not always reach the Windows process; match it
    # by the profile directory, which is ours alone, so the user's own Chrome
    # is never touched.
    system("powershell.exe", "-NoProfile", "-Command",
           "Get-CimInstance Win32_Process -Filter \"name='chrome.exe'\" | " \
           "Where-Object { $_.CommandLine -like '*fmrb_drive*' } | " \
           "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
           out: "/dev/null", err: "/dev/null")
  end
  File.delete(STATE)
  puts "browser stopped"
end

def main
  argv = ARGV.dup
  if argv.empty? || ["-h", "--help"].include?(argv[0])
    puts File.read(File.expand_path(__FILE__))[/\A(#!.*\n)?((?:#.*\n)+)/, 2].gsub(/^# ?/, "")
    return 0
  end
  layout = nil
  if (at = argv.index("--port")) then $port = argv[at + 1].to_i; argv.slice!(at, 2) end
  if (at = argv.index("--host")) then $host = argv[at + 1]; argv.slice!(at, 2) end
  if (at = argv.index("--layout")) then layout = argv[at + 1]; argv.slice!(at, 2) end
  if (at = argv.index("--timeout")) then $timeout = argv[at + 1].to_i; argv.slice!(at, 2) end
  headless = !!argv.delete("--headless")
  url_args = nil
  if (at = argv.index("--url-args")) then url_args = argv[at + 1]; argv.slice!(at, 2) end

  # fmrb_input.rb loaded the sim's layout; the browser has its own.
  $layout = layout || wasm_layout
  $char_keys = load_keymap($layout)

  case argv[0]
  when "up"   then browser_up(headless, url_args)
  when "down" then browser_down
  else run_commands(argv)
  end
  0
end

exit(main) if __FILE__ == $PROGRAM_NAME
