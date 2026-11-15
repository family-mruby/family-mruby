#!/usr/bin/env ruby
# Move files to and from a board over WiFi, through the development file
# endpoints (/fs/list, /fs/get, /fs/put, /fs/del, /fs/mkdir, /fs/md5;
# fmruby-core main/drivers/devctl/devctl_http.c, on the remote desktop's
# server on Modern and a small server of its own on Retro).
#
# BLE was the only way to get a file off the device and it tops out at a few
# tens of KB/s -- fine for a .rb, hopeless for the JPEGs PicoRabbit exports or
# an MJPEG clip. WiFi moves several hundred KB/s. A development build
# (FMRB_DEV_REMOTE_CTL) reaches every path, the keys included; firmware from
# before 2026-11-15 refuses anything outside /app, /home, /usr/share and
# /mnt/sd and never hands out a key (fmruby-core doc/remote_guard/plan.md).
#
# One-shot form:
#
#   ruby tools/fmrb_rd_fs.rb <IP> ls    <path>              # entries, sizes
#   ruby tools/fmrb_rd_fs.rb <IP> get   <path> [local]      # download
#   ruby tools/fmrb_rd_fs.rb <IP> put   <local> <path>      # upload (atomic on the device)
#   ruby tools/fmrb_rd_fs.rb <IP> del   <path>              # file, or empty directory
#   ruby tools/fmrb_rd_fs.rb <IP> mkdir <path>
#   ruby tools/fmrb_rd_fs.rb <IP> pull  <path> <local_dir>  # download a tree
#   ruby tools/fmrb_rd_fs.rb <IP> push  <local_dir> <path>  # upload a tree (directories made as needed)
#   ruby tools/fmrb_rd_fs.rb <IP> rmr   <path>              # delete a tree
#
# pull and push skip a file whose size already matches on the other side;
# add --force to copy everything.
#
# /home with its keys, and the storage tree of a build (fmruby-core
# doc/dev_remote_ctl/plan.md, "the development build"):
#
#   ruby tools/fmrb_rd_fs.rb <IP> backup  [dir] [--machine m] [--mac xxxxxx]
#   ruby tools/fmrb_rd_fs.rb <IP> restore <dir> [--force]
#   ruby tools/fmrb_rd_fs.rb <IP> sync    <storage_root> [--dry-run] [--conf]
#   ruby tools/fmrb_rd_fs.rb <IP> wait    [--timeout s] [--name fmruby-xxxxxx] [--after-reboot]
#   ruby tools/fmrb_rd_fs.rb <IP> reboot
#
# backup copies the board's /home (keys and passwords included) into dir,
# by default ~/asterism_keys/devices/<machine>-<MAC last 3>/home_backup_<time>/
# (directories 700, files 600; the machine and the MAC come from /status).
# Each file is checked against the board's MD5, and a manifest.json written
# last records every file and directory (empty ones too). Run it again on the
# same dir to finish an interrupted one: what is already there and matches is
# kept. restore writes dir/home back (directories first, then the files that
# differ, each checked after it lands) and lists what the board has in /home
# that the backup does not, without deleting it. Neither prints a file's
# contents. LittleFS keeps no owner, mode or time, so names, contents and
# directories are all there is to keep.
#
# sync sends what differs between a build's storage tree (build/storage_root)
# and the board, leaving /home, /tmp, /mnt, /var/cache and the saved settings
# (/etc/system_conf.toml; --conf sends it too) alone: a missing file or a
# different size is sent, an equal size is compared by MD5. Files the board
# has and the build does not are listed, never deleted. This is what follows
# an app-only flash (rake flash:app_sync).
#
# What no storage image carries (fmruby-core config/storage_exclude_common.txt)
# is put on a board when it is wanted (fmruby-core doc/flash_layout F0-F1):
#
#   ruby tools/fmrb_rd_fs.rb <IP> tests push [name...] [--reserve KB] [--flash DIR]
#   ruby tools/fmrb_rd_fs.rb <IP> tests clean           # all of /app/test
#   ruby tools/fmrb_rd_fs.rb <IP> tests ls
#   ruby tools/fmrb_rd_fs.rb <IP> extra walk_scroller [--remove]
#   ruby tools/fmrb_rd_fs.rb <IP> df [path]             # free space (/fs/df)
#
# tests push sends the named test apps (base names: ckpt_counter takes
# ckpt_counter.app.rb, .app.toml and whatever else bears that name; none named
# sends all of flash/app/test) to /app/test, only what is missing or differs
# in size. When that would leave less than the reserve free (512 KB unless
# --reserve), it first deletes the test files put there earliest that this
# push does not need. tests clean at the end of a series of tests deletes
# /app/test. extra puts an optional app from flash/ (or any path under it) on
# the board, --remove takes it away.
#
# wait polls /status until the board answers (after a flash or a reboot) and
# prints ip=<address>; --name re-resolves the board's mDNS name when the
# address stops answering (DHCP may hand out another). reboot restarts it.
#
# Interactive form -- give only the address and you get a prompt, like an
# FTP client, with a current directory on the device and one on the PC:
#
#   ruby tools/fmrb_rd_fs.rb <IP>
#   /mnt/sd> ls
#   /mnt/sd> cd picorabbit/intro_ja
#   /mnt/sd/picorabbit/intro_ja> pull . ./exports
#   /mnt/sd/picorabbit/intro_ja> lcd ~/slides
#   /mnt/sd/picorabbit/intro_ja> push . /mnt/sd/slides
#   /mnt/sd/picorabbit/intro_ja> help
#
# A typical development loop: put the app, launch it, look, kill it.
#
#   ruby tools/fmrb_rd_fs.rb $IP put my.app.rb /app/test/my.app.rb
#   ruby tools/fmrb_rd_launch.rb $IP /app/test/my.app.rb
#
# Exit status is 0 on success, 1 when the device answered with an error
# (in the interactive form an error is printed and the prompt comes back).

require "net/http"
require "json"
require "uri"
require "digest"
require "fileutils"
require "socket"
require "time"

class FmrbFs
  class DeviceError < StandardError; end

  attr_reader :host

  def initialize(host)
    @host = host
  end

  # ---- the five endpoints ----

  def list(path)
    expect_ok(request(Net::HTTP::Get, "/fs/list", path))["entries"]
  end

  def get(path)
    res = request(Net::HTTP::Get, "/fs/get", path)
    expect_ok(res) if res.code != "200"
    res.body
  end

  def put(path, data)
    expect_ok(request(Net::HTTP::Put, "/fs/put", path, body: data))
  end

  def del(path)
    expect_ok(request(Net::HTTP::Delete, "/fs/del", path))
  end

  def mkdir(path)
    expect_ok(request(Net::HTTP::Post, "/fs/mkdir", path))
  end

  # ---- the board ----

  def status
    uri = URI("http://#{@host}/status")
    res = Net::HTTP.start(uri.host, uri.port, read_timeout: 5, open_timeout: 5) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    raise DeviceError, "#{res.code} /status" unless res.code == "200"
    JSON.parse(res.body)
  end

  # { "md5" => hex, "size" => n }, or nil when the firmware has no /fs/md5
  # (before 2026-11-15): the callers then fall back to the size.
  def md5(path)
    res = request(Net::HTTP::Get, "/fs/md5", path)
    doc = JSON.parse(res.body) rescue nil
    return nil if res.code == "404" && !(doc.is_a?(Hash) && doc.key?("ok"))
    expect_ok(res)
  end

  # { "total" => bytes, "free" => bytes } of the filesystem under path, or
  # nil when the firmware has no /fs/df (before 2026-11-16).
  def df(path = "/")
    res = request(Net::HTTP::Get, "/fs/df", path)
    doc = JSON.parse(res.body) rescue nil
    return nil if res.code == "404" && !(doc.is_a?(Hash) && doc.key?("ok"))
    expect_ok(res)
  end

  # Whether the firmware answers /fs/md5 at all (asked once).
  def md5_supported?
    return @md5_supported unless @md5_supported.nil?
    res = request(Net::HTTP::Get, "/fs/md5", "/")
    doc = JSON.parse(res.body) rescue nil
    @md5_supported = !(res.code == "404" && !(doc.is_a?(Hash) && doc.key?("ok")))
  end

  def reboot
    uri = URI("http://#{@host}/sys/reboot")
    res = Net::HTTP.start(uri.host, uri.port, read_timeout: 10, open_timeout: 5) do |http|
      http.request(Net::HTTP::Post.new(uri))
    end
    raise DeviceError, "404: this firmware has no /sys/reboot (before 2026-11-15)" if res.code == "404"
    expect_ok(res)
  end

  # ---- trees ----

  # Download everything under path into local (created if missing).
  # Returns the number of files copied.
  def pull_tree(path, local, force, log = nil)
    Dir.mkdir(local) unless File.directory?(local)
    count = 0
    list(path).each do |e|
      remote = join(path, e["name"])
      target = File.join(local, e["name"])
      if e["dir"]
        count += pull_tree(remote, target, force, log)
        next
      end
      next if !force && File.file?(target) && File.size(target) == e["size"]
      data = get(remote)
      File.binwrite(target, data)
      log&.call("  #{remote} (#{data.bytesize} bytes)")
      count += 1
    end
    count
  end

  # Upload everything under local to path, making directories on the way.
  def push_tree(local, path, force, log = nil)
    mkdir(path)
    have = {}
    list(path).each { |e| have[e["name"]] = e }
    count = 0
    Dir.children(local).sort.each do |name|
      src = File.join(local, name)
      remote = join(path, name)
      if File.directory?(src)
        count += push_tree(src, remote, force, log)
        next
      end
      next unless File.file?(src)
      e = have[name]
      next if !force && e && !e["dir"] && e["size"] == File.size(src)
      data = File.binread(src)
      put(remote, data)
      log&.call("  #{remote} (#{data.bytesize} bytes)")
      count += 1
    end
    count
  end

  # Delete a tree, deepest entries first, then path itself.
  def rm_tree(path)
    count = 0
    list(path).each do |e|
      remote = join(path, e["name"])
      if e["dir"]
        count += rm_tree(remote)
      else
        del(remote)
        count += 1
      end
    end
    del(path)
    count + 1
  end

  def join(dir, name)
    dir.end_with?("/") ? dir + name : "#{dir}/#{name}"
  end

  # Every entry under path, depth first: [{ "path", "dir", "size" }].
  # skip: a predicate on a directory's path; a skipped directory is listed but
  # not entered. A directory that cannot be listed below the starting one (a
  # mount point with nothing mounted, such as /mnt/sd without a card) is
  # listed and left alone instead of failing the whole walk.
  def walk(path, out = [], skip: nil)
    list(path).sort_by { |e| e["name"] }.each do |e|
      remote = join(path, e["name"])
      out << { "path" => remote, "dir" => e["dir"], "size" => e["size"] }
      next unless e["dir"]
      next if skip&.call(remote)
      begin
        walk(remote, out, skip: skip)
      rescue DeviceError
        next
      end
    end
    out
  end

  private

  def request(klass, route, path, body: nil)
    uri = URI("http://#{@host}#{route}?path=#{URI.encode_www_form_component(path)}")
    req = klass.new(uri)
    if body
      req.body = body
      req["Content-Type"] = "application/octet-stream"
    end
    Net::HTTP.start(uri.host, uri.port, read_timeout: 120, open_timeout: 10) do |http|
      http.request(req)
    end
  end

  # JSON answers carry ok:true/false; raise with the device's reason when false.
  def expect_ok(res)
    doc = JSON.parse(res.body) rescue nil
    if doc.nil? || doc["ok"] != true
      err = doc ? doc["err"] : res.body[0, 200]
      raise DeviceError, "#{res.code} #{err}"
    end
    doc
  end
end

# ---- /home backup and restore, the storage sync, waiting for a board ----

module FmrbBoard
  module_function

  # FmrbConst::BOARD -> the name ~/asterism_keys/devices/ uses for it.
  MACHINE_DIRS = { "naryav4" => "p4nano", "narya_v3" => "naryav3" }.freeze
  KEYS_DIR = File.expand_path("~/asterism_keys/devices")

  # An address for a name. A board's mDNS name (fmruby-XXXXXX.local) is not
  # resolvable everywhere: WSL has no mDNS of its own and borrows Windows'.
  def resolve(host)
    return host if host =~ /\A\d{1,3}(\.\d{1,3}){3}(:\d+)?\z/
    begin
      addr = Addrinfo.getaddrinfo(host, 80, Socket::AF_INET).first
      return addr.ip_address if addr
    rescue SocketError
      nil
    end
    if host.end_with?(".local") && File.exist?("/proc/sys/fs/binfmt_misc/WSLInterop")
      out = IO.popen(["powershell.exe", "-NoProfile", "-Command",
                      "(Resolve-DnsName #{host} -ErrorAction SilentlyContinue | " \
                      "Where-Object Type -eq 'A').IPAddress"], err: File::NULL, &:read) rescue ""
      ip = out.to_s[/\b(?:\d{1,3}\.){3}\d{1,3}\b/]
      return ip if ip
    end
    nil
  end

  # <machine>-<MAC last 3> from /status (firmware since 2026-11-15 says
  # "board" and "host"); either can be given instead.
  def device_dir_name(status, machine: nil, mac: nil)
    board = status && status["board"]
    machine ||= MACHINE_DIRS.fetch(board, board) if board
    mac ||= status["host"].to_s[/-(\h{6})\z/, 1] if status
    unless machine && mac
      raise ArgumentError, "cannot tell which board this is (its /status has no board/host: " \
                           "firmware before 2026-11-15) -- give --machine and --mac, or a directory"
    end
    "#{machine}-#{mac.downcase}"
  end

  def private_mkdir(dir)
    missing = []
    d = File.expand_path(dir)
    until File.directory?(d)
      missing.unshift(d)
      d = File.dirname(d)
    end
    missing.each { |m| Dir.mkdir(m, 0o700) }
    File.chmod(0o700, dir)
  end
end

class FmrbHome
  ROOT = "/home"

  def initialize(fs, log)
    @fs = fs
    @log = log
  end

  # Copy the board's /home into dir/home and write dir/manifest.json last.
  def backup(dir)
    old_umask = File.umask(0o077)
    FmrbBoard.private_mkdir(dir)
    local_root = File.join(dir, "home")
    FmrbBoard.private_mkdir(local_root)
    status = (@fs.status rescue {})
    entries = @fs.walk(ROOT)
    md5_ok = @fs.md5_supported?
    manifest = { "complete" => false, "board" => status["board"], "host" => status["host"],
                 "ip" => status["ip"], "started" => Time.now.iso8601, "entries" => [] }
    write_manifest(dir, manifest)
    copied = kept = bytes = 0
    entries.each do |e|
      local = File.join(local_root, rel(e["path"]))
      if e["dir"]
        FmrbBoard.private_mkdir(local)
        manifest["entries"] << { "path" => e["path"], "dir" => true }
        next
      end
      remote_sum = md5_ok ? @fs.md5(e["path"]) : nil
      if File.file?(local) && File.size(local) == e["size"] &&
         (remote_sum.nil? || Digest::MD5.file(local).hexdigest == remote_sum["md5"])
        kept += 1
      else
        fetch(e["path"], local, remote_sum)
        copied += 1
        @log.call("  #{e['path']} (#{File.size(local)} bytes)")
      end
      bytes += File.size(local)
      manifest["entries"] << { "path" => e["path"], "size" => File.size(local),
                               "md5" => Digest::MD5.file(local).hexdigest }
    end
    manifest["complete"] = true
    manifest["finished"] = Time.now.iso8601
    write_manifest(dir, manifest)
    files = manifest["entries"].count { |m| !m["dir"] }
    dirs = manifest["entries"].count { |m| m["dir"] }
    { files: files, dirs: dirs, bytes: bytes, copied: copied, kept: kept, verified: md5_ok }
  ensure
    File.umask(old_umask) if old_umask
  end

  # Write dir/home back into the board's /home.
  def restore(dir, force)
    local_root = File.join(dir, "home")
    raise ArgumentError, "#{local_root} is not a directory" unless File.directory?(local_root)
    manifest_file = File.join(dir, "manifest.json")
    if File.exist?(manifest_file)
      m = JSON.parse(File.read(manifest_file))
      unless m["complete"]
        raise ArgumentError, "#{dir} is an interrupted backup (manifest.json says complete: false); " \
                             "run backup on it again first"
      end
    end
    @fs.mkdir(ROOT)
    on_board = {}
    @fs.walk(ROOT).each { |e| on_board[e["path"]] = e }
    sent = same = bytes = 0
    local_entries(local_root).each do |path, local|
      if File.directory?(local)
        @fs.mkdir(path) unless on_board[path] && on_board[path]["dir"]
        next
      end
      data = File.binread(local)
      sum = Digest::MD5.hexdigest(data)
      have = on_board[path]
      if !force && have && !have["dir"] && have["size"] == data.bytesize
        remote = @fs.md5(path)
        if remote.nil? || remote["md5"] == sum
          same += 1
          next
        end
      end
      @fs.put(path, data)
      check = @fs.md5(path)
      if check && check["md5"] != sum
        raise FmrbFs::DeviceError, "#{path}: the board's copy does not match after the put"
      end
      sent += 1
      bytes += data.bytesize
      @log.call("  #{path} (#{data.bytesize} bytes)")
    end
    backed = local_entries(local_root).map(&:first)
    extra = on_board.keys.reject { |p| backed.include?(p) }.sort
    { sent: sent, same: same, bytes: bytes, extra: extra }
  end

  private

  def rel(path)
    path.delete_prefix(ROOT).delete_prefix("/")
  end

  # [[device path, local path]], parents before children.
  def local_entries(local_root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: local_root)
       .reject { |r| File.basename(r) == "." || File.basename(r) == ".." || r.end_with?(".part") }
       .sort
       .map { |r| ["#{ROOT}/#{r}", File.join(local_root, r)] }
  end

  # A file lands under .part and is renamed only once it is whole and matches
  # the board's MD5, so an interrupted run never leaves a short file that
  # looks finished. One retry for a transfer that came out wrong.
  def fetch(path, local, remote_sum)
    2.times do |attempt|
      data = @fs.get(path)
      ok = remote_sum ? Digest::MD5.hexdigest(data) == remote_sum["md5"] : true
      if ok
        part = "#{local}.part"
        File.open(part, "wb", 0o600) { |f| f.write(data) }
        File.rename(part, local)
        return
      end
      raise FmrbFs::DeviceError, "#{path}: two downloads did not match the board's MD5" if attempt == 1
    end
  end

  def write_manifest(dir, manifest)
    file = File.join(dir, "manifest.json")
    File.open("#{file}.part", "w", 0o600) { |f| f.write(JSON.pretty_generate(manifest)) }
    File.rename("#{file}.part", file)
  end
end

class FmrbStorageSync
  # The board's own: the user's files, RAM, the card, caches, the settings it saves.
  SKIP = ["/home", "/tmp", "/mnt", "/var/cache"].freeze
  CONF = "/etc/system_conf.toml"

  def initialize(fs, log)
    @fs = fs
    @log = log
    @lists = {}
  end

  def run(local_root, dry_run: false, conf: false)
    raise ArgumentError, "#{local_root} is not a directory" unless File.directory?(local_root)
    skip = conf ? SKIP : SKIP + [CONF]
    sent = same = bytes = 0
    held = []
    local = {}
    Dir.glob("**/*", File::FNM_DOTMATCH, base: local_root).sort.each do |r|
      next if File.basename(r) == "." || File.basename(r) == ".."
      path = "/#{r}"
      next if skipped?(path, skip)
      full = File.join(local_root, r)
      local[path] = true
      if File.directory?(full)
        @fs.mkdir(path) unless dry_run || board_entry(path)&.fetch("dir")
        next
      end
      have = board_entry(path)
      size = File.size(full)
      if have && !have["dir"] && have["size"] == size
        remote = @fs.md5(path)
        raise FmrbFs::DeviceError, "this firmware has no /fs/md5 (before 2026-11-15): sync cannot compare" if remote.nil?
        if remote["md5"] == Digest::MD5.file(full).hexdigest
          same += 1
          next
        end
      end
      @fs.put(path, File.binread(full)) unless dry_run
      sent += 1
      bytes += size
      @log.call("  #{dry_run ? 'would send' : 'sent'} #{path} (#{size} bytes)")
    end
    if !conf && File.file?(File.join(local_root, CONF.delete_prefix("/")))
      have = board_entry(CONF)
      remote = have && @fs.md5(CONF)
      if remote.nil? || remote["md5"] != Digest::MD5.file(File.join(local_root, CONF.delete_prefix("/"))).hexdigest
        held << CONF
      end
    end
    extra = board_only(local, skip)
    { sent: sent, same: same, bytes: bytes, extra: extra, held: held }
  end

  private

  def skipped?(path, skip)
    skip.any? { |s| path == s || path.start_with?("#{s}/") }
  end

  def board_list(dir)
    @lists[dir] ||= begin
      @fs.list(dir).to_h { |e| [e["name"], e] }
    rescue FmrbFs::DeviceError
      {}
    end
  end

  def board_entry(path)
    board_list(File.dirname(path))[File.basename(path)]
  end

  # Files and directories on the board under the synced part that the build
  # does not have: listed for a person to decide, never deleted.
  def board_only(local, skip)
    out = []
    @fs.walk("/", skip: ->(p) { skipped?(p, skip) }).each do |e|
      next if skipped?(e["path"], skip)
      out << e["path"] unless local[e["path"]]
    end
    # A directory the build lacks: list it, not each file inside.
    out.reject { |p| out.any? { |q| q != p && p.start_with?("#{q}/") } }
  end
end

# Poll /status until the board answers. With after_reboot, first wait (up to
# 20 s) for it to stop answering: the reboot has not happened yet when
# /sys/reboot replies.
def wait_for_board(host, timeout:, name: nil, after_reboot: false, log: ->(_) {})
  deadline = Time.now + timeout
  if after_reboot
    down_by = [Time.now + 20, deadline].min
    while Time.now < down_by
      break unless (FmrbFs.new(host).status rescue nil)
      sleep 1
    end
  end
  silent_since = Time.now
  current = host
  while Time.now < deadline
    st = (FmrbFs.new(current).status rescue nil)
    return [current, st] if st
    if name && Time.now - silent_since > 15
      ip = FmrbBoard.resolve(name.end_with?(".local") ? name : "#{name}.local")
      if ip && ip != current
        log.call("#{current} is silent; #{name} now resolves to #{ip}")
        current = ip
      end
      silent_since = Time.now
    end
    sleep 2
  end
  nil
end

# ---- output helpers shared by both forms ----

def print_listing(entries)
  entries.sort_by { |e| [e["dir"] ? 0 : 1, e["name"]] }.each do |e|
    puts format("%s %10s  %s", e["dir"] ? "d" : "-", e["dir"] ? "" : e["size"], e["name"])
  end
end

def rate(bytes, seconds)
  seconds > 0 ? format("%.1f KB/s", bytes / 1024.0 / seconds) : "-"
end

def timed
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  [r, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0]
end

# ---- one-shot form ----

def one_shot(fs, cmd, args)
  force = args.delete("--force")
  case cmd
  when "ls"
    path = args.shift or abort "ls needs a path"
    print_listing(fs.list(path))
  when "get"
    path = args.shift or abort "get needs a path"
    local = args.shift || File.basename(path)
    data, dt = timed { fs.get(path) }
    File.binwrite(local, data)
    puts "#{path} -> #{local} (#{data.bytesize} bytes, #{rate(data.bytesize, dt)})"
  when "put"
    local = args.shift or abort "put needs a local file and a device path"
    path = args.shift or abort "put needs a device path"
    data = File.binread(local)
    _, dt = timed { fs.put(path, data) }
    puts "#{local} -> #{path} (#{data.bytesize} bytes, #{rate(data.bytesize, dt)})"
  when "del"
    path = args.shift or abort "del needs a path"
    fs.del(path)
    puts "deleted #{path}"
  when "mkdir"
    path = args.shift or abort "mkdir needs a path"
    doc = fs.mkdir(path)
    puts(doc["existed"] ? "exists #{path}" : "created #{path}")
  when "pull"
    path = args.shift or abort "pull needs a device path and a local directory"
    local = args.shift or abort "pull needs a local directory"
    n = fs.pull_tree(path, local, force, ->(s) { puts s })
    puts "pulled #{n} files from #{path} to #{local}"
  when "push"
    local = args.shift or abort "push needs a local directory and a device path"
    path = args.shift or abort "push needs a device path"
    abort "#{local} is not a directory" unless File.directory?(local)
    n = fs.push_tree(local, path, force, ->(s) { puts s })
    puts "pushed #{n} files from #{local} to #{path}"
  when "rmr"
    path = args.shift or abort "rmr needs a path"
    n = fs.rm_tree(path)
    puts "deleted #{n} entries under #{path}"
  when "backup"
    machine = option(args, "--machine")
    mac = option(args, "--mac")
    dir = args.shift
    unless dir
      name = FmrbBoard.device_dir_name((fs.status rescue nil), machine: machine, mac: mac)
      dir = File.join(FmrbBoard::KEYS_DIR, name, "home_backup_#{Time.now.strftime('%Y%m%d-%H%M%S')}")
    end
    r, dt = timed { FmrbHome.new(fs, ->(s) { puts s }).backup(dir) }
    puts "backed up /home: #{r[:files]} files, #{r[:dirs]} directories, #{r[:bytes]} bytes " \
         "(#{r[:copied]} copied, #{r[:kept]} already there, #{format('%.0f', dt)} s)" \
         "#{r[:verified] ? ', each checked by MD5' : ', sizes only (no /fs/md5 on this firmware)'}"
    puts "backup=#{File.expand_path(dir)}"
  when "restore"
    dir = args.shift or abort "restore needs the backup directory"
    r, dt = timed { FmrbHome.new(fs, ->(s) { puts s }).restore(File.expand_path(dir), force) }
    puts "restored /home: #{r[:sent]} files sent (#{r[:bytes]} bytes), #{r[:same]} already the same " \
         "(#{format('%.0f', dt)} s)"
    unless r[:extra].empty?
      puts "on the board but not in the backup (left as they are):"
      r[:extra].each { |p| puts "  #{p}" }
    end
  when "sync"
    root = args.shift or abort "sync needs the storage tree (fmruby-core/build/storage_root)"
    dry = args.delete("--dry-run")
    conf = args.delete("--conf")
    r, dt = timed { FmrbStorageSync.new(fs, ->(s) { puts s }).run(root, dry_run: dry, conf: conf) }
    puts "#{dry ? 'would send' : 'sent'} #{r[:sent]} files (#{r[:bytes]} bytes), " \
         "#{r[:same]} already the same (#{format('%.0f', dt)} s)"
    r[:held].each do |p|
      puts "#{p} differs and was kept: it holds the board's saved settings (--conf sends the build's)"
    end
    unless r[:extra].empty?
      puts "on the board but not in the build (left as they are):"
      r[:extra].each { |p| puts "  #{p}" }
    end
  when "wait"
    timeout = (option(args, "--timeout") || "180").to_i
    name = option(args, "--name")
    after = args.delete("--after-reboot")
    got = wait_for_board(fs.host, timeout: timeout, name: name, after_reboot: after,
                         log: ->(s) { puts s })
    abort "the board did not answer /status within #{timeout} s" unless got
    puts "ip=#{got[0]}"
  when "reboot"
    fs.reboot
    puts "rebooting #{fs.host}"
  when "df"
    path = args.shift || "/"
    d = fs.df(path) or abort "this firmware has no /fs/df (before 2026-11-16)"
    puts "#{path}: #{d['free'] / 1024} KB free of #{d['total'] / 1024} KB"
  when "tests"
    flash = option(args, "--flash")
    reserve = (option(args, "--reserve") || FmrbDevFiles::RESERVE_KB).to_i
    dev = FmrbDevFiles.new(fs, ->(s) { puts s }, **(flash ? { flash: File.expand_path(flash) } : {}))
    case (sub = args.shift)
    when "push"
      r, dt = timed { dev.push_tests(args, reserve_kb: reserve) }
      puts "tests: sent #{r[:sent]} files (#{r[:bytes]} bytes), #{r[:same]} already there " \
           "(#{format('%.0f', dt)} s)"
    when "clean"
      n = dev.clean_tests
      puts(n.zero? ? "tests: no #{FmrbDevFiles::TEST_DIR} on the board" : "tests: deleted #{n} entries under #{FmrbDevFiles::TEST_DIR}")
    when "ls"
      dev.list_tests.each do |p, size, at|
        puts format("%8d  %-19s  %s", size, at ? at.strftime("%Y-%m-%d %H:%M:%S") : "-", p)
      end
    else
      abort "tests push [name...] [--reserve KB] [--flash DIR] | tests clean | tests ls (got #{sub.inspect})"
    end
  when "extra"
    flash = option(args, "--flash")
    remove = args.delete("--remove")
    dev = FmrbDevFiles.new(fs, ->(s) { puts s }, **(flash ? { flash: File.expand_path(flash) } : {}))
    if remove
      puts "extra: deleted #{dev.uninstall(args)} entries"
    else
      r, dt = timed { dev.install(args) }
      puts "extra: sent #{r[:sent]} files (#{r[:bytes]} bytes), #{r[:same]} already there " \
           "(#{format('%.0f', dt)} s); the launcher lists it after a rescan (right click on the desktop)"
    end
  else
    abort "unknown command #{cmd} (ls|get|put|del|mkdir|pull|push|rmr|backup|restore|sync|wait|reboot|df|tests|extra)"
  end
end

# "--key value" out of args, or nil.
def option(args, key)
  i = args.index(key)
  return nil unless i
  args.delete_at(i)
  args.delete_at(i)
end

# ---- interactive form ----

HELP = <<~TEXT
  ls [path]            list (device)        lls [path]     list (PC)
  cd <path>            change dir (device)  lcd <path>     change dir (PC)
  pwd                  show both dirs
  get <file> [local]   download a file      put <local> [file]   upload a file
  pull <dir> <local>   download a tree      push <local> <dir>   upload a tree
  rm <path>            delete file/empty dir   rmr <dir>   delete a tree (asks)
  mkdir <path>         make a directory     cat <file>     show a text file
  launch <app.rb>      start an app (/app/launch)   ps    list apps
  help                 this text            quit / exit / Ctrl-D
  Device paths are relative to the device dir unless they start with "/";
  PC paths are relative to the PC dir. --force on pull/push copies everything.
TEXT

# Device-side path arithmetic: relative to base unless absolute, with "."
# and ".." folded so the device never sees them (it would refuse "..").
def resolve(base, p)
  return base if p.nil? || p == "."
  abs = p.start_with?("/") ? p : "#{base}/#{p}"
  parts = []
  abs.split("/").each do |seg|
    next if seg.empty? || seg == "."
    if seg == ".."
      parts.pop
    else
      parts << seg
    end
  end
  "/" + parts.join("/")
end

# The Nth word of the line, or an ArgumentError carrying the usage text.
def need(args, i, usage)
  args[i] or raise(ArgumentError, usage)
end

def interactive(host, fs)
  # Line editing and history on a terminal; plain reads when the input is a
  # pipe (a scripted session), where Reline would repaint every character.
  reader = nil
  if $stdin.tty?
    begin
      require "reline"
      reader = ->(prompt) { Reline.readline(prompt, true) }
    rescue LoadError
      reader = nil
    end
  end
  reader ||= ->(prompt) { print prompt; $stdout.flush; $stdin.gets&.chomp }
  cwd = "/mnt/sd"
  lcwd = Dir.pwd
  puts "connected to #{host}. type help for commands."
  loop do
    line = reader.call("#{cwd}> ")
    break if line.nil?
    args = line.strip.split(/\s+/)
    next if args.empty?
    cmd = args.shift
    force = args.delete("--force")
    begin
      case cmd
      when "ls"
        print_listing(fs.list(resolve(cwd, args[0])))
      when "lls"
        dir = File.expand_path(args[0] || ".", lcwd)
        Dir.children(dir).sort.each do |n|
          full = File.join(dir, n)
          puts format("%s %10s  %s", File.directory?(full) ? "d" : "-",
                      File.directory?(full) ? "" : File.size(full), n)
        end
      when "cd"
        target = resolve(cwd, args[0] || "/mnt/sd")
        fs.list(target)  # fails loudly if it is not a directory
        cwd = target
      when "lcd"
        lcwd = File.expand_path(args[0] || "~", lcwd)
        puts lcwd
      when "pwd"
        puts "device: #{cwd}\nPC:     #{lcwd}"
      when "get"
        path = resolve(cwd, need(args, 0, "get <file> [local]"))
        local = File.expand_path(args[1] || File.basename(path), lcwd)
        data, dt = timed { fs.get(path) }
        File.binwrite(local, data)
        puts "#{path} -> #{local} (#{data.bytesize} bytes, #{rate(data.bytesize, dt)})"
      when "put"
        local = File.expand_path(need(args, 0, "put <local> [file]"), lcwd)
        path = resolve(cwd, args[1] || File.basename(local))
        data = File.binread(local)
        _, dt = timed { fs.put(path, data) }
        puts "#{local} -> #{path} (#{data.bytesize} bytes, #{rate(data.bytesize, dt)})"
      when "pull"
        path = resolve(cwd, need(args, 0, "pull <dir> <local>"))
        local = File.expand_path(need(args, 1, "pull <dir> <local>"), lcwd)
        n = fs.pull_tree(path, local, force, ->(s) { puts s })
        puts "pulled #{n} files"
      when "push"
        local = File.expand_path(need(args, 0, "push <local> <dir>"), lcwd)
        path = resolve(cwd, need(args, 1, "push <local> <dir>"))
        raise ArgumentError, "#{local} is not a directory" unless File.directory?(local)
        n = fs.push_tree(local, path, force, ->(s) { puts s })
        puts "pushed #{n} files"
      when "rm", "del"
        path = resolve(cwd, need(args, 0, "rm <path>"))
        fs.del(path)
        puts "deleted #{path}"
      when "rmr"
        path = resolve(cwd, need(args, 0, "rmr <dir>"))
        print "delete everything under #{path}? [y/N] "
        $stdout.flush
        if $stdin.gets.to_s.strip.downcase == "y"
          puts "deleted #{fs.rm_tree(path)} entries"
        end
      when "mkdir"
        path = resolve(cwd, need(args, 0, "mkdir <path>"))
        doc = fs.mkdir(path)
        puts(doc["existed"] ? "exists #{path}" : "created #{path}")
      when "cat"
        path = resolve(cwd, need(args, 0, "cat <file>"))
        puts fs.get(path)
      when "launch"
        path = resolve(cwd, need(args, 0, "launch <app.rb>"))
        res = Net::HTTP.post(URI("http://#{host}/app/launch?path=#{URI.encode_www_form_component(path)}"), "")
        puts res.body
      when "ps"
        puts Net::HTTP.get(URI("http://#{host}/app/list"))
      when "help", "?"
        puts HELP
      when "quit", "exit", "q"
        break
      else
        puts "unknown command #{cmd} (help for the list)"
      end
    rescue FmrbFs::DeviceError, ArgumentError, Errno::ENOENT, Errno::EISDIR => e
      puts "error: #{e.message}"
    end
  end
end

# ---- files a board carries only while they are wanted ----
#
# No storage image carries the test apps (fmruby-core/flash/app/test) or the
# optional apps (walk_scroller), fmruby-core config/storage_exclude_common.txt.
# A tool that runs a test app on a board puts it there first and takes the
# whole of /app/test away when its run is over (doc/flash_layout F1: kept
# while a series of tests goes on, gone at its end). Before sending, it looks
# at the free space (/fs/df) and, when sending would leave less than the
# reserve, deletes the test files put there earliest that this push does not
# need; /app/test/.pushed.json on the board records when each was put.
class FmrbDevFiles
  FLASH = File.expand_path(ENV["FMRB_FLASH_DIR"] || File.join(__dir__, "..", "fmruby-core", "flash"))
  TEST_DIR = "/app/test"
  MANIFEST = "/app/test/.pushed.json"
  BLOCK = 4096
  RESERVE_KB = 512
  # Optional apps by name: the paths under flash/ that make each one.
  EXTRAS = {
    "walk_scroller" => %w[app/demo/walk_scroller.app.rb app/demo/walk_scroller.app.toml
                          app/demo/walk_scroller usr/share/sprites/walk_scroller]
  }.freeze

  def initialize(fs, log, flash: FLASH)
    @fs = fs
    @log = log
    @flash = flash
  end

  # The files under flash/ (relative paths) for the test apps named: an app's
  # base name ("ckpt_counter") takes every entry of that name in app/test
  # (.app.rb, .app.toml, a picture, a directory). None named: all of them.
  def test_files(names)
    root = File.join(@flash, "app/test")
    raise ArgumentError, "no #{root}" unless File.directory?(root)
    entries = Dir.children(root).sort
    picked = if names.nil? || names.empty?
               entries
             else
               names.flat_map do |n|
                 base = File.basename(n).sub(/\.app\.\w+\z/, "")
                 got = entries.select { |e| e == base || e.start_with?("#{base}.") }
                 raise ArgumentError, "no test app #{n} in #{root}" if got.empty?
                 got
               end.uniq
             end
    picked.flat_map { |e| expand("app/test/#{e}") }
  end

  # Put the test apps on the board (only what is missing or differs in size).
  def push_tests(names, reserve_kb: RESERVE_KB)
    files = test_files(names)
    manifest = read_manifest
    on_board = board_files(TEST_DIR)
    make_room(files, on_board, manifest, reserve_kb)
    r = send_files(files, on_board)
    now = Time.now.to_i
    files.each { |f| manifest["/#{f}"] = { "size" => File.size(File.join(@flash, f)), "at" => now } }
    @fs.put(MANIFEST, JSON.generate(manifest))
    r.merge(files: files.size)
  end

  # Take every test file away (all of /app/test: no image carries any).
  def clean_tests
    return 0 unless dir?(TEST_DIR)
    @fs.rm_tree(TEST_DIR)
  end

  # [path, size, put at (Time or nil)] of what the board has under /app/test.
  def list_tests
    manifest = read_manifest
    board_files(TEST_DIR).reject { |p, _| p == MANIFEST }.sort.map do |p, size|
      at = manifest.dig(p, "at")
      [p, size, at && Time.at(at)]
    end
  end

  # Put an optional app (EXTRAS) or any path under flash/ on the board.
  def install(names)
    files = extra_paths(names).flat_map { |rel| expand(rel) }
    on_board = {}
    extra_paths(names).each { |rel| on_board.merge!(board_files("/#{rel}")) }
    r = send_files(files, on_board)
    r.merge(files: files.size)
  end

  # Delete what install put there.
  def uninstall(names)
    count = 0
    extra_paths(names).each do |rel|
      path = "/#{rel}"
      if dir?(path)
        count += @fs.rm_tree(path)
      elsif file?(path)
        @fs.del(path)
        count += 1
      end
    end
    count
  end

  private

  def extra_paths(names)
    raise ArgumentError, "name an optional app (#{EXTRAS.keys.join(', ')}) or a path under flash/" if names.empty?
    names.flat_map do |n|
      next EXTRAS[n] if EXTRAS.key?(n)
      rel = n.sub(%r{\A/}, "")
      raise ArgumentError, "#{n}: not an optional app (#{EXTRAS.keys.join(', ')}) nor a path under #{@flash}" unless
        File.exist?(File.join(@flash, rel)) && !rel.split("/").include?("..")
      [rel]
    end
  end

  # rel (a file or a directory under flash/) -> the files under it.
  def expand(rel)
    full = File.join(@flash, rel)
    return [rel] if File.file?(full)
    Dir.glob("**/*", base: full).sort.select { |f| File.file?(File.join(full, f)) }.map { |f| "#{rel}/#{f}" }
  end

  # { "/app/test/x.app.rb" => size } of the files under path, or of path
  # itself when it is a file (none when it is missing).
  def board_files(path)
    entry = (@fs.list(File.dirname(path)).find { |e| e["name"] == File.basename(path) } rescue nil)
    return {} unless entry
    return { path => entry["size"] } unless entry["dir"]
    @fs.walk(path).reject { |e| e["dir"] }.to_h { |e| [e["path"], e["size"]] }
  rescue FmrbFs::DeviceError
    {}
  end

  def dir?(path)
    parent = File.dirname(path)
    @fs.list(parent).any? { |e| e["name"] == File.basename(path) && e["dir"] }
  rescue FmrbFs::DeviceError
    false
  end

  def file?(path)
    @fs.list(File.dirname(path)).any? { |e| e["name"] == File.basename(path) && !e["dir"] }
  rescue FmrbFs::DeviceError
    false
  end

  def read_manifest
    JSON.parse(@fs.get(MANIFEST))
  rescue FmrbFs::DeviceError, JSON::ParserError
    {}
  end

  def blocks(size)
    [(size + BLOCK - 1) / BLOCK, 1].max * BLOCK
  end

  # When sending would leave less than the reserve free, delete the test
  # files this push does not need, the earliest put first (those the manifest
  # does not know count as the earliest).
  def make_room(files, on_board, manifest, reserve_kb)
    need = files.sum do |f|
      size = File.size(File.join(@flash, f))
      on_board["/#{f}"] == size ? 0 : blocks(size)
    end
    df = @fs.df("/app")
    unless df
      @log.call("(this firmware has no /fs/df: the free space is not checked)")
      return
    end
    reserve = reserve_kb * 1024
    short = need + reserve - df["free"]
    return if short <= 0
    wanted = files.map { |f| "/#{f}" }
    old = on_board.keys.reject { |p| p == MANIFEST || wanted.include?(p) }
                  .sort_by { |p| [manifest.dig(p, "at") || 0, p] }
    old.each do |p|
      break if short <= 0
      @fs.del(p)
      manifest.delete(p)
      short -= blocks(on_board[p])
      @log.call("  deleted #{p} (put there earlier; making room)")
    end
    df = @fs.df("/app")
    return if need + reserve <= df["free"]
    raise FmrbFs::DeviceError, "not enough room: #{need / 1024} KB to send, #{df['free'] / 1024} KB free, " \
                               "#{reserve_kb} KB to keep free (--reserve KB)"
  end

  def send_files(files, on_board)
    sent = 0
    bytes = 0
    made = {}
    files.each do |f|
      local = File.join(@flash, f)
      path = "/#{f}"
      next if on_board[path] == File.size(local)
      dir = File.dirname(path)
      unless made[dir]
        mkdir_p(dir)
        made[dir] = true
      end
      data = File.binread(local)
      @fs.put(path, data)
      @log.call("  #{path} (#{data.bytesize} bytes)")
      sent += 1
      bytes += data.bytesize
    end
    { sent: sent, bytes: bytes, same: files.size - sent }
  end

  def mkdir_p(dir)
    parts = dir.split("/").reject(&:empty?)
    parts.each_index { |i| @fs.mkdir("/" + parts[0..i].join("/")) }
  end
end

# Loaded by tools/fmrb_flash_keep.rb for the classes above; run only as a command.
if $PROGRAM_NAME == __FILE__
  host = ARGV.shift or abort "usage: fmrb_rd_fs.rb HOST [ls|get|put|del|mkdir|pull|push|rmr|backup|restore|sync|wait|reboot|df|tests|extra ...]"
  host = FmrbBoard.resolve(host) || abort("cannot resolve #{host}")
  fs = FmrbFs.new(host)
  if ARGV.empty?
    interactive(host, fs)
  else
    begin
      one_shot(fs, ARGV.shift, ARGV)
    rescue FmrbFs::DeviceError, ArgumentError => e
      warn "error: #{e.message}"
      exit 1
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      warn "error: cannot reach #{host}: #{e.message}"
      exit 1
    end
  end
end
