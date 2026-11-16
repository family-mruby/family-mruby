#!/usr/bin/env ruby
# Host tests for the PC's side of the release build's remote control guard
# (tools/fmrb_rd_token.rb, fmruby-core doc/remote_guard G2): the token file
# and its modes, pairing, finding a board again after DHCP moved it, the retry
# on a 401, and the messages a refused request gives. Against a small fake
# board on a loopback port; nothing touches ~/.config/fmrb or a real board.
#
#   ruby tools/fmrb_rd_token_test.rb
#
# The tools on top (fmrb_rd_fs.rb, the MCP tab5_* tools) are covered by
# tools/mcp/selftest.rb (step 8).
require "minitest/autorun"
require "socket"
require "json"
require "tmpdir"

ENV["FMRB_CONFIG_DIR"] = File.join(Dir.mktmpdir("fmrb-token-test"), "conf")
require_relative "fmrb_rd_token"

class FakeBoard
  TOKEN = "0123456789abcdef0123456789abcdef"
  attr_accessor :guard, :status_ip, :code
  attr_reader :port, :hits

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @guard = :open
    @status_ip = "127.0.0.1"
    @code = "042137"
    @hits = []
    @thread = Thread.new { loop { serve(@server.accept) } rescue nil }
  end

  def addr
    "127.0.0.1:#{@port}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(c)
    method, target, = c.gets.to_s.split
    headers = {}
    while (h = c.gets.to_s) && !h.strip.empty?
      k, v = h.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip
    end
    path, query = target.to_s.split("?", 2)
    tok = headers["x-fmrb-token"]
    @hits << [method, path, tok]
    status, body =
      case [method, path]
      when %w[GET /status]
        g = @guard.nil? ? "free" : @guard.to_s
        [200, %({"ip":"#{@status_ip}","board":"naryav4","host":"fmruby-c0ffee","guard":"#{g}"})]
      when %w[POST /pair]
        if @guard.nil?
          [200, '{"ok":true,"guard":"free","token":""}']
        elsif @guard == :closed
          [403, '{"ok":false,"guard":"closed","err":"remote control is off on this board"}']
        elsif query.to_s == "code=#{@code}"
          [200, %({"ok":true,"guard":"open","token":"#{TOKEN}"})]
        else
          [403, '{"ok":false,"guard":"wrong","left":4,"err":"that is not the number (4 tries left)"}']
        end
      else
        if @guard == :closed
          [401, '{"ok":false,"guard":"closed","err":"remote control is off on this board"}']
        elsif @guard == :open && tok != TOKEN
          [401, %({"ok":false,"guard":"#{tok ? 'bad_token' : 'no_token'}","err":"this PC is not paired"})]
        else
          [200, '{"ok":true}']
        end
      end
    c.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  ensure
    c.close rescue nil
  end
end

class FmrbRdTokenTest < Minitest::Test
  def setup
    FileUtils.rm_rf(FmrbRdToken.dir)
    @board = FakeBoard.new
  end

  def teardown
    @board.stop
  end

  # A request the way the tools make one, through with_token.
  def get(addr, path = "/app/list")
    FmrbRdToken.with_token(addr) do |tok|
      res = Net::HTTP.start(*addr.split(":").then { |h, p| [h, p.to_i] }) do |h|
        h.get(path, tok ? { FmrbRdToken::HEADER => tok } : {})
      end
      [res.code.to_i, res.body]
    end
  end

  def test_nothing_stored_sends_no_token_and_a_development_board_answers
    @board.guard = nil
    status, = get(@board.addr)
    assert_equal 200, status
    assert_nil @board.hits.last[2]
    refute File.exist?(FmrbRdToken.path)
  end

  def test_pair_keeps_the_token_by_name_0600_in_0700
    r = FmrbRdToken.pair(@board.addr, "042137")
    assert_equal "fmruby-c0ffee", r[:host]
    assert_equal "open", r[:guard]
    assert_equal 0o600, File.stat(FmrbRdToken.path).mode & 0o777
    assert_equal 0o700, File.stat(FmrbRdToken.dir).mode & 0o777
    assert_equal FakeBoard::TOKEN, FmrbRdToken.token_for("fmruby-c0ffee")
    assert_equal FakeBoard::TOKEN, FmrbRdToken.token_for("fmruby-c0ffee.local")
    assert_equal FakeBoard::TOKEN, FmrbRdToken.token_for("127.0.0.1")   # the address /status gave
    status, = get(@board.addr)
    assert_equal 200, status
  end

  def test_number_with_leading_zeros_and_bad_input
    assert_raises(FmrbRdToken::Denied) { FmrbRdToken.pair(@board.addr, "12a456") }
    assert_raises(FmrbRdToken::Denied) { FmrbRdToken.pair(@board.addr, "1234567") }
    e = assert_raises(FmrbRdToken::Denied) { FmrbRdToken.pair(@board.addr, "111111") }
    assert_equal "wrong", e.guard
    assert_includes e.message, "4 tries left"
    refute File.exist?(FmrbRdToken.path)
  end

  def test_pair_on_a_development_board_stores_nothing
    @board.guard = nil
    r = FmrbRdToken.pair(@board.addr, "000000")
    assert_equal "free", r[:guard]
    refute File.exist?(FmrbRdToken.path)
  end

  def test_pair_while_closed_says_why
    @board.guard = :closed
    e = assert_raises(FmrbRdToken::Denied) { FmrbRdToken.pair(@board.addr, "042137") }
    assert_equal "closed", e.guard
  end

  def test_not_paired_gives_the_steps_and_the_command
    e = assert_raises(FmrbRdToken::Denied) { get(@board.addr) }
    assert_includes e.message, "401"
    assert_includes e.message, "Config > Remote control: ON"
    assert_includes e.message, "ruby tools/fmrb_rd_fs.rb #{@board.addr} pair <number>"
  end

  def test_closed_after_a_restart_tells_a_paired_pc_to_turn_it_on
    FmrbRdToken.pair(@board.addr, "042137")
    @board.guard = :closed
    e = assert_raises(FmrbRdToken::Denied) { get(@board.addr) }
    assert_equal "closed", e.guard
    assert_includes e.message, "A PC paired before needs nothing more"
  end

  def test_a_board_moved_by_dhcp_is_found_by_its_name
    FmrbRdToken.pair(@board.addr, "042137")
    # The board now answers at another address the store does not know: the
    # first request goes without a token, the 401 makes the tool ask /status,
    # and the name finds the token.
    other = "localhost:#{@board.port}"
    @board.status_ip = "192.0.2.77"
    @board.hits.clear
    status, = get(other)
    assert_equal 200, status
    tokens = @board.hits.reject { |m, p, _| p == "/status" }.map(&:last)
    assert_equal [nil, FakeBoard::TOKEN], tokens
    assert_equal "192.0.2.77", FmrbRdToken.load.dig("boards", "fmruby-c0ffee", "ip")
  end

  def test_revoked_on_the_board_asks_to_pair_again
    FmrbRdToken.pair(@board.addr, "042137")
    doc = FmrbRdToken.load
    doc["boards"]["fmruby-c0ffee"]["token"] = "f" * 32
    FmrbRdToken.save(doc)
    e = assert_raises(FmrbRdToken::Denied) { get(@board.addr) }
    assert_includes e.message, "pair <number>"
  end

  def test_forget
    FmrbRdToken.pair(@board.addr, "042137")
    assert FmrbRdToken.forget("fmruby-c0ffee.local")
    assert_nil FmrbRdToken.token_for("fmruby-c0ffee")
    refute FmrbRdToken.forget("fmruby-c0ffee")
  end

  def test_a_damaged_file_is_an_empty_store
    FileUtils.mkdir_p(FmrbRdToken.dir)
    File.write(FmrbRdToken.path, "{not json")
    assert_nil FmrbRdToken.token_for("fmruby-c0ffee")
    FmrbRdToken.pair(@board.addr, "042137")
    assert_equal FakeBoard::TOKEN, FmrbRdToken.token_for("fmruby-c0ffee")
  end
end
