# Family mruby Debug (VSCode)

Debug PicoRuby VMs running on Family mruby from VSCode, via the `fmrb_debugd`
daemon (`doc/vm_remote_debug_*` in fmruby-core). Phase 2: TCP transport against
the Linux simulation (`localhost:5555`).

## Prerequisites

- The Family mruby stack running with debugd listening on TCP 5555
  (`tools/dev_run_check.sh --keep` at the repo root exposes it via docker
  compose port `5555:5555`).
- Python 3 with the `msgpack` package on the machine that runs VSCode
  (`pip install msgpack`).
- This repo checked out so that `vscode-fmrb-debug/` and `fmruby-core/` are
  siblings (the default `adapterPath` resolves relatively).

## Run (development mode)

1. Open the `vscode-fmrb-debug/` folder in VSCode.
2. Press `F5` (Run Extension) to launch an Extension Development Host.
3. In the dev host, open your Family mruby workspace (the folder containing
   `fmruby-core/`).
4. Create `.vscode/launch.json`:

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

5. Launch a debuggable app on the device (e.g. Kamon from the launcher).
6. Start debugging with the config above. Set breakpoints in the app's `.rb`
   source; execution stops on hit, with the call stack and local variables.

## Notes

- `app` may be an app name (matched against `ps`) or a numeric pid.
- Standalone app files (`flash/app/**.app.rb`) need no mapping: the device
  matches breakpoints by basename.
- Combined apps (kernel / `system_*`, built from `subdir/*.rb`) use the
  generated `*_combined.map.json` (see `combinedMaps`) to map original
  file:line <-> the combined line the device reports.
- `extensionKind: ["ui"]` keeps the adapter on the VSCode UI host, which is
  what Phase 3 (BLE, Windows-only) will need. For Phase 2 the adapter just
  connects to `localhost:5555`.

## Status

Phase 2 (TCP). The adapter (`fmruby-core/tool/debug/fmrb_dap_adapter.py`) is
verified headless by `fmruby-core/tool/debug/test_phase2.py`. The VSCode UI
flow (F5, breakpoint gutter, variables pane, stepping) requires manual
verification on a machine with the VSCode GUI.
