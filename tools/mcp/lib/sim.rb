# frozen_string_literal: true

# Linux simulation (three docker containers) for the fmrb MCP server (P3).
#
# The simulation is the cheapest place to check a change, and it has three
# traps that a person only avoids by remembering them. This file remembers
# them instead:
#
#   1. `rake build:linux` prints "Linux build complete" even when the build
#      directory still holds an ESP32 build, so the sim can be started against
#      a firmware that was never built for it. Every start checks the two ELFs
#      are really x86-64 first.
#   2. Restarting one container kills the frame buffer. There is no
#      single-container restart here, only the whole stack.
#   3. graphics-audio remembers the frame-buffer size and applies a change on
#      the NEXT boot, so the first run after switching hardware targets comes
#      up at the previous resolution. A start that comes up at the wrong size
#      restarts itself once.
#
# And one rule about other people's work: a stack that was already running is
# reused, never recreated, and sim_down refuses to take it away unless it was
# ours or the caller insists.
require "base64"
require "fileutils"
require "json"
require "shellwords"
require "time"

require_relative "support"

module FmrbMcp
  class Sim
    LOCK_NAME = "sim"
    UP_TIMEOUT = 240              # the script waits 60s for the boot marker
    DOWN_TIMEOUT = 120
    SHOT_TIMEOUT = 60
    INPUT_TIMEOUT = 180
    APP_TIMEOUT = 60
    MODERN_TARGETS = %w[TAB5 NARYAv4].freeze
    MODERN_SIZE = [426, 240].freeze
    RETRO_SIZE = [320, 240].freeze
    ELF_X86_64 = 0x3E             # e_machine
    MAX_TEXT_BYTES = 60 * 1024

    def initialize(repo_root:, state_dir:)
      @repo_root = File.expand_path(repo_root)
      @state_dir = File.expand_path(state_dir)
      FileUtils.mkdir_p(@state_dir)
    end

    def core_elf
      ENV["FMRB_MCP_SIM_CORE_ELF"] ||
        File.join(@repo_root, "fmruby-core", "build", "fmruby-core.elf")
    end

    def graphics_elf
      ENV["FMRB_MCP_SIM_GA_ELF"] ||
        File.join(@repo_root, "fmruby-graphics-audio", "build",
                  "fmruby-graphics-audio.elf")
    end

    def state_file
      File.join(@state_dir, "sim.json")
    end

    def boot_png
      File.join(@state_dir, "sim_boot.png")
    end

    def shot_png
      File.join(@state_dir, "sim_screen.png")
    end

    # --- tools ---------------------------------------------------------------

    def up(gui: false)
      check_builds!
      notes = []
      lock.hold("the Linux sim", hint: "wait for the other session's sim operation to finish") do
        result = start_once(gui, notes)

        # The resolution carries over from the previous boot, so a start right
        # after a target switch comes up at the old size. One restart fixes it;
        # a second failure is a different problem and says so.
        if result[:mismatch] && result[:reused]
          notes << "the running stack is #{result[:size]} but this build expects " \
                   "#{expected_size_s}. It was already running when we got here, so it " \
                   "was left alone -- restart it yourself (sim_down then sim_up) if it is yours."
        elsif result[:mismatch]
          notes << "came up at #{result[:size]}, expected #{expected_size_s}; " \
                   "restarting once (graphics-audio applies a new frame-buffer size " \
                   "on the next boot, so the first run after a target switch is stale)"
          compose_down
          result = start_once(gui, notes)
          if result[:mismatch]
            raise Error, "the sim is #{result[:size]} but #{expected_size_s} was expected, " \
                         "and a restart did not change it. Either " \
                         "fmruby-graphics-audio/flash/etc/display_conf_linux.txt is not " \
                         "being updated, or the build does not match " \
                         "FMRB_HW_TARGET=#{hw_target} in fmruby-core/.env (the environment " \
                         "overrides the file, so a build can differ from what .env says). " \
                         "Rebuild both repositories for the target you mean."
          end
        end

        save_state(started_by_us: !result[:reused], size: result[:size], gui: gui)
        result.merge(notes: notes, expected_size: expected_size_s,
                     hw_target: hw_target, png: boot_png)
      end
    end

    def down(force: false)
      st = read_state
      if st && st["started_by_us"] == false && !force
        raise Error, "this stack was already running when the sim tools first saw it, " \
                     "so it is the user's (or another session's) -- it may be a GUI run " \
                     "they are watching. Pass force: true to take it down anyway."
      end
      lock.hold("the Linux sim", hint: "wait for the other session's sim operation to finish") do
        res = compose_down
        File.unlink(state_file) rescue nil
        { down: res[:ok], output: Sub.clamp(res[:output].strip, MAX_TEXT_BYTES),
          was_ours: st.nil? ? "unknown" : st["started_by_us"] }
      end
    end

    def screenshot(wait: nil)
      cmd = ["python3", File.join(@repo_root, "tools", "fmrb_screenshot.py")]
      cmd += ["--wait", wait.to_s] if wait
      cmd << shot_png
      File.unlink(shot_png) rescue nil
      res = Sub.run({}, cmd, chdir: @repo_root, timeout: SHOT_TIMEOUT)
      unless res[:ok] && File.exist?(shot_png)
        raise Error, "no screenshot: #{res[:output].strip}\n" \
                     "If the stack is not running, sim_up first."
      end
      png = File.binread(shot_png)
      w, h = png_size(shot_png)
      { path: shot_png, bytes: png.bytesize, size: "#{w}x#{h}",
        data: Base64.strict_encode64(png) }
    end

    # Shellwords, not a plain split: `text "hello world"` has to reach the tool
    # as one argument or it types only the first word.
    def input(commands)
      words = begin
        Shellwords.split(commands.to_s)
      rescue ArgumentError => e
        raise Error, "could not read the command list (#{e.message}). " \
                     "Quote a string with spaces like: text \"hello world\""
      end
      raise Error, "no commands given" if words.empty?

      res = Sub.run({}, ["ruby", File.join(@repo_root, "tools", "fmrb_input.rb"), *words],
                    chdir: @repo_root, timeout: INPUT_TIMEOUT)
      raise Error, "input failed: #{res[:output].strip}" unless res[:ok]
      { sent: words, output: res[:output].strip }
    end

    def app(action:, path: nil, pid: nil)
      args =
        case action
        when "ps" then ["ps"]
        when "spawn"
          raise Error, "spawn needs a path, e.g. /app/demo/kamon.app.rb" if path.nil? || path.empty?
          ["spawn", "path=#{path}"]
        when "kill"
          raise Error, "kill needs a pid (see action: \"ps\")" if pid.nil?
          ["kill", "pid=#{pid.to_i}"]
        else
          raise Error, "unknown action #{action.inspect} (spawn|ps|kill)"
        end

      client = File.join(@repo_root, "fmruby-core", "tool", "debug", "fmrb_dbg_client.py")
      res = Sub.run({}, ["python3", client, "--json", "localhost", *args],
                    chdir: @repo_root, timeout: APP_TIMEOUT)
      unless res[:ok]
        hint = if res[:output].include?("refused") || res[:output].include?("Connection")
                 " The debug server lives in the running sim, so sim_up first."
               else
                 ""
               end
        raise Error, "sim_app #{action} failed: #{res[:output].strip}#{hint}"
      end
      doc = begin
        JSON.parse(res[:output].lines.last.to_s)
      rescue JSON::ParserError
        raise Error, "the debug client answered something that is not JSON: " \
                     "#{Sub.clamp(res[:output], 2000)}"
      end
      raise Error, "sim_app #{action} was refused: #{doc['error']}" if doc["error"]
      { action: action, result: doc }
    end

    def status
      st = read_state
      { running: core_running?, state: st, expected_size: expected_size_s,
        hw_target: hw_target }
    end

    private

    def lock
      @lock ||= Lock.new(@state_dir, LOCK_NAME)
    end

    # --- builds ---------------------------------------------------------------

    # `rake build:linux` reports success against a leftover ESP32 build tree, so
    # "it built" is not evidence that what is in build/ can run here. Read the
    # ELF headers instead of believing the log.
    def check_builds!
      bad = []
      { "fmruby-core" => core_elf, "fmruby-graphics-audio" => graphics_elf }.each do |repo, path|
        unless File.exist?(path)
          bad << "#{repo}: #{path} is missing"
          next
        end
        machine = elf_machine(path)
        if machine.nil?
          bad << "#{repo}: #{path} is not an ELF file"
        elsif machine != ELF_X86_64
          bad << "#{repo}: #{path} is #{elf_machine_name(machine)}, not x86-64"
        end
      end
      return if bad.empty?

      raise Error, "the Linux build is not there: #{bad.join('; ')}.\n" \
                   "`rake build:linux` prints \"Linux build complete\" even when the " \
                   "build directory still holds an ESP32 build, so this is checked " \
                   "before anything is started. In each repository:\n" \
                   "  rake clean_all && rake build:linux\n" \
                   "(clean_all, not clean: switching targets needs the full clean.)"
    end

    def elf_machine(path)
      head = File.binread(path, 20)
      return nil unless head && head.bytesize >= 20 && head[0, 4] == "\x7FELF".b
      head[18, 2].unpack1("v")     # e_machine, little-endian ELF
    rescue StandardError
      nil
    end

    def elf_machine_name(machine)
      { 0x3E => "x86-64", 0xF3 => "RISC-V (an ESP32-P4 build)",
        0x5E => "Xtensa (an ESP32-S3 build)", 0x28 => "ARM" }[machine] ||
        format("machine 0x%02X", machine)
    end

    # --- stack ----------------------------------------------------------------

    def start_once(gui, notes)
      File.unlink(boot_png) rescue nil
      cmd = [File.join(@repo_root, "tools", "dev_run_check.sh"), "--keep"]
      cmd << "--gui" if gui
      cmd << boot_png
      # Always --keep: bringing the stack down is sim_down's decision, made
      # with the knowledge of whose stack it is.
      res = Sub.run({}, cmd, chdir: @repo_root, timeout: UP_TIMEOUT)
      unless res[:ok] && File.exist?(boot_png)
        raise Error, "the sim did not come up: #{Sub.clamp(res[:output].strip, 6000)}\n" \
                     "If a container is up but wedged, attach gdb before restarting it " \
                     "-- a hung sim is the one place the state can still be read " \
                     "(the procedure is in the root CLAUDE.md)."
      end
      reused = res[:output].include?("already running")
      w, h = png_size(boot_png)
      notes << "reused the stack that was already running" if reused
      { reused: reused, size: "#{w}x#{h}",
        mismatch: [w, h] != expected_size, boot_log: Sub.clamp(res[:output].strip, 4000) }
    end

    def compose_down
      Sub.run({}, ["docker", "compose", "down"], chdir: @repo_root, timeout: DOWN_TIMEOUT)
    end

    def core_running?
      res = Sub.run({}, ["docker", "inspect", "-f", "{{.State.Running}}", "fmruby_core"],
                    chdir: @repo_root, timeout: 30)
      res[:output].strip == "true"
    rescue Error
      false
    end

    # --- target and size ------------------------------------------------------

    # The environment wins over the file, the way dotenv works, so a build can
    # legitimately differ from what .env says -- which is why a mismatch names
    # both possibilities rather than blaming the carry-over.
    def hw_target
      env = ENV["FMRB_HW_TARGET"]
      return env if env && !env.empty?
      path = File.join(@repo_root, "fmruby-core", ".env")
      return "" unless File.exist?(path)
      File.readlines(path).each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        k, v = line.split("=", 2)
        next unless k && v
        return v.split("#", 2).first.to_s.strip if k.strip == "FMRB_HW_TARGET"
      end
      ""
    end

    def expected_size
      MODERN_TARGETS.include?(hw_target) ? MODERN_SIZE : RETRO_SIZE
    end

    def expected_size_s
      expected_size.join("x")
    end

    def png_size(path)
      head = File.binread(path, 24)
      raise Error, "#{path} is not a PNG" unless head && head[0, 8] == "\x89PNG\r\n\x1A\n".b
      [head[16, 4].unpack1("N"), head[20, 4].unpack1("N")]
    end

    # --- state ----------------------------------------------------------------

    def read_state
      return nil unless File.exist?(state_file)
      JSON.parse(File.read(state_file))
    rescue StandardError
      nil
    end

    def save_state(started_by_us:, size:, gui:)
      # Once ours, stay ours: a later sim_up that reuses the stack we started
      # must not downgrade it to "someone else's" and make sim_down refuse.
      previous = read_state
      ours = started_by_us || (previous && previous["started_by_us"]) || false
      File.write(state_file,
                 JSON.pretty_generate("started_by_us" => ours, "size" => size,
                                      "gui" => gui, "at" => Time.now.iso8601))
    rescue StandardError
      nil
    end
  end
end
