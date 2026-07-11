import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite(.serialized)
struct FeatureFlagsTests {
    @Test("feature flag bool coercion accepts provider bool-like values")
    func featureFlagBoolCoercionAcceptsProviderBoolLikeValues() {
        #expect(CmuxFeatureFlags.coerceBoolFlagValue(true, default: false))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(false, default: true))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue(NSNumber(value: true), default: false))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(NSNumber(value: false), default: true))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue("TRUE", default: false))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(" false ", default: true))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue("not-a-bool", default: true))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue("not-a-bool", default: false))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue(nil, default: true))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(nil, default: false))
    }

    @MainActor
    @Test("feature flag resolution prefers override, then remote, then default")
    func featureFlagResolutionPrecedence() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first)
        let suiteName = "cmux.feature.flags.precedence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var remoteValues: [String: Any] = [:]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }

        #expect(flags.overrideValue(for: flag) == nil)
        #expect(flags.remoteValue(for: flag) == nil)
        #expect(!flags.effectiveValue(for: flag))

        remoteValues[flag.key] = true
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == true)
        #expect(flags.effectiveValue(for: flag))

        flags.setOverride(false, for: flag)
        #expect(flags.overrideValue(for: flag) == false)
        #expect(flags.remoteValue(for: flag) == true)
        #expect(!flags.effectiveValue(for: flag))

        flags.setOverride(nil, for: flag)
        #expect(flags.overrideValue(for: flag) == nil)
        #expect(flags.effectiveValue(for: flag))

        remoteValues.removeValue(forKey: flag.key)
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == nil)
        #expect(!flags.effectiveValue(for: flag))
    }

    @MainActor
    @Test("feature flag overrides persist through UserDefaults")
    func featureFlagOverridePersistenceRoundTrip() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first)
        let suiteName = "cmux.feature.flags.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstLoad = CmuxFeatureFlags(defaults: defaults) { _ in true }
        firstLoad.setOverride(false, for: flag)
        #expect(firstLoad.overrideValue(for: flag) == false)
        #expect(!firstLoad.effectiveValue(for: flag))

        let secondLoad = CmuxFeatureFlags(defaults: defaults) { _ in true }
        #expect(secondLoad.overrideValue(for: flag) == false)
        #expect(!secondLoad.effectiveValue(for: flag))

        secondLoad.setOverride(nil, for: flag)
        let thirdLoad = CmuxFeatureFlags(defaults: defaults) { _ in true }
        #expect(thirdLoad.overrideValue(for: flag) == nil)
        #expect(!thirdLoad.effectiveValue(for: flag))

        thirdLoad.applyLoadedFlags()
        #expect(thirdLoad.effectiveValue(for: flag))
    }

    @MainActor
    @Test("feature flag override notifications follow effective value changes")
    func featureFlagOverrideNotificationsFollowEffectiveValueChanges() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first)
        let suiteName = "cmux.feature.flags.notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let remoteValues: [String: Any] = [flag.key: false]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }
        flags.applyLoadedFlags()

        let notificationQueue = DispatchQueue(label: "cmux.feature.flags.notification.count")
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: flags,
            queue: nil
        ) { _ in
            notificationQueue.sync {
                notificationCount += 1
            }
        }
        defer {
            NotificationCenter.default.removeObserver(token)
        }

        flags.setOverride(false, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 0)

        flags.setOverride(true, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 1)

        flags.setOverride(true, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 1)

        flags.setOverride(nil, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 2)
    }
}
#endif
