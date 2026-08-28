#!/usr/bin/env ruby
# frozen_string_literal: true

# The Tab5 half of the fmrb MCP selftest, run against a fake board.
#
# Not meant to be run directly: selftest.rb starts it inside a network
# namespace (unshare -rn), because the real endpoints live on port 80 and an
# unprivileged process cannot bind that. Inside the namespace 127.0.0.1:80 is
# ours, so the whole path runs unmodified -- the server, the rd_* CLI tools it
# shells out to, and the HTTP client they share.
#
# The fake answers the endpoints rd_http.c answers: /status, /app/list,
# /app/launch, /app/kill, /fs/list, /stream (one JPEG) and a /ws handshake. It
# can also pretend to be a release firmware, which has no /app or /fs at all.
require "json"
require "tmpdir"
require "open3"
require "socket"
require "base64"

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

# A JPEG as far as anything here cares: starts with SOI, ends with EOI, and
# has no stray EOI in between (fmrb_rd_snap.rb cuts on those two markers).
FAKE_JPEG = ("\xFF\xD8\xFF\xE0".b + ("fmrb selftest frame " * 8).b + "\xFF\xD9".b)

class FakeTab5
  attr_accessor :release_mode   # a firmware built without FMRB_DEV_REMOTE_CTL

  def initialize(port = 80)
    @server = TCPServer.new("127.0.0.1", port)
    @release_mode = false
    @thread = Thread.new { accept_loop }
  end

  def stop
    @thread&.kill
    @server.close rescue nil
  end

  private

  def accept_loop
    loop do
      conn = @server.accept
      Thread.new(conn) { |c| serve(c) rescue nil; c.close rescue nil }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(c)
    line = c.gets
    return unless line
    method, target, = line.split
    loop { break if c.gets.to_s.strip.empty? }   # drain the headers
    path, query = target.split("?", 2)
    dev = !@release_mode

    case [method, path]
    when %w[GET /status]
      json(c, '{"ip":"127.0.0.1","mode":"mjpeg","streaming":false,"fps":15.0,"kbps":420}')
    when %w[GET /app/list]
      return not_found(c) unless dev
      json(c, '{"apps":[{"pid":0,"name":"kernel","state":"running"},' \
              '{"pid":4,"name":"Services","state":"running"}]}')
    when %w[POST /app/launch]
      return not_found(c) unless dev
      json(c, query.to_s.include?("path=") ? '{"ok":true,"pid":9}' : '{"ok":false,"err":1}')
    when %w[POST /app/kill]
      return not_found(c) unless dev
      # The firmware protects the kernel, the host and the system desktop.
      if query.to_s.include?("pid=0")
        json(c, '{"ok":false,"err":"protected"}', "400 Bad Request")
      else
        json(c, '{"ok":true}')
      end
    when %w[GET /fs/list]
      return not_found(c) unless dev
      json(c, '{"ok":true,"entries":[{"name":"demo","dir":true,"size":0},' \
              '{"name":"hello.app.rb","dir":false,"size":128}]}')
    when %w[GET /stream]
      stream(c)
    when %w[GET /ws]
      # fmrb_rd_input.rb only checks for "101" before it starts sending.
      c.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
              "Connection: Upgrade\r\n\r\n")
      c.read rescue nil
    else
      not_found(c)
    end
  end

  def json(c, body, status = "200 OK")
    c.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end

  def not_found(c)
    body = "404"
    c.write("HTTP/1.1 404 Not Found\r\nContent-Length: #{body.bytesize}\r\n" \
            "Connection: close\r\n\r\n#{body}")
  end

  def stream(c)
    c.write("HTTP/1.1 200 OK\r\n" \
            "Content-Type: multipart/x-mixed-replace; boundary=f\r\n\r\n")
    3.times do
      c.write("--f\r\nContent-Type: image/jpeg\r\n" \
              "Content-Length: #{FAKE_JPEG.bytesize}\r\n\r\n")
      c.write(FAKE_JPEG)
      c.write("\r\n")
      sleep 0.05
    end
  end
end

class Srv
  attr_reader :raw_stdout

  def initialize(env)
    @in, @out, @err, @wait = Open3.popen3(env, "ruby", SERVER)
    @id = 0
    @raw_stdout = []
    request("initialize", { protocolVersion: "2025-06-18", capabilities: {},
                            clientInfo: { name: "tab5-selftest", version: "0" } })
    @in.puts JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
    @in.flush
  end

  def request(m, p = nil)
    @id += 1
    msg = { jsonrpc: "2.0", id: @id, method: m }
    msg[:params] = p if p
    @in.puts JSON.generate(msg)
    @in.flush
    line = @out.gets
    raise "no response to #{m}" if line.nil?
    @raw_stdout << line
    JSON.parse(line)
  end

  def call(name, args = {})
    request("tools/call", { name: name, arguments: args })
  end

  def close
    @in.close rescue nil
    @wait.value
    @out.close rescue nil
    @err.close rescue nil
  end
end

def payload(res)
  text = res.dig("result", "content").reverse.find { |c| c["type"] == "text" }["text"]
  [JSON.parse(text), res.dig("result", "isError")]
end

fake = FakeTab5.new
Dir.mktmpdir("fmrb-mcp-tab5") do |dir|
  # A name nothing can resolve, so the "board is gone" path fails fast instead
  # of finding the real Tab5 that may be sitting on the developer's desk.
  env = { "FMRB_MCP_STATE_DIR" => dir,
          "FMRB_MCP_TAB5_HOST" => "fmrb-selftest-nosuch.local" }
  srv = Srv.new(env)

  puts "  -- address resolution --"
  doc, err = payload(srv.call("tab5_ip", { ip: "127.0.0.1" }))
  check("an explicit address is verified against /status") do
    [!err && doc["source"] == "argument" && doc.dig("status", "ip") == "127.0.0.1", doc.inspect]
  end

  doc, err = payload(srv.call("tab5_ip"))
  check("the verified address is cached and reused") do
    [!err && doc["source"].to_s.start_with?("cache"), doc.inspect]
  end

  fake.stop
  doc, err = payload(srv.call("tab5_ip"))
  check("a cached address that stops answering is an error, not a hang") do
    [err == true, doc.inspect]
  end
  check("the failure says how to find the address by hand") do
    m = doc["message"].to_s
    [m.include?("cannot find the Tab5") && m.include?("Remote desktop ready"), m]
  end
  check("the dead address was dropped from the cache") do
    [!File.exist?(File.join(dir, "tab5_ip.json")), "tab5_ip.json survived"]
  end
  fake = FakeTab5.new

  puts "  -- screen --"
  res = srv.call("tab5_screenshot", { ip: "127.0.0.1" })
  img = res.dig("result", "content").find { |c| c["type"] == "image" }
  check("the frame comes back as image content, not a file path") do
    [!img.nil? && img["mimeType"] == "image/jpeg", res.dig("result", "content").inspect]
  end
  check("the image data is a real JPEG") do
    bytes = Base64.strict_decode64(img["data"].to_s)
    [bytes.start_with?("\xFF\xD8".b), bytes[0, 4].unpack1("H*")]
  end
  doc, = payload(res)
  check("the text part carries the file and the frame size") do
    [doc["frame_size"] == "426x240" && doc["bytes"].to_i > 0 && !doc["path"].to_s.empty?, doc.inspect]
  end

  puts "  -- apps --"
  doc, err = payload(srv.call("tab5_app", { action: "ps", ip: "127.0.0.1" }))
  check("ps returns structured apps, not a scraped table") do
    [!err && doc["apps"].is_a?(Array) && doc["apps"].first["name"] == "kernel", doc.inspect]
  end
  doc, err = payload(srv.call("tab5_app", { action: "launch", ip: "127.0.0.1",
                                            path: "/app/demo/spinel_hello.app.rb" }))
  check("launch by path returns the new pid") { [!err && doc["pid"] == 9, doc.inspect] }
  doc, err = payload(srv.call("tab5_app", { action: "kill", pid: 9, ip: "127.0.0.1" }))
  check("kill of a user app succeeds") { [!err && doc["killed"] == 9, doc.inspect] }
  doc, err = payload(srv.call("tab5_app", { action: "kill", pid: 0, ip: "127.0.0.1" }))
  check("kill of the kernel is refused with an explanation") do
    [err == true && doc["message"].to_s.include?("Only user apps"), doc.inspect]
  end
  doc, err = payload(srv.call("tab5_app", { action: "launch", ip: "127.0.0.1" }))
  check("launch without a path says so before touching the board") do
    [err == true && doc["message"].to_s.include?("needs a path"), doc.inspect]
  end

  puts "  -- files --"
  doc, err = payload(srv.call("tab5_fs", { action: "ls", device_path: "/app", ip: "127.0.0.1" }))
  check("ls reaches the device and lists entries") do
    [!err && doc["output"].to_s.include?("hello.app.rb"), doc.inspect]
  end
  doc, err = payload(srv.call("tab5_fs", { action: "put", local_path: "/nope/missing.rb",
                                           device_path: "/app/x.rb", ip: "127.0.0.1" }))
  check("put of a missing local file fails before the transfer") do
    [err == true && doc["message"].to_s.include?("does not exist"), doc.inspect]
  end

  puts "  -- input --"
  doc, err = payload(srv.call("tab5_input", { commands: "click 10 20 sleep 10", ip: "127.0.0.1" }))
  check("a click reaches the websocket") { [!err && doc["sent"] == "click 10 20 sleep 10", doc.inspect] }
  doc, err = payload(srv.call("tab5_input", { commands: "key nosuchkey", ip: "127.0.0.1" }))
  check("an unknown key names the key instead of failing silently") do
    [err == true && doc["message"].to_s.include?("unknown key: nosuchkey"), doc.inspect]
  end

  puts "  -- a firmware without the development endpoints --"
  fake.release_mode = true
  doc, err = payload(srv.call("tab5_app", { action: "ps", ip: "127.0.0.1" }))
  check("404 is diagnosed as a release build, not as a broken board") do
    [err == true && doc["message"].to_s.include?("no development remote control"), doc.inspect]
  end
  check("and it names the switch that turns them on") do
    [doc["message"].to_s.include?("FMRB_DEV_REMOTE_CTL"), doc["message"]]
  end
  fake.release_mode = false

  puts "  -- registration and stdout purity --"
  listed = srv.request("tools/list").dig("result", "tools").map { |t| t["name"] }.sort
  check("the five Tab5 tools are registered") do
    want = %w[tab5_app tab5_fs tab5_input tab5_ip tab5_screenshot]
    [(want - listed).empty?, listed.inspect]
  end
  check("every line the server wrote to stdout is JSON-RPC") do
    bad = srv.raw_stdout.reject { |l| JSON.parse(l)["jsonrpc"] == "2.0" rescue false }
    [bad.empty?, bad.first(2).inspect]
  end

  srv.close
end
fake.stop

exit($failures.zero? ? 0 : 1)
