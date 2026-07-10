import Foundation

/// UserDefaults keys for the device presence heartbeat.
///
/// amux ships no hosted presence endpoint. A distributor must explicitly set a
/// service URL and authentication composition before this client can run.
enum PresenceSettings {
    /// Master gate. Resolved by ``isEnabled(defaults:)``; an explicit value
    /// always wins, otherwise Debug defaults on and Release off.
    static let enabledKey = "presenceHeartbeatEnabled"
    /// Base URL of the presence service (the cmux-presence worker), e.g.
    /// "https://cmux-presence.<account>.workers.dev". Empty means disabled.
    static let serviceURLKey = "presenceServiceURL"
    /// Env override for dev/tagged builds, mirroring CMUX_VM_API_BASE_URL.
    static let serviceURLEnvKey = "CMUX_PRESENCE_BASE_URL"
    /// Empty by design: amux does not inherit the upstream development worker.
    static let debugDefaultServiceURL = ""

    /// Empty by design: amux does not inherit the upstream production worker.
    static let productionServiceURL = ""

    /// Whether the heartbeat gate is on. An explicitly written value always wins.
    /// With no stored value, presence FOLLOWS the mobile feature: announcing the
    /// Mac's presence only makes sense once the user has enabled iOS pairing/host
    /// (``MobileHostService/isListeningEnabled``), and a user who turns mobile on
    /// expects their phone to see the Mac online. Default (mobile off) => off, for
    /// privacy — the Mac announces nothing until the user opts into mobile.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) != nil {
            return defaults.bool(forKey: enabledKey)
        }
        return MobileHostService.isListeningEnabled(defaults: defaults)
    }
}
