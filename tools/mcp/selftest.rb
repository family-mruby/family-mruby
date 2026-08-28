#!/usr/bin/env ruby
# frozen_string_literal: true

# Hardware-free check of the fmrb MCP server.
#
#   ruby tools/mcp/selftest.rb
#
# It spawns the real server as a subprocess and talks JSON-RPC to it over a
# pipe -- the same path Claude Code uses -- in a throwaway state directory, so
# it never touches ~/.fmrb_mcp or a real board. What it proves:
#
#   1. the server starts, answers initialize, and lists the four tools
#   2. serial_log with no capture and no log returns a tidy answer, not a crash
#   3. a port already flock'd by another process makes serial_start fail
#      explicitly ("in use by another session") instead of stealing it
#   4. against a virtual serial port (socat pty pair, skipped when socat is
#      missing): a capture really runs, serial_log reads what arrived, and the
#      log survives a stop/start cycle even though the capture tool truncates
#      its output file
#   5. killing the server takes the capture child with it -- an orphan holding
#      the port is the worst thing this server could leave behind
#   6. stdout stays pure JSON-RPC throughout
#   7. the boot-log reader calls a download-mode stall a stall and not a boot
#      loop, and the subprocess helper reports failure and timeout honestly
#   8. the Tab5 tools, against a fake board (selftest_tab5.rb, run inside a
#      network namespace so it can hold port 80)
#   9. the simulation tools, against fake builds and fake CLI tools
#      (selftest_sim.rb; the parts that need docker are acceptance work)
require "json"
require "tmpdir"
require "open3"

require_relative "lib/serial_manager"

SERVER = File.expand_path("fmrb_mcp_server.rb", __dir__)
FAKE_PORT = "/dev/ttyFMRBSELFTEST"

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

class ServerPipe
  attr_reader :raw_stdout

  def initialize(env)
    @stdin, @stdout, @stderr, @wait = Open3.popen3(env, "ruby", SERVER)
    @id = 0
    @raw_stdout = []
  end

  def request(method, params = nil)
    @id += 1
    msg = { jsonrpc: "2.0", id: @id, method: method }
    msg[:params] = params if params
    @stdin.puts(JSON.generate(msg))
    @stdin.flush
    line = @stdout.gets
    raise "no response to #{method} (stderr: #{drain_stderr})" if line.nil?
    @raw_stdout << line
    JSON.parse(line)
  end

  def notify(method, params = nil)
    msg = { jsonrpc: "2.0", method: method }
    msg[:params] = params if params
    @stdin.puts(JSON.generate(msg))
    @stdin.flush
  end

  def call_tool(name, args = {})
    request("tools/call", { name: name, arguments: args })
  end

  def drain_stderr
    @stderr.read_nonblock(65_536)
  rescue StandardError
    ""
  end

  def kill_server
    Process.kill("TERM", @wait.pid)
    @wait.value
  end

  def close
    @stdin.close rescue nil
    @wait.value
    @stdout.close rescue nil
    @stderr.close rescue nil
  end
end

def process_alive?(pid)
  return false unless pid
  Process.kill(0, pid)
  true
rescue Errno::ESRCH, Errno::EPERM
  false
end

def feed(path, text)
  File.open(path, "wb") { |f| f.write(text) }
end

def tool_payload(response)
  text = response.dig("result", "content", 0, "text")
  [JSON.parse(text), response.dig("result", "isError")]
end

Dir.mktmpdir("fmrb-mcp-selftest") do |dir|
  env = { "FMRB_MCP_STATE_DIR" => dir }
  server = ServerPipe.new(env)

  puts "1. handshake and tool list"
  init = server.request("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "fmrb-selftest", version: "0" },
  })
  server.notify("notifications/initialized")
  check("initialize returns a server name") do
    name = init.dig("result", "serverInfo", "name")
    [name == "fmrb", name.inspect]
  end

  listed = server.request("tools/list").dig("result", "tools").map { |t| t["name"] }.sort
  check("tools/list has the four P1 tools") do
    want = %w[flash serial_log serial_start serial_stop]
    [(want - listed).empty?, listed.inspect]
  end
  check("every tool has a description") do
    tools = server.request("tools/list").dig("result", "tools")
    bad = tools.reject { |t| t["description"].to_s.length > 40 }.map { |t| t["name"] }
    [bad.empty?, bad.inspect]
  end

  puts "2. serial_log with nothing captured"
  payload, is_error = tool_payload(server.call_tool("serial_log"))
  check("does not error") { [!is_error, payload.inspect] }
  check("reports no capture and no log") do
    [payload["running"] == false && payload["log_present"] == false, payload.inspect]
  end
  check("returns empty text rather than nil") { [payload["text"] == "", payload["text"].inspect] }

  payload, is_error = tool_payload(server.call_tool("serial_log", { tail: 5, grep: "Guru" }))
  check("grep on an empty log is not an error") { [!is_error, payload.inspect] }

  payload, is_error = tool_payload(server.call_tool("serial_log", { grep: "[unclosed", regex: true }))
  check("an invalid regexp is an explicit tool error") do
    [is_error == true && payload["message"].to_s.include?("invalid regexp"), payload.inspect]
  end

  puts "3. flock: the port is held by someone else"
  lock_path = File.join(dir, "dev-ttyFMRBSELFTEST.lock")
  holder = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
  holder.flock(File::LOCK_EX | File::LOCK_NB) or raise "could not take the test lock"
  holder.write("selftest holder")
  holder.flush

  payload, is_error = tool_payload(server.call_tool("serial_start", { port: FAKE_PORT }))
  check("serial_start refuses the busy port") { [is_error == true, payload.inspect] }
  check("the refusal says another session holds it") do
    [payload["message"].to_s.include?("in use by another session"), payload["message"].inspect]
  end
  check("no capture process was spawned") do
    [!File.exist?(File.join(dir, "capture.pid")), "capture.pid exists"]
  end

  holder.flock(File::LOCK_UN)
  holder.close

  raw_stdout = server.raw_stdout.dup

  vport = File.join(dir, "vport")
  vhost = File.join(dir, "vhost")
  socat = system("which socat > /dev/null 2>&1")
  socat_pid = nil

  if socat
    socat_pid = Process.spawn("socat", "-d", "-d",
                              "pty,raw,echo=0,link=#{vport}",
                              "pty,raw,echo=0,link=#{vhost}",
                              out: File::NULL, err: File::NULL, pgroup: true)
    60.times { break if File.exist?(vport) && File.exist?(vhost); sleep 0.1 }
  end

  if socat && File.exist?(vport)
    puts "4. capture against a virtual serial port"

    payload, is_error = tool_payload(server.call_tool("serial_start", { port: vport }))
    check("serial_start succeeds") { [!is_error && payload["started"] == true, payload.inspect] }
    child_pid = payload["pid"]
    check("it reports a live capture process") do
      [child_pid.is_a?(Integer) && process_alive?(child_pid), child_pid.inspect]
    end

    payload, = tool_payload(server.call_tool("serial_start", { port: vport }))
    check("a second serial_start is a no-op, not a second capture") do
      [payload["started"] == false && payload["pid"] == child_pid, payload.inspect]
    end

    feed(vhost, "rst:0x1 (POWERON),boot:0x8\r\nI (123) M1|boot|internal=1000\r\n")
    sleep 1.0
    payload, = tool_payload(server.call_tool("serial_log"))
    check("serial_log shows what arrived on the port") do
      [payload["text"].include?("M1|boot"), payload["text"].inspect]
    end
    check("CR and ANSI noise are cleaned up") do
      [!payload["text"].include?("\r"), "CR survived"]
    end
    payload, = tool_payload(server.call_tool("serial_log", { grep: "POWERON" }))
    check("grep filters to the matching lines") do
      [payload["matched_lines"] == 1 && payload["text"].include?("POWERON"), payload.inspect]
    end

    tool_payload(server.call_tool("serial_stop"))
    check("the capture child is gone after serial_stop") do
      [!process_alive?(child_pid), "pid #{child_pid} still alive"]
    end

    # The capture tool opens its output with "wb": without the archive step a
    # restart (which is exactly what flash does) would erase the earlier log.
    payload, = tool_payload(server.call_tool("serial_start", { port: vport }))
    feed(vhost, "second segment marker\r\n")
    sleep 1.0
    payload, = tool_payload(server.call_tool("serial_log"))
    check("the log from before the restart is still there") do
      [payload["text"].include?("M1|boot") && payload["text"].include?("second segment marker"),
       payload["text"].inspect]
    end
    tool_payload(server.call_tool("serial_stop"))
  else
    puts "4. capture against a virtual serial port -- SKIPPED (socat not available)"
  end

  server.close

  if socat && File.exist?(vport)
    puts "5. a killed server does not leave the port held"
    victim = ServerPipe.new(env)
    victim.request("initialize", { protocolVersion: "2025-06-18", capabilities: {},
                                   clientInfo: { name: "fmrb-selftest", version: "0" } })
    victim.notify("notifications/initialized")
    payload, = tool_payload(victim.call_tool("serial_start", { port: vport }))
    child_pid = payload["pid"]
    check("capture running before the kill") { [process_alive?(child_pid), payload.inspect] }
    victim.kill_server
    50.times { break unless process_alive?(child_pid); sleep 0.1 }
    check("SIGTERM to the server kills the capture child") do
      [!process_alive?(child_pid), "orphan pid #{child_pid} still holds the port"]
    end
    raw_stdout.concat(victim.raw_stdout)
    victim.close
  end

  if socat_pid
    Process.kill("TERM", -socat_pid) rescue nil
    Process.waitpid(socat_pid) rescue nil
  end

  puts "6. stdout purity"
  check("every line the servers wrote to stdout is JSON-RPC") do
    bad = raw_stdout.reject do |line|
      JSON.parse(line)["jsonrpc"] == "2.0" rescue false
    end
    [bad.empty?, bad.first(2).inspect]
  end

  puts "7. boot-log reading and the subprocess helper (direct)"
  mgr = FmrbMcp::SerialManager.new(repo_root: File.expand_path("../..", __dir__),
                                   state_dir: File.join(dir, "direct"))

  stall = mgr.send(:boot_summary, <<~LOG)
    ESP-ROM:esp32p4-20230811
    rst:0x1 (POWERON),boot:0x204 (DOWNLOAD(USB/UART0))
    waiting for download
  LOG
  check("a download-mode stall is named as such") do
    [stall[:download_mode_stall] == true &&
       stall[:verdict].include?("NOT a boot loop"), stall[:verdict]]
  end
  check("a stall is not counted as a crash") { [stall[:crash_marker_lines] == 0, stall.inspect] }

  crash = mgr.send(:boot_summary, <<~LOG)
    ESP-ROM:esp32s3-20210327
    Guru Meditation Error: Core 0 panic'ed (LoadProhibited)
    Backtrace: 0x4200 0x4201
  LOG
  check("crash lines are counted") { [crash[:crash_marker_lines] == 2, crash.inspect] }

  # A Tab5 boot attached with reset: true -- no ROM banner, because the second
  # reset re-enumerates USB and the first ~0.4s is gone. Measured against a
  # real board on 2026-08-29.
  tab5 = mgr.send(:boot_summary, <<~LOG)
    I (417) esp_image: segment 1: paddr=00282368 vaddr=30100000 size=0037ch load
    I (837) boot: Loaded app from partition at offset 0x10000
    I (14:54:26.395) boot: Family mruby OS version 2.1.0
  LOG
  check("a Tab5 boot without a ROM banner still reads as a boot") do
    [tab5[:rom_banner] == false && tab5[:bootloader] == true &&
       !tab5[:verdict].start_with?("output seen but"), tab5.inspect]
  end

  healthy = mgr.send(:boot_summary, <<~LOG)
    ESP-ROM:esp32s3-20210327
    rst:0x1 (POWERON),boot:0x8
    I (900) fmrb_mem: M1|after_display|internal=120000|largest=64000|psram=8000000
  LOG
  check("a clean boot reads as healthy") do
    [healthy[:verdict].start_with?("healthy"), healthy[:verdict]]
  end

  quiet = mgr.send(:boot_summary, "")
  check("silence is explained, not called a failure") do
    [quiet[:verdict].include?("no serial output"), quiet[:verdict]]
  end

  ok = mgr.send(:run, {}, ["true"], chdir: dir, timeout: 10)
  check("run reports success") { [ok[:ok] == true && ok[:status] == 0, ok.inspect] }

  bad = mgr.send(:run, {}, ["sh", "-c", "echo boom >&2; exit 3"], chdir: dir, timeout: 10)
  check("run reports failure with the output") do
    [bad[:ok] == false && bad[:status] == 3 && bad[:output].include?("boom"), bad.inspect]
  end

  slow = mgr.send(:run, {}, ["sleep", "30"], chdir: dir, timeout: 1)
  check("run kills and flags a timeout") do
    [slow[:timed_out] == true && slow[:ok] == false, slow.inspect]
  end

  missing = begin
    mgr.send(:run, {}, ["fmrb-no-such-command"], chdir: dir, timeout: 5)
    nil
  rescue FmrbMcp::Error => e
    e.message
  end
  check("a missing command is a clear error") do
    [missing.to_s.include?("cannot run"), missing.inspect]
  end

  puts "8. the Tab5 tools against a fake board"
  # The endpoints live on port 80, which an unprivileged process cannot bind.
  # A user+network namespace gives us a private loopback where we can, so the
  # whole path -- server, rd_* CLI tools, HTTP client -- runs unmodified.
  tab5 = File.expand_path("selftest_tab5.rb", __dir__)
  out, status = Open3.capture2e("unshare", "-rn", "sh", "-c",
                                "ip link set lo up; ruby #{tab5}")
  if status.success?
    puts out.chomp
  elsif out.include?("unshare") && !out.include?("  ok ")
    puts "  SKIPPED (no user namespaces here: #{out.strip.lines.first.to_s.strip})"
  else
    puts out.chomp
    $failures += 1
    puts "  FAIL the Tab5 selftest reported failures"
  end

  puts "9. the simulation tools without docker"
  sim = File.expand_path("selftest_sim.rb", __dir__)
  out, status = Open3.capture2e("ruby", sim)
  puts out.chomp
  unless status.success?
    $failures += 1
    puts "  FAIL the simulation selftest reported failures"
  end

  puts
  if $failures.zero?
    puts "selftest: all checks passed"
  else
    puts "selftest: #{$failures} check(s) FAILED"
  end
  exit($failures.zero? ? 0 : 1)
end
