# frozen_string_literal: true

# Tab5 (Modern / ESP32-P4) remote control for the fmrb MCP server (P2).
#
# Everything here goes over the board's remote-desktop HTTP server on port 80.
# Unlike the serial port, that is not an exclusive resource, so there is no
# flock in this file. What it does own is the one piece of state the CLI tools
# make the caller carry by hand: the address.
#
# The board is on DHCP, so its IP changes from boot to boot and a value that
# worked yesterday quietly points at nothing (or at somebody else's device)
# today. So no tool here takes an address as a required argument: the address
# is resolved, verified against the board's own /status, cached briefly, and
# thrown away the moment it stops answering.
require "base64"
require "fileutils"
require "json"
require "time"

require_relative "support"
# The rd_* CLI tools and this server speak to the same HTTP endpoints; sharing
# the client keeps one definition of "what the firmware answers".
require_relative "../../fmrb_rd_http"

module FmrbMcp
  # The board did not answer. Distinct from Error so resolution can retry once
  # with a fresh address before giving up.
  class Tab5Unreachable < Error; end

  class Tab5
    CACHE_TTL = 300               # seconds; a DHCP lease outlives this easily
    # Every board answers to this one. With two on a network they both do, and
    # which replies is a race -- so a board's own name (fmruby-XXXXXX.local,
    # from its WiFi MAC) is tried first when the serial log has told us one.
    MDNS_SHARED = "fmruby.local"
    TAIL_BYTES = 256 * 1024       # of a serial log: enough for the last boot
    MDNS_NAME = ENV.fetch("FMRB_MCP_TAB5_HOST", MDNS_SHARED)
    FB_WIDTH = 426                # frame-buffer coordinates, not window pixels
    FB_HEIGHT = 240
    HTTP_TIMEOUT = 8
    INPUT_TIMEOUT = 120
    SNAP_TIMEOUT = 30
    FS_BASE_TIMEOUT = 60
    FS_BYTES_PER_SEC = 10_000     # deliberately pessimistic (put measures ~150KB/s)
    MAX_TEXT_BYTES = 60 * 1024

    def initialize(repo_root:, state_dir:)
      @repo_root = File.expand_path(repo_root)
      @state_dir = File.expand_path(state_dir)
      FileUtils.mkdir_p(@state_dir)
    end

    def tools_dir
      File.join(@repo_root, "tools")
    end

    def ip_cache_file
      File.join(@state_dir, "tab5_ip.json")
    end

    # --- address ------------------------------------------------------------

    # Returns { ip:, source:, status:, notes: }. Every other method starts here.
    def resolve(explicit = nil, refresh: false)
      notes = []

      if explicit && !explicit.empty?
        status = probe(explicit)
        cache_ip(explicit, "argument")
        return { ip: explicit, source: "argument", status: status, notes: notes }
      end

      unless refresh
        cached = read_cache
        if cached
          begin
            status = probe(cached["ip"])
            return { ip: cached["ip"], source: "cache (#{cached['source']})",
                     status: status, notes: notes }
          rescue Tab5Unreachable => e
            # A cached address that stopped answering is worse than none: it
            # sends every later call to a device that is not there.
            notes << "cached #{cached['ip']} did not answer (#{e.message}); resolving again"
            clear_cache
          end
        end
      end

      ip, how = discover(notes)
      status = probe(ip)
      cache_ip(ip, how)
      { ip: ip, source: how, status: status, notes: notes }
    end

    # --- tools ---------------------------------------------------------------

    def screenshot(ip: nil)
      r = resolve(ip)
      out = File.join(@state_dir, "tab5_screen.jpg")
      File.unlink(out) rescue nil
      res = Sub.run({}, ["ruby", File.join(tools_dir, "fmrb_rd_snap.rb"), r[:ip], out],
                    chdir: @repo_root, timeout: SNAP_TIMEOUT)
      unless res[:ok] && File.exist?(out)
        raise Error, "could not grab a frame from #{r[:ip]}: #{res[:output].strip}"
      end
      jpeg = File.binread(out)
      { ip: r[:ip], path: out, bytes: jpeg.bytesize,
        frame_size: "#{FB_WIDTH}x#{FB_HEIGHT}", data: Base64.strict_encode64(jpeg),
        notes: r[:notes] }
    end

    def input(commands, ip: nil)
      words = commands.to_s.split
      raise Error, "no commands given" if words.empty?
      r = resolve(ip)
      res = Sub.run({}, ["ruby", File.join(tools_dir, "fmrb_rd_input.rb"), r[:ip], *words],
                    chdir: @repo_root, timeout: INPUT_TIMEOUT)
      unless res[:ok]
        raise Error, "input failed: #{res[:output].strip}"
      end
      { ip: r[:ip], sent: words.join(" "), output: res[:output].strip,
        frame_size: "#{FB_WIDTH}x#{FB_HEIGHT}", notes: r[:notes] }
    end

    def app(action:, path: nil, pid: nil, ip: nil)
      r = resolve(ip)
      case action
      when "ps"
        status, body = http(r[:ip], "GET", "/app/list")
        doc = parse_json(status, body, "/app/list")
        { ip: r[:ip], apps: doc["apps"] || [], notes: r[:notes] }
      when "launch"
        raise Error, "launch needs a path, e.g. /app/demo/spinel_hello.app.rb" if blank?(path)
        status, body = http(r[:ip], "POST", "/app/launch?path=#{path}")
        doc = parse_json(status, body, "/app/launch")
        unless doc["ok"]
          raise Error, "launch of #{path} failed (HTTP #{status}): #{body}"
        end
        { ip: r[:ip], launched: path, pid: doc["pid"], notes: r[:notes] }
      when "kill"
        raise Error, "kill needs a pid (see action: \"ps\")" if pid.nil?
        status, body = http(r[:ip], "POST", "/app/kill?pid=#{pid.to_i}")
        if status == 400
          raise Error, "the firmware refused to kill pid #{pid} (HTTP 400). " \
                       "Only user apps can be killed from here -- the kernel, " \
                       "the host and the system desktop are protected."
        end
        doc = parse_json(status, body, "/app/kill")
        raise Error, "kill of pid #{pid} failed (HTTP #{status}): #{body}" unless doc["ok"]
        { ip: r[:ip], killed: pid.to_i, notes: r[:notes] }
      else
        raise Error, "unknown action #{action.inspect} (launch|ps|kill)"
      end
    end

    def fs(action:, device_path: nil, local_path: nil, force: false, ip: nil)
      r = resolve(ip)
      args, timeout = fs_args(action, device_path, local_path, force)
      args << "--force" if force && %w[pull push].include?(action)

      res = Sub.run({}, ["ruby", File.join(tools_dir, "fmrb_rd_fs.rb"), r[:ip], *args],
                    chdir: @repo_root, timeout: timeout)
      notes = r[:notes].dup
      if %w[put push get pull].include?(action)
        notes << "the remote desktop stream pauses during a large transfer and " \
                 "resumes when it finishes"
      end
      unless res[:ok]
        hint = if res[:output].include?("400")
                 " Paths are limited to /app, /home, /usr/share and /mnt/sd, " \
                 "and \"..\" is refused."
               else
                 ""
               end
        raise Error, "fs #{action} failed#{res[:timed_out] ? ' (timed out)' : ''}: " \
                     "#{res[:output].strip}#{hint}"
      end
      { ip: r[:ip], action: action, output: Sub.clamp(res[:output].strip, MAX_TEXT_BYTES),
        notes: notes }
    end

    private

    def blank?(s)
      s.nil? || s.to_s.empty?
    end

    def fs_args(action, device_path, local_path, _force)
      case action
      when "ls"    then [["ls", need(device_path, "ls needs device_path")], FS_BASE_TIMEOUT]
      when "mkdir" then [["mkdir", need(device_path, "mkdir needs device_path")], FS_BASE_TIMEOUT]
      when "del"   then [["del", need(device_path, "del needs device_path")], FS_BASE_TIMEOUT]
      when "rmr"   then [["rmr", need(device_path, "rmr needs device_path")], FS_BASE_TIMEOUT * 5]
      when "get"
        d = need(device_path, "get needs device_path")
        [["get", d, need(local_path, "get needs local_path")], FS_BASE_TIMEOUT * 5]
      when "put"
        l = need(local_path, "put needs local_path (the file on this machine)")
        raise Error, "#{l} does not exist" unless File.exist?(l)
        [["put", l, need(device_path, "put needs device_path")], transfer_timeout(File.size(l))]
      when "pull"
        d = need(device_path, "pull needs device_path")
        [["pull", d, need(local_path, "pull needs local_path (a directory)")], FS_BASE_TIMEOUT * 10]
      when "push"
        l = need(local_path, "push needs local_path (a directory)")
        raise Error, "#{l} is not a directory" unless File.directory?(l)
        [["push", l, need(device_path, "push needs device_path")], transfer_timeout(dir_size(l))]
      else
        raise Error, "unknown action #{action.inspect} (ls|get|put|push|pull|mkdir|del|rmr)"
      end
    end

    def need(value, message)
      raise Error, message if blank?(value)
      value
    end

    def dir_size(dir)
      Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }.sum { |f| File.size(f) }
    end

    def transfer_timeout(bytes)
      FS_BASE_TIMEOUT + (bytes.to_f / FS_BYTES_PER_SEC).ceil
    end

    # --- HTTP ---------------------------------------------------------------

    # FmrbRdHttp reports failure the way a CLI should -- by calling abort --
    # which inside a long-lived server would take the whole process down. Turn
    # that back into an exception rather than forking the client.
    def http(ip, method, path, timeout: HTTP_TIMEOUT)
      FmrbRdHttp.request(ip, method, path, timeout: timeout)
    rescue SystemExit => e
      raise Tab5Unreachable, e.message.to_s.strip
    end

    def parse_json(status, body, endpoint)
      if status == 404
        raise Error, "#{endpoint} answered 404: this firmware has no development " \
                     "remote control. It is compiled in only with FMRB_DEV_REMOTE_CTL " \
                     "(on by default, off in release builds), so a release firmware " \
                     "cannot be driven this way."
      end
      JSON.parse(body)
    rescue JSON::ParserError
      raise Error, "#{endpoint} answered HTTP #{status} with something that is not JSON: " \
                   "#{Sub.clamp(body.to_s, 500)}"
    end

    def probe(ip)
      status, body = http(ip, "GET", "/status", timeout: 5)
      if status == 404
        raise Tab5Unreachable, "#{ip} answered 404 for /status -- something is " \
                               "listening on port 80, but it is not a Family mruby " \
                               "remote desktop"
      end
      doc = begin
        JSON.parse(body)
      rescue JSON::ParserError
        raise Tab5Unreachable, "#{ip} did not answer /status with JSON: #{Sub.clamp(body.to_s, 200)}"
      end
      doc
    end

    # --- discovery ----------------------------------------------------------

    def discover(notes)
      tried = []
      mdns_names.each do |host|
        resolvers(host).each do |name, cmd|
          res = begin
            Sub.run({}, cmd, chdir: @repo_root, timeout: 20)
          rescue Error
            # Not every box has every resolver. A missing one is not the answer
            # to "where is the board" -- move on to the next and let the summary
            # at the end say what was tried.
            tried << "#{host} via #{name}: not installed"
            next
          end
          ip = res[:output].to_s[/\b(?:\d{1,3}\.){3}\d{1,3}\b/]
          if ip
            notes << "resolved #{host} to #{ip} via #{name}"
            return [ip, name]
          end
          tried << "#{host} via #{name}: #{res[:output].to_s.strip.empty? ? 'no answer' : res[:output].strip.lines.first.to_s.strip}"
        end
      end
      raise Error, unreachable_message(tried)
    end

    # The names to try, most specific first.
    #
    # A board announces its own at boot ("wifi: mDNS hostname: X.local"), and
    # the serial capture is usually running, so the log names the board that
    # is actually plugged in -- which is the one being worked on. Falling back
    # to the shared name keeps this working when nothing has been captured.
    #
    # An explicit FMRB_MCP_TAB5_HOST means that name and no other.
    def mdns_names
      return [MDNS_NAME] if ENV["FMRB_MCP_TAB5_HOST"]
      [own_mdns_name, MDNS_SHARED].compact.uniq
    end

    def own_mdns_name
      dir = File.expand_path(ENV["FMRB_MCP_STATE_DIR"] || "~/.fmrb_mcp")
      # current.log is the capture that is running; capture.log is what has
      # been archived. The live one is read second so a boot from a minute ago
      # wins over one from this morning -- the archive lags behind it.
      last = nil
      ["capture.log", "current.log"].each do |name|
        log = File.join(dir, name)
        next unless File.exist?(log)
        # Read binary and only the tail. A serial capture carries whatever
        # bytes the line produced, so decoding it as text raises on the first
        # scrap of noise -- and the archive runs to hundreds of thousands of
        # lines, of which only the last boot matters.
        text = File.open(log, "rb") do |f|
          f.seek(-[f.size, TAIL_BYTES].min, IO::SEEK_END)
          f.read
        end
        m = text.to_s.scan(/mDNS hostname: (\S+\.local)/).last
        last = m[0] if m
      end
      last == MDNS_SHARED ? nil : last
    rescue StandardError
      nil
    end

    # mDNS has no single spelling. WSL has no avahi but can borrow the Windows
    # resolver; a native Linux box usually has avahi behind getent.
    def resolvers(host = MDNS_NAME)
      list = []
      if wsl?
        list << ["powershell mDNS", ["powershell.exe", "-NoProfile", "-Command",
                                     "(Resolve-DnsName #{host} -ErrorAction SilentlyContinue | " \
                                     "Where-Object Type -eq 'A').IPAddress"]]
      end
      list << ["getent", ["getent", "hosts", host]]
      list << ["avahi", ["avahi-resolve", "-4", "-n", host]]
      list
    end

    def wsl?
      return true if ENV["WSL_DISTRO_NAME"]
      File.exist?("/proc/sys/fs/binfmt_misc/WSLInterop")
    end

    def unreachable_message(tried)
      "cannot find the Tab5. Tried: #{tried.join('; ')}.\n" \
      "Check that the board is powered, booted and on the same WiFi. If a " \
      "serial capture is running, the boot log line " \
      "\"rd_http: Remote desktop ready: http://<IP>/\" carries the address, " \
      "and serial_log will show it. You can also pass the address directly " \
      "as the `ip` argument, or name the board with FMRB_MCP_TAB5_HOST " \
      "(each board answers to fmruby-XXXXXX.local as well as fmruby.local)."
    end

    # --- cache ----------------------------------------------------------------

    def read_cache
      return nil unless File.exist?(ip_cache_file)
      doc = JSON.parse(File.read(ip_cache_file))
      return nil unless doc["ip"] && doc["at"]
      return nil if Time.now - Time.parse(doc["at"]) > CACHE_TTL
      doc
    rescue StandardError
      nil
    end

    def cache_ip(ip, source)
      File.write(ip_cache_file,
                 JSON.pretty_generate("ip" => ip, "source" => source,
                                      "at" => Time.now.iso8601))
    rescue StandardError
      nil
    end

    def clear_cache
      File.unlink(ip_cache_file) rescue nil
    end
  end
end
