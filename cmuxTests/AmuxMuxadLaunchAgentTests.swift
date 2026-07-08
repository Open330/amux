import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmuxMuxadLaunchAgentTests: XCTestCase {
    func testDefersToRunningDaemonWithoutWritingPlist() {
        let agent = AmuxMuxadLaunchAgent()
        // A muxad is already running → never install a competing agent,
        // regardless of whether a bundled muxad exists.
        XCTAssertEqual(
            agent.install(muxadPath: "/bundled/muxad", daemonAlreadyRunning: true),
            .deferredToRunningDaemon
        )
        XCTAssertFalse(agent.isInstalled, "no plist should be written when deferring")
    }

    func testNoBundledDaemonWhenPathMissing() {
        let agent = AmuxMuxadLaunchAgent()
        XCTAssertEqual(
            agent.install(muxadPath: nil, daemonAlreadyRunning: false),
            .noBundledDaemon
        )
        XCTAssertFalse(agent.isInstalled)
    }

    func testPlistContainsLabelAndProgram() {
        let plist = AmuxMuxadLaunchAgent.plistContents(muxadPath: "/opt/amux/bin/muxad")
        XCTAssertTrue(plist.contains("<string>com.open330.amux.muxad</string>"))
        XCTAssertTrue(plist.contains("<string>/opt/amux/bin/muxad</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
    }

    func testPlistPathUnderLaunchAgents() {
        XCTAssertTrue(
            AmuxMuxadLaunchAgent().plistURL.path
                .hasSuffix("Library/LaunchAgents/com.open330.amux.muxad.plist")
        )
    }
}
