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

// Diagnostic log, visible under Output -> "fmrb debug".
let output = null;
function log(msg) {
  if (output) output.appendLine(`[${new Date().toISOString()}] ${msg}`);
}

// The extension runs on the UI host (extensionKind ["ui"]), so under
// Remote-WSL this is the Windows side, where "python3" usually does not
// exist; the "py" launcher does.
function defaultPython() {
  return process.platform === "win32" ? "py" : "python3";
}

// Target string for fmrb_dbg_client.py / the DAP adapter: "ble[:<name>]"
// for BLE (empty spec -> scan for a single Family-mruby-* device), else
// "host:port" for TCP.
function targetOf(cfg) {
  if (cfg.transport === "ble") {
    return cfg.deviceName ? `ble:${cfg.deviceName}` : "ble";
  }
  return `${cfg.host || DEFAULT_HOST}:${cfg.port || DEFAULT_PORT}`;
}

// fmrb_proc_state_t (fmrb_app.h) -> display name.
const STATE_NAMES = { 0: "free", 1: "init", 2: "running", 3: "suspended", 4: "stopping" };

// The extension runs on the UI host (extensionKind ["ui"]). Under Remote-WSL
// the workspace lives inside WSL, so every location has two spellings:
//   posix - the path inside WSL ("/home/..."), what VSCode documents use and
//           what breakpoint/stack paths are exchanged in;
//   ui    - the same location as seen from the UI-host process (a
//           "\\wsl.localhost\<distro>\..." UNC path), needed for
//           fs.existsSync and for spawning / reading files with the Windows
//           Python. In a non-remote window both are the same fsPath.
function locsForUri(uri) {
  if (uri.scheme === "vscode-remote" && (uri.authority || "").startsWith("wsl")) {
    const distro = uri.authority.slice(uri.authority.indexOf("+") + 1);
    const winPath = uri.path.replace(/\//g, "\\");
    // \\wsl.localhost is current; \\wsl$ is the older alias.
    return [`\\\\wsl.localhost\\${distro}`, `\\\\wsl$\\${distro}`].map((root) => ({
      remote: true,
      authority: uri.authority,
      posix: uri.path,
      ui: root + winPath,
    }));
  }
  return [{ remote: false, posix: uri.fsPath, ui: uri.fsPath }];
}

function joinLoc(loc, ...parts) {
  return {
    remote: loc.remote,
    authority: loc.authority,
    posix: loc.remote ? [loc.posix, ...parts].join("/") : path.join(loc.posix, ...parts),
    ui: path.join(loc.ui, ...parts),
  };
}

// Existence check for a location. The UI-host extension process cannot stat
// \\wsl.localhost\... UNC paths with node fs (VSCode's UNC host allowlist
// silently turns existsSync into false), so remote locations are checked
// through vscode.workspace.fs with the original vscode-remote URI; child
// processes (the Windows Python) are not affected by the allowlist and can
// still open the UNC spelling.
async function locExists(loc) {
  if (loc.remote) {
    try {
      await vscode.workspace.fs.stat(
        vscode.Uri.from({ scheme: "vscode-remote", authority: loc.authority, path: loc.posix })
      );
      return true;
    } catch (e) {
      return false;
    }
  }
  try {
    return fs.existsSync(loc.ui);
  } catch (e) {
    return false;
  }
}

// Locate the fmruby-core checkout: the given (or any open) workspace folder
// may be the family-mruby root (contains fmruby-core/) or fmruby-core itself.
// Fall back to the sibling of this extension (in-tree development layout;
// when installed from a VSIX the extension lives under the extensions dir and
// has no such sibling, hence the workspace folders come first).
// Returns a {posix, ui, remote} location or null.
async function findCoreDir(context, folder) {
  const uris = [];
  if (folder && folder.uri) uris.push(folder.uri);
  for (const wf of vscode.workspace.workspaceFolders || []) {
    uris.push(wf.uri);
  }
  const candidates = [];
  for (const u of uris) {
    for (const loc of locsForUri(u)) {
      candidates.push(joinLoc(loc, "fmruby-core")); // family-mruby root
      candidates.push(loc);                         // fmruby-core itself
    }
  }
  const sibling = path.join(context.extensionPath, "..", "fmruby-core");
  candidates.push({ remote: false, posix: sibling, ui: sibling });
  for (const c of candidates) {
    const probe = joinLoc(c, "tool", "debug");
    const found = await locExists(probe);
    log(`findCoreDir: ${probe.remote ? probe.posix : probe.ui} -> ${found}`);
    if (found) return c;
  }
  log(
    `findCoreDir: no candidate matched (folder=${folder && folder.uri}, ` +
      `workspaceFolders=${(vscode.workspace.workspaceFolders || [])
        .map((wf) => wf.uri.toString())
        .join(", ")})`
  );
  return null;
}

async function toolPath(context, folder, file) {
  const core = await findCoreDir(context, folder);
  if (!core) return null;
  return path.join(core.ui, "tool", "debug", file);
}

// Run `fmrb_dbg_client.py <host:port> ps --json` and return the app list.
async function fetchPs(context, folder, cfg) {
  const py = cfg.pythonPath || defaultPython();
  const client = await toolPath(context, folder, "fmrb_dbg_client.py");
  if (!client) {
    return Promise.reject(
      new Error("fmruby-core checkout not found (open the family-mruby or fmruby-core folder)")
    );
  }
  const target = targetOf(cfg);
  // BLE needs to scan + connect first, which takes far longer than TCP.
  const timeout = cfg.transport === "ble" ? 40000 : 7000;
  log(`fetchPs: ${py} ${client} ${target} ps --json (timeout ${timeout}ms)`);
  return new Promise((resolve, reject) => {
    execFile(py, [client, target, "ps", "--json"], { timeout }, (err, stdout, stderr) => {
      log(`fetchPs: err=${err ? err.message : "none"} stdout=${(stdout || "").trim().slice(0, 200)} stderr=${(stderr || "").trim().slice(0, 200)}`);
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
    // BLE scan + connect takes seconds; show progress so the UI does not
    // look stuck.
    apps = await vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title:
          cfg.transport === "ble"
            ? "fmrb: scanning for device and querying apps over BLE..."
            : "fmrb: querying running apps...",
      },
      () => fetchPs(context, folder, cfg)
    );
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
  output = vscode.window.createOutputChannel("fmrb debug");
  context.subscriptions.push(output);
  log(
    `activate: version=${context.extension ? context.extension.packageJSON.version : "?"} ` +
      `platform=${process.platform} extensionPath=${context.extensionPath}`
  );
  const factory = {
    async createDebugAdapterDescriptor(session) {
      const cfg = session.configuration || {};
      const py = cfg.pythonPath || defaultPython();
      const adapter =
        cfg.adapterPath || (await toolPath(context, session.workspaceFolder, "fmrb_dap_adapter.py"));
      log(`createDebugAdapterDescriptor: py=${py} adapter=${adapter}`);
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
      log(
        `resolveDebugConfiguration: folder=${folder ? folder.uri.toString() : "none"} ` +
          `config=${JSON.stringify(config)}`
      );
      if (!config.type) {
        config.type = "fmrb";
        config.request = "attach";
        config.name = "fmrb: attach";
      }
      if (config.transport !== "ble") {
        config.host = config.host || DEFAULT_HOST;
        config.port = config.port || DEFAULT_PORT;
      }

      // Source-mapping defaults, resolved against the actual workspace so no
      // launch.json is needed (package.json "default" values are editor
      // hints only and never reach the adapter).
      const core = await findCoreDir(context, folder);
      if (core) {
        // The adapter runs on the UI host, and VSCode resolves the source
        // paths it returns against the UI host's filesystem — a plain
        // "/home/..." posix path would be looked up (and shown) as a local
        // Windows path. VSCode accepts full URIs in Source.path, so in a
        // remote window pass the local side of the mappings as
        // vscode-remote:// URI strings; the adapter only prefix-concatenates
        // them, and VSCode parses the result back to the workspace document.
        // combinedMaps are read from disk by the adapter itself -> ui form.
        const localStr = (loc) =>
          loc.remote
            ? vscode.Uri.from({
                scheme: "vscode-remote",
                authority: loc.authority,
                path: loc.posix + "/",
              }).toString()
            : loc.posix + path.sep;
        config.pathMappings = config.pathMappings || [
          { device: "/app/", local: localStr(joinLoc(core, "flash", "app")) },
        ];
        config.projectMappings = config.projectMappings || [
          { device: "/project/", local: localStr(core) },
        ];
        config.combinedMaps = config.combinedMaps || [
          path.join(core.ui, "main", "prebuild_scripts", "*", "mrb"),
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
        {
          type: "fmrb",
          request: "attach",
          name: "fmrb: attach over BLE (pick app)",
          transport: "ble",
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
