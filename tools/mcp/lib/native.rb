# frozen_string_literal: true

# The native Linux program (fmruby-core/native/, doc/linux_native/) for the
# fmrb MCP server.
#
# One process on this machine, no docker: the Modern machine's firmware built
# for x86-64, presenting through the backends a machine definition names
# (fmruby-core/config/machines/). Everything here shells out to
# tools/fmrb_native.rb -- one implementation, whether a person or a tool is
# driving -- which talks to the program through its run directory
# (/tmp/fmrb-native-<uid>: control socket, inject socket, log) and its debug
# server (TCP 5565). None of that is shared with the sim (5555, the docker
# socket), so the two run side by side.
#
# The rule about other people's work is the sim's: a program that was already
# running is reused as it is, and native_down refuses to stop one this server
# did not start unless the caller insists.
require "base64"
require "fileutils"
require "json"
require "shellwords"
require "time"

require_relative "support"

module FmrbMcp
  class Native
    LOCK_NAME = "native"
    UP_TIMEOUT = 150
    CMD_TIMEOUT = 60
    INPUT_TIMEOUT = 180
    MAX_TEXT_BYTES = 60 * 1024

    def initialize(repo_root:, state_dir:)
      @repo_root = File.expand_path(repo_root)
      @state_dir = File.expand_path(state_dir)
      FileUtils.mkdir_p(@state_dir)
    end

    def tool = File.join(@repo_root, "tools", "fmrb_native.rb")
    def state_file = File.join(@state_dir, "native.json")
    def shot_png = File.join(@state_dir, "native_screen.png")

    # --- tools ---------------------------------------------------------------

    def up(machine: nil, engine: nil, gui: false, set: nil, alsa_file: false)
      notes = []
      lock.hold("the native program", hint: "wait for the other session's native operation to finish") do
        st = status_line
        if st[:running]
          notes << "reused the native program that was already running (#{st[:line]}); " \
                   "machine, engine and the other options were not applied -- native_down " \
                   "first to start it another way"
          save_state(started_by_us: false, machine: st[:machine])
        else
          args = ["up"]
          args += ["--machine", machine] if machine && !machine.empty?
          args += ["--engine", engine] if engine && !engine.empty?
          args << "--gui" if gui
          args << "--alsa-file" if alsa_file
          Array(set).each { |kv| args += ["--set", kv.to_s] }
          res = run(args, timeout: UP_TIMEOUT)
          unless res[:ok]
            raise Error, "the native program did not start: #{Sub.clamp(res[:output].strip, 6000)}"
          end
          notes << res[:output].strip
          save_state(started_by_us: true, machine: res[:output][/machine (\S+)/, 1])
        end
        shot = screenshot
        { notes: notes, status: status_line[:line], png: shot[:path], size: shot[:size],
          data: shot[:data] }
      end
    end

    def down(force: false)
      st = read_state
      if st && st["started_by_us"] == false && !force
        raise Error, "the native program was already running when the native tools first saw " \
                     "it, so it is the user's (or another session's) -- it may be a window " \
                     "they are using. Pass force: true to stop it anyway."
      end
      lock.hold("the native program", hint: "wait for the other session's native operation to finish") do
        res = run(["down"], timeout: CMD_TIMEOUT)
        File.unlink(state_file) rescue nil
        { down: res[:ok], output: Sub.clamp(res[:output].strip, MAX_TEXT_BYTES),
          was_ours: st.nil? ? "unknown" : st["started_by_us"] }
      end
    end

    def screenshot
      File.unlink(shot_png) rescue nil
      res = run(["shot", shot_png], timeout: CMD_TIMEOUT)
      unless res[:ok] && File.exist?(shot_png)
        raise Error, "no screenshot: #{res[:output].strip}\nIf it is not running, native_up first."
      end
      png = File.binread(shot_png)
      w, h = png_size(shot_png)
      { path: shot_png, bytes: png.bytesize, size: "#{w}x#{h}", data: Base64.strict_encode64(png) }
    end

    # Shellwords, as for the sim: `text "hello world"` is one argument.
    def input(commands)
      words = begin
        Shellwords.split(commands.to_s)
      rescue ArgumentError => e
        raise Error, "could not read the command list (#{e.message}). " \
                     "Quote a string with spaces like: text \"hello world\""
      end
      raise Error, "no commands given" if words.empty?
      res = run(["input", *words], timeout: INPUT_TIMEOUT)
      raise Error, "input failed: #{res[:output].strip}" unless res[:ok]
      { sent: words, output: res[:output].strip }
    end

    def app(action:, path: nil, pid: nil)
      args =
        case action
        when "ps" then ["app", "ps"]
        when "spawn"
          raise Error, "spawn needs a path, e.g. /app/demo/kamon.app.rb" if path.nil? || path.empty?
          ["app", "spawn", path]
        when "kill"
          raise Error, "kill needs a pid (see action: \"ps\")" if pid.nil?
          ["app", "kill", pid.to_i.to_s]
        else
          raise Error, "unknown action #{action.inspect} (spawn|ps|kill)"
        end
      res = run(args, timeout: CMD_TIMEOUT)
      unless res[:ok]
        hint = res[:output] =~ /refused|Connection/ ? " The debug server lives in the running program, so native_up first." : ""
        raise Error, "native_app #{action} failed: #{res[:output].strip}#{hint}"
      end
      doc = begin
        JSON.parse(res[:output].lines.last.to_s)
      rescue JSON::ParserError
        raise Error, "the debug client answered something that is not JSON: #{Sub.clamp(res[:output], 2000)}"
      end
      raise Error, "native_app #{action} was refused: #{doc['error']}" if doc["error"]
      { action: action, result: doc }
    end

    def status
      { status: status_line[:line], state: read_state }
    end

    private

    def lock
      @lock ||= Lock.new(@state_dir, LOCK_NAME)
    end

    def run(args, timeout:)
      Sub.run({}, ["ruby", tool, *args], chdir: @repo_root, timeout: timeout)
    end

    def status_line
      res = run(["status"], timeout: 30)
      line = res[:output].strip.lines.last.to_s.strip
      { running: line.include?("running,"), line: line, machine: line[/machine (\S+),/, 1] }
    end

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

    def save_state(started_by_us:, machine:)
      previous = read_state
      ours = started_by_us || (previous && previous["started_by_us"]) || false
      File.write(state_file, JSON.pretty_generate("started_by_us" => ours, "machine" => machine,
                                                  "at" => Time.now.iso8601))
    rescue StandardError
      nil
    end
  end
end
