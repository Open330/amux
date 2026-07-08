import AppKit

extension AppDelegate {
    /// Debug entrypoint for the amux Phase 0 spike: mirrors a local tmux
    /// session into a workspace through the RemoteTmux control-mode stack.
    ///
    /// Attach-or-creates the `amux-spike` session on the dedicated `-L amux`
    /// server socket (see ``RemoteTmuxHost/amuxLocal()``), so repeated
    /// invocations after the mirror workspace is closed re-attach to the same
    /// live session — the detach-survives-the-app property under test.
    @objc func openDebugAmuxLocalTmuxMirror(_ sender: Any?) {
        guard let manager = tabManager else { return }
        do {
            try remoteTmuxController.mirrorLocalAmuxSession(into: manager)
        } catch {
            #if DEBUG
            cmuxDebugLog("amux: local tmux mirror failed: \(error)")
            #endif
        }
    }
}
