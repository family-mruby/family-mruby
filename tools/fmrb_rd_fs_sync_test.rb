#!/usr/bin/env ruby
# Host tests for the end of a storage sync (tools/fmrb_rd_fs.rb,
# FmrbStorageSync): when it sent anything it asks the desktop to read /app
# again (POST /app/rescan, fmruby-core main/drivers/devctl/devctl_http.c),
# since the launcher keeps the list it built at boot. Older firmware without
# the route, or a board that does not answer, gets a note and no failure.
# Then the files of the system's part that the build no longer has (left
# over from an older image): which are chosen, how they are summed up, and
# that only prune deletes them.
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

  # Files with their folders, as the board's would be.
  def add(path, data = "x")
    @files[path] = data
    d = File.dirname(path)
    until d == "/"
      mkdir(d)
      d = File.dirname(d)
    end
  end

  def dirs = @dirs

  def walk(_path, skip: nil)
    (@files.keys + @dirs - ["/"]).sort.map do |p|
      { "path" => p, "dir" => @dirs.include?(p), "size" => (@files[p] || "").bytesize }
    end.reject { |e| skip&.call(e["path"]) }
  end

  def del(path)
    @files.delete(path) || @dirs.delete(path)
  end

  def rm_tree(path)
    (@files.keys + @dirs).select { |p| p.start_with?("#{path}/") }.each { |p| del(p) }
    del(path)
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

# What app_sync lists (and with prune deletes) after it sent the build's
# files: the system's part the build no longer has.
class FmrbStorageSyncLeftoverTest < Minitest::Test
  BUILD = %w[app/demo/hello.app.rb usr/share/doc/a.md help/index.txt etc/hid_devices.toml
             lib/templates/t.rb cache/.keep boot/boot.png bin/sh].freeze

  def setup
    @root = Dir.mktmpdir("fmrb-sync-root")
    BUILD.each do |r|
      FileUtils.mkdir_p(File.join(@root, File.dirname(r)))
      File.write(File.join(@root, r), "x")
    end
    @board = MemBoard.new
    BUILD.each { |r| @board.add("/#{r}", "x") }
    @log = []
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def sync(**opts)
    FmrbStorageSync.new(@board, ->(l) { @log << l }).run(@root, **opts)
  end

  def old_image
    @board.add("/usr/share/doc/old.md", "12345")
    @board.add("/usr/share/gone/one.png", "1234567890")
    @board.add("/usr/share/gone/two.png", "12")
    @board.add("/help/Old.txt", "123")
    @board.add("/app/demo/removed.app.rb", "1234")
    @board.add("/bin/x", "1")
    @board.add("/cache/launcher/icon.bmp", "12")
    @board.add("/etc/old.toml", "1")
  end

  def users_and_boards_own
    @board.add("/home/notes.txt")
    @board.add("/app/usr/mine.app.rb")
    @board.add("/app/test/t.app.rb")
    @board.add("/mnt/sd/x")
    @board.add("/tmp/x")
    @board.add("/var/log/x")
    @board.add("/var/cache/launcher_index")
    @board.add("/etc/system_conf.toml", "the board's settings")
    @board.add("/app/other/thing.app.rb") # a folder the image does not have
    @board.add("/data/x")
  end

  def test_the_system_part_is_chosen_and_counted
    old_image
    users_and_boards_own
    r = sync
    left = r[:leftover]
    # /etc is never among them (the board's settings live there).
    assert_equal ["/app/demo/removed.app.rb", "/bin/x", "/cache/launcher", "/help/Old.txt",
                  "/usr/share/doc/old.md", "/usr/share/gone"], left[:paths]
    assert_equal ["/cache/launcher", "/usr/share/gone"], left[:dirs]
    assert_equal 7, left[:files]
    assert_equal 5 + 10 + 2 + 3 + 4 + 1 + 2, left[:bytes]
    assert_equal 0, left[:deleted]
    # Not deleted without prune.
    assert @board.files.key?("/usr/share/gone/one.png")
    # The rest is listed as it was, but never what is kept.
    assert_equal ["/app/other", "/data"], r[:extra]
  end

  def test_kept_parts_are_never_listed
    users_and_boards_own
    r = sync(prune: true)
    assert_equal [], r[:leftover][:paths]
    all = r[:leftover][:paths] + r[:extra]
    %w[/home /app/usr /app/test /mnt /tmp /var /etc/system_conf.toml].each do |k|
      refute(all.any? { |p| p == k || p.start_with?("#{k}/") }, k)
    end
    assert_equal "the board's settings", @board.files["/etc/system_conf.toml"]
    assert @board.files.key?("/app/usr/mine.app.rb")
    assert @board.files.key?("/home/notes.txt")
  end

  def test_prune_deletes_them_and_nothing_else
    old_image
    users_and_boards_own
    r = sync(prune: true)
    assert_equal 7, r[:leftover][:deleted]
    gone = %w[/usr/share/doc/old.md /usr/share/gone/one.png /usr/share/gone/two.png /help/Old.txt
              /app/demo/removed.app.rb /bin/x /cache/launcher/icon.bmp]
    gone.each { |p| refute @board.files.key?(p), p }
    refute_includes @board.dirs, "/usr/share/gone"
    BUILD.each { |b| assert @board.files.key?("/#{b}"), b }
    %w[/home/notes.txt /app/usr/mine.app.rb /app/test/t.app.rb /data/x /app/other/thing.app.rb
       /etc/old.toml].each do |p|
      assert @board.files.key?(p), p
    end
    # Synced again: nothing left over.
    assert_equal [], sync(prune: true)[:leftover][:paths]
  end

  # What the build leaves out of its images (config/storage_exclude_*.txt
  # next to build/storage_root) was put over WiFi later: never a leftover.
  def test_what_the_images_leave_out_is_kept
    base = Dir.mktmpdir("fmrb-sync-core")
    root = File.join(base, "build", "storage_root")
    FileUtils.mkdir_p(root)
    FileUtils.cp_r(Dir.glob(File.join(@root, "*")), root)
    FileUtils.mkdir_p(File.join(base, "config"))
    File.write(File.join(base, "config", "storage_exclude_common.txt"),
               "# a comment\napp/demo/walk.app.rb   # put later\nusr/share/sprites/walk\n")
    @board.add("/app/demo/walk.app.rb", "1")
    @board.add("/usr/share/sprites/walk/a.png", "12")
    @board.add("/usr/share/doc/old.md", "12345")
    r = FmrbStorageSync.new(@board, ->(l) { @log << l }).run(root, prune: true)
    assert_equal ["/usr/share/doc/old.md"], r[:leftover][:paths]
    assert @board.files.key?("/app/demo/walk.app.rb")
    assert @board.files.key?("/usr/share/sprites/walk/a.png")
    assert_equal ["/app/demo/walk.app.rb", "/usr/share/sprites/walk"],
                 FmrbStorageSync.excluded_paths(root)
  ensure
    FileUtils.rm_rf(base) if base
  end

  def test_a_dry_run_deletes_nothing
    old_image
    r = sync(prune: true, dry_run: true)
    assert_equal 0, r[:leftover][:deleted]
    assert @board.files.key?("/bin/x")
  end

  def test_the_summary_lines
    old_image
    r = sync
    lines = FmrbStorageSync.leftover_lines(r[:leftover], prune: false)
    assert_match(/7 files, 27 bytes/, lines[0])
    assert_includes lines, "  /usr/share/gone/"
    assert_equal "left as they are (PRUNE=1 deletes them)", lines.last
    assert_equal 1 + 6 + 1, lines.size
    r = sync(prune: true)
    assert_equal "deleted 7 files", FmrbStorageSync.leftover_lines(r[:leftover], prune: true).last
    assert_equal [], FmrbStorageSync.leftover_lines(sync[:leftover], prune: false)
  end

  def test_a_long_list_is_cut
    12.times { |i| @board.add("/usr/share/old#{i}.txt") }
    lines = FmrbStorageSync.leftover_lines(sync[:leftover], prune: false)
    assert_equal "  ... and 4 more", lines[-2]
    assert_equal 1 + FmrbStorageSync::LIST_HEAD + 2, lines.size
  end
end
