# Family mruby Debug (VSCode)

Debug PicoRuby VMs running on Family mruby from VSCode, via the `fmrb_debugd`
daemon (`doc/vm_remote_debug_*` in fmruby-core). Phase 2: TCP transport against
the Linux simulation (`localhost:5555`).

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
- `extensionKind: ["ui"]` keeps the adapter on the VSCode UI host, which is
  what Phase 3 (BLE, Windows-only) will need. For Phase 2 the adapter just
  connects to `localhost:5555`.

## Troubleshooting

- `version` times out: the stack is not up, or the core service does not
  publish 5555 (check `docker compose ps` and `docker-compose.yml`).
- attach fails with NOT_FOUND: the app name does not match `ps` output —
  check the exact name with the `ps` command above.
- Breakpoint never hits: confirm the file's basename matches the running
  app's source, and (for combined apps) that the `*_combined.map.json` was
  regenerated by the last build.

## Status

Phase 2 (TCP). The adapter (`fmruby-core/tool/debug/fmrb_dap_adapter.py`) is
verified headless by `fmruby-core/tool/debug/test_phase2.py`. The VSCode UI
flow (F5, breakpoint gutter, variables pane, stepping) requires manual
verification on a machine with the VSCode GUI.
