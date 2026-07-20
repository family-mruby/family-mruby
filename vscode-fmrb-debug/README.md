# Family mruby Debug (VSCode)

Debug PicoRuby VMs running on Family mruby from VSCode, via the `fmrb_debugd`
daemon (`doc/vm_remote_debug_*` in fmruby-core). Two transports:

- **TCP** (`"transport": "tcp"`, the default) — the Linux simulation on
  `localhost:5555`. Steps 1-4 below.
- **BLE** (`"transport": "ble"`) — ESP32 hardware over the BLE debug GATT
  service. See [Debugging hardware over BLE](#debugging-hardware-over-ble).

Japanese version: [README.ja.md](README.ja.md)

## How this debugger works (read first)

This is an **attach-style** debugger. There is no special "debug mode" or
debug build:

- Family mruby is started **normally** (the usual GUI simulation). The
  `fmrb_debugd` daemon is always part of the Linux build and starts listening
  on TCP 5555 automatically.
- VSCode attaches **later**, to an app that is already running. Until you
  attach, the VM runs with zero debugger overhead. When you disconnect, the
  app just keeps running.
- Only the attached app stops at breakpoints. The desktop, other apps, and
  the GUI keep running while it is parked.

So the order is always: **start the stack -> launch the target app in the
GUI -> attach from VSCode**.

## Prerequisites

- Both repos built for Linux (`rake build:linux`; see the repo root README).
- Python 3 with the `msgpack` package on the machine that runs VSCode
  (`pip install msgpack`).
- This repo checked out so that `vscode-fmrb-debug/` and `fmruby-core/` are
  siblings (the default `adapterPath` resolves relatively).

## Step 1: Start Family mruby (normal GUI startup)

In a WSL shell at the repo root, start the stack the way you always do:

```bash
docker compose up          # GUI window appears (WSLg)
```

That is all. `docker-compose.yml` already publishes the debug port
(`5555:5555` on the core service), and debugd is running inside fmruby-core
from boot. You do NOT need `dev_run_check.sh` — that script is the headless
variant used by the autonomous tests; it exposes the same port and works the
same way (`tools/dev_run_check.sh --keep`) if you ever want no GUI.

To check that debugd is reachable:

```bash
python3 fmruby-core/tool/debug/fmrb_dbg_client.py localhost:5555 version
python3 fmruby-core/tool/debug/fmrb_dbg_client.py localhost:5555 ps
```

`ps` lists the VMs (kernel, system_desktop, and any app you started) — these
are what you can attach to.

## Step 2: Launch the target app in the GUI

Start the app you want to debug from the Family mruby launcher (e.g. Kamon).
The app must exist in `ps` before VSCode attaches; attaching by name looks it
up there. (Restarting the app later is fine — pids change but the name match
is re-done on each attach.)

## Step 3: Install the extension (once)

No Extension Development Host / second window is needed. In your normal
VSCode window (the one where you have `family-mruby` or `fmruby-core` open):

1. Command Palette (`Ctrl+Shift+P`) ->
   **"Developer: Install Extension from Location..."**
2. Select the `family-mruby/vscode-fmrb-debug/` folder.

The extension is now installed persistently (it survives restarts; after
pulling extension changes, run "Developer: Reload Window").

The workspace can be either the `family-mruby` root or `fmruby-core` — the
extension detects the `fmruby-core` checkout and sets the breakpoint path
mappings accordingly.

## Step 4: Attach

1. Open the Run and Debug panel and select **"fmrb: attach (pick app)"**
   from the configuration dropdown (no launch.json needed). Start it: a
   QuickPick lists the VMs currently running on the device (`ps`); select
   the app to attach to.
2. Set breakpoints in the app's `.rb` source under
   `fmruby-core/flash/app/...` (e.g.
   `fmruby-core/flash/app/demo/kamon.app.rb`). Execution stops on hit, with
   the call stack and local variables. Stepping, pause, and continue work as
   usual.
3. Stop debugging (disconnect) when done — the app resumes and keeps
   running. You can re-attach any time.

Optional: if you always attach to the same app, pin it in
`.vscode/launch.json` and the picker is skipped:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fmrb",
      "request": "attach",
      "name": "fmrb: attach to Kamon",
      "host": "localhost",
      "port": 5555,
      "app": "Kamon"
    }
  ]
}
```

(`app` omitted -> picker; `app` set to a name or pid -> direct attach.)

## Debugging hardware over BLE

Same attach model as above, but the daemon lives on the board and is reached
over the BLE debug GATT service instead of TCP. Verified target: ESP32-S3
("Retro").

### Where things run

**WSL2 has no Bluetooth access.** The extension therefore declares
`extensionKind: ["ui"]`, so with Remote-WSL both the extension and the Python
adapter it spawns run on the **Windows** side. The workspace is reached over a
`\\wsl$\...` UNC path, which Windows Python can execute and read. TCP
debugging still works from there thanks to WSL2's localhost forwarding.

### Setup (once)

1. Install the Python dependencies on the **Windows** interpreter (not the WSL
   one):
   ```
   pip install bleak msgpack
   ```
2. Make sure Bluetooth is on and the board is not already connected to another
   host (the device accepts one connection at a time).
3. Find the device name from the boot log — look for the `BLE device name:`
   line, e.g. `Family-mruby-c4823e`. The name always ends with the low three
   bytes of the MAC.

### launch.json

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fmrb",
      "request": "attach",
      "name": "fmrb: attach over BLE",
      "transport": "ble",
      "deviceName": "Family-mruby-c4823e",
      "app": "Kamon",
      "pythonPath": "py"
    }
  ]
}
```

- `deviceName` may be omitted: the adapter then scans and connects if exactly
  one `Family-mruby-*` device is visible (it reports the candidates otherwise).
  A MAC address works too and skips the scan, which helps if scanning is
  unreliable.
- `pythonPath` defaults to `python3`, which often does not exist on Windows.
  Use `"py"` or a full path such as
  `"C:\\Users\\you\\AppData\\Local\\Programs\\Python\\Python312\\python.exe"`.

Then launch the app on the board and attach exactly as in step 4.

### Notes and limits

- On disconnect (including going out of range or killing VSCode) the device
  detaches every VM automatically, so a board is never left parked.
- There is no automatic reconnect: after a drop, restart the debug session.
- The first command after connecting is retried a few times, because frames
  sent in the brief window before the daemon registers its transport are
  dropped by design.

## Extension development (F5) — only when hacking on the extension itself

Open `vscode-fmrb-debug/` in a VSCode window and press F5. The Extension
Development Host opens `fmruby-core/` (see `.vscode/launch.json`).
Note VSCode cannot open the same folder in two windows: if the folder the
dev host tries to open is already open elsewhere, no new window appears —
close the other window first or change the folder argument.

## Shutting down

Disconnect the debug session first (so the app is not left parked), then stop
the stack as usual (`Ctrl-C` / `docker compose down`). If you forget to
disconnect, the TCP drop makes debugd auto-detach everything, so the stack
still shuts down cleanly.

If you restart the stack, just re-attach; nothing on the VSCode side needs to
change.

## Notes

- `app` may be an app name (matched against `ps`) or a numeric pid.
- Standalone app files (`flash/app/**.app.rb`) need no mapping: the device
  matches breakpoints by basename.
- Combined apps (kernel / `system_*`, built from `subdir/*.rb`) use the
  generated `*_combined.map.json` (see `combinedMaps`) to map original
  file:line <-> the combined line the device reports.
- Attaching to the kernel VM itself works, but while it is parked at a
  breakpoint the whole desktop UI freezes (by design). For "look without
  stopping", use `ps` / `log_read` from the CLI client instead.
- `extensionKind: ["ui"]` keeps the extension and the adapter on the VSCode UI
  host. BLE requires it (WSL2 has no Bluetooth); TCP works from there too via
  localhost forwarding.
- After changing `package.json` or `extension.js`, repackage
  (`npx @vscode/vsce package`) and reinstall the VSIX. Reloading the window is
  not enough.

## Troubleshooting

- `version` times out: the stack is not up, or the core service does not
  publish 5555 (check `docker compose ps` and `docker-compose.yml`).
- attach fails with NOT_FOUND: the app name does not match `ps` output —
  check the exact name with the `ps` command above.
- Breakpoint never hits: confirm the file's basename matches the running
  app's source, and (for combined apps) that the `*_combined.map.json` was
  regenerated by the last build.

BLE specifically:

- `bleak` not found: it was installed on the WSL interpreter instead of the
  Windows one, or `pythonPath` points at the wrong interpreter.
- "no Family-mruby-* device found": Bluetooth off, board not powered, or
  another host still holds the connection. Try naming the device (or its MAC)
  explicitly.
- Connects but every command times out: something is connected to the board
  but it is not answering — check the boot log for `debugd task started`.
- If running the adapter from the `\\wsl$` UNC path misbehaves, copy
  `fmruby-core/tool/debug/` to a local Windows folder and point `adapterPath`
  at that copy.

## Status

TCP (Linux simulation) and BLE (ESP32-S3) transports are implemented. The
adapter (`fmruby-core/tool/debug/fmrb_dap_adapter.py`) is verified headless by
`fmruby-core/tool/debug/test_phase2.py`, and the BLE frame codec is
cross-checked byte for byte against the device C implementation. The VSCode UI
flow and BLE end-to-end against real hardware require manual verification.
