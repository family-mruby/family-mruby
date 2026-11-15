#!/usr/bin/env ruby
# The WiFi halves of flashing a board without losing its /home, for
# `rake flash:keep_home` / `rake flash:app_sync` (fmruby-core
# rakelib/device.rake) and the MCP flash tool's keep_home / app_sync
# (tools/mcp). The flash itself is theirs -- the serial port is -- so this
# does what comes before it and after it, over the development endpoints
# (tools/fmrb_rd_fs.rb, fmruby-core doc/dev_remote_ctl/plan.md).
#
#   ruby tools/fmrb_flash_keep.rb prepare <host> --storage-root <dir> [--dir <backup>]
#       Before a full flash: check that the new image's /etc/wifi.toml will
#       bring WiFi up (the board's own settings are in /home, which the flash
#       replaces), then back /home up with its keys. Prints backup=<dir> and
#       name=<mDNS name>.
#   ruby tools/fmrb_flash_keep.rb finish <host> --dir <backup> [--name <mDNS name>] [--timeout s]
#       After it: wait for the board, write /home back, reboot, wait again.
#   ruby tools/fmrb_flash_keep.rb name <host>
#       The board's mDNS name (name=fmruby-xxxxxx), to find it again after a flash.
#   ruby tools/fmrb_flash_keep.rb sync <host> --storage-root <dir> [--name <mDNS name>] [--conf] [--timeout s]
#       After an app-only flash: wait for the board, then send what differs
#       between the build's storage tree and the board (/home untouched).
#
# Exit status: 0 done, 1 an error, 3 the board did not come back on WiFi
# (then the message says what to do over serial instead).

require_relative "fmrb_rd_fs"

module FmrbFlashKeep
  module_function

  WAIT_SECS = 240   # a P4 boots and joins WiFi in well under a minute; the
                    # rest is the hard reset after a long write, and DHCP

  def option(args, key)
    i = args.index(key)
    return nil unless i
    args.delete_at(i)
    args.delete_at(i)
  end

  # Whether a board with an empty /home would join a network: wifi_task reads
  # /home/wifi.toml, then /etc/wifi.toml, and uses the first that exists.
  # Only the enable and ssid keys are looked at, and nothing is printed from
  # the file.
  def image_wifi_problem(storage_root)
    file = File.join(storage_root, "etc", "wifi.toml")
    return "the new image has no /etc/wifi.toml (#{file})" unless File.file?(file)
    text = File.read(file)
    return "the new image's /etc/wifi.toml says enable = false" if text =~ /^\s*enable\s*=\s*false\b/
    return "the new image's /etc/wifi.toml names no network (ssid)" unless text =~ /^\s*ssid\s*=\s*"[^"]+"/
    nil
  end

  def serial_hint(dir)
    "Write it back over serial instead: in fmruby-core, " \
      "`rake flash:keep_home_serial BACKUP=#{dir} STORAGE_ONLY=1` puts the new image's tree " \
      "with this /home into the storage partition (the firmware is already written)."
  end

  def wait!(host, name, timeout, after_reboot: false, dir: nil)
    got = wait_for_board(host, timeout: timeout, name: name, after_reboot: after_reboot,
                               log: ->(s) { puts s })
    return got[0] if got
    warn "the board did not answer on WiFi within #{timeout} s#{name ? " (#{name})" : ''}."
    warn serial_hint(dir) if dir
    exit 3
  end

  def run(cmd, args)
    host = args.shift or abort "#{cmd} needs the board's address"
    host = FmrbBoard.resolve(host) || abort("cannot resolve #{host}")
    timeout = (option(args, "--timeout") || WAIT_SECS).to_i
    log = ->(s) { puts s }
    case cmd
    when "name"
      st = FmrbFs.new(host).status
      abort "this firmware's /status has no host (before 2026-11-15)" unless st["host"]
      puts "name=#{st['host']}"
    when "prepare"
      root = option(args, "--storage-root") or abort "prepare needs --storage-root"
      dir = option(args, "--dir")
      if (problem = image_wifi_problem(root))
        warn "not flashing: #{problem}, so the board would not come back on WiFi to have " \
             "its /home written back. Use `rake flash:keep_home_serial` (fmruby-core): it " \
             "reads /home over serial and writes it into the new storage image."
        exit 3
      end
      fs = FmrbFs.new(host)
      st = fs.status
      dir ||= File.join(FmrbBoard::KEYS_DIR, FmrbBoard.device_dir_name(st),
                        "home_backup_#{Time.now.strftime('%Y%m%d-%H%M%S')}")
      dir = File.expand_path(dir)
      r = FmrbHome.new(fs, log).backup(dir)
      puts "backed up /home: #{r[:files]} files, #{r[:dirs]} directories, #{r[:bytes]} bytes" \
           "#{r[:verified] ? ', each checked by MD5' : ''}"
      puts "backup=#{dir}"
      puts "name=#{st['host']}" if st["host"]
    when "finish"
      dir = option(args, "--dir") or abort "finish needs --dir"
      dir = File.expand_path(dir)
      name = option(args, "--name")
      name ||= (JSON.parse(File.read(File.join(dir, "manifest.json")))["host"] rescue nil)
      ip = wait!(host, name, timeout, dir: dir)
      puts "the board is back at #{ip}"
      fs = FmrbFs.new(ip)
      r = FmrbHome.new(fs, log).restore(dir, false)
      puts "restored /home: #{r[:sent]} files sent (#{r[:bytes]} bytes), #{r[:same]} already the same"
      unless r[:extra].empty?
        puts "on the board but not in the backup (left as they are): #{r[:extra].join(', ')}"
      end
      fs.reboot
      puts "rebooting so the WiFi settings and keys in /home are read"
      ip = wait!(ip, name, timeout, after_reboot: true)
      puts "ip=#{ip}"
    when "sync"
      root = option(args, "--storage-root") or abort "sync needs --storage-root"
      name = option(args, "--name")
      conf = args.delete("--conf")
      ip = wait!(host, name, timeout)
      puts "the board is back at #{ip}"
      r = FmrbStorageSync.new(FmrbFs.new(ip), log).run(root, conf: conf)
      puts "sent #{r[:sent]} files (#{r[:bytes]} bytes), #{r[:same]} already the same"
      r[:held].each { |p| puts "#{p} differs and was kept (the board's saved settings; CONF=1 / --conf sends it)" }
      unless r[:extra].empty?
        puts "on the board but not in the build (left as they are):"
        r[:extra].each { |p| puts "  #{p}" }
      end
      puts "ip=#{ip}"
    else
      abort "unknown command #{cmd} (prepare|finish|name|sync)"
    end
  rescue FmrbFs::DeviceError, ArgumentError => e
    warn "error: #{e.message}"
    exit 1
  rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    warn "error: cannot reach the board: #{e.message}"
    exit 1
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  cmd = ARGV.shift or abort "usage: fmrb_flash_keep.rb prepare|finish|name|sync <host> ..."
  FmrbFlashKeep.run(cmd, ARGV)
end
