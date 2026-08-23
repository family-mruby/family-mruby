#!/usr/bin/env ruby
# Move files to and from a Tab5 over WiFi, through the remote desktop's
# development file endpoints (/fs/list, /fs/get, /fs/put, /fs/del,
# /fs/mkdir; fmruby-core main/drivers/remote_desktop/rd_http.c).
#
# BLE was the only way to get a file off the device and it tops out at a few
# tens of KB/s -- fine for a .rb, hopeless for the JPEGs PicoRabbit exports or
# an MJPEG clip. WiFi moves several hundred KB/s. Paths are the ones apps use
# (/app, /home, /usr/share, /mnt/sd); the device refuses anything else.
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
# pull and push skip a file whose size already matches on the other side
# (the device has no checksums); add --force to copy everything.
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

class FmrbFs
  class DeviceError < StandardError; end

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
  else
    abort "unknown command #{cmd} (ls|get|put|del|mkdir|pull|push|rmr)"
  end
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

host = ARGV.shift or abort "usage: fmrb_rd_fs.rb HOST [ls|get|put|del|mkdir|pull|push|rmr ...]"
fs = FmrbFs.new(host)
if ARGV.empty?
  interactive(host, fs)
else
  begin
    one_shot(fs, ARGV.shift, ARGV)
  rescue FmrbFs::DeviceError => e
    warn "error: #{e.message}"
    exit 1
  end
end
