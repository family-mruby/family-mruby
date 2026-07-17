// Minimal VSCode extension for the Family mruby remote debugger.
//
// It registers debug type "fmrb" and launches the Python DAP adapter
// (fmruby-core/tool/debug/fmrb_dap_adapter.py) as an external process,
// bridging VSCode's DAP to fmrb_debugd over TCP.
//
// No launch.json is required: starting an "fmrb" session without an "app"
// queries `ps` on the device and shows a QuickPick of the running apps.
//
// extensionKind is ["ui"] so that under Remote-WSL the extension (and the
// adapter it spawns) run on the Windows UI host, matching the Phase 3 BLE
// requirement; for Phase 2 the adapter simply connects to localhost:5555
// (WSL2 -> Windows localhost forwarding).
const vscode = require("vscode");
const path = require("path");
const fs = require("fs");
const { execFile } = require("child_process");

const DEFAULT_HOST = "localhost";
const DEFAULT_PORT = 5555;

// fmrb_proc_state_t (fmrb_app.h) -> display name.
const STATE_NAMES = { 0: "free", 1: "init", 2: "running", 3: "suspended", 4: "stopping" };

// Locate the fmruby-core checkout: the given (or any open) workspace folder
// may be the family-mruby root (contains fmruby-core/) or fmruby-core itself.
// Fall back to the sibling of this extension (in-tree development layout;
// when installed from a VSIX the extension lives under ~/.vscode-server and
// has no such sibling, hence the workspace folders come first).
function findCoreDir(context, folder) {
  const candidates = [];
  const folders = [];
  if (folder && folder.uri && folder.uri.fsPath) folders.push(folder.uri.fsPath);
  for (const wf of vscode.workspace.workspaceFolders || []) {
    folders.push(wf.uri.fsPath);
  }
  for (const ws of folders) {
    candidates.push(path.join(ws, "fmruby-core")); // family-mruby root
    candidates.push(ws);                           // fmruby-core itself
  }
  candidates.push(path.join(context.extensionPath, "..", "fmruby-core"));
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, "tool", "debug"))) return c;
  }
  return null;
}

function toolPath(context, folder, file) {
  const core = findCoreDir(context, folder);
  if (!core) return null;
  return path.join(core, "tool", "debug", file);
}

// Run `fmrb_dbg_client.py <host:port> ps --json` and return the app list.
function fetchPs(context, folder, cfg) {
  const py = cfg.pythonPath || "python3";
  const client = toolPath(context, folder, "fmrb_dbg_client.py");
  if (!client) {
    return Promise.reject(
      new Error("fmruby-core checkout not found (open the family-mruby or fmruby-core folder)")
    );
  }
  const target = `${cfg.host || DEFAULT_HOST}:${cfg.port || DEFAULT_PORT}`;
  return new Promise((resolve, reject) => {
    execFile(py, [client, target, "ps", "--json"], { timeout: 7000 }, (err, stdout, stderr) => {
      if (err) {
        const detail = (stderr || "").trim() || err.message;
        reject(new Error(`ps query failed (is the stack up on ${target}?): ${detail}`));
        return;
      }
      try {
        const resp = JSON.parse(stdout.trim());
        if (resp && resp.apps) resolve(resp.apps);
        else reject(new Error(`unexpected ps response: ${stdout.trim()}`));
      } catch (e) {
        reject(new Error(`cannot parse ps output: ${stdout.trim()}`));
      }
    });
  });
}

// Show a QuickPick of running apps; resolves to a pid, or undefined if
// cancelled.
async function pickApp(context, folder, cfg) {
  let apps;
  try {
    apps = await fetchPs(context, folder, cfg);
  } catch (e) {
    vscode.window.showErrorMessage(`fmrb: ${e.message}`);
    return undefined;
  }
  if (!apps.length) {
    vscode.window.showErrorMessage("fmrb: no VMs running (start an app on the device first)");
    return undefined;
  }
  const items = apps.map((a) => ({
    label: a.name || `pid ${a.pid}`,
    description: `pid=${a.pid}  ${STATE_NAMES[a.state] || a.state}`,
    detail: `mem ${a.mem_used}/${a.mem_total}`,
    pid: a.pid,
  }));
  const sel = await vscode.window.showQuickPick(items, {
    placeHolder: "Select the app (VM) to attach to",
  });
  return sel ? sel.pid : undefined;
}

function activate(context) {
  const factory = {
    createDebugAdapterDescriptor(session) {
      const cfg = session.configuration || {};
      const py = cfg.pythonPath || "python3";
      const adapter =
        cfg.adapterPath || toolPath(context, session.workspaceFolder, "fmrb_dap_adapter.py");
      if (!adapter) {
        throw new Error(
          "fmrb: fmruby-core checkout not found (open the family-mruby or fmruby-core folder, or set adapterPath)"
        );
      }
      return new vscode.DebugAdapterExecutable(py, [adapter]);
    },
  };
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("fmrb", factory)
  );

  const provider = {
    // Fill defaults; when "app" is not given, let the user pick from `ps`.
    async resolveDebugConfiguration(folder, config) {
      if (!config.type) {
        config.type = "fmrb";
        config.request = "attach";
        config.name = "fmrb: attach";
      }
      config.host = config.host || DEFAULT_HOST;
      config.port = config.port || DEFAULT_PORT;

      // Source-mapping defaults, resolved against the actual workspace so no
      // launch.json is needed (package.json "default" values are editor
      // hints only and never reach the adapter).
      const core = findCoreDir(context, folder);
      if (core) {
        config.pathMappings = config.pathMappings || [
          { device: "/app/", local: path.join(core, "flash", "app") + path.sep },
        ];
        config.projectMappings = config.projectMappings || [
          { device: "/project/", local: core + path.sep },
        ];
        config.combinedMaps = config.combinedMaps || [
          path.join(core, "main", "prebuild_scripts", "*", "mrb"),
        ];
      }

      if (config.app === undefined || config.app === null || config.app === "") {
        const pid = await pickApp(context, folder, config);
        if (pid === undefined) return undefined; // cancelled -> abort session
        config.app = pid;
      }
      return config;
    },

    // Entries for the Run and Debug dropdown (no launch.json needed).
    provideDebugConfigurations(_folder, _token) {
      return [
        {
          type: "fmrb",
          request: "attach",
          name: "fmrb: attach (pick app)",
          host: DEFAULT_HOST,
          port: DEFAULT_PORT,
        },
      ];
    },
  };
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("fmrb", provider)
  );
  // Same entry offered dynamically so it shows up without any launch.json.
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider(
      "fmrb",
      provider,
      vscode.DebugConfigurationProviderTriggerKind.Dynamic
    )
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
