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
require "json"

begin
  require "mcp"
rescue LoadError
  warn "fmrb-mcp: the `mcp` gem is missing. Install it with: gem install mcp"
  exit 1
end

require_relative "lib/serial_manager"

REPO_ROOT = File.expand_path("../..", __dir__)
MANAGER = FmrbMcp::SerialManager.new(repo_root: REPO_ROOT)

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

    THIS ERASES THE DEVICE'S /home PARTITION. User data goes with it, and so
    does the TTS API key (the key is injected at build time, so a rebuild and
    reflash restores it -- but anything the user saved on the device does not
    come back). Confirm with the user before flashing a board they have been
    using.

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
  input_schema: { properties: {}, required: [] },
) do |server_context: nil, **_extra|
  respond { MANAGER.flash }
end

server = MCP::Server.new(
  name: "fmrb",
  title: "Family mruby device tools",
  version: "0.1.0",
  instructions: <<~TXT,
    Serial and flash control for the Family mruby ESP32 boards.

    Normal order of work: serial_start once at the beginning, then serial_log
    whenever you want to look, and flash when you have a new build. Do not
    stop and restart the capture just to read it -- reopening the port resets
    the board and you lose the evidence.
  TXT
  tools: [SERIAL_START, SERIAL_LOG, SERIAL_STOP, FLASH],
)

at_exit { MANAGER.shutdown(archive: true) }
%w[TERM INT HUP].each do |sig|
  Signal.trap(sig) do
    MANAGER.shutdown
    exit!(0)
  end
end

MCP::Server::Transports::StdioTransport.new(server).open
