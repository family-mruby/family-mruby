#!/usr/bin/env ruby
# frozen_string_literal: true

# fmrb MCP server -- P1: serial capture + flash for the ESP32 boards.
#
# Register it with Claude Code via the repository's .mcp.json, or by hand:
#   claude mcp add fmrb -- ruby /path/to/family-mruby/tools/mcp/fmrb_mcp_server.rb
#
# The stdio rule: stdout carries JSON-RPC and nothing else. Everything this
# server or its children would print goes to stderr or to a file under
# ~/.fmrb_mcp/ (override with FMRB_MCP_STATE_DIR).
require "base64"
require "json"

begin
  require "mcp"
rescue LoadError
  warn "fmrb-mcp: the `mcp` gem is missing. Install it with: gem install mcp"
  exit 1
end

require_relative "lib/serial_manager"
require_relative "lib/tab5"
require_relative "lib/sim"

REPO_ROOT = File.expand_path("../..", __dir__)
MANAGER = FmrbMcp::SerialManager.new(repo_root: REPO_ROOT)
TAB5 = FmrbMcp::Tab5.new(repo_root: REPO_ROOT, state_dir: MANAGER.state_dir)
SIM = FmrbMcp::Sim.new(repo_root: REPO_ROOT, state_dir: MANAGER.state_dir)

MCP.configure do |config|
  config.exception_reporter = ->(exception, context) do
    warn "fmrb-mcp: #{exception.class}: #{exception.message} #{context.inspect}"
    warn exception.backtrace&.first(5)&.join("\n").to_s
  end
end

# Tool bodies return a Hash; this renders it as pretty JSON text so the model
# sees named fields rather than a wall of prose, and turns our own errors into
# tool errors instead of protocol errors.
def respond
  payload = yield
  MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(payload) }])
rescue FmrbMcp::LockBusy => e
  tool_error("port busy", e.message)
rescue FmrbMcp::Error => e
  tool_error("fmrb-mcp error", e.message)
rescue StandardError => e
  warn "fmrb-mcp: #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}"
  tool_error(e.class.name, e.message)
end

def tool_error(kind, message)
  MCP::Tool::Response.new(
    [{ type: "text", text: JSON.pretty_generate(error: kind, message: message) }],
    error: true,
  )
end

SERIAL_START = MCP::Tool.define(
  name: "serial_start",
  title: "Start the serial capture",
  description: <<~DESC,
    Open the ESP32 serial port once and keep it open, streaming the log to a
    file that serial_log reads. Start this at the beginning of a session and
    leave it running.

    Why it works this way: opening the port resets the board on most adapters,
    so a "open it only when I want to look" workflow keeps rebooting the thing
    you are trying to observe and hides the crash you are hunting. One long
    capture avoids that; serial_log then never touches the port.

    The port is exclusive. While a capture is open, nothing else can use the
    port -- but you do not need to stop it by hand to flash: the flash tool
    stops and resumes the capture for you.

    Arguments:
      port  - device path. Defaults to the cache in fmruby-core/.serial_port;
              if that is missing, `rake check-port` is run to detect the board
              (it probes with esptool inside docker and takes a while).
      baud  - default 115200.
      reset - false (default) attaches without touching the reset lines
              (--no-reset). true pulses RTS to reset the board first, so the
              log starts at the boot. Use true when you want a clean boot log,
              false when the board is already doing something you do not want
              to interrupt.

    Whether attaching reboots the board, and how much of the boot you get,
    depends on the board. Measured on both paths 2026-08-29:

      Tab5 / ESP32-P4 (USB-Serial-JTAG, /dev/ttyACM0): opening the port
      reboots the chip whichever value you pass -- the log says
      "rst:0x17 (CHIP_USB_UART_RESET)". So reset: false is NOT "attach
      without disturbing it" here; it costs one reboot. It is still the
      better choice on this board: it gives a log that starts at the ROM
      banner. reset: true adds a SECOND reset, and the USB re-enumeration
      that follows swallows the first ~0.4s, so the banner and the reset
      cause are lost and the log starts at the second-stage bootloader
      ("esp_image: segment 1"). Prefer reset: false on a Tab5.

      NARYA / ESP32-S3 (separate USB-UART bridge): reset: false attaches
      without pulsing the reset lines, and reset: true starts the log at the
      ROM banner. Some adapters still glitch DTR/RTS on open, so an attach
      can reboot the board there too, but it is not the rule.

    Either way it costs at most one reboot, once. That is exactly why the
    capture then stays open and serial_log reads the file instead.

    The capture stops on its own after 24 hours, and when this server exits.
  DESC
  annotations: { destructive_hint: false, idempotent_hint: true, open_world_hint: true },
  input_schema: {
    properties: {
      port: { type: "string", description: "serial device, e.g. /dev/ttyUSB0 or /dev/ttyACM0" },
      baud: { type: "integer", description: "baud rate (default 115200)" },
      reset: { type: "boolean", description: "pulse RTS to reset the board first (default false)" },
    },
    required: [],
  },
) do |port: nil, baud: nil, reset: false, server_context: nil, **_extra|
  respond { MANAGER.start(port: port, baud: baud, reset: reset) }
end

SERIAL_LOG = MCP::Tool.define(
  name: "serial_log",
  title: "Read the captured serial log",
  description: <<~DESC,
    Read the log file the capture is writing. This never opens the serial
    port, so calling it repeatedly cannot reset the board -- that is the whole
    point of keeping one capture open.

    It also works when no capture is running: you get whatever was captured
    before, with the time of the last write, so you can tell stale output from
    live output.

    Arguments:
      tail  - how many lines to return (default 100, max 5000). Lines are
              counted after filtering.
      grep  - keep only lines containing this text (plain substring).
      regex - treat grep as a Ruby regular expression instead. Note that shell
              grep syntax does not carry over: write "Guru|abort", not
              "Guru\\|abort".

    Useful filters for this firmware:
      "Guru"     crash markers; a healthy boot has none (also try "abort")
      "M1|"      per-step internal RAM snapshots during boot
      "fmrb_task:" 10s dump of per-task stack high-water marks
      "fmrb_app:"  VM pool and Spinel exception-stack depth
      "spx: hid_lat" input latency, "GFX STATS" graphics timing
      "rst:0x"   reset causes -- a new one here means the board rebooted.
                 On a Tab5 an attach shows "rst:0x17 (CHIP_USB_UART_RESET)";
                 anything appearing later means something really did reset it
  DESC
  annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true },
  input_schema: {
    properties: {
      grep: { type: "string", description: "substring filter (or regexp when regex is true)" },
      tail: { type: "integer", description: "number of lines to return (default 100, max 5000)" },
      regex: { type: "boolean", description: "treat grep as a Ruby regexp (default false)" },
    },
    required: [],
  },
) do |grep: nil, tail: 100, regex: false, server_context: nil, **_extra|
  respond { MANAGER.log(grep: grep, tail: tail, regex: regex) }
end

SERIAL_STOP = MCP::Tool.define(
  name: "serial_stop",
  title: "Stop the serial capture",
  description: <<~DESC,
    Stop the capture and release the port, so a serial monitor, `idf.py
    monitor`, or another session can use it. The log file is kept -- serial_log
    still reads it afterwards.

    You do not need this before flashing (the flash tool handles the port
    itself). Use it when handing the board over to something else, or to clear
    a capture left behind by a server that died.
  DESC
  annotations: { destructive_hint: false, idempotent_hint: true },
  input_schema: { properties: {}, required: [] },
) do |server_context: nil, **_extra|
  respond { MANAGER.stop }
end

FLASH = MCP::Tool.define(
  name: "flash",
  title: "Flash the firmware and summarise the boot",
  description: <<~DESC,
    Build-free flash of the already-built firmware in fmruby-core, doing the
    port dance for you: stop the capture, flash, resume the capture with
    --no-reset, then read the fresh log and summarise the boot.

    THE DEFAULT FULL FLASH ERASES THE DEVICE'S /home PARTITION. User data goes
    with it, and so does the TTS API key (the key is injected at build time, so
    a rebuild and reflash restores it -- but anything the user saved on the
    device does not come back). Confirm with the user before full-flashing a
    board they have been using.

    app_only: true writes only the app partition (`rake flash:app`). The
    storage image -- /home included -- is untouched, so no confirmation is
    needed and the write is much faster. Use it when only firmware code
    changed. The trade-off is silent staleness: if flash/ or config/ changed,
    the device keeps the OLD files with no warning. When in doubt about
    whether storage content changed, do a full flash.

    Fixed choices, on purpose:
      - FLASH_BAUD=115200. The rake default of 460800 frequently fails to
        connect under WSL2.
      - The target chip comes from FMRB_HW_TARGET in fmruby-core/.env. This
        tool never changes it; flash what is built.
      - Nothing is rebuilt here. Run the build yourself first.

    Reading the result:
      - "device reports readiness to read but returned no data" means some
        other process holds the port (a serial monitor, `rake monitor`, a
        capture outside this server), not a hardware fault.
      - A log that stops at "boot:0x204 (DOWNLOAD...)" / "waiting for
        download" is a download-mode stall, NOT a boot loop. It happens on the
        Tab5 (USB-Serial-JTAG) because the post-flash hard reset does not
        always take. Ask the user to press the reset button; do not go
        debugging a crash that did not happen.
      - The boot summary counts crash markers (Guru Meditation, abort()); zero
        is healthy.
      - If no capture was running before the flash, none is started after it,
        and there is no boot log. Call serial_start first when you want one.
      - Because the capture resumes with --no-reset, it can attach after the
        boot banner has already scrolled past. A missing banner is not a
        failure; use serial_start(reset: true) for a log that starts at boot.

    Attaching the USB device to WSL (`rake attach`, usbipd) is not done here --
    it needs Windows-side privileges. Ask the user if the port is missing.
  DESC
  annotations: { destructive_hint: true, idempotent_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      app_only: { type: "boolean",
                  description: "write only the app partition; storage (/home) untouched (default false)" },
    },
    required: [],
  },
) do |app_only: false, server_context: nil, **_extra|
  respond { MANAGER.flash(app_only: app_only) }
end


# --- Tab5 (Modern / ESP32-P4) over WiFi ------------------------------------
#
# None of these take a required address: the board is on DHCP, so a hard-coded
# IP is a bug waiting to happen. They resolve it, check it against the board's
# own /status, and cache it for five minutes.

TAB5_NOTE = <<~NOTE
  This is the Tab5 (Modern, ESP32-P4) only. The Retro board (NARYA/S3) has no
  remote desktop and cannot be driven this way -- use the Linux simulation, or
  ask the user to press the keys.

  The remote desktop is unauthenticated and its /app and /fs endpoints exist
  only in development builds (FMRB_DEV_REMOTE_CTL, on by default, off in
  release), so this assumes a board on a trusted network. A 404 means a
  firmware without them, not a broken board.

  A crash takes WiFi down with it, so when the board stops answering, the log
  that matters is on the serial line: serial_start / serial_log on this same
  server.
NOTE

TAB5_IP = MCP::Tool.define(
  name: "tab5_ip",
  title: "Find the Tab5 on the network",
  description: <<~DESC,
    Resolve the board's address and confirm it is answering, returning what
    its own /status says (ip, whether it is streaming, fps, kbps).

    You rarely need to call this: every other tab5_* tool resolves the address
    itself. Reach for it when one of them cannot find the board and you want
    to see the resolution attempts, or after a reboot to confirm the board is
    back.

    The address comes from mDNS (fmruby.local -- through the Windows resolver
    on WSL, avahi/getent otherwise) and is cached for five minutes. A cached
    address that stops answering is thrown away and resolved again rather than
    retried, because DHCP hands the board a different one on every boot.

    refresh: true skips the cache. ip: "1.2.3.4" pins an address for this call
    (it is still checked before use).

    #{TAB5_NOTE}
  DESC
  annotations: { read_only_hint: true, destructive_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      ip: { type: "string", description: "use this address instead of resolving" },
      refresh: { type: "boolean", description: "ignore the cached address (default false)" },
    },
    required: [],
  },
) do |ip: nil, refresh: false, server_context: nil, **_extra|
  respond { TAB5.resolve(ip, refresh: refresh) }
end

TAB5_SCREENSHOT = MCP::Tool.define(
  name: "tab5_screenshot",
  title: "See the Tab5's screen",
  description: <<~DESC,
    Grab one frame from the board's screen and return it as an image, so you
    can look at it directly instead of saving a file and opening it.

    The frame is 426x240 -- the frame buffer, which is also the coordinate
    system tab5_input uses, whatever size the picture looks on screen. The
    JPEG is also written to a file (the path comes back in the text part) for
    tools that want the bytes, such as fmrb_pngdiff.rb.

    Drawing reaches the screen when the app presents, not when it draws, so a
    shot taken immediately after an input can show the frame before the
    change. If the screen looks unchanged, take another one before concluding
    that the input did nothing.

    #{TAB5_NOTE}
  DESC
  annotations: { read_only_hint: true, destructive_hint: false, open_world_hint: true },
  input_schema: {
    properties: { ip: { type: "string", description: "use this address instead of resolving" } },
    required: [],
  },
) do |ip: nil, server_context: nil, **_extra|
  begin
    shot = TAB5.screenshot(ip: ip)
    MCP::Tool::Response.new([
      { type: "image", data: shot[:data], mimeType: "image/jpeg" },
      { type: "text", text: JSON.pretty_generate(shot.reject { |k, _| k == :data }) },
    ])
  rescue FmrbMcp::Error => e
    tool_error("fmrb-mcp error", e.message)
  rescue StandardError => e
    warn "fmrb-mcp: #{e.class}: #{e.message}"
    tool_error(e.class.name, e.message)
  end
end

TAB5_INPUT = MCP::Tool.define(
  name: "tab5_input",
  title: "Click and type on the Tab5",
  description: <<~DESC,
    Send mouse and keyboard events to the board. They join the firmware's
    normal input path, so global hotkeys work too (Ctrl+Q quits an app,
    Ctrl+Tab switches focus, F10 opens the menu bar, F11 is fullscreen).

    `commands` is one string, executed left to right:

      click X Y | rclick X Y | dclick X Y | move X Y | mdown X Y | mup X Y
      drag X1 Y1 X2 Y2 | key NAME | key ctrl+NAME | keydown NAME | keyup NAME
      sleep MS

    e.g. "click 20 5 sleep 500 click 15 17" or "key ctrl+tab".

    Coordinates are frame-buffer coordinates, 426x240, the same system
    tab5_screenshot returns -- unrelated to how large the window looks.

    Moving a window takes `drag`, not `click`: a title bar only follows a
    pointer that actually moves while the button is held. Click the window
    first to focus it, then drag it.

    Key names are the ones in the tool's scancode table: a-z, 0-9, f1-f12,
    arrows, tab, esc, enter, space, backspace, and a few symbols. An unknown
    name comes back as an error naming the key.

    Two things this cannot tell you. The Tab5's touch screen is relative
    (a tap moves the cursor from where it was), so a UI that depends on
    absolute touch positions cannot be judged from injected events -- ask the
    user to try it by hand. And these events look exactly like the user's own,
    so if they may be using the board right now, ask before interrupting.

    #{TAB5_NOTE}
  DESC
  annotations: { destructive_hint: false, idempotent_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      commands: { type: "string", description: "e.g. \"click 20 5 sleep 300 key enter\"" },
      ip: { type: "string", description: "use this address instead of resolving" },
    },
    required: ["commands"],
  },
) do |commands:, ip: nil, server_context: nil, **_extra|
  respond { TAB5.input(commands, ip: ip) }
end

TAB5_APP = MCP::Tool.define(
  name: "tab5_app",
  title: "Start, list and stop apps on the Tab5",
  description: <<~DESC,
    Drive apps by path instead of through the launcher: no menu, no scrolling
    to the right row, nothing that breaks when the list moves.

      action: "launch", path: "/app/demo/spinel_hello.app.rb"   -> returns a pid
      action: "ps"                                              -> pid, name, state
      action: "kill",   pid: 7

    Only user apps can be killed; the firmware refuses the kernel, the host
    and the system desktop, so a slip cannot take the screen down.

    With tab5_fs this is the development loop that needs no reflashing at all:
    put the .app.rb (and its .app.toml) under /app, launch it, look with
    tab5_screenshot, kill it, put the next version.

    #{TAB5_NOTE}
  DESC
  annotations: { destructive_hint: false, idempotent_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      action: { type: "string", enum: %w[launch ps kill], description: "launch, ps or kill" },
      path: { type: "string", description: "app path for launch, e.g. /app/demo/spinel_hello.app.rb" },
      pid: { type: "integer", description: "pid for kill (from action: ps)" },
      ip: { type: "string", description: "use this address instead of resolving" },
    },
    required: ["action"],
  },
) do |action:, path: nil, pid: nil, ip: nil, server_context: nil, **_extra|
  respond { TAB5.app(action: action, path: path, pid: pid, ip: ip) }
end

TAB5_FS = MCP::Tool.define(
  name: "tab5_fs",
  title: "Move files to and from the Tab5",
  description: <<~DESC,
    Read and write the board's filesystem over WiFi.

      action: "ls",    device_path: "/app"
      action: "get",   device_path: "/mnt/sd/shot.jpg", local_path: "shot.jpg"
      action: "put",   local_path: "my.app.rb", device_path: "/app/test/my.app.rb"
      action: "mkdir", device_path: "/app/test"
      action: "del",   device_path: "/app/test/my.app.rb"
      action: "pull",  device_path: "/mnt/sd/picorabbit", local_path: "./exports"
      action: "push",  local_path: "./myapp", device_path: "/app/myapp"
      action: "rmr",   device_path: "/app/test"

    Paths on the device are the four roots apps use -- /app, /home,
    /usr/share, /mnt/sd. Anything outside them, and any "..", is refused by
    the firmware.

    put writes to a temporary name and renames, so an interrupted upload does
    not leave a half-written file. pull and push skip files whose size already
    matches; force: true copies everything.

    Two things worth knowing: a large transfer pauses the remote desktop
    stream until it finishes (it comes back on its own), and "rmr" deletes a
    whole tree with no confirmation -- do not call it without the user asking
    for that deletion.

    #{TAB5_NOTE}
  DESC
  annotations: { destructive_hint: true, idempotent_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      action: { type: "string", enum: %w[ls get put push pull mkdir del rmr],
                description: "ls, get, put, push, pull, mkdir, del or rmr" },
      device_path: { type: "string", description: "path on the board (/app, /home, /usr/share, /mnt/sd)" },
      local_path: { type: "string", description: "path on this machine" },
      force: { type: "boolean", description: "for pull/push: copy even when sizes match" },
      ip: { type: "string", description: "use this address instead of resolving" },
    },
    required: ["action"],
  },
) do |action:, device_path: nil, local_path: nil, force: false, ip: nil, server_context: nil, **_extra|
  respond { TAB5.fs(action: action, device_path: device_path, local_path: local_path,
                    force: force, ip: ip) }
end


# --- Linux simulation (docker) ---------------------------------------------

SIM_NOTE = <<~NOTE
  The simulation runs the same core and graphics-audio code as the boards, on
  this machine, in three docker containers. It is the cheapest place to check
  a change; what it cannot tell you is how something sounds, how NTSC output
  looks, or how the real hardware behaves.

  Coordinates and resolution follow the hardware target in fmruby-core/.env:
  Retro (NARYAv3 and friends) is 320x240, Modern (TAB5, NARYAv4) is 426x240.
  sim_up reports the size it actually came up at.
NOTE

SIM_UP = MCP::Tool.define(
  name: "sim_up",
  title: "Start the Linux simulation",
  description: <<~DESC,
    Bring the simulation up (headless by default) and return the first frame,
    so you can see it booted rather than assume it.

    Two things it refuses to do quietly. It checks both ELFs are really x86-64
    before starting anything, because `rake build:linux` prints "Linux build
    complete" even when the build directory still holds an ESP32 build -- the
    classic false green. And if the stack comes up at the wrong resolution it
    restarts once by itself: graphics-audio remembers the frame-buffer size and
    applies a change on the next boot, so the first run after switching
    hardware targets is stale.

    A stack that is already running is reused as-is, never recreated -- the
    user may have a GUI run open. When that happens you are told, and a
    resolution mismatch on a reused stack is reported rather than fixed.

    gui: true uses a real X11 window instead of the headless SDL driver.

    The whole stack always goes up and down together. There is no
    single-container restart, because restarting core alone leaves the frame
    buffer dead while `docker compose ps` still says Up.

    #{SIM_NOTE}
  DESC
  annotations: { destructive_hint: false, idempotent_hint: true, open_world_hint: true },
  input_schema: {
    properties: { gui: { type: "boolean", description: "show an X11 window (default false, headless)" } },
    required: [],
  },
) do |gui: false, server_context: nil, **_extra|
  begin
    r = SIM.up(gui: gui)
    shot = File.exist?(r[:png]) ? Base64.strict_encode64(File.binread(r[:png])) : nil
    content = []
    content << { type: "image", data: shot, mimeType: "image/png" } if shot
    content << { type: "text", text: JSON.pretty_generate(r) }
    MCP::Tool::Response.new(content)
  rescue FmrbMcp::Error => e
    tool_error("fmrb-mcp error", e.message)
  rescue StandardError => e
    warn "fmrb-mcp: #{e.class}: #{e.message}"
    tool_error(e.class.name, e.message)
  end
end

SIM_DOWN = MCP::Tool.define(
  name: "sim_down",
  title: "Stop the Linux simulation",
  description: <<~DESC,
    Take the whole stack down (docker compose down) and forget its state.

    If the stack was already running when the sim tools first saw it, this
    refuses: it is the user's or another session's, possibly a GUI run they are
    watching. force: true takes it down anyway -- ask first.

    Tidy up with this when you are done verifying, so the next session starts
    from a known state.

    #{SIM_NOTE}
  DESC
  annotations: { destructive_hint: true, idempotent_hint: true },
  input_schema: {
    properties: { force: { type: "boolean", description: "take down a stack this server did not start" } },
    required: [],
  },
) do |force: false, server_context: nil, **_extra|
  respond { SIM.down(force: force) }
end

SIM_SCREENSHOT = MCP::Tool.define(
  name: "sim_screenshot",
  title: "See the simulation's screen",
  description: <<~DESC,
    Capture the current frame from the simulation's shared-memory frame buffer
    and return it as an image. The PNG is also written to a file (the path is
    in the text part) for tools like fmrb_pngdiff.rb.

    Drawing reaches the screen when the app presents, not when it draws, so a
    shot taken right after an input can still show the old frame. If nothing
    changed, take another one before deciding the input did nothing.

    wait: seconds to wait for a completed frame (the capture needs one).

    #{SIM_NOTE}
  DESC
  annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true },
  input_schema: {
    properties: { wait: { type: "integer", description: "seconds to wait for a frame (default: none)" } },
    required: [],
  },
) do |wait: nil, server_context: nil, **_extra|
  begin
    shot = SIM.screenshot(wait: wait)
    MCP::Tool::Response.new([
      { type: "image", data: shot[:data], mimeType: "image/png" },
      { type: "text", text: JSON.pretty_generate(shot.reject { |k, _| k == :data }) },
    ])
  rescue FmrbMcp::Error => e
    tool_error("fmrb-mcp error", e.message)
  rescue StandardError => e
    warn "fmrb-mcp: #{e.class}: #{e.message}"
    tool_error(e.class.name, e.message)
  end
end

SIM_INPUT = MCP::Tool.define(
  name: "sim_input",
  title: "Click and type in the simulation",
  description: <<~DESC,
    Send synthetic mouse and keyboard events. They are injected into the same
    input stream real SDL events use, so nothing downstream can tell them apart.

    `commands` is one string, executed left to right:

      move X Y | click X Y | down X Y | up X Y | key NAME | key shift+NAME
      text "STRING" | sleep MS

    Quote a string that contains spaces: text "hello world" arrives as one
    argument. A double click is click, sleep 120, click.

    Worth knowing before you trust a result:
      - Coordinates are frame-buffer coordinates; the size is whatever sim_up
        or sim_screenshot reported (320x240 Retro, 426x240 Modern).
      - Key handling in app code must read ev[:scancode]; ev[:keycode] here is
        an SDL keysym and differs from the device.
      - Alt is dead in the simulation. Menus reached with Alt cannot be
        driven here.
      - Kana input: toggle with key ctrl+space (works on any layout);
        key zenkaku only on a JP layout. In kana mode `text` becomes romaji
        composition (text "kya" gives きゃ).
      - A key press cannot be held: press and release are 40ms apart and get
        swallowed by the 50ms tick, so a game that needs a held key cannot be
        driven from here -- ask the user.
      - A newly added app does not appear in the launcher until it is
        rescanned (right-click, i.e. click with button 3). Launching by path
        with sim_app skips the launcher entirely.

    #{SIM_NOTE}
  DESC
  annotations: { destructive_hint: false, idempotent_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      commands: { type: "string", description: "e.g. \"click 30 55 sleep 120 click 30 55\"" },
    },
    required: ["commands"],
  },
) do |commands:, server_context: nil, **_extra|
  respond { SIM.input(commands) }
end

SIM_APP = MCP::Tool.define(
  name: "sim_app",
  title: "Start, list and stop apps in the simulation",
  description: <<~DESC,
    Drive apps by path through the simulation's debug server, the way tab5_app
    does over WiFi:

      action: "spawn", path: "/app/demo/kamon.app.rb"   -> returns a pid
      action: "ps"
      action: "kill",  pid: 5

    Paths are the device's, not this machine's (/app, /home, /usr/share).
    Launching by path needs no launcher interaction, so a newly added app runs
    without the right-click rescan the launcher would need.

    The debug server lives inside the running simulation: sim_up first, or the
    connection is simply refused.

    #{SIM_NOTE}
  DESC
  annotations: { destructive_hint: false, idempotent_hint: false, open_world_hint: true },
  input_schema: {
    properties: {
      action: { type: "string", enum: %w[spawn ps kill], description: "spawn, ps or kill" },
      path: { type: "string", description: "app path for spawn, e.g. /app/demo/kamon.app.rb" },
      pid: { type: "integer", description: "pid for kill (from action: ps)" },
    },
    required: ["action"],
  },
) do |action:, path: nil, pid: nil, server_context: nil, **_extra|
  respond { SIM.app(action: action, path: path, pid: pid) }
end

server = MCP::Server.new(
  name: "fmrb",
  title: "Family mruby device tools",
  version: "0.1.0",
  instructions: <<~TXT,
    Device tools for the Family mruby boards: the serial line and flashing for
    both of them, and remote control of the Tab5 (Modern, ESP32-P4) over WiFi.

    Serial: serial_start once at the beginning, then serial_log whenever you
    want to look, and flash when you have a new build. Do not stop and restart
    the capture just to read it -- reopening the port resets the board and you
    lose the evidence.

    Tab5 over WiFi: tab5_app launches and stops apps by path, tab5_screenshot
    shows the screen, tab5_input clicks and types, tab5_fs moves files. None of
    them need an address; it is resolved and re-resolved for you. When the
    board stops answering these, it has usually crashed and taken WiFi with
    it -- look at the serial log.

    The Retro board (NARYA/S3) has serial and flash only; it has no remote
    desktop -- check its UI in the simulation instead.

    Linux simulation: sim_up starts the three containers and shows the first
    frame, sim_screenshot and sim_input drive it, sim_app launches apps by
    path, sim_down tidies up. It refuses to start against a stale ESP32 build,
    and reuses (rather than recreates) a stack that is already running, which
    may be the user's.
  TXT
  tools: [SERIAL_START, SERIAL_LOG, SERIAL_STOP, FLASH,
          TAB5_IP, TAB5_SCREENSHOT, TAB5_INPUT, TAB5_APP, TAB5_FS,
          SIM_UP, SIM_DOWN, SIM_SCREENSHOT, SIM_INPUT, SIM_APP],
)

at_exit { MANAGER.shutdown(archive: true) }
%w[TERM INT HUP].each do |sig|
  Signal.trap(sig) do
    MANAGER.shutdown
    exit!(0)
  end
end

MCP::Server::Transports::StdioTransport.new(server).open
