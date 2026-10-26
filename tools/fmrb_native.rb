#!/usr/bin/env ruby
# Drive the native Linux program (fmruby-core/native/, doc/linux_native/) the
# way the sim tools drive the simulation: start it, look at it, type into it,
# launch apps, stop it.
#
# Usage:
#   fmrb_native.rb up [--gui] [--engine mruby] [--scale N]
#                     [--user-dir DIR] [--cache-dir DIR] [--timeout SEC]
#                                   start it and wait for "Boot complete".
#                                   Headless by default (SDL_VIDEODRIVER=dummy,
#                                   SDL_AUDIODRIVER=disk into <run>/audio.raw);
#                                   --gui opens the window (WSLg) instead.
#   fmrb_native.rb down             ask it to quit (SIGTERM if it does not)
#   fmrb_native.rb shot [OUT.png]   the composited frame as a PNG at its own
#                                   size (426x240, 640x360 in the high-res mode)
#   fmrb_native.rb input CMD...     tools/fmrb_input.rb's commands, sent to this
#                                   program's inject socket, with the keyboard
#                                   layout of the user's /etc/system_conf.toml
#   fmrb_native.rb app ps | spawn PATH | kill PID
#                                   through the debug server (port 5565)
#   fmrb_native.rb audio [SEC]      peak / RMS / non-zero samples of the last SEC
#                                   seconds (default 2) of the disk audio output
#   fmrb_native.rb log [N]          the last N lines (default 40) of its log
#   fmrb_native.rb status           running or not, frame size, pid
#
# The run directory (sockets, pid, log, audio) is /tmp/fmrb-native-<uid>,
# or FMRB_NATIVE_RUN_DIR / --run-dir before the command. The program's own
# options and environment are documented in native/backend/main_native.c.

require "fileutils"
require "json"
require "open3"
require "socket"

HERE = File.dirname(File.expand_path(__FILE__))
CORE = File.expand_path(File.join(HERE, "..", "fmruby-core"))
DBG_CLIENT = File.join(CORE, "tool", "debug", "fmrb_dbg_client.py")
INPUT_TOOL = File.join(HERE, "fmrb_input.rb")
DEBUG_PORT = (ENV["FMRB_DEBUG_TCP_PORT"] || 5565).to_i
AUDIO_RATE = 15_720

def usage
  puts File.read(__FILE__)[/\A(#!.*\n)?((?:#.*\n)+)/, 2].gsub(/^# ?/, "")
end

def run_dir
  $run_dir ||= (ENV["FMRB_NATIVE_RUN_DIR"].to_s.empty? ? "/tmp/fmrb-native-#{Process.uid}" : ENV["FMRB_NATIVE_RUN_DIR"])
end

def path(name) = File.join(run_dir, name)

def pid
  Integer(File.read(path("pid")).strip)
rescue Errno::ENOENT, ArgumentError
  nil
end

def alive?(p)
  return false unless p
  Process.kill(0, p)
  true
rescue Errno::ESRCH, Errno::EPERM
  false
end

# One request on the control socket. Returns [header line, rest of the bytes].
def ctl(request, timeout: 10)
  sock = UNIXSocket.new(path("ctl"))
  sock.write("#{request}\n")
  data = +""
  deadline = Time.now + timeout
  loop do
    raise "control socket: no answer in #{timeout}s" if Time.now > deadline
    ready = IO.select([sock], nil, nil, 0.5)
    next unless ready
    chunk = sock.read_nonblock(65_536, exception: false)
    break if chunk.nil?
    next if chunk == :wait_readable
    data << chunk
  end
  sock.close
  head, body = data.split("\n", 2)
  [head.to_s, body.to_s.b]
rescue Errno::ENOENT, Errno::ECONNREFUSED
  abort "fmrb_native: not running (no control socket at #{path('ctl')})"
end

def user_dir_default
  base = ENV["XDG_DATA_HOME"].to_s.start_with?("/") ? ENV["XDG_DATA_HOME"] : File.join(Dir.home, ".local", "share")
  File.join(base, "family-mruby-dev")
end

def cmd_up(args)
  gui = false
  engine = "standard"
  extra = []
  timeout = 60
  user_dir = nil
  until args.empty?
    a = args.shift
    case a
    when "--gui" then gui = true
    when "--engine" then engine = args.shift
    when "--scale" then extra += ["--scale", args.shift]
    when "--user-dir" then user_dir = File.expand_path(args.shift); extra += ["--user-dir", user_dir]
    when "--cache-dir" then extra += ["--cache-dir", File.expand_path(args.shift)]
    when "--timeout" then timeout = args.shift.to_i
    else abort "up: unknown option #{a}"
    end
  end
  abort "up: --engine is standard or mruby" unless %w[standard mruby].include?(engine)
  bin = File.join(CORE, "native", engine == "mruby" ? "build-mruby" : "build", "fmruby-native")
  abort "#{bin} not found; run (in fmruby-core) rake native:core#{engine == 'mruby' ? ' NATIVE_ENGINE=mruby' : ''}" unless File.exist?(bin)
  abort "already running (pid #{pid}); fmrb_native.rb down first" if alive?(pid)

  FileUtils.mkdir_p(run_dir, mode: 0o700)
  log = path("core.log")
  env = { "FMRB_NATIVE_RUN_DIR" => run_dir }
  unless gui
    env["SDL_VIDEODRIVER"] = "dummy"
    env["SDL_AUDIODRIVER"] = "disk"
    env["SDL_DISKAUDIOFILE"] = path("audio.raw")
  end
  # Remembered for `input`, which reads the keyboard layout from that /etc.
  File.write(path("user_dir"), (user_dir || user_dir_default) + "\n")
  started = Time.now
  child = Process.spawn(env, bin, *extra, out: log, err: [:child, :out],
                        chdir: run_dir, pgroup: true)
  Process.detach(child)
  booted = false
  deadline = started + timeout
  while Time.now < deadline
    abort "fmrb_native: exited during boot; see #{log}\n#{tail(log, 20)}" unless alive?(child)
    if File.exist?(log) && File.read(log).include?("Boot complete")
      booted = true
      break
    end
    sleep 0.2
  end
  abort "fmrb_native: no \"Boot complete\" within #{timeout}s; see #{log}" unless booted
  printf("up: pid %d, boot complete in %.1f s (%s, %s)\n", child, Time.now - started,
         engine, gui ? "window" : "headless")
  puts "  user dir: #{user_dir || user_dir_default}"
  puts "  log: #{log}"
end

def cmd_down
  p = pid
  unless alive?(p)
    puts "down: not running"
    return
  end
  begin
    ctl("quit", timeout: 3)
  rescue StandardError
    # fall through to the signal
  end
  50.times do
    break unless alive?(p)
    sleep 0.1
  end
  if alive?(p)
    Process.kill("TERM", p)
    30.times do
      break unless alive?(p)
      sleep 0.1
    end
  end
  Process.kill("KILL", p) if alive?(p)
  puts "down: stopped pid #{p}"
end

def cmd_shot(args)
  out = args.shift || path("shot.png")
  head, body = ctl("shot")
  m = /\AOK (\d+) (\d+) (\d+)\z/.match(head) or abort "shot: #{head}"
  abort "shot: short PNG (#{body.bytesize}/#{m[1]} bytes)" if body.bytesize < m[1].to_i
  File.binwrite(out, body[0, m[1].to_i])
  puts "shot: #{out} (#{m[2]}x#{m[3]})"
end

def configured_layout
  dir = File.exist?(path("user_dir")) ? File.read(path("user_dir")).strip : user_dir_default
  conf = File.join(dir, "etc", "system_conf.toml")
  return nil unless File.exist?(conf)
  File.foreach(conf) do |line|
    m = /^\s*keyboard_layout\s*=\s*"([a-z]+)"/.match(line)
    return m[1] if m
  end
  nil
end

def cmd_input(args)
  abort "input: no commands" if args.empty?
  argv = ["ruby", INPUT_TOOL, "--socket", path("inject")]
  layout = configured_layout
  argv += ["--layout", layout] if layout && !args.include?("--layout")
  system(*argv, *args) or exit 1
end

def cmd_app(args)
  action = args.shift
  kv =
    case action
    when "ps" then ["ps"]
    when "spawn"
      p = args.shift or abort "app spawn: needs a path (e.g. /app/demo/kamon.app.rb)"
      ["spawn", "path=#{p}"]
    when "kill"
      p = args.shift or abort "app kill: needs a pid (see app ps)"
      ["kill", "pid=#{p.to_i}"]
    else abort "app: ps | spawn PATH | kill PID"
    end
  out, status = Open3.capture2e("python3", DBG_CLIENT, "--json", "localhost:#{DEBUG_PORT}", *kv)
  abort "app #{action}: #{out.strip}" unless status.success?
  puts out.lines.last.to_s.strip
end

def cmd_audio(args)
  secs = (args.shift || 2).to_f
  file = path("audio.raw")
  abort "audio: no #{file} (headless runs write it)" unless File.exist?(file)
  bytes = (secs * AUDIO_RATE).to_i * 2
  size = File.size(file)
  data = File.open(file, "rb") do |f|
    f.seek([size - bytes, 0].max)
    f.read
  end
  samples = data.unpack("s<*")
  abort "audio: empty" if samples.empty?
  peak = samples.map(&:abs).max
  rms = Math.sqrt(samples.sum { |v| v * v }.to_f / samples.length)
  nonzero = samples.count { |v| v != 0 }
  printf("audio: last %.1f s: %d samples, peak %d, rms %.1f, non-zero %d (file %d bytes)\n",
         samples.length.to_f / AUDIO_RATE, samples.length, peak, rms, nonzero, size)
end

def tail(file, n)
  return "" unless File.exist?(file)
  File.readlines(file).last(n).join
end

def cmd_log(args)
  print tail(path("core.log"), (args.shift || 40).to_i)
end

def cmd_status
  p = pid
  unless alive?(p)
    puts "status: not running"
    return
  end
  head, = ctl("info")
  m = /\AOK (\d+) (\d+) (\d+) (\d+)\z/.match(head)
  if m
    puts "status: running, pid #{m[4]}, frame #{m[1]}x#{m[2]} (seq #{m[3]})"
  else
    puts "status: running, pid #{p} (#{head})"
  end
end

def main
  args = ARGV.dup
  if (at = args.index("--run-dir"))
    $run_dir = File.expand_path(args[at + 1])
    args.slice!(at, 2)
  end
  cmd = args.shift
  case cmd
  when "up" then cmd_up(args)
  when "down" then cmd_down
  when "shot" then cmd_shot(args)
  when "input" then cmd_input(args)
  when "app" then cmd_app(args)
  when "audio" then cmd_audio(args)
  when "log" then cmd_log(args)
  when "status" then cmd_status
  when nil, "-h", "--help" then usage
  else abort "unknown command: #{cmd} (see --help)"
  end
end

main if __FILE__ == $PROGRAM_NAME
