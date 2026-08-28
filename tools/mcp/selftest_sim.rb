#!/usr/bin/env ruby
# frozen_string_literal: true

# The simulation half of the fmrb MCP selftest. Everything here runs without
# docker: the parts that need containers are in the acceptance list instead.
#
# Two fakes stand in for the machinery. A fake repository root holds stand-in
# CLI tools that print the argv they were given, which is how the argument
# handling is checked without a running sim; and fake ELF files stand in for
# the builds, which is how the false-green guard is checked without spending
# ten minutes on a real one.
require "json"
require "tmpdir"
require "fileutils"
require "open3"

require_relative "lib/sim"

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

# An ELF header is all the build check reads: magic, then e_machine at 18.
def write_elf(path, machine)
  head = +"\x7FELF\x02\x01\x01".b + ("\x00".b * 9) + [2].pack("v") + [machine].pack("v")
  File.binwrite(path, head + ("\x00".b * 64))
end

def write_png(path, width, height)
  ihdr = [width, height].pack("NN") + "\x08\x02\x00\x00\x00".b
  File.binwrite(path, "\x89PNG\r\n\x1A\n".b + [13].pack("N") + "IHDR".b + ihdr)
end

# A repository whose CLI tools report what they were called with, so argument
# handling can be checked without a sim behind them.
def fake_repo(dir, hw_target: "TAB5")
  FileUtils.mkdir_p(File.join(dir, "tools"))
  FileUtils.mkdir_p(File.join(dir, "fmruby-core", "tool", "debug"))
  File.write(File.join(dir, "fmruby-core", ".env"),
             "# comment\nFMRB_HW_TARGET=#{hw_target}  # inline comment\n")
  File.write(File.join(dir, "tools", "fmrb_input.rb"),
             "require 'json'\nputs JSON.generate(ARGV)\n")
  File.write(File.join(dir, "fmruby-core", "tool", "debug", "fmrb_dbg_client.py"),
             "import json,sys\nprint(json.dumps({\"argv\": sys.argv[1:], \"pid\": 7}))\n")
  dir
end

Dir.mktmpdir("fmrb-mcp-sim") do |dir|
  repo = fake_repo(File.join(dir, "repo"))
  state = File.join(dir, "state")
  sim = FmrbMcp::Sim.new(repo_root: repo, state_dir: state)

  puts "  -- the false-green guard --"
  core = File.join(dir, "core.elf")
  ga = File.join(dir, "ga.elf")
  ENV["FMRB_MCP_SIM_CORE_ELF"] = core
  ENV["FMRB_MCP_SIM_GA_ELF"] = ga

  err = (sim.up rescue $!)
  check("a missing build is refused before anything starts") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("is missing"), err.inspect]
  end
  check("and it says which rake task fixes it") do
    [err.message.include?("clean_all") && err.message.include?("build:linux"), err.message]
  end

  write_elf(core, 0xF3)           # RISC-V: an ESP32-P4 build
  write_elf(ga, 0x3E)
  err = (sim.up rescue $!)
  check("a leftover ESP32 build is named for what it is") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("RISC-V") &&
       err.message.include?("not x86-64"), err.message]
  end
  check("the reason the log cannot be trusted is spelled out") do
    [err.message.include?("Linux build complete"), err.message]
  end

  File.write(core, "#!/bin/sh\necho not an elf\n")
  err = (sim.up rescue $!)
  check("a file that is not an ELF at all is caught too") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("not an ELF"), err.message]
  end

  write_elf(core, 0x3E)
  write_elf(ga, 0x3E)

  puts "  -- input: quoting survives --"
  r = sim.input('click 30 55 sleep 120 text "hello world" key enter')
  argv = JSON.parse(r[:output])
  check("a quoted string reaches the tool as ONE argument") do
    [argv == ["click", "30", "55", "sleep", "120", "text", "hello world", "key", "enter"],
     argv.inspect]
  end
  err = (sim.input('text "unbalanced') rescue $!)
  check("an unbalanced quote is explained, not passed on") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("Quote a string"), err.inspect]
  end
  err = (sim.input("  ") rescue $!)
  check("an empty command list is refused") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("no commands"), err.inspect]
  end

  puts "  -- apps: the debug client is called the way it expects --"
  r = sim.app(action: "spawn", path: "/app/demo/kamon.app.rb")
  check("spawn passes path= and returns the parsed answer") do
    [r[:result]["argv"] == ["--json", "localhost", "spawn", "path=/app/demo/kamon.app.rb"] &&
       r[:result]["pid"] == 7, r.inspect]
  end
  r = sim.app(action: "kill", pid: 5)
  check("kill passes pid=") do
    [r[:result]["argv"].last == "pid=5", r.inspect]
  end
  err = (sim.app(action: "spawn") rescue $!)
  check("spawn without a path stops before calling out") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("needs a path"), err.inspect]
  end
  err = (sim.app(action: "restart") rescue $!)
  check("an unknown action is refused") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("unknown action"), err.inspect]
  end

  puts "  -- whose stack is it --"
  FileUtils.mkdir_p(state)
  File.write(File.join(state, "sim.json"),
             JSON.generate("started_by_us" => false, "size" => "426x240"))
  err = (sim.down rescue $!)
  check("a stack this server did not start is not taken down") do
    [err.is_a?(FmrbMcp::Error) && err.message.include?("force: true"), err.inspect]
  end
  check("and the refusal says why it might matter") do
    [err.message.include?("GUI run"), err.message]
  end

  puts "  -- resolution --"
  check("a Modern target expects 426x240") do
    [sim.send(:expected_size_s) == "426x240", sim.send(:expected_size_s)]
  end
  retro = FmrbMcp::Sim.new(repo_root: fake_repo(File.join(dir, "retro"), hw_target: "NARYAv3"),
                           state_dir: File.join(dir, "retro_state"))
  check("a Retro target expects 320x240") do
    [retro.send(:expected_size_s) == "320x240", retro.send(:expected_size_s)]
  end
  png = File.join(dir, "shot.png")
  write_png(png, 426, 240)
  check("the size is read from the PNG, not from what the script printed") do
    [sim.send(:png_size, png) == [426, 240], sim.send(:png_size, png).inspect]
  end

  puts "  -- through the server --"
  ENV.delete("FMRB_MCP_SIM_CORE_ELF")
  ENV.delete("FMRB_MCP_SIM_GA_ELF")
  stale = File.join(dir, "stale.elf")
  write_elf(stale, 0x5E)          # Xtensa: an ESP32-S3 build
  env = { "FMRB_MCP_STATE_DIR" => File.join(dir, "srv"),
          "FMRB_MCP_SIM_CORE_ELF" => stale,
          "FMRB_MCP_SIM_GA_ELF" => ga }
  sin, sout, serr, wait = Open3.popen3(env, "ruby", SERVER)
  id = 0
  req = lambda do |m, p = nil|
    id += 1
    h = { jsonrpc: "2.0", id: id, method: m }
    h[:params] = p if p
    sin.puts JSON.generate(h)
    sin.flush
    line = sout.gets
    raise "no response to #{m}" if line.nil?
    [line, JSON.parse(line)]
  end
  raw = []
  line, = req.call("initialize", { protocolVersion: "2025-06-18", capabilities: {},
                                   clientInfo: { name: "sim-selftest", version: "0" } })
  raw << line
  sin.puts JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
  sin.flush

  line, res = req.call("tools/list")
  raw << line
  listed = res.dig("result", "tools").map { |t| t["name"] }.sort
  check("all fourteen tools are registered") do
    want = %w[flash serial_log serial_start serial_stop
              sim_app sim_down sim_input sim_screenshot sim_up
              tab5_app tab5_fs tab5_input tab5_ip tab5_screenshot]
    [listed == want, listed.inspect]
  end

  line, res = req.call("tools/call", { name: "sim_up", arguments: {} })
  raw << line
  doc = JSON.parse(res.dig("result", "content", 0, "text"))
  check("sim_up refuses a stale S3 build over the wire too") do
    [res.dig("result", "isError") == true && doc["message"].include?("Xtensa"), doc.inspect]
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
