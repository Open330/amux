import Foundation

/// Owns the per-endpoint ``RemoteTmuxSSHTransport`` instances ``RemoteTmuxController``
/// uses for SSH discovery, keyed by ``RemoteTmuxHost/connectionHash`` (destination +
/// port + identity).
///
/// Factored out of the controller so the get-or-create lifecycle and the scattered
/// dictionary bookkeeping live behind a small `@MainActor` surface. It only manages
/// the transport handles; it deliberately does NOT own the `ssh -O exit`
/// (``RemoteTmuxSSHTransport/spawnControlMasterExit(host:)``) teardown, which the
/// controller sequences around its own `await` gaps.
@MainActor
final class RemoteTmuxTransportRegistry {
    private var transports: [String: any RemoteTmuxTransport] = [:]

    /// Returns (creating if needed) the transport for a host — SSH for remote
    /// hosts, the local process runner for the amux engine. The two kinds can
    /// never collide on a cache slot: ``RemoteTmuxHost/connectionHash`` mixes
    /// the kind into the digest.
    func transport(for host: RemoteTmuxHost) -> any RemoteTmuxTransport {
        if let existing = transports[host.connectionHash] {
            return existing
        }
        let transport: any RemoteTmuxTransport = switch host.kind {
        case .ssh: RemoteTmuxSSHTransport(host: host)
        case .localDefault, .localAmux: RemoteTmuxLocalTransport(host: host)
        }
        transports[host.connectionHash] = transport
        return transport
    }

    /// Tears down a host's shared SSH master (used when removing a host).
    func disconnectMaster(host: RemoteTmuxHost) async {
        let transport = transports.removeValue(forKey: host.connectionHash)
        await transport?.shutdownMaster()
    }

    /// Whether a transport already exists for `connectionHash` (the reattach-reclaim check).
    func contains(connectionHash: String) -> Bool {
        transports[connectionHash] != nil
    }

    /// Removes and returns the transport for `connectionHash`, if any.
    @discardableResult
    func remove(connectionHash: String) -> (any RemoteTmuxTransport)? {
        transports.removeValue(forKey: connectionHash)
    }

    /// The hosts of every currently-tracked transport.
    func allHosts() -> [RemoteTmuxHost] {
        transports.values.map(\.host)
    }

    /// Drops every tracked transport (does not exit their masters).
    func removeAll() {
        transports.removeAll()
    }
}
