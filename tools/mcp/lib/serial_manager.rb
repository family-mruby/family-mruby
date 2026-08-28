# frozen_string_literal: true

# Serial + flash state management for the fmrb MCP server (P1).
#
# This is the one place in the server that is more than a thin wrapper: it
# owns the `fmrb_serial_capture.py` child process so the three operational
# rules that used to live only in CLAUDE.md are enforced by code.
#
#   1. The serial port is exclusive. A capture (or any monitor) holding it
#      makes `rake flash` fail with "device reports readiness to read but
#      returned no data".
#   2. Re-opening the port resets the board on most adapters, so "open it
#      only when you want to look" produces false negatives. Instead the
#      capture stays open and readers read the file it writes.
#   3. Flashing means: stop the capture, flash, resume the capture with
#      --no-reset.
#
# Cross-session exclusion uses flock on ~/.fmrb_mcp/<port>.lock, because one
# stdio server process is spawned per Claude session -- an in-process mutex
# would not see the other server.
require "fileutils"
require "json"
require "time"

module FmrbMcp
  class Error < StandardError; end

  # The port is held by another MCP server process (another Claude session)
  # or by something else that took the same lock. Never stolen silently.
  class LockBusy < Error; end

  class SerialManager
    CAPTURE_SECS = 86_400        # -t 0 would capture nothing (the tool loops
                                 # until now+secs), so "stay open" is a big -t.
    DEFAULT_BAUD = 115_200
    FLASH_BAUD = 115_200         # 460800 (the rake default) fails to connect
                                 # often under WSL2.
    FLASH_TIMEOUT = 300
    CHECK_PORT_TIMEOUT = 240
    BOOT_SETTLE_SECS = 5         # how long to let the board talk after flash
    MAX_SCAN_BYTES = 8 * 1024 * 1024
    MAX_TEXT_BYTES = 120 * 1024

    attr_reader :state_dir, :repo_root

    def initialize(repo_root:, state_dir: nil)
      @repo_root = File.expand_path(repo_root)
      @state_dir = File.expand_path(
        state_dir || ENV["FMRB_MCP_STATE_DIR"] || "~/.fmrb_mcp"
      )
      FileUtils.mkdir_p(@state_dir)
      @lock_file = nil
      @lock_port = nil
      @lock_for_flash_only = false
      @child_pid = nil
      @meta = nil
    end

    def core_dir
      File.join(@repo_root, "fmruby-core")
    end

    def capture_script
      File.join(@repo_root, "tools", "fmrb_serial_capture.py")
    end

    def port_cache_file
      File.join(core_dir, ".serial_port")
    end

    # Finished capture segments, appended (see archive_current!).
    def archive_log
      File.join(@state_dir, "capture.log")
    end

    # The segment the running capture writes (it truncates its output file).
    def current_log
      File.join(@state_dir, "current.log")
    end

    def child_output_log
      File.join(@state_dir, "capture.stderr.log")
    end

    def pid_file
      File.join(@state_dir, "capture.pid")
    end

    def meta_file
      File.join(@state_dir, "capture.meta.json")
    end

    # --- tools ------------------------------------------------------------

    def start(port: nil, baud: nil, reset: false)
      baud ||= DEFAULT_BAUD
      notes = []

      if running?
        if port && port != @meta["port"]
          raise Error, "capture is already running on #{@meta['port']} " \
                       "(pid #{@child_pid}). Call serial_stop first to switch to #{port}."
        end
        return {
          started: false,
          note: "already running (no-op)",
          **capture_status,
        }
      end

      resolved = resolve_port(port, notes)
      acquire_lock(resolved, for_flash_only: false)
      notes.concat(reap_orphan_capture)
      archive_current!

      cmd = ["python3", capture_script,
             "-p", resolved, "-b", baud.to_s, "-t", CAPTURE_SECS.to_s]
      cmd << "--no-reset" unless reset
      cmd << current_log

      # The child must never write to our stdout: that stream carries
      # JSON-RPC only.
      out = File.open(child_output_log, "w")
      begin
        @child_pid = Process.spawn(*cmd, chdir: @repo_root,
                                   in: File::NULL, out: out, err: out)
      rescue SystemCallError => e
        release_lock
        raise Error, "cannot start the capture (#{cmd.first}): #{e.message}"
      ensure
        out.close
      end

      # A busy port or a missing pyserial shows up within a second.
      sleep 1.0
      unless alive?(@child_pid)
        Process.waitpid(@child_pid, Process::WNOHANG) rescue nil
        msg = File.read(child_output_log).strip rescue ""
        @child_pid = nil
        release_lock
        raise Error, "capture failed to start on #{resolved}.\n#{msg}"
      end

      @meta = {
        "port" => resolved, "baud" => baud, "reset" => reset,
        "pid" => @child_pid, "started_at" => Time.now.iso8601,
        "server_pid" => Process.pid,
      }
      File.write(pid_file, @child_pid.to_s)
      File.write(meta_file, JSON.pretty_generate(@meta))

      { started: true, notes: notes, **capture_status }
    end

    def stop
      was = running?
      notes = []
      unless was
        # A capture left behind by a server that died still holds the port.
        # serial_stop is where the user expects that to be cleaned up.
        stale_port = stale_meta_port
        if stale_port
          begin
            acquire_lock(stale_port, for_flash_only: true) unless @lock_file
            notes.concat(reap_orphan_capture)
          rescue LockBusy
            notes << "#{stale_port} is held by another session; left it alone"
          end
        end
      end
      stop_child
      archive_current!
      release_lock
      { stopped: was, note: was ? "capture stopped" : "no capture was running",
        notes: notes, log: archive_log, log_lines: count_lines(archive_log) }
    end

    # Reads the log FILE. Never touches the port -- this is the whole point of
    # keeping one capture open (re-opening resets the board).
    def log(grep: nil, tail: 100, regex: false)
      tail = 100 if tail.nil?
      tail = 1 if tail < 1
      tail = 5000 if tail > 5000

      text = read_recent(MAX_SCAN_BYTES)
      lines = text.split("\n")
      total = lines.length
      matched = nil

      if grep && !grep.empty?
        if regex
          begin
            re = Regexp.new(grep)
          rescue RegexpError => e
            raise Error, "invalid regexp #{grep.inspect}: #{e.message}"
          end
          lines = lines.grep(re)
        else
          lines = lines.select { |l| l.include?(grep) }
        end
        matched = lines.length
      end

      shown = lines.last(tail)
      body = clamp(shown.join("\n"))

      {
        running: running?,
        capture: running? ? capture_status : nil,
        log_present: File.exist?(archive_log) || File.exist?(current_log),
        last_write: last_write_time&.iso8601,
        total_lines: total,
        matched_lines: matched,
        shown_lines: shown.length,
        text: body,
      }
    end

    def flash
      notes = []
      was_running = running?
      port = @lock_port || resolve_port(nil, notes)
      acquire_lock(port, for_flash_only: !was_running) unless holding_lock?(port)
      notes.concat(reap_orphan_capture) unless was_running

      # `rake flash` reads the port from fmruby-core/.serial_port itself, so a
      # capture started on an explicitly given port can be on a different one.
      cached = read_port_cache
      if cached && cached != port
        notes << "the capture is on #{port} but `rake flash` uses #{cached} " \
                 "(fmruby-core/.serial_port). Flashing #{cached}; run " \
                 "`rake check-port` if that is the wrong board."
      end

      if was_running
        stop_child
        archive_current!
        notes << "capture stopped for flashing (will resume with --no-reset)"
      end

      env = { "FLASH_BAUD" => FLASH_BAUD.to_s }
      result = run(env, ["rake", "flash"], chdir: core_dir, timeout: FLASH_TIMEOUT)
      output = clamp(result[:output])

      diagnosis = []
      unless result[:ok]
        if result[:output].include?("device reports readiness to read")
          diagnosis << "the port is held by another process (a serial monitor, " \
                       "`rake monitor`, or a capture outside this server). " \
                       "Close it and retry."
        end
        if result[:timed_out]
          diagnosis << "flash timed out after #{FLASH_TIMEOUT}s and was killed. " \
                       "The docker container it started may still be running."
        end
      end

      boot = nil
      if was_running
        restart_capture_after_flash(port, notes)
        sleep BOOT_SETTLE_SECS
        boot = boot_summary(read_file(current_log))
      else
        notes << "no capture was running before the flash, so none was started " \
                 "afterwards and there is no boot log. Call serial_start to watch the boot."
        release_lock if @lock_for_flash_only
      end

      { ok: result[:ok], exit_status: result[:status], timed_out: result[:timed_out],
        output: output, diagnosis: diagnosis, boot: boot, notes: notes,
        capture: running? ? capture_status : nil }
    end

    # Called from at_exit / signal traps. An orphaned capture holding the port
    # is the worst failure mode this server can leave behind.
    def shutdown
      stop_child
      release_lock
    rescue StandardError
      nil
    end

    # --- port resolution ---------------------------------------------------

    def resolve_port(explicit, notes = [])
      return explicit if explicit && !explicit.empty?

      cached = read_port_cache
      return cached if cached

      notes << "no .serial_port cache; running `rake check-port` (probes ports with esptool via docker)"
      r = run({}, ["rake", "check-port"], chdir: core_dir, timeout: CHECK_PORT_TIMEOUT)
      cached = read_port_cache
      unless cached
        hint = "\nIf no device turned up at all and this is WSL, the board is " \
               "probably not attached to Linux yet: ask the user to run " \
               "`rake attach` in fmruby-core (it needs Windows-side privileges, " \
               "so this server cannot do it)."
        raise Error, "could not determine the serial port. `rake check-port` " \
                     "#{r[:timed_out] ? 'timed out' : "exited #{r[:status]}"}:\n" \
                     "#{clamp(r[:output])}#{hint}"
      end
      notes << "detected #{cached}"
      cached
    end

    # Port recorded by whichever server last started a capture. Used only to
    # find an orphan to reap -- never to probe hardware.
    def stale_meta_port
      return nil unless File.exist?(meta_file)
      JSON.parse(File.read(meta_file))["port"]
    rescue StandardError
      nil
    end

    def read_port_cache
      return nil unless File.exist?(port_cache_file)
      p = File.read(port_cache_file).strip
      return nil if p.empty?
      return nil unless File.exist?(p)
      p
    end

    # --- capture child -----------------------------------------------------

    def running?
      alive?(@child_pid)
    end

    def capture_status
      m = @meta || {}
      { running: running?, pid: @child_pid, port: m["port"], baud: m["baud"],
        reset_on_start: m["reset"], started_at: m["started_at"],
        log: archive_log, live_log: current_log,
        expires_at: expiry(m["started_at"]) }
    end

    private

    def expiry(started_at)
      return nil unless started_at
      (Time.parse(started_at) + CAPTURE_SECS).iso8601
    rescue ArgumentError
      nil
    end

    def stop_child
      return false unless alive?(@child_pid)
      pid = @child_pid
      Process.kill("TERM", pid) rescue nil
      unless reap_child(pid, 3.0)
        Process.kill("KILL", pid) rescue nil
        reap_child(pid, 2.0)
      end
      @child_pid = nil
      File.unlink(pid_file) rescue nil
      true
    end

    # Waits for our own child, reaping it. `alive?` (kill 0) is not enough on
    # its own: a killed but unreaped child is a zombie and still answers to
    # signal 0, so polling it alone would spin until the timeout every time.
    def reap_child(pid, timeout)
      deadline = Time.now + timeout
      loop do
        gone = begin
          !Process.waitpid(pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          true
        end
        return true if gone
        return false if Time.now > deadline
        sleep 0.05
      end
    end

    def restart_capture_after_flash(port, notes)
      baud = (@meta && @meta["baud"]) || DEFAULT_BAUD
      begin
        start(port: port, baud: baud, reset: false)
        notes << "capture resumed with --no-reset"
      rescue Error => e
        notes << "capture could NOT be resumed: #{e.message}"
      end
    end

    # `fmrb_serial_capture.py` opens its output with "wb", i.e. it truncates.
    # Roll the finished segment into the archive so a flash (stop + restart)
    # does not throw away the log that came before it.
    def archive_current!
      return unless File.exist?(current_log)
      data = File.binread(current_log)
      unless data.empty?
        File.open(archive_log, "ab") { |f| f.write(data) }
      end
      File.unlink(current_log) rescue nil
    end

    # We hold the lock, so any live capture process recorded in the pid file
    # is an orphan from a server that died without cleaning up.
    def reap_orphan_capture
      notes = []
      return notes unless File.exist?(pid_file)
      pid = File.read(pid_file).to_i
      if pid > 0 && alive?(pid) && capture_process?(pid)
        Process.kill("TERM", pid) rescue nil
        20.times { break unless alive?(pid); sleep 0.1 }
        Process.kill("KILL", pid) rescue nil if alive?(pid)
        notes << "killed an orphaned capture (pid #{pid}) left by a previous server"
      end
      File.unlink(pid_file) rescue nil
      notes
    end

    def capture_process?(pid)
      cmdline = File.binread("/proc/#{pid}/cmdline") rescue nil
      return false unless cmdline
      cmdline.include?("fmrb_serial_capture.py")
    end

    def alive?(pid)
      return false unless pid
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # --- flock -------------------------------------------------------------

    def lock_path(port)
      File.join(@state_dir, port.to_s.gsub(/[^A-Za-z0-9]+/, "-").sub(/\A-+/, "") + ".lock")
    end

    def holding_lock?(port)
      !@lock_file.nil? && @lock_port == port
    end

    def acquire_lock(port, for_flash_only:)
      return if holding_lock?(port)
      release_lock if @lock_file

      path = lock_path(port)
      f = File.open(path, File::RDWR | File::CREAT, 0o644)
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        holder = (f.read.strip rescue "")
        f.close
        raise LockBusy, "#{port} is in use by another session#{holder.empty? ? '' : " (#{holder})"}. " \
                        "This server never steals the port: stop the other session's " \
                        "capture (serial_stop) or wait for it to finish."
      end
      f.truncate(0)
      f.write("server pid #{Process.pid} since #{Time.now.iso8601}")
      f.flush
      @lock_file = f
      @lock_port = port
      @lock_for_flash_only = for_flash_only
    end

    def release_lock
      return unless @lock_file
      @lock_file.flock(File::LOCK_UN) rescue nil
      @lock_file.close rescue nil
      @lock_file = nil
      @lock_port = nil
      @lock_for_flash_only = false
    end

    # --- log reading -------------------------------------------------------

    def read_file(path)
      return "" unless File.exist?(path)
      scrub(File.binread(path))
    end

    def read_recent(max_bytes)
      cur = tail_bytes(current_log, max_bytes)
      rest = max_bytes - cur.bytesize
      arc = rest > 0 ? tail_bytes(archive_log, rest) : ""
      scrub(arc + cur)
    end

    def tail_bytes(path, max_bytes)
      return "" unless File.exist?(path) && max_bytes > 0
      size = File.size(path)
      return File.binread(path) if size <= max_bytes
      data = File.open(path, "rb") { |f| f.seek(size - max_bytes); f.read }
      nl = data.index("\n")
      nl ? data[(nl + 1)..] : data
    end

    # Serial output is bytes, not text: it can contain partial UTF-8 (the log
    # is read while it is being written) and ANSI colour from ESP-IDF. Both
    # would otherwise break JSON generation or the readability of the result.
    def scrub(bytes)
      bytes.force_encoding(Encoding::UTF_8)
           .scrub("?")
           .gsub(/\e\[[0-9;]*[A-Za-z]/, "")
           .gsub("\r\n", "\n")
           .delete("\r")
    end

    def clamp(text, limit = MAX_TEXT_BYTES)
      return text if text.bytesize <= limit
      tail = text.byteslice(text.bytesize - limit, limit)
                 .force_encoding(Encoding::UTF_8).scrub("?")
      "...(truncated #{text.bytesize - limit} bytes)...\n" + tail.sub(/\A[^\n]*\n/, "")
    end

    def count_lines(path)
      return 0 unless File.exist?(path)
      File.foreach(path, mode: "rb").count
    end

    def last_write_time
      times = [archive_log, current_log].select { |p| File.exist?(p) }.map { |p| File.mtime(p) }
      times.max
    end

    # --- boot log reading --------------------------------------------------

    # Deliberately conservative: it reports what it saw and does NOT call a
    # download-mode stall a boot loop, nor a missing banner a failure (a
    # --no-reset capture that attaches after the reset legitimately misses it).
    def boot_summary(text)
      lines = text.split("\n")
      crashes = lines.grep(/Guru Meditation|\babort\(\)|Backtrace:|StoreProhibited|LoadProhibited/)
      dl_mode = text.include?("waiting for download") ||
                text.match?(/boot:0x[0-9a-f]*[0-9a-f]\s*\(DOWNLOAD/i)
      banner = text.match?(/ESP-ROM:|rst:0x[0-9a-f]+/i)
      app_up = text.include?("M1|") || text.include?("main_loop started")

      verdict =
        if dl_mode
          "DOWNLOAD MODE STALL -- this is NOT a boot loop. The chip stayed in " \
          "the serial download mode after flashing. Ask the user to press the " \
          "reset button on the board, then read the log again."
        elsif crashes.any?
          "crash markers found (#{crashes.length}); read the log around them"
        elsif app_up
          "healthy: no crash markers, firmware reached its boot instrumentation"
        elsif banner
          "booted (ROM banner seen), but no firmware boot instrumentation yet; " \
          "read the log again in a few seconds"
        elsif text.strip.empty?
          "no serial output captured yet. The capture resumes with --no-reset " \
          "after a flash, so it can attach after the boot has already scrolled " \
          "past; call serial_start(reset: true) for a log that starts at the banner."
        else
          "output seen but no boot banner and no firmware markers; " \
          "the capture may have attached mid-boot (it resumes with --no-reset)"
        end

      { verdict: verdict, crash_marker_lines: crashes.length,
        crash_lines: crashes.first(10), rom_banner: banner,
        firmware_markers: app_up, download_mode_stall: dl_mode,
        captured_lines: lines.length,
        tail: clamp(lines.last(40).join("\n"), 8000) }
    end

    # --- subprocess --------------------------------------------------------

    def run(env, cmd, chdir:, timeout:)
      r, w = IO.pipe
      r.binmode
      pid = begin
        Process.spawn(env, *cmd, chdir: chdir, in: File::NULL,
                      out: w, err: [:child, :out], pgroup: true)
      rescue Errno::ENOENT => e
        r.close
        w.close
        raise Error, "cannot run #{cmd.first}: #{e.message} (is it on PATH for this server?)"
      end
      w.close

      buf = +""
      reader = Thread.new { buf << r.read }

      status = nil
      timed_out = false
      deadline = Time.now + timeout
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        break if status
        if Time.now > deadline
          timed_out = true
          Process.kill("TERM", -pid) rescue nil
          sleep 2
          Process.kill("KILL", -pid) rescue nil
          Process.waitpid(pid) rescue nil
          break
        end
        sleep 0.2
      end

      reader.join(5)
      r.close rescue nil

      { ok: !timed_out && status&.success? || false,
        status: status&.exitstatus, timed_out: timed_out,
        output: scrub(buf) }
    end
  end
end
