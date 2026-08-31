#!/usr/bin/env ruby
# frozen_string_literal: true

# The browser half of the fmrb MCP selftest. Everything here runs without a
# browser and without the development server: the parts that need them are in
# the acceptance list instead.
#
# One fake stands in for the machinery: a repository root whose fmrb_web.rb
# prints the argv it was given (and writes a PNG when asked for a screenshot),
# which is how the argument handling, the refusals and the state rules are
# checked without anything running behind them.
require "json"
require "tmpdir"
require "fileutils"
require "open3"

require_relative "lib/web"

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

def write_png(path, width, height)
  ihdr = [width, height].pack("NN") + "\x08\x02\x00\x00\x00".b
  File.binwrite(path, "\x89PNG\r\n\x1A\n".b + [13].pack("N") + "IHDR".b + ihdr)
end

# A repository whose fmrb_web.rb reports what it was called with.
def fake_repo(dir)
  FileUtils.mkdir_p(File.join(dir, "tools"))
  FileUtils.mkdir_p(File.join(dir, "fmruby-core", "wasm", "build"))
  File.write(File.join(dir, "tools", "fmrb_web.rb"), <<~RUBY)
    require 'json'
    args = ARGV.dup
    if (at = args.index('--port')) then args.slice!(at, 2) end
    if args[0] == 'screenshot'
      path = args[1]
      ihdr = [426, 240].pack('NN') + "\\x08\\x02\\x00\\x00\\x00".b
      File.binwrite(path, "\\x89PNG\\r\\n\\x1A\\n".b + [13].pack('N') + 'IHDR'.b + ihdr)
    end
    puts args[0] == 'status' ? 'running=true 426x240 frame=9 home=persistent' : JSON.generate(args)
  RUBY
  dir
end

def bundle!(dir)
  %w[core_web.js core_web.wasm core_web.data].each do |f|
    File.write(File.join(dir, "fmruby-core", "wasm", "build", f), "x")
  end
end

Dir.mktmpdir("fmrb-mcp-web") do |dir|
  repo = fake_repo(File.join(dir, "repo"))
  state = File.join(dir, "state")
  web = FmrbMcp::Web.new(repo_root: repo, state_dir: state)

  puts "  the browser tools (no browser, no server)"

  check("web_up says how to build a bundle that is not there") do
    begin
      web.up
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("rake wasm:web") && e.message.include?("core_web.js"), e.message]
    end
  end

  bundle!(repo)

  check("input keeps a quoted string in one piece") do
    r = web.input('click 30 8 text "hello world" key ctrl+s')
    [r[:sent] == ["click", "30", "8", "text", "hello world", "key", "ctrl+s"], r.inspect]
  end

  check("input refuses an unbalanced quote with advice") do
    begin
      web.input('text "unclosed')
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("hello world"), e.message]
    end
  end

  check("input refuses an empty command list") do
    begin
      web.input("   ")
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("no commands"), e.message]
    end
  end

  check("screenshot returns the PNG the tool wrote, with its size") do
    shot = web.screenshot
    [shot[:size] == "426x240" && shot[:data].to_s.length > 20, shot.reject { |k, _| k == :data }.inspect]
  end

  check("fs put sends local first, remote second") do
    local = File.join(dir, "a.rb")
    File.write(local, "puts 1\n")
    r = web.fs(action: "put", path: "/flash/home/a.rb", local_path: local)
    [JSON.parse(r[:output]) == ["put", local, "/flash/home/a.rb"], r[:output]]
  end

  check("fs get names the remote file first, the local one second") do
    r = web.fs(action: "get", path: "/flash/home/a.rb", local_path: File.join(dir, "b.rb"))
    [JSON.parse(r[:output]) == ["get", "/flash/home/a.rb", File.join(dir, "b.rb")], r[:output]]
  end

  check("fs put refuses a local file that is not there") do
    begin
      web.fs(action: "put", path: "/flash/home/x", local_path: File.join(dir, "nope"))
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("not there"), e.message]
    end
  end

  check("fs refuses an unknown action by name") do
    begin
      web.fs(action: "chmod", path: "/flash/home")
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("ls|cat|get|put|rm"), e.message]
    end
  end

  check("fs ls without a path says what is missing") do
    begin
      web.fs(action: "ls")
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("/flash/home"), e.message]
    end
  end

  # The state rules: whose browser is it, and which port.
  File.write(File.join(state, "web.json"), JSON.dump(
    "port" => 8123, "server_ours" => false, "browser_ours" => false))

  check("a port once used is remembered") do
    st = web.status
    [st[:port] == 8123, st.inspect]
  end

  check("web_down refuses a browser that was not ours") do
    begin
      web.down
      [false, "no error raised"]
    rescue FmrbMcp::Error => e
      [e.message.include?("force"), e.message]
    end
  end

  check("web_down with force closes it anyway, and leaves someone else's server") do
    r = web.down(force: true)
    [r[:down] && r[:output].include?("left the development server alone"), r.inspect]
  end

  check("the state file is gone after down") do
    [!File.exist?(File.join(state, "web.json")), "still there"]
  end

  # Over the wire: the tools are listed and answer as tools, not as protocol
  # errors, when nothing is running.
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
  line, = req.call("initialize", { "protocolVersion" => "2024-11-05",
                                   "capabilities" => {},
                                   "clientInfo" => { "name" => "selftest", "version" => "0" } })
  raw << line
  line, res = req.call("tools/list", {})
  raw << line
  names = (res.dig("result", "tools") || []).map { |t| t["name"] }
  check("the six web tools are listed") do
    want = %w[web_up web_down web_screenshot web_input web_fs web_reload]
    [(want - names).empty?, (want - names).inspect]
  end

  line, res = req.call("tools/call", { name: "web_input", arguments: { commands: "" } })
  raw << line
  check("an empty web_input is a tool error, not a protocol error") do
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
