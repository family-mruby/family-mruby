# The tokens a PC holds for boards whose remote control is guarded (a release
# build: fmruby-core doc/remote_guard/plan.md, G2). Shared by every tool that
# talks to a board over WiFi: tools/fmrb_rd_*.rb, tools/fmrb_flash_keep.rb and
# the MCP server's tab5_* tools.
#
# How a release board lets a PC in: the owner turns on Config > Remote control
# on the board and steps it to "Pair a PC", which shows a six-digit number
# while it is open; the PC sends it once
#
#   ruby tools/fmrb_rd_fs.rb <IP> pair 123456
#
# and receives a token, which every later request carries (X-Fmrb-Token). The
# board keeps up to four PCs (the SHA-256 of their tokens) and can forget them
# all (Config). The switch is kept across restarts until it is turned off; the
# token lasts until it is forgotten. New PCs pair only while "Pair a PC" is
# open; a paired one works whenever the switch is on.
# A development build needs none of this: it answers every request, and the
# tools send no token there (none is stored for it).
#
# The tokens live in ~/.config/fmrb/remote_tokens.json (directory 0700, file
# 0600; FMRB_CONFIG_DIR moves it), keyed by the board's mDNS name from /status
# (fmruby-XXXXXX), which outlives DHCP: the address it was last reached at is
# kept too, so most requests need no /status first. Standard library only.
require "json"
require "fileutils"
require "net/http"
require "uri"
require "time"

module FmrbRdToken
  HEADER = "X-Fmrb-Token"
  FILE_NAME = "remote_tokens.json"

  # The board said no. message is for the person at the PC: what to do on the
  # board, and the pair command to run.
  class Denied < StandardError
    attr_reader :guard

    def initialize(message, guard = nil)
      super(message)
      @guard = guard
    end
  end

  module_function

  def dir
    ENV["FMRB_CONFIG_DIR"] || File.join(Dir.home, ".config", "fmrb")
  end

  def path
    File.join(dir, FILE_NAME)
  end

  def load
    doc = JSON.parse(File.read(path))
    doc.is_a?(Hash) && doc["boards"].is_a?(Hash) ? doc : { "boards" => {} }
  rescue Errno::ENOENT, JSON::ParserError
    { "boards" => {} }
  end

  # Written beside and renamed over, created 0600 inside a 0700 directory.
  def save(doc)
    FileUtils.mkdir_p(dir, mode: 0o700)
    File.chmod(0o700, dir) rescue nil
    tmp = "#{path}.tmp#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate(doc))
    end
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
  end

  # "fmruby-abc123.local" and "fmruby-abc123" are the same board.
  def bare(name)
    name.to_s.sub(/\.local\z/, "")
  end

  # The token for an address or a name, from what is stored; nil when none.
  def token_for(addr)
    boards = load["boards"]
    entry = boards[bare(addr)]
    return entry["token"] if entry
    # An address two boards were seen at (DHCP gave one's old address to the
    # other): ask the board at it who it is rather than take the first.
    at = boards.values.select { |e| e["ip"] == addr }
    return at.first["token"] if at.size == 1
    at.empty? ? nil : learn(addr)
  end

  # Ask the board who it is and look its name up; remember the address it
  # answered on. Returns the token or nil. For a request refused with a token
  # stored under another address (DHCP moved the board).
  def learn(addr)
    status = fetch_status(addr)
    host = status && status["host"]
    return nil unless host
    doc = load
    entry = doc["boards"][host]
    return nil unless entry
    ip = status["ip"] || addr
    stale = doc["boards"].any? { |name, e| name != host && e["ip"] == ip }
    if entry["ip"] != ip || stale
      entry["ip"] = ip
      doc["boards"].each { |name, e| e.delete("ip") if name != host && e["ip"] == ip }
      save(doc)
    end
    entry["token"]
  end

  def fetch_status(addr)
    uri = URI("http://#{addr}/status")
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) do |h|
      h.request(Net::HTTP::Get.new(uri))
    end
    res.code == "200" ? JSON.parse(res.body) : nil
  rescue StandardError
    nil
  end

  # Trade the number on the board's screen for a token and keep it. Returns
  # { host:, board:, ip:, guard: } (guard "free" for a development build,
  # which needs no token: nothing is stored then). Raises Denied with the
  # board's reason.
  def pair(addr, code)
    code = code.to_s.strip
    raise Denied.new("the number is the six digits shown on the board in Config > Remote control > Pair a PC", "wrong") unless code =~ /\A\d{1,6}\z/
    uri = URI("http://#{addr}/pair?code=#{code}")
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |h|
      h.request(Net::HTTP::Post.new(uri))
    end
    doc = JSON.parse(res.body) rescue nil
    if res.code == "404" && !(doc.is_a?(Hash) && doc.key?("ok"))
      raise Denied.new("#{addr} has no /pair: its firmware is from before the remote control guard " \
                       "(2026-11-16) and needs no pairing", "free")
    end
    raise Denied.new("#{addr} answered #{res.code} to /pair: #{res.body.to_s[0, 200]}") unless doc.is_a?(Hash)
    raise Denied.new(doc["err"].to_s, doc["guard"]) unless doc["ok"]
    status = fetch_status(addr) || {}
    host = status["host"] || bare(addr)
    if doc["guard"] == "free" || doc["token"].to_s.empty?
      return { host: host, board: status["board"], ip: status["ip"] || addr, guard: "free" }
    end
    store = load
    # Another board last seen at this address is not there any more.
    store["boards"].each { |name, e| e.delete("ip") if name != host && e["ip"] == (status["ip"] || addr) }
    store["boards"][host] = {
      "token" => doc["token"], "ip" => status["ip"] || addr, "board" => status["board"],
      "paired_at" => Time.now.utc.iso8601
    }
    save(store)
    { host: host, board: status["board"], ip: status["ip"] || addr, guard: "open" }
  end

  # Forget what this PC holds for a board (the board keeps its side until
  # Config forgets it).
  def forget(addr)
    doc = load
    key = doc["boards"].key?(bare(addr)) ? bare(addr) : doc["boards"].find { |_, e| e["ip"] == addr }&.first
    return false unless key
    doc["boards"].delete(key)
    save(doc)
    true
  end

  # The sentence for a 401: the board's own reason when it gave one, and the
  # command that pairs.
  def denied_message(addr, body)
    doc = JSON.parse(body.to_s) rescue nil
    guard = doc.is_a?(Hash) ? doc["guard"] : nil
    reason = doc.is_a?(Hash) && doc["err"] ? doc["err"] : "the board refused this PC"
    steps = case guard
            when "closed"
              "On the board: Config > Remote control: ON (it stays on until turned off). " \
              "A PC paired before needs nothing more; a new one steps it on to Pair a PC and runs the pair command with the number shown."
            else
              "On the board: Config > Remote control, step to Pair a PC, read the six-digit number, then on this PC:"
            end
    msg = "401 #{reason}\n#{steps}\n  ruby tools/fmrb_rd_fs.rb #{addr} pair <number>"
    Denied.new(msg, guard)
  end

  # Run a request with the stored token, and once more with a token found by
  # the board's name when it answers 401 (DHCP moved it). yield(token) must
  # return [status_code_integer, body]. Raises Denied when the board still says
  # no.
  def with_token(addr)
    tok = token_for(addr)
    status, body = yield(tok)
    return [status, body] unless status.to_i == 401
    fresh = learn(addr)
    if fresh && fresh != tok
      status, body = yield(fresh)
      return [status, body] unless status.to_i == 401
    end
    raise denied_message(addr, body)
  end
end
