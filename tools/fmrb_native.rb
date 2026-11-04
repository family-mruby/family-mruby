#!/usr/bin/env ruby
# Drive the native Linux program (fmruby-core/native/, doc/linux_native/) the
# way the sim tools drive the simulation: start it, look at it, type into it,
# launch apps, stop it.
#
# Usage:
#   fmrb_native.rb up [--gui] [--engine mruby] [--machine NAME|PATH]
#                     [--set KEY=VALUE]... [--alsa-file] [--scale N]
#                     [--user-dir DIR] [--cache-dir DIR] [--timeout SEC]
#                     [--debug-port N]
#                                   start it and wait for "Boot complete".
#                                   Headless by default (SDL_VIDEODRIVER=dummy,
#                                   SDL_AUDIODRIVER=disk into <run>/audio.raw);
#                                   --gui opens the window (WSLg) instead.
#                                   --machine picks the machine definition
#                                   (sdl, cardputer_zero_hdmi, ... in
#                                   fmruby-core/config/machines/, or a file);
#                                   a machine this system cannot run is
#                                   refused, and the reason is printed.
#                                   --set changes one field of it.
#                                   --debug-port moves its debug server off
#                                   5565 (a second program beside the first:
#                                   give it a --run-dir and a --user-dir of
#                                   its own too); the run directory remembers
#                                   it for the other commands.
#                                   --alsa-file plays through ALSA instead,
#                                   into alsa-lib's file plugin (an
#                                   asoundrc of its own, ALSA_CONFIG_PATH):
#                                   the samples land in <run>/audio.raw too.
#   fmrb_native.rb down             ask it to quit (SIGTERM if it does not)
#   fmrb_native.rb shot [OUT.png]   the composited frame as a PNG at its own
#                                   size (426x240, 640x360 in the high-res mode)
#   fmrb_native.rb input CMD...     tools/fmrb_input.rb's commands, sent to this
#                                   program's inject socket, with the keyboard
#                                   layout of the user's /etc/system_conf.toml
#   fmrb_native.rb app ps | spawn PATH | kill PID
#                                   through the debug server (port 5565, or
#                                   the one up was given)
#   fmrb_native.rb app checkpoint PID [--restart] [--hold MS] [--max MS]
#                                   write app PID to a checkpoint image and
#                                   close it (doc/checkpoint); --restart starts
#                                   the image again at once. Waits for the
#                                   app's answer (MS, default 5000) and prints
#                                   {status: written, path} | {status: refused,
#                                   reason} | {status: timeout}. Only an app on
#                                   mruby whose .app.toml says movable = true
#                                   is written; another is refused and goes on.
#                                   --hold MS: written but not closed: held
#                                   where it stopped ({status: held, path,
#                                   size}) until app finish, or MS run out
#                                   (then it goes on by itself)
#   fmrb_native.rb app finish PID close|continue [REASON]
#                                   close a held app, or let it go on
#   fmrb_native.rb app restore PATH start an app from its image (a .ckpt,
#                                   /tmp/<name>.ckpt inside the program: its
#                                   /tmp is the program's own, not the PC's);
#                                   answers once it is restored: {status:
#                                   restored, pid[, missing]} | {status:
#                                   refused, reason}. missing: the methods the
#                                   program calls that this build has none of
#                                   (it goes on; only the names its .app.toml
#                                   requires are refused)
#   fmrb_native.rb app move PID --to RUN_DIR|PORT [--hold MS] [--damage]
#                                   move app PID into the program of RUN_DIR
#                                   (another native program, started with
#                                   --run-dir and --debug-port), or into the
#                                   one whose debug server is on PORT here
#                                   (the Linux simulation: 5555). The app
#                                   moves out of the simulation the same way
#                                   with FMRB_DEBUG_TCP_PORT=5555: written and
#                                   held here, the image (and its .toml) is
#                                   carried there in pieces, started there,
#                                   and closed here once it is up there, or
#                                   let go on here when it was refused there
#                                   or nobody answered (MS, default 10000).
#                                   Prints {status: moved, pid (there), ...,
#                                   missing (there, when any)} or {status:
#                                   stayed, reason, ...}.
#                                   --damage cuts the image short on the way
#                                   (for the regression check: refused there)
#   fmrb_native.rb app move PID --node NODE [--hold MS] [--max MS]
#                                   move app PID to the machine whose Asterism
#                                   node ID is NODE (doc/checkpoint F5): this
#                                   program's kernel asks that machine first
#                                   (the methods the app calls; refused
#                                   before anything stops when a name its
#                                   .app.toml requires is missing there), has
#                                   the app write its image and hold, has the
#                                   transfer app carry it over Asterism, and
#                                   closes it here once it is up there (or
#                                   lets it go on). That machine takes it only
#                                   from the nodes in its
#                                   /home/asterism/receive.toml. Prints
#                                   {status: moved, pid (there), detail,
#                                   missing?, took_ms} | {status: stayed,
#                                   reason, here} | {status: timeout}
#   fmrb_native.rb file get PATH OUT | put SRC PATH
#                                   a file under the program's /tmp/ out to
#                                   the PC, or in from it (in pieces, through
#                                   the debug server)
#   fmrb_native.rb audio [SEC]      peak / RMS / non-zero samples of the last SEC
#                                   seconds (default 2) of the disk audio output
#   fmrb_native.rb log [N]          the last N lines (default 40) of its log
#   fmrb_native.rb status           running or not, machine, frame size, pid
#   fmrb_native.rb stats [reset]    the blocking-call gate's counters (calls,
#                                   jobs in flight, helper threads, cancels)
#                                   and burst_ms, the longest time one task
#                                   kept all others waiting; reset starts
#                                   that maximum over
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
AUDIO_RATE = 15_720
DEFAULT_DEBUG_PORT = 5565
# A move holds the app this long by default while its image is carried.
MOVE_HOLD_MS = 10_000
# Bytes of a file per debug request (a frame is 4 KB with its header).
PIECE = 3072

require_relative "fmrb_msgpack"

def usage
  puts File.read(__FILE__)[/\A(#!.*\n)?((?:#.*\n)+)/, 2].gsub(/^# ?/, "")
end

def run_dir
  $run_dir ||= (ENV["FMRB_NATIVE_RUN_DIR"].to_s.empty? ? "/tmp/fmrb-native-#{Process.uid}" : ENV["FMRB_NATIVE_RUN_DIR"])
end

def path(name) = File.join(run_dir, name)

# The debug port of the program of a run directory: FMRB_DEBUG_TCP_PORT, else
# the one `up` was given (remembered there), else 5565.
def debug_port(dir = run_dir)
  return ENV["FMRB_DEBUG_TCP_PORT"].to_i if dir == run_dir && !ENV["FMRB_DEBUG_TCP_PORT"].to_s.empty?
  Integer(File.read(File.join(dir, "debug_port")).strip)
rescue Errno::ENOENT, ArgumentError
  DEFAULT_DEBUG_PORT
end

# The debug server's protocol (doc/remote_debug/vm_remote_debug_protocol.md):
# frames of a u32 length and a msgpack body; a request is [0, seq, cmd,
# payload], its response [1, seq, err, payload]. One connection for many
# requests (a file in pieces), which the Python client's command line is not.
class DebugLink
  class Error < StandardError; end

  def initialize(port, timeout: 5)
    @port = port
    @timeout = timeout
    @seq = 0
    @sock = Socket.tcp("127.0.0.1", port, connect_timeout: timeout)
    @buf = +"".b
    request("version")   # the daemon answers before anything real is sent
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError => e
    raise Error, "no debug server on port #{port} (#{e.class.name.split('::').last}); is the program up?"
  end

  def close = @sock.close

  # The payload of the answer; raises with the error code when err != 0.
  def request(cmd, payload = nil, timeout: @timeout)
    @seq = (@seq + 1) & 0xFFFF
    body = FmrbMsgpack.pack([0, @seq, cmd, payload])
    @sock.write([body.bytesize].pack("N") + body)
    deadline = Time.now + timeout
    loop do
      msg = read_frame(deadline) or raise Error, "#{cmd}: no answer from port #{@port} in #{timeout}s"
      next unless msg.is_a?(Array) && msg[0] == 1 && msg[1] == @seq
      raise Error, "#{cmd}: error #{msg[2]}" unless msg[2].zero?
      return msg[3]
    end
  end

  private

  def read_frame(deadline)
    loop do
      if @buf.bytesize >= 4
        n = @buf.unpack1("N")
        if @buf.bytesize >= 4 + n
          body = @buf.byteslice(4, n)
          @buf = @buf.byteslice(4 + n..)
          return FmrbMsgpack.unpack(body)
        end
      end
      left = deadline - Time.now
      return nil if left <= 0
      next unless IO.select([@sock], nil, nil, left)
      chunk = @sock.read_nonblock(65_536, exception: false)
      raise Error, "the debug server on port #{@port} closed the connection" if chunk.nil?
      @buf << chunk.b unless chunk == :wait_readable
    end
  end
end

def with_debug(port)
  link = DebugLink.new(port)
  yield link
ensure
  link&.close
end

# A file under the program's /tmp/, in pieces.
def file_get(link, file)
  data = +"".b
  size = nil
  loop do
    r = link.request("file_get", { "path" => file, "pos" => data.bytesize })
    size ||= r["size"]
    data << r["data"].to_s.b
    break if data.bytesize >= size || r["data"].to_s.empty?
  end
  raise DebugLink::Error, "#{file}: #{data.bytesize} of #{size} bytes" if data.bytesize != size
  data
end

def file_put(link, file, data)
  id = link.request("file_begin", { "path" => file, "size" => data.bytesize })["id"]
  pos = 0
  while pos < data.bytesize
    piece = data.byteslice(pos, PIECE)
    link.request("file_chunk", { "id" => id, "pos" => pos, "data" => piece })
    pos += piece.bytesize
  end
  link.request("file_commit", { "id" => id })
end

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

# alsa-lib's configuration for --alsa-file: the default PCM is the file
# plugin over the null device, writing raw S16 (what the program opens:
# 15720 Hz mono), so `audio` reads it like the SDL disk output.
def alsa_file_conf(out)
  <<~CONF
    # written by tools/fmrb_native.rb up --alsa-file
    pcm.!default {
      type file
      slave.pcm "fmrb_null"
      file "#{out}"
      format "raw"
    }
    pcm.fmrb_null {
      type null
    }
  CONF
end

def cmd_up(args)
  gui = false
  engine = "standard"
  extra = []
  timeout = 60
  user_dir = nil
  alsa_file = false
  port = nil
  until args.empty?
    a = args.shift
    case a
    when "--gui" then gui = true
    when "--engine" then engine = args.shift
    when "--machine" then extra += ["--machine", args.shift]
    when "--set" then extra += ["--set", args.shift]
    when "--alsa-file" then alsa_file = true
    when "--scale" then extra += ["--scale", args.shift]
    when "--user-dir" then user_dir = File.expand_path(args.shift); extra += ["--user-dir", user_dir]
    when "--cache-dir" then extra += ["--cache-dir", File.expand_path(args.shift)]
    when "--timeout" then timeout = args.shift.to_i
    when "--debug-port" then port = Integer(args.shift)
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
  port ||= ENV["FMRB_DEBUG_TCP_PORT"].to_s.empty? ? DEFAULT_DEBUG_PORT : ENV["FMRB_DEBUG_TCP_PORT"].to_i
  env["FMRB_DEBUG_TCP_PORT"] = port.to_s
  # Remembered for the other commands (app, file, a move into this one).
  File.write(path("debug_port"), "#{port}\n")
  unless gui
    env["SDL_VIDEODRIVER"] = "dummy"
    env["SDL_AUDIODRIVER"] = "disk"
    env["SDL_DISKAUDIOFILE"] = path("audio.raw")
  end
  if alsa_file
    FileUtils.rm_f(path("audio.raw"))
    File.write(path("asound.conf"), alsa_file_conf(path("audio.raw")))
    env["ALSA_CONFIG_PATH"] = path("asound.conf")
    extra += ["--set", "audio.backend=alsa", "--set", "audio.device=default"]
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
    unless alive?(child)
      refusal = File.exist?(log) ? File.readlines(log).grep(/native: refused:/).last : nil
      abort "fmrb_native: #{refusal.strip.sub(/\Anative: /, '')}" if refusal
      abort "fmrb_native: exited during boot; see #{log}\n#{tail(log, 20)}"
    end
    if File.exist?(log) && File.read(log).include?("Boot complete")
      booted = true
      break
    end
    sleep 0.2
  end
  abort "fmrb_native: no \"Boot complete\" within #{timeout}s; see #{log}" unless booted
  machine = File.read(log)[/native: machine (\S+)/, 1] || "?"
  printf("up: pid %d, boot complete in %.1f s (machine %s, %s, %s%s)\n", child, Time.now - started,
         machine, engine, gui ? "window" : "headless", alsa_file ? ", ALSA into the file plugin" : "")
  puts "  user dir: #{user_dir || user_dir_default}"
  puts "  debug port: #{port}" if port != DEFAULT_DEBUG_PORT
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
    when "checkpoint"
      checkpoint_kv(args)
    when "restore"
      p = args.shift or abort "app restore: needs an image (e.g. /tmp/ckpt_counter.ckpt)"
      abort "app restore: #{p} is not a checkpoint image (.ckpt)" unless p.end_with?(".ckpt")
      return debug_json { |l| l.request("restore", { "path" => p, "max" => 8000 }, timeout: 12) }
    when "finish"
      p = Integer(args.shift || "", exception: false) or abort "app finish: needs a pid"
      how = args.shift
      abort "app finish: close or continue" unless %w[close continue].include?(how)
      payload = { "pid" => p, "close" => how == "close", "reason" => args.join(" "), "max" => 5000 }
      return debug_json { |l| l.request("checkpoint_finish", payload, timeout: 10) }
    when "move" then return cmd_move(args)
    else abort "app: ps | spawn PATH | kill PID | checkpoint PID [--restart] [--hold MS] [--max MS] | " \
               "finish PID close|continue | restore PATH | move PID --to RUN_DIR|PORT"
    end
  out, status = Open3.capture2e("python3", DBG_CLIENT, "--json", "localhost:#{debug_port}", *kv)
  abort "app #{action}: #{out.strip}" unless status.success?
  puts out.lines.last.to_s.strip
end

# app checkpoint PID [--restart] [--hold MS] [--max MS] -> the debug server's checkpoint
def checkpoint_kv(args)
  pid = nil
  restart = false
  max = nil
  hold = nil
  while (a = args.shift)
    case a
    when "--restart" then restart = true
    when "--max" then max = Integer(args.shift || abort("app checkpoint: --max needs milliseconds"))
    when "--hold" then hold = Integer(args.shift || abort("app checkpoint: --hold needs milliseconds"))
    else pid = Integer(a, exception: false) or abort "app checkpoint: #{a}: not a pid"
    end
  end
  abort "app checkpoint: needs a pid (see app ps)" unless pid
  kv = ["checkpoint", "pid=#{pid}", "restart=#{restart ? 1 : 0}"]
  kv << "max=#{max}" if max
  kv << "hold=#{hold}" if hold
  kv
end

# One request on this program's debug server, printed as JSON.
def debug_json
  r = with_debug(debug_port) { |l| yield l }
  puts JSON.generate(r)
rescue DebugLink::Error => e
  abort "fmrb_native: #{e.message}"
end

def ms_since(t) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round

# app move PID --to RUN_DIR: the steps of a move (doc/checkpoint F2, D15).
# This program's kernel has the app write its image and hold where it
# stopped; the image and the .toml beside it go to the other program in
# pieces (file_begin / file_chunk / file_commit); the other program's kernel
# starts the image and answers once it is restored; this kernel then closes
# the app, or lets it go on when the other side refused or did not answer.
def cmd_move(args)
  return cmd_move_node(args) if args.include?("--node")
  pid = nil
  to = nil
  hold = MOVE_HOLD_MS
  damage = false
  while (a = args.shift)
    case a
    when "--to"
      t = args.shift || abort("app move: --to needs a run directory or a port")
      # A bare number is a debug port on this machine: the simulation's 5555,
      # or any program that is not a native one started with a run directory.
      to = t.match?(/\A\d+\z/) ? Integer(t) : File.expand_path(t)
    when "--hold" then hold = Integer(args.shift || abort("app move: --hold needs milliseconds"))
    when "--damage" then damage = true
    else pid = Integer(a, exception: false) or abort "app move: #{a}: not a pid"
    end
  end
  abort "app move: needs a pid and --to RUN_DIR|PORT" unless pid && to
  abort "app move: #{to} is this program's run directory" if to == File.expand_path(run_dir)
  to_port = to.is_a?(Integer) ? to : debug_port(to)
  abort "app move: port #{to_port} is this program's own" if to_port == debug_port
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out = { "from_pid" => pid }
  begin
    a = DebugLink.new(debug_port)
  rescue DebugLink::Error => e
    abort "fmrb_native: #{e.message}"
  end
  begin
    held = a.request("checkpoint", { "pid" => pid, "hold" => hold, "max" => 8000 }, timeout: 12)
    unless held["status"] == "held"
      # Never held: refused, or no answer in time (were it held later, its
      # kernel lets it go on once the hold runs out).
      puts JSON.generate(out.merge("status" => "stayed", "reason" => held["reason"] || held["status"]))
      return
    end
    image = held["path"]
    out["image"] = image
    out["held_ms"] = ms_since(t0)
    toml = image.sub(/\.ckpt\z/, ".toml")
    there = nil
    verdict = begin
      data = file_get(a, image)
      attrs = file_get(a, toml)
      out["bytes"] = data.bytesize
      data = data.byteslice(0, data.bytesize - 16) if damage
      b = DebugLink.new(to_port)
      begin
        file_put(b, toml, attrs)
        file_put(b, image, data)
        out["carried_ms"] = ms_since(t0)
        r = b.request("restore", { "path" => image, "max" => 8000 }, timeout: 12)
        there = r["pid"] if r["status"] == "restored"
        r
      ensure
        b.close
      end
    rescue DebugLink::Error => e
      { "status" => "refused", "reason" => e.message }
    end
    reason = verdict["reason"] || verdict["status"]
    fin = a.request("checkpoint_finish", { "pid" => pid, "close" => !there.nil?, "reason" => there ? "" : "not taken there: #{reason}",
                                           "max" => 5000 }, timeout: 10)
    out["done_ms"] = ms_since(t0)
    out["missing"] = verdict["missing"] if there && verdict["missing"]
    if there && fin["status"] == "closed"
      puts JSON.generate(out.merge("status" => "moved", "pid" => there))
    elsif there
      # Up there but this one went on (its hold ran out first): two copies;
      # the one there is stopped.
      with_debug(to_port) { |b| b.request("kill", { "pid" => there }, timeout: 10) } rescue nil # rubocop:disable Style/RescueModifier
      puts JSON.generate(out.merge("status" => "stayed", "reason" => "it went on here before it was up there " \
                                   "(#{fin['reason'] || fin['status']}); the copy there was stopped"))
    else
      puts JSON.generate(out.merge("status" => "stayed", "reason" => reason, "here" => fin["status"]))
    end
  rescue DebugLink::Error => e
    abort "fmrb_native: app move: #{e.message}"
  ensure
    a.close
  end
end

# app move PID --node NODE: a move over Asterism (doc/checkpoint F5). The
# program's kernel holds every step; the debug server's "move" waits for the
# outcome, read from the app's answer ("moved to NODE as PID n; it lacks:
# ..." or why it stayed).
def cmd_move_node(args)
  pid = nil
  node = nil
  hold = nil
  max = 40_000
  while (a = args.shift)
    case a
    when "--node" then node = args.shift || abort("app move: --node needs the Asterism node ID of the other machine")
    when "--hold" then hold = Integer(args.shift || abort("app move: --hold needs milliseconds"))
    when "--max" then max = Integer(args.shift || abort("app move: --max needs milliseconds"))
    else pid = Integer(a, exception: false) or abort "app move: #{a}: not a pid"
    end
  end
  abort "app move: needs a pid and --node NODE" unless pid && node
  req = { "pid" => pid, "to" => node, "max" => max }
  req["hold"] = hold if hold
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = with_debug(debug_port) { |link| link.request("move", req, timeout: max / 1000 + 5) }
  out = { "from_pid" => pid, "to" => node }.merge(r)
  if r["status"] == "moved"
    detail = r["detail"].to_s
    out["pid"] = detail[/as PID (\d+)/, 1].to_i
    lacks = detail[/it lacks: (.*)\z/, 1]
    out["missing"] = lacks.split(" ") if lacks
  end
  out["took_ms"] = ms_since(t0)
  puts JSON.generate(out)
rescue DebugLink::Error => e
  abort "fmrb_native: app move: #{e.message}"
end

# file get PATH OUT | put SRC PATH: a file under the program's /tmp/.
def cmd_file(args)
  what = args.shift
  case what
  when "get"
    src, out = args
    abort "file get: PATH OUT" unless src && out
    data = with_debug(debug_port) { |l| file_get(l, src) }
    File.binwrite(out, data)
    puts "file get: #{src} -> #{out} (#{data.bytesize} bytes)"
  when "put"
    src, dest = args
    abort "file put: SRC PATH" unless src && dest
    data = File.binread(src)
    with_debug(debug_port) { |l| file_put(l, dest, data) }
    puts "file put: #{src} -> #{dest} (#{data.bytesize} bytes)"
  else abort "file: get PATH OUT | put SRC PATH"
  end
rescue DebugLink::Error => e
  abort "fmrb_native: #{e.message}"
end

def cmd_audio(args)
  secs = (args.shift || 2).to_f
  file = path("audio.raw")
  abort "audio: no #{file} (headless runs and --alsa-file write it)" unless File.exist?(file)
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
  m = /\AOK (\d+) (\d+) (\d+) (\d+) (\S+)\z/.match(head)
  if m
    puts "status: running, pid #{m[4]}, machine #{m[5]}, frame #{m[1]}x#{m[2]} (seq #{m[3]})"
  else
    puts "status: running, pid #{p} (#{head})"
  end
end

def cmd_stats(args)
  head, = ctl(args.first == "reset" ? "stats reset" : "stats")
  abort "fmrb_native: #{head}" unless head.start_with?("OK ")
  puts head.sub(/\AOK /, "")
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
  when "file" then cmd_file(args)
  when "audio" then cmd_audio(args)
  when "log" then cmd_log(args)
  when "status" then cmd_status
  when "stats" then cmd_stats(args)
  when nil, "-h", "--help" then usage
  else abort "unknown command: #{cmd} (see --help)"
  end
end

main if __FILE__ == $PROGRAM_NAME
