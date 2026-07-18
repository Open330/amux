import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmuxRemoteHostSetupTests: XCTestCase {
    func testParsesFullyProvisionedHost() {
        let report = AmuxRemoteHostSetup.parseReport(fromProbeOutput: """
        Welcome banner noise
        MUXA_VERSION=muxa 0.8.17
        MUXAD=running
        HOOKS_CLAUDE=wired
        HOOKS_CODEX=wired
        """)
        XCTAssertEqual(report.muxaVersion, "muxa 0.8.17")
        XCTAssertTrue(report.muxadRunning)
        XCTAssertTrue(report.claudeHooksWired)
        XCTAssertTrue(report.codexHooksWired)
        XCTAssertFalse(report.notifierEnabled)
    }

    func testParsesBareHost() {
        let report = AmuxRemoteHostSetup.parseReport(fromProbeOutput: """
        MUXA_VERSION=
        MUXAD=absent
        HOOKS_CLAUDE=absent
        HOOKS_CODEX=absent
        """)
        XCTAssertNil(report.muxaVersion)
        XCTAssertFalse(report.muxadRunning)
        XCTAssertFalse(report.claudeHooksWired)
        XCTAssertFalse(report.codexHooksWired)
    }

    func testParsesNotifierEnabled() {
        let report = AmuxRemoteHostSetup.parseReport(fromProbeOutput: """
        MUXA_VERSION=muxa 0.8.17
        MUXAD=running
        HOOKS_CLAUDE=wired
        HOOKS_CODEX=absent
        NOTIFIER=enabled
        """)
        XCTAssertTrue(report.notifierEnabled)
        XCTAssertFalse(report.codexHooksWired)
    }

    func testWireArgvIsHooksOnlyInit() {
        let script = AmuxRemoteHostSetup.wireHooksArgv.joined(separator: " ")
        XCTAssertTrue(script.contains("--component claude-hooks,codex-hooks,gemini-hooks,opencode-hooks"))
        XCTAssertTrue(script.contains("--yes"))
        // Never the full wizard/preset: hooks-only is the contract (no
        // tmux.conf edits, no service-manager install from amux).
        XCTAssertFalse(script.contains("--preset"))
    }

    // Regression: hook detection must match the concrete command muxa installs
    // (`muxa hook <agent>`), not the bare product name. A codex config whose
    // only "muxa" occurrence is a `[projects."…/muxa"]` path header, or a stray
    // comment mentioning muxa, must NOT be reported as "hooks wired".
    func testInspectionMatchesConcreteHookMarkers() {
        let script = AmuxRemoteHostSetup.inspectionArgv.joined(separator: " ")
        XCTAssertTrue(script.contains("muxa hook claude"))
        XCTAssertTrue(script.contains("muxa hook codex"))
        XCTAssertFalse(
            script.contains("grep -qs muxa \""),
            "the loose bare-product grep false-positives on unrelated muxa mentions"
        )
    }
}
