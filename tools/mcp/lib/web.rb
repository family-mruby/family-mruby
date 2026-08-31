# frozen_string_literal: true

# The browser build (wasm) for the fmrb MCP server.
#
# Two long-lived processes stand between a tool call and the machine: the
# development server, which serves the page with the isolation headers
# SharedArrayBuffer needs AND relays commands, and a browser with the page
# open at ?drive=1. This file owns both so a caller does not have to.
#
# The relay runs the other way round from the sim: a browser cannot be
# reached from outside, so the page asks the development server for a command
# and posts the answer back. tools/fmrb_web.rb is the shell end of that, and
# everything here shells out to it -- one implementation, whether a person or
# a tool is driving.
#
# The same rule about other people's work as the sim: a server or a browser
# that was already running is reused, never replaced, and web_down refuses to
# take one away unless it was ours or the caller insists.
require "base64"
require "fileutils"
require "json"
require "net/http"
require "shellwords"
require "time"

require_relative "support"

module FmrbMcp
  class Web
    LOCK_NAME = "web"
    DEFAULT_PORT = 8006
    UP_TIMEOUT = 180
    CMD_TIMEOUT = 120
    SERVE_WAIT = 20               # seconds for WEBrick to answer
    MAX_TEXT_BYTES = 60 * 1024

    def initialize(repo_root:, state_dir:)
      @repo_root = File.expand_path(repo_root)
      @core = File.join(@repo_root, "fmruby-core")
      @state_dir = File.expand_path(state_dir)
      FileUtils.mkdir_p(@state_dir)
    end

    def state_file = File.join(@state_dir, "web.json")
    def serve_log = File.join(@state_dir, "web_serve.log")
    def shot_png = File.join(@state_dir, "web_screen.png")
    def tool = File.join(@repo_root, "tools", "fmrb_web.rb")

    # --- tools ---------------------------------------------------------------

    def up(headless: true, port: nil, url_args: nil)
      check_bundle!
      port = (port || read_state&.dig("port") || DEFAULT_PORT).to_i
      notes = []
      lock.hold("the browser build", hint: "wait for the other session's web operation to finish") do
        server_ours = ensure_server(port, notes)
        browser_ours = ensure_browser(port, headless, url_args, notes)
        save_state(port: port, server_ours: server_ours, browser_ours: browser_ours,
                   headless: headless)
        wait_settled(port, notes)
        wait_drawing(port, notes)
        st = run_tool(port, ["status"])
        shot = screenshot(port: port, tries: 3)
        { port: port, page: st[:output].strip, notes: notes,
          url: page_url(port, url_args), png: shot[:path],
          size: shot[:size], data: shot[:data] }
      end
    end

    def down(force: false)
      st = read_state
      port = (st&.dig("port") || DEFAULT_PORT).to_i
      if st && st["browser_ours"] == false && !force
        raise Error, "the browser was already open when the web tools first saw it, " \
                     "so it is the user's (or another session's) -- they may be " \
                     "watching it. Pass force: true to close it anyway."
      end
      lock.hold("the browser build", hint: "wait for the other session's web operation to finish") do
        out = []
        res = Sub.run({}, ["ruby", tool, "--port", port.to_s, "down"],
                      chdir: @repo_root, timeout: CMD_TIMEOUT)
        out << res[:output].strip
        if st.nil? || st["server_ours"]
          out << (stop_server(st&.dig("server_pid")) ? "development server stopped" :
                                                       "no development server of ours to stop")
        else
          out << "left the development server alone (it was already running)"
        end
        File.unlink(state_file) rescue nil
        { down: true, port: port, output: out.reject(&:empty?).join("\n") }
      end
    end

    # tries > 1 for the moments right after a boot or a reload: the page's own
    # thread is busy carrying the machine up, and a request can wait longer
    # than one round for its turn. Everywhere else a single try is right --
    # a page that is not answering should say so quickly.
    def screenshot(port: nil, tries: 1)
      port = resolve_port(port)
      File.unlink(shot_png) rescue nil
      res = nil
      attempt = 0
      begin
        attempt += 1
        res = run_tool(port, ["screenshot", shot_png])
      rescue Error
        raise if attempt >= tries
        sleep 3
        retry
      end
      unless File.exist?(shot_png)
        raise Error, "no screenshot: #{res[:output].strip}"
      end
      png = File.binread(shot_png)
      w, h = png_size(shot_png)
      { path: shot_png, bytes: png.bytesize, size: "#{w}x#{h}",
        data: Base64.strict_encode64(png) }
    end

    # Shellwords, not a plain split: `text "hello world"` has to reach the
    # tool as one argument or it types only the first word.
    def input(commands, port: nil)
      words = begin
        Shellwords.split(commands.to_s)
      rescue ArgumentError => e
        raise Error, "could not read the command list (#{e.message}). " \
                     "Quote a string with spaces like: text \"hello world\""
      end
      raise Error, "no commands given" if words.empty?
      res = run_tool(resolve_port(port), words)
      { sent: words, output: Sub.clamp(res[:output].strip, MAX_TEXT_BYTES) }
    end

    def fs(action:, path: nil, local_path: nil, port: nil)
      port = resolve_port(port)
      args =
        case action
        when "ls", "rm"
          need_path!(action, path)
          [action, path]
        when "cat"
          need_path!(action, path)
          ["cat", path]
        when "get"
          need_path!(action, path)
          raise Error, "get needs local_path (where to write it here)" if blank?(local_path)
          ["get", path, local_path]
        when "put"
          need_path!(action, path)
          raise Error, "put needs local_path (the file to send)" if blank?(local_path)
          unless File.exist?(local_path)
            raise Error, "#{local_path} is not there"
          end
          ["put", local_path, path]
        else
          raise Error, "unknown action #{action.inspect} (ls|cat|get|put|rm)"
        end
      res = run_tool(port, args)
      { action: action, path: path, local_path: local_path,
        output: Sub.clamp(res[:output], MAX_TEXT_BYTES) }
    end

    def reload(port: nil)
      port = resolve_port(port)
      res = run_tool(port, ["reload"], timeout: UP_TIMEOUT)
      notes = []
      wait_settled(port, notes)
      wait_drawing(port, notes)
      shot = screenshot(port: port, tries: 3)
      { reloaded: true, output: res[:output].strip, notes: notes,
        size: shot[:size], png: shot[:path], data: shot[:data] }
    end

    def status
      st = read_state
      port = (st&.dig("port") || DEFAULT_PORT).to_i
      page = begin
        run_tool(port, ["status"], timeout: 30)[:output].strip
      rescue Error => e
        "not answering (#{e.message.lines.first.to_s.strip})"
      end
      { port: port, server: server_answers?(port), page: page, state: st,
        bundle: bundle_ready? ? "built" : "missing" }
    end

    private

    def lock = @lock ||= Lock.new(@state_dir, LOCK_NAME)

    def blank?(s) = s.nil? || s.to_s.empty?

    def need_path!(action, path)
      raise Error, "#{action} needs path, e.g. /flash/home" if blank?(path)
    end

    def resolve_port(port)
      (port || read_state&.dig("port") || DEFAULT_PORT).to_i
    end

    def page_url(port, url_args)
      "http://localhost:#{port}/wasm/web/index.html?autostart=1&drive=1" +
        (url_args ? "&#{url_args}" : "")
    end

    # The machine's first frame is not the same as a page that answers: the
    # boot keeps the browser's own thread busy in long bursts (every file the
    # firmware opens is a call proxied to it), so a command sent too early
    # waits out its round and comes back empty-handed. Wait for two answers in
    # a row before handing the page over to the caller.
    def wait_settled(port, notes, seconds = 120)
      deadline = Time.now + seconds
      good = 0
      waited = false
      while Time.now < deadline
        begin
          run_tool(port, ["--timeout", "30", "status"], timeout: 60)
          good += 1
          break if good >= 2
        rescue Error
          good = 0
          waited = true
        end
        sleep 1
      end
      notes << "waited for the page to settle after the boot" if waited
      good >= 2
    end

    # And settled is still not drawn: the page answers well before the desktop
    # has painted, and a shot taken then is the boot splash or a white
    # rectangle. The frame counter tells the two apart -- it climbs in bursts
    # while the machine is coming up (measured after a reload: +18, +6, +3 per
    # second) and falls to the menu bar clock's one a second once the desktop
    # is idle. Wait for two calm seconds, having drawn something first.
    def wait_drawing(port, notes, seconds = 45)
      deadline = Time.now + seconds
      prev = frame_seq(port)
      calm = 0
      while Time.now < deadline
        sleep 1
        now = frame_seq(port)
        if now && prev && now >= 10 && now >= prev && (now - prev) <= 1
          calm += 1
          return true if calm >= 2
        else
          calm = 0
        end
        prev = now
      end
      notes << "the screen may still be busy: the frame counter never settled"
      false
    end

    def frame_seq(port)
      out = run_tool(port, ["--timeout", "30", "status"], timeout: 60)[:output]
      out[/frame=(\d+)/, 1]&.to_i
    rescue Error
      nil
    end

    def run_tool(port, args, timeout: CMD_TIMEOUT)
      res = Sub.run({}, ["ruby", tool, "--port", port.to_s, *args],
                    chdir: @repo_root, timeout: timeout)
      unless res[:ok]
        raise Error, "#{args.first} failed: #{Sub.clamp(res[:output].strip, 4000)}\n" \
                     "If nothing is running yet, web_up first."
      end
      res
    end

    # --- the bundle -----------------------------------------------------------

    def bundle_files
      %w[core_web.js core_web.wasm core_web.data]
        .map { |f| File.join(@core, "wasm", "build", f) }
    end

    def bundle_ready? = bundle_files.all? { |f| File.exist?(f) }

    def check_bundle!
      missing = bundle_files.reject { |f| File.exist?(f) }
      return if missing.empty?
      raise Error, "the browser bundle is not built (#{missing.map { |f| File.basename(f) }.join(', ')} " \
                   "missing under fmruby-core/wasm/build/).\n" \
                   "  cd fmruby-core && rake wasm:web\n" \
                   "It reads the git index, so file moves have to be staged first, and " \
                   "`rake clean_all` takes the wasm libmruby with it (rake wasm:mruby " \
                   "rebuilds that)."
    end

    # --- the development server ----------------------------------------------

    # It is not only a static server: the page's ?drive=1 relay lives in it,
    # and so do the isolation headers without which the module cannot start.
    def ensure_server(port, notes)
      if server_answers?(port)
        notes << "reused the development server already on port #{port}"
        return false
      end
      out = File.open(serve_log, "w")
      pid = begin
        Process.spawn({}, "rake", "wasm:serve", "PORT=#{port}",
                      chdir: @core, in: File::NULL, out: out, err: out, pgroup: true)
      rescue SystemCallError => e
        raise Error, "cannot start the development server: #{e.message}"
      ensure
        out.close
      end
      Process.detach(pid)
      @serve_pid = pid
      deadline = Time.now + SERVE_WAIT
      until server_answers?(port)
        if Time.now > deadline
          log = (File.read(serve_log).strip rescue "")
          raise Error, "the development server did not answer on port #{port} " \
                       "within #{SERVE_WAIT}s.\n#{Sub.clamp(log, 3000)}"
        end
        sleep 0.5
      end
      notes << "started the development server on port #{port}"
      true
    end

    def server_answers?(port)
      Net::HTTP.start("localhost", port, open_timeout: 1, read_timeout: 3) do |http|
        http.head("/wasm/web/index.html").code == "200"
      end
    rescue StandardError
      false
    end

    def stop_server(pid)
      pid = pid.to_i
      return false if pid.zero?
      begin
        Process.kill("TERM", -pid)     # the whole group: rake spawns WEBrick
      rescue SystemCallError
        begin
          Process.kill("TERM", pid)
        rescue SystemCallError
          return false
        end
      end
      true
    end

    # --- the browser ----------------------------------------------------------

    def ensure_browser(port, headless, url_args, notes)
      if page_answers?(port)
        notes << "reused the browser already on the page"
        return false
      end
      args = ["up"]
      args << "--headless" if headless
      args += ["--url-args", url_args] if url_args
      res = Sub.run({}, ["ruby", tool, "--port", port.to_s, *args],
                    chdir: @repo_root, timeout: UP_TIMEOUT)
      unless res[:ok]
        raise Error, "the browser did not come up: #{Sub.clamp(res[:output].strip, 4000)}\n" \
                     "With no browser on this machine, set FMRB_CHROME, or open the " \
                     "page by hand at #{page_url(port, url_args)} and call web_up again " \
                     "-- a page that is already there is used as it is."
      end
      notes << "started a browser (#{headless ? 'headless' : 'visible'})"
      true
    end

    def page_answers?(port)
      res = Sub.run({}, ["ruby", tool, "--port", port.to_s, "status"],
                    chdir: @repo_root, timeout: 40)
      res[:ok] && res[:output].include?("running=true")
    end

    # --- state ----------------------------------------------------------------

    def png_size(path)
      head = File.binread(path, 24)
      raise Error, "#{path} is not a PNG" unless head && head[0, 8] == "\x89PNG\r\n\x1A\n".b
      [head[16, 4].unpack1("N"), head[20, 4].unpack1("N")]
    end

    def read_state
      return nil unless File.exist?(state_file)
      JSON.parse(File.read(state_file))
    rescue StandardError
      nil
    end

    # Once ours, stay ours: a later web_up that reuses what we started must not
    # downgrade it to "someone else's" and make web_down refuse.
    def save_state(port:, server_ours:, browser_ours:, headless:)
      previous = read_state
      File.write(state_file, JSON.pretty_generate(
        "port" => port,
        "server_ours" => server_ours || previous&.dig("server_ours") || false,
        "browser_ours" => browser_ours || previous&.dig("browser_ours") || false,
        "server_pid" => @serve_pid || previous&.dig("server_pid"),
        "headless" => headless,
        "at" => Time.now.iso8601
      ))
    rescue StandardError
      nil
    end
  end
end
