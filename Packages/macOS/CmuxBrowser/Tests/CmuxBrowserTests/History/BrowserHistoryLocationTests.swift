import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistoryLocationTests {
    @Test func foldsDebugAndStagingNamespaces() {
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.open330.amux.debug.my-tag") == "com.open330.amux.debug")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.open330.amux.staging.rc") == "com.open330.amux.staging")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app") == "com.cmuxterm.app")
    }

    @Test func historyFileURLNestsUnderNamespace() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let location = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.open330.amux.debug.tag")
        #expect(location.namespace == "com.open330.amux.debug")
        #expect(location.historyFileURL.path == "/tmp/appsupport/com.open330.amux.debug/browser_history.json")
    }

    @Test func legacyURLPresentOnlyWhenNamespaceDiffers() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let tagged = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.open330.amux.debug.tag")
        #expect(tagged.legacyTaggedHistoryFileURL?.path == "/tmp/appsupport/com.open330.amux.debug.tag/browser_history.json")

        let prod = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app")
        #expect(prod.legacyTaggedHistoryFileURL == nil)
    }

    @Test func amuxNamespacesExposeLegacyCmuxMigrationCandidates() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let stable = BrowserHistoryLocation(
            applicationSupportDirectory: root,
            bundleIdentifier: "com.open330.amux"
        )
        #expect(stable.legacyHistoryFileURLs.map(\.path) == [
            "/tmp/appsupport/com.cmuxterm.app/browser_history.json",
        ])

        let tagged = BrowserHistoryLocation(
            applicationSupportDirectory: root,
            bundleIdentifier: "com.open330.amux.debug.issue-7"
        )
        #expect(tagged.legacyHistoryFileURLs.map(\.path) == [
            "/tmp/appsupport/com.open330.amux.debug.issue-7/browser_history.json",
            "/tmp/appsupport/com.cmuxterm.app.debug/browser_history.json",
            "/tmp/appsupport/com.cmuxterm.app.debug.issue-7/browser_history.json",
        ])
    }
}
