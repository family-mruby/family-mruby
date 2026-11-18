# frozen_string_literal: true

# Linux simulation (three docker containers) for the fmrb MCP server (P3).
#
# The simulation is the cheapest place to check a change, and it has three
# traps that a person only avoids by remembering them. This file remembers
# them instead:
#
#   1. A start must not run a firmware that was never built for the sim, or
#      one built from older sources. The sim's build has its own directory
#      (fmruby-core/build-linux, beside the ESP32 build/), and every start
#      checks the two ELFs are really x86-64 and that the core's build stamp
#      (fmruby-core/tools/build_stamp.rb) matches the sources; a stale build
#      is refused with the files that are newer and the command that
#      rebuilds it, unless the caller allows it.
#   2. Restarting one container kills the frame buffer. There is no
#      single-container restart here, only the whole stack.
#   3. graphics-audio remembers the frame-buffer size and applies a change on
#      the NEXT boot, so the first run after switching hardware targets comes
#      up at the previous resolution. A start that comes up at the wrong size
#      restarts itself once.
#   4. The sdl2-display container runs an image built from three files (its
#      main.c and fmruby-core's two wire headers), and `docker compose up`
#      never rebuilds an image that exists. An image older than shm_display.h
#      reads the shared memory at the wrong offsets. Every start compares the
#      image's copies with the working tree first.
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
    # Modern's two resolutions (fmruby-core doc/modern_resolution): the sim
    # comes up at the one its system_conf asks for, 426x240 unless 640x360
    # was chosen in Config; the kernel boots any other value as 426x240.
    MODERN_SIZES = [[426, 240], [640, 360]].freeze
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
        File.join(@repo_root, "fmruby-core", "build-linux", "fmruby-core.elf")
    end

    def graphics_elf
      ENV["FMRB_MCP_SIM_GA_ELF"] ||
        File.join(@repo_root, "fmruby-graphics-audio", "build-linux",
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

    def up(gui: false, allow_stale: false)
      check_builds!
      notes = []
      check_stale!(allow_stale, notes)
      check_display_image!(notes)
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

    # the kernel, the host and the system desktop
    SYSTEM_PIDS = [0, 1, 2].freeze

    def app(action:, path: nil, pid: nil)
      args =
        case action
        when "ps" then ["ps"]
        when "spawn"
          raise Error, "spawn needs a path, e.g. /app/demo/kamon.app.rb" if path.nil? || path.empty?
          ["spawn", "path=#{path}"]
        when "kill"
          raise Error, "kill needs a pid (see action: \"ps\")" if pid.nil?
          if SYSTEM_PIDS.include?(pid.to_i)
            # the debug server would stop the kernel, the host or the desktop
            # all the same (devctl on the boards refuses them)
            raise Error, "pid #{pid.to_i} is part of the system (the kernel, the host or the desktop), " \
                         "not an app: stopping it leaves the sim without input. Kill a user app (see action: \"ps\")."
          end
          ["kill", "pid=#{pid.to_i}"]
        else
          raise Error, "unknown action #{action.inspect} (spawn|ps|kill)"
        end

      client = File.join(@repo_root, "fmruby-core", "tools", "debug", "fmrb_dbg_client.py")
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

    # Mute and volume through the debug server, the simulation's stand-in for
    # the boards' devctl /audio endpoints.
    def audio(action:, level: nil)
      args =
        case action
        when "get"    then ["audio"]
        when "mute"   then ["audio", "on=1"]
        when "unmute" then ["audio", "on=0"]
        when "volume"
          unless level.is_a?(Integer) && level.between?(0, 10)
            raise Error, "volume needs a level from 0 (silence) to 10"
          end
          ["audio", "volume=#{level}"]
        else
          raise Error, "unknown action #{action.inspect} (get|mute|unmute|volume)"
        end
      client = File.join(@repo_root, "fmruby-core", "tools", "debug", "fmrb_dbg_client.py")
      res = Sub.run({}, ["python3", client, "--json", "localhost", *args],
                    chdir: @repo_root, timeout: APP_TIMEOUT)
      unless res[:ok]
        hint = if res[:output].include?("refused") || res[:output].include?("Connection")
                 " The debug server lives in the running sim, so sim_up first."
               else
                 ""
               end
        raise Error, "sim_audio #{action} failed: #{res[:output].strip}#{hint}"
      end
      doc = begin
        JSON.parse(res[:output].lines.last.to_s)
      rescue JSON::ParserError
        raise Error, "the debug client answered something that is not JSON: " \
                     "#{Sub.clamp(res[:output], 2000)}"
      end
      if doc["error"]
        raise Error, "sim_audio #{action} was refused (#{doc['error']}): a core built " \
                     "before the mute (fmruby-core doc/reference/audio_output.md) does not know the command"
      end
      { muted: doc["muted"], volume: doc["volume"] }
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
                   "Both repositories build the sim in build-linux/ (beside the ESP32 build/). " \
                   "Build them:\n" \
                   "  cd fmruby-core && rake build:linux\n" \
                   "  cd fmruby-graphics-audio && rake build:linux"
    end

    # The two sim builds' stamps against their sources (fmruby-core/tools/
    # build_stamp.rb: the core's "linux", graphics-audio's "ga-linux"). A
    # stack that is already running is reused whatever it was built from (it
    # may be the user's), so then it is only reported.
    def check_stale!(allow_stale, notes)
      why = %w[linux ga-linux].filter_map { |kind| Stamp.refusal(@repo_root, kind) }.join("\n")
      return if why.empty?
      if allow_stale
        notes << "started a stale build (allow_stale): #{why.lines.first.strip}"
      elsif core_running?
        notes << "the running stack was reused, but its build is stale: #{why.lines.first.strip}"
      else
        raise Error, why
      end
    end

    # The files sdl2-display/Dockerfile copies into the image (paths from the
    # workspace root: the two headers are fmruby-core's wire format), and
    # where the image keeps them.
    DISPLAY_IMAGE_FILES = {
      "fmruby-core/components/fmrb_wire/include/shm_display.h" => "/app/include/shm_display.h",
      "fmruby-core/components/fmrb_wire/include/fmrb_hid_event.h" => "/app/include/fmrb_hid_event.h",
      "fmruby-graphics-audio/sdl2-display/main.c" => "/app/main.c",
    }.freeze

    def display_image_name
      res = Sub.run({}, ["docker", "compose", "config", "--images"], chdir: @repo_root, timeout: 60)
      name = res[:ok] ? res[:output].lines.map(&:strip).find { |l| l.end_with?("sdl2-display") } : nil
      name || "#{File.basename(@repo_root)}-sdl2-display"
    rescue Error
      "#{File.basename(@repo_root)}-sdl2-display"
    end

    # An image that does not exist yet is fine: compose builds it on the way
    # up. One that exists but was built from other sources is not -- compose
    # would run it as it is.
    def check_display_image!(notes)
      image = display_image_name
      res = Sub.run({}, ["docker", "run", "--rm", "--entrypoint", "cat", image,
                         *DISPLAY_IMAGE_FILES.values], chdir: @repo_root, timeout: 120)
      unless res[:ok]
        notes << "no #{image} image to compare with yet; compose builds it"
        return
      end
      local = DISPLAY_IMAGE_FILES.keys.map { |f| File.binread(File.join(@repo_root, f)) }.join
      return if res[:output].b == local.b

      raise Error, "the #{image} image was built from other sources than the working " \
                   "tree (#{DISPLAY_IMAGE_FILES.keys.join(', ')}). " \
                   "`docker compose up` reuses an image as it is, and one built from an older " \
                   "shm_display.h reads the frames and the sound at the wrong offsets. " \
                   "Rebuild it, then sim_up again:\n  docker compose build sdl2-display"
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
      # with the knowledge of whose stack it is. STALE_OK: the stamp was
      # checked (or allowed) above, once.
      res = Sub.run({ "STALE_OK" => "1" }, cmd, chdir: @repo_root, timeout: UP_TIMEOUT)
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
      MODERN_TARGETS.include?(hw_target) ? modern_size : RETRO_SIZE
    end

    # display_width / display_height of the file the sim boots from
    # (fmruby-core/flash/etc/system_conf.toml, made by rake build:linux from
    # config/, written by Config afterwards).
    def modern_size
      path = File.join(@repo_root, "fmruby-core", "flash", "etc", "system_conf.toml")
      w = h = nil
      if File.exist?(path)
        File.foreach(path) do |line|
          break if line.lstrip.start_with?("[")
          k, v = line.split("#", 2).first.split("=", 2).map { |x| x.to_s.strip }
          w = v.to_i if k == "display_width"
          h = v.to_i if k == "display_height"
        end
      end
      MODERN_SIZES.include?([w, h]) ? [w, h] : MODERN_SIZES.first
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
