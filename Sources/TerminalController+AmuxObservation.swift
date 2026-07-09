import CmuxMuxa
import Foundation

/// Socket handlers for the amux agent-observation layer (badges, details,
/// remote-host provisioning).
extension TerminalController {
    /// `amux.remote_setup` — inspect (default) or provision the muxa
    /// observation stack on an SSH host: muxa CLI presence/version, muxad
    /// liveness, agent-hook wiring, and muxa's own notifier state. Params:
    /// `host` (required SSH destination; `port`/`identity_file` optional),
    /// optional `action` — `"inspect"` (default) or `"wire"` (runs the
    /// hooks-only `muxa init` remotely, which also starts muxad when
    /// absent). Worker lane (SSH round trips via v2VmCall).
    nonisolated func v2AmuxRemoteSetup(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params), host.kind == .ssh else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let action = (params["action"] as? String) ?? "inspect"
        guard action == "inspect" || action == "wire" else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.amux.remoteSetupActionInvalid",
                    defaultValue: "action must be inspect or wire"
                )
            )
        }
        return v2VmCall(id: id, timeoutSeconds: 120) {
            let setup = AmuxRemoteHostSetup()
            var wireOutput: String?
            if action == "wire" {
                wireOutput = try await setup.wireHooks(host: host)
            }
            let report = try await setup.inspect(host: host)
            var payload: [String: Any] = [
                "host": host.destination,
                "muxa_installed": report.muxaVersion != nil,
                "muxad_running": report.muxadRunning,
                "claude_hooks": report.claudeHooksWired,
                "codex_hooks": report.codexHooksWired,
                "notifier_enabled": report.notifierEnabled,
            ]
            payload["muxa_version"] = report.muxaVersion
            payload["wire_output"] = wireOutput
            return payload
        }
    }

}
