#!/usr/bin/env ruby
# Host tests for the end of a storage sync (tools/fmrb_rd_fs.rb,
# FmrbStorageSync): when it sent anything it asks the desktop to read /app
# again (POST /app/rescan, fmruby-core main/drivers/devctl/devctl_http.c),
# since the launcher keeps the list it built at boot. Older firmware without
# the route, or a board that does not answer, gets a note and no failure.
# The sync runs against an in-memory board; FmrbFs#rescan_apps against a small
# fake HTTP board on a loopback port. Nothing touches ~/.config/fmrb or a
# real board.
#
#   ruby tools/fmrb_rd_fs_sync_test.rb
require "minitest/autorun"
require "socket"
require "tmpdir"
require "fileutils"
require "digest"

ENV["FMRB_CONFIG_DIR"] = File.join(Dir.mktmpdir("fmrb-sync-test"), "conf")
require_relative "fmrb_rd_fs"

# The board's files as a hash of path => content, with the calls the sync
# makes (list, md5, put, mkdir, walk) and rescan_apps answering as told.
class MemBoard
  attr_accessor :rescan
  attr_reader :files, :rescans

  def initialize(files = {})
    @files = files.dup
    @dirs = ["/"]
    @rescan = true
    @rescans = 0
  end

  def list(dir)
    names = {}
    (@files.keys + @dirs).each do |p|
      next if p == "/" || File.dirname(p) != dir
      names[File.basename(p)] = { "name" => File.basename(p), "dir" => @dirs.include?(p),
                                  "size" => (@files[p] || "").bytesize }
    end
    names.values
  end

  def md5(path)
    @files[path] && { "md5" => Digest::MD5.hexdigest(@files[path]) }
  end

  def put(path, data)
    @files[path] = data
  end

  def mkdir(path)
    @dirs << path unless @dirs.include?(path)
  end

  def walk(_path, skip: nil)
    (@files.keys + @dirs - ["/"]).map { |p| { "path" => p } }.reject { |e| skip&.call(e["path"]) }
  end

  def rescan_apps
    @rescans += 1
    raise @rescan if @rescan.is_a?(Exception)
    @rescan
  end
end

class FmrbStorageSyncRescanTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("fmrb-sync-root")
    FileUtils.mkdir_p(File.join(@root, "app/demo"))
    File.write(File.join(@root, "app/demo/hello.app.toml"), "hidden = true\n")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def sync(board, **opts)
    FmrbStorageSync.new(board, ->(_) {}).run(@root, **opts)
  end

  def test_asks_for_a_rescan_when_something_was_sent
    board = MemBoard.new
    r = sync(board)
    assert_equal 1, r[:sent]
    assert_equal 1, board.rescans
    assert_equal :asked, r[:rescan]
    assert_match(/read \/app again/, FmrbStorageSync.rescan_note(r[:rescan]))
  end

  def test_no_rescan_when_nothing_differs
    board = MemBoard.new("/app/demo/hello.app.toml" => "hidden = true\n")
    board.mkdir("/app")
    board.mkdir("/app/demo")
    r = sync(board)
    assert_equal 0, r[:sent]
    assert_equal 0, board.rescans
    assert_nil r[:rescan]
    assert_nil FmrbStorageSync.rescan_note(r[:rescan])
  end

  def test_no_rescan_on_a_dry_run
    board = MemBoard.new
    r = sync(board, dry_run: true)
    assert_equal 1, r[:sent]
    assert_equal 0, board.rescans
    assert_nil r[:rescan]
  end

  def test_older_firmware_gets_a_note_to_reboot
    board = MemBoard.new
    board.rescan = false
    r = sync(board)
    assert_equal :absent, r[:rescan]
    assert_match(/no \/app\/rescan.*reboot/, FmrbStorageSync.rescan_note(r[:rescan]))
  end

  def test_a_failed_rescan_does_not_fail_the_sync
    board = MemBoard.new
    board.rescan = FmrbFs::DeviceError.new("503 kernel busy")
    r = sync(board)
    assert_equal 1, r[:sent]
    assert_equal "503 kernel busy", r[:rescan]
    assert_match(/kernel busy.*reboot/, FmrbStorageSync.rescan_note(r[:rescan]))
  end
end

# POST /app/rescan answered as the firmware would: 200 {"ok":true}, 503
# {"ok":false,...} when the kernel's queue is full, 404 from firmware that
# does not have the route.
class RescanBoard
  attr_accessor :answer
  attr_reader :hits

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @answer = [200, '{"ok":true}']
    @hits = []
    @thread = Thread.new { loop { serve(@server.accept) } rescue nil }
  end

  def addr
    "127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(c)
    method, target, = c.gets.to_s.split
    while (h = c.gets.to_s) && !h.strip.empty?; end
    @hits << [method, target]
    status, body = @answer
    c.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  ensure
    c.close rescue nil
  end
end

class FmrbFsRescanTest < Minitest::Test
  def setup
    @board = RescanBoard.new
    @fs = FmrbFs.new(@board.addr)
  end

  def teardown
    @board.stop
  end

  def test_posts_app_rescan
    assert_equal true, @fs.rescan_apps
    assert_equal [["POST", "/app/rescan"]], @board.hits
  end

  def test_firmware_without_the_route
    @board.answer = [404, "This URI does not exist"]
    assert_equal false, @fs.rescan_apps
  end

  def test_kernel_busy_is_an_error
    @board.answer = [503, '{"ok":false,"err":"kernel busy"}']
    e = assert_raises(FmrbFs::DeviceError) { @fs.rescan_apps }
    assert_match(/kernel busy/, e.message)
  end
end
