// Minimal VSCode extension for the Family mruby remote debugger.
//
// It registers debug type "fmrb" and launches the Python DAP adapter
// (fmruby-core/tools/debug/fmrb_dap_adapter.py) as an external process,
// bridging VSCode's DAP to fmrb_debugd over TCP.
//
// extensionKind is ["ui"] so that under Remote-WSL the extension (and the
// adapter it spawns) run on the Windows UI host, matching the Phase 3 BLE
// requirement; for Phase 2 the adapter simply connects to localhost:5555
// (WSL2 -> Windows localhost forwarding).
const vscode = require("vscode");
const path = require("path");

function activate(context) {
  const factory = {
    createDebugAdapterDescriptor(session) {
      const cfg = session.configuration || {};
      const py = cfg.pythonPath || "python3";
      // Default: the adapter in a sibling fmruby-core checkout next to this
      // extension (…/family-mruby/vscode-fmrb-debug -> …/family-mruby/fmruby-core).
      const adapter =
        cfg.adapterPath ||
        path.join(
          context.extensionPath,
          "..",
          "fmruby-core",
          "tools",
          "debug",
          "fmrb_dap_adapter.py"
        );
      return new vscode.DebugAdapterExecutable(py, [adapter]);
    },
  };

  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("fmrb", factory)
  );

  // Provide a default attach config when none exists.
  const provider = {
    resolveDebugConfiguration(_folder, config) {
      if (!config.type) {
        config.type = "fmrb";
        config.request = "attach";
        config.name = "fmrb: attach";
        config.host = "localhost";
        config.port = 5555;
        config.app = "Kamon";
      }
      return config;
    },
  };
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("fmrb", provider)
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
