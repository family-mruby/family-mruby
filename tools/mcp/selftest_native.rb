#!/usr/bin/env ruby
# frozen_string_literal: true

# The native-program half of the fmrb MCP selftest. Nothing here needs the
# program built: a fake repository whose fmrb_native.rb prints the argv it
# was given (and plays "running", "refused" and "screenshot" when asked)
# stands in for it, so the argument handling, the refusals and the state
# rules are checked without anything running behind them. Driving the real
# program is acceptance work (doc/linux_native/report/l2.md).
require "json"
require "tmpdir"
require "fileutils"
require "open3"

require_relative "lib/native"

SERVER = File.expand_path("fmrb_mcp_server.rb", __dir__)
$failures = 0

def check(label)
  ok, detail = yield
  if ok
    puts "  ok   #{label}"
  else
    $failures += 1
    puts "  FAIL #{label}#{detail ? " -- #{detail}" : ""}"
  end
rescue StandardError => e
  $failures += 1
  puts "  FAIL #{label} -- #{e.class}: #{e.message}"
end

# A repository whose fmrb_native.rb reports what it was called with. A file
# beside it says whether the "program" runs; machine "nosuch" is refused.
def fake_repo(dir)
  FileUtils.mkdir_p(File.join(dir, "tools"))
  File.write(File.join(dir, "tools", "fmrb_native.rb"), <<~RUBY)
    require 'json'
    flag = File.join(__dir__, 'running')
    args = ARGV.dup
    case args[0]
    when 'status'
      puts File.exist?(flag) ? 'status: running, pid 42, machine sdl, frame 426x240 (seq 9)' : 'status: not running'
    when 'up'
      if args.include?('nosuch')
        warn 'fmrb_native: refused: machine nosuch: display: no DRM device'
        exit 1
      end
      File.write(flag, '1')
      File.write(File.join(__dir__, 'last_up.json'), JSON.generate(args))
      puts 'up: pid 42, boot complete in 3.9 s (machine sdl, standard, headless)'
    when 'down'
      File.delete(flag) if File.exist?(flag)
      puts 'down: stopped pid 42'
    when 'shot'
      ihdr = [426, 240].pack('NN') + "\\x08\\x02\\x00\\x00\\x00".b
      File.binwrite(args[1], "\\x89PNG\\r\\n\\x1A\\n".b + [13].pack('N') + 'IHDR'.b + ihdr)
      puts "shot: \#{args[1]} (426x240)"
    when 'app'
      puts JSON.generate(args[1] == 'ps' ? { 'apps' => [] } : { 'argv' => args })
    else
      puts JSON.generate(args)
    end
  RUBY
  dir
end

Dir.mktmpdir("fmrb-mcp-native") do |dir|
  repo = fake_repo(File.join(dir, "repo"))
  state = File.join(dir, "state")
  native = FmrbMcp::Native.new(repo_root: repo, state_dir: state)

  puts "  the native-program tools (no program)"

  check("a refused machine comes back as the error, with the reason") do
    begin
      native.up(machine: "nosuch")
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("refused: machine nosuch") && e.message.include?("no DRM device"), e.message]
    end
  end

  check("up passes the machine, the fields and the ALSA file option, and returns a frame") do
    r = native.up(machine: "cardputer_zero_hdmi", set: ["display.rotate=90"], alsa_file: true)
    argv = JSON.parse(File.read(File.join(repo, "tools", "last_up.json")))
    want = ["up", "--machine", "cardputer_zero_hdmi", "--alsa-file", "--set", "display.rotate=90"]
    [argv == want && r[:size] == "426x240" && r[:data].to_s.length > 20, argv.inspect]
  end

  check("a program started here is ours") do
    st = JSON.parse(File.read(File.join(state, "native.json")))
    [st["started_by_us"] == true, st.inspect]
  end

  check("input keeps a quoted string in one piece") do
    r = native.input('click 30 5 text "hello world" key ctrl+s')
    [r[:sent] == ["click", "30", "5", "text", "hello world", "key", "ctrl+s"], r.inspect]
  end

  check("input refuses an empty command list") do
    begin
      native.input("  ")
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("no commands"), e.message]
    end
  end

  check("app spawn passes the path, kill the pid") do
    a = native.app(action: "spawn", path: "/app/demo/kamon.app.rb")
    b = native.app(action: "kill", pid: 7)
    [a[:result]["argv"] == ["app", "spawn", "/app/demo/kamon.app.rb"] &&
      b[:result]["argv"] == ["app", "kill", "7"], [a, b].inspect]
  end

  check("app spawn without a path says what is missing") do
    begin
      native.app(action: "spawn")
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("needs a path"), e.message]
    end
  end

  check("down stops our own program") do
    r = native.down
    [r[:down] && r[:was_ours] == true && !File.exist?(File.join(state, "native.json")), r.inspect]
  end

  # Someone else's program: reused, and not stopped without force.
  File.write(File.join(repo, "tools", "running"), "1")
  check("a running program is reused, and the options are said not to apply") do
    r = native.up(machine: "linux_pc_drm")
    [r[:notes].join.include?("reused") && r[:notes].join.include?("not applied"), r[:notes].inspect]
  end

  check("down refuses a program that was not ours") do
    begin
      native.down
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("force"), e.message]
    end
  end

  check("down with force stops it anyway") do
    r = native.down(force: true)
    [r[:down] && r[:was_ours] == false, r.inspect]
  end

  # Over the wire: the five tools are listed, and a call with nothing behind
  # it is a tool error, not a protocol error.
  env = { "FMRB_MCP_STATE_DIR" => File.join(dir, "wire") }
  sin, sout, serr, wait = Open3.popen3(env, "ruby", SERVER)
  id = 0
  req = lambda do |method, params|
    id += 1
    sin.puts(JSON.generate("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    sin.flush
    line = sout.gets
    [line, JSON.parse(line.to_s)]
  end
  raw = []
  line, = req.call("initialize", { "protocolVersion" => "2024-11-05", "capabilities" => {},
                                   "clientInfo" => { "name" => "selftest", "version" => "0" } })
  raw << line
  line, res = req.call("tools/list", {})
  raw << line
  names = (res.dig("result", "tools") || []).map { |t| t["name"] }
  check("the five native tools are listed") do
    want = %w[native_up native_down native_screenshot native_input native_app]
    [(want - names).empty?, (want - names).inspect]
  end
  check("their descriptions say they run beside the sim and take a machine") do
    up = res.dig("result", "tools").find { |t| t["name"] == "native_up" }
    d = up.to_h["description"].to_s
    [d.include?("SAME TIME as the sim") && d.include?("machine"), d[0, 120]]
  end

  line, res = req.call("tools/call", { name: "native_input", arguments: { commands: "" } })
  raw << line
  check("an empty native_input is a tool error, not a protocol error") do
    [res.dig("result", "isError") == true, res.inspect]
  end

  check("every line the server wrote to stdout is JSON-RPC") do
    bad = raw.reject { |l| JSON.parse(l)["jsonrpc"] == "2.0" rescue false }
    [bad.empty?, bad.first(2).inspect]
  end

  sin.close
  wait.value
  sout.close
  serr.close
end

exit($failures.zero? ? 0 : 1)
