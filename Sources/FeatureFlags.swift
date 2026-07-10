import Foundation
import Observation

struct CmuxFeatureFlagDefinition: Identifiable, Equatable {
    var id: String { key }

    let key: String
    let title: String
    let flagDescription: String
    let defaultWhenUnavailable: Bool
}

/// Compatibility feature flags for settings inherited from cmux. amux does not
/// connect these flags to an external provider; injected providers remain
/// available to deterministic tests and future Open330-owned integrations.
///
/// Fallback semantics (flags must never break the app):
/// - Until an explicitly injected provider returns a payload, every flag keeps
///   its safe default. Production amux does not inject a hosted provider.
/// - Once a payload has arrived, a false flag reads as off. An absent flag
///   still uses the explicit per-flag fallback below.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags()

    private static let proUpgradeUIDefault = false
    private static let mobileConnectButtonDefault = false
    private static let overrideKeyPrefix = "cmux.flags.override."

    // Order is load-bearing for the typed accessors below. A keyed lookup would
    // repeat flag-key literals and violate the feature-flag lint's single
    // evaluation-site rule.
    static var allFlags: [CmuxFeatureFlagDefinition] {
        [
            // FLAG(key: pro-upgrade-ui-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Retained for config compatibility. amux does not expose the inherited
            // cmux billing service, so the typed accessor remains disabled.
            CmuxFeatureFlagDefinition(
                key: "pro-upgrade-ui-enabled-release",
                title: String(localized: "featureFlags.proUpgrade.title", defaultValue: "Pro upgrade UI"),
                flagDescription: String(
                    localized: "featureFlags.proUpgrade.description",
                    defaultValue: "Shows Pro upgrade entrypoints in the sidebar, Settings, command palette, and Help menu."
                ),
                defaultWhenUnavailable: Self.proUpgradeUIDefault
            ),

            // FLAG(key: mobile-connect-button-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
            // Retained for config compatibility. amux does not expose the inherited
            // cmux account-backed pairing service, so the accessor remains disabled.
            CmuxFeatureFlagDefinition(
                key: "mobile-connect-button-enabled-release",
                title: String(localized: "featureFlags.mobileConnect.title", defaultValue: "Mobile Connect button"),
                flagDescription: String(
                    localized: "featureFlags.mobileConnect.description",
                    defaultValue: "Shows the iPhone button that opens the Mobile Connect pairing window."
                ),
                defaultWhenUnavailable: Self.mobileConnectButtonDefault
            ),
        ]
    }

    var isProUpgradeUIEnabled: Bool {
        false
    }

    var isMobileConnectButtonEnabled: Bool {
        false
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let remoteFlagValueProvider: (String) -> Any?
    private var localOverridesByKey: [String: Bool] = [:]
    private var remoteValuesByKey: [String: Bool] = [:]
    private var effectiveValuesByKey: [String: Bool] = [:]

    init(
        defaults: UserDefaults = .standard,
        remoteFlagValueProvider: @escaping (String) -> Any? = { _ in nil }
    ) {
        self.defaults = defaults
        self.remoteFlagValueProvider = remoteFlagValueProvider
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    /// Resolves an explicitly injected provider once. The production provider
    /// is nil, so inherited hosted flags retain their safe defaults.
    func start() {
        applyLoadedFlags()
    }

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        effectiveValuesByKey[definition.key] ?? definition.defaultWhenUnavailable
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func remoteValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        remoteValuesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        let previousEffectiveValues = effectiveValuesByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    func clearAllOverrides() {
        let previousEffectiveValues = effectiveValuesByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    func applyLoadedFlags() {
        let previousEffectiveValues = effectiveValuesByKey
        remoteValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key)) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    private func recomputeEffectiveValues() {
        effectiveValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = localOverridesByKey[definition.key]
                ?? remoteValuesByKey[definition.key]
                ?? definition.defaultWhenUnavailable
        }
    }

    private func postChangeIfNeeded(previousEffectiveValues: [String: Bool]) {
        if Self.allFlags.contains(where: { definition in
            previousEffectiveValues[definition.key] != effectiveValuesByKey[definition.key]
        }) {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: overrideDefaultsKey(for: key)) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?, default fallback: Bool) -> Bool {
        coerceBoolFlagValue(value) ?? fallback
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }

        return nil
    }
}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
