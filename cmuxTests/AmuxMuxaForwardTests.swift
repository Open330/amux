import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AmuxMuxaForwardTests: XCTestCase {
    func testForwardSocketPathIsHostUniqueAndBounded() {
        let a = RemoteTmuxHost(destination: "alice@gpu-box")
        let b = RemoteTmuxHost(destination: "alice@other-box")
        XCTAssertNotEqual(a.muxaForwardSocketPath, b.muxaForwardSocketPath)
        XCTAssertTrue(a.muxaForwardSocketPath.contains("/.cmux/ssh/muxa-"))
        XCTAssertTrue(a.muxaForwardSocketPath.hasSuffix("-\(a.connectionHash).sock"))
        XCTAssertTrue(
            RemoteTmuxHost.controlSocketPathFitsUnixLimit(a.muxaForwardSocketPath),
            "forward socket path must fit the AF_UNIX limit"
        )
    }

    func testForwardSocketPathBoundedForLongDestination() {
        let long = RemoteTmuxHost(
            destination: "some-extremely-long-user-name@a-very-long-hostname.internal.example.company.network.example.com"
        )
        XCTAssertTrue(RemoteTmuxHost.controlSocketPathFitsUnixLimit(long.muxaForwardSocketPath))
        XCTAssertTrue(long.muxaForwardSocketPath.hasSuffix("-\(long.connectionHash).sock"))
    }

    func testForwardSocketPathDiffersFromControlSocketPath() {
        let host = RemoteTmuxHost(destination: "alice@gpu-box")
        XCTAssertNotEqual(host.muxaForwardSocketPath, host.controlSocketPath)
    }

    func testProbeOutputParserPicksSocketPathLine() {
        let output = """
        Welcome to gpu-box! Message of the day.
        /run/user/1000/muxa.sock
        """
        XCTAssertEqual(
            RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: output),
            "/run/user/1000/muxa.sock"
        )
    }

    func testProbeOutputParserAcceptsTmpFallbackPath() {
        XCTAssertEqual(
            RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: "/tmp/muxa-501.sock\n"),
            "/tmp/muxa-501.sock"
        )
    }

    func testProbeOutputParserRejectsNoise() {
        XCTAssertNil(RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: ""))
        XCTAssertNil(RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: "bash: no such file\n"))
        XCTAssertNil(RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: "muxa.sock"))
        XCTAssertNil(RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: "/etc/passwd"))
    }

    func testProbeOutputParserTakesLastCandidate() {
        let output = """
        /tmp/muxa-0.sock
        /run/user/1000/muxa.sock
        """
        XCTAssertEqual(
            RemoteTmuxHost.remoteMuxaSocketPath(fromProbeOutput: output),
            "/run/user/1000/muxa.sock"
        )
    }

    func testForwardInvocationShape() {
        let host = RemoteTmuxHost(destination: "alice@gpu-box")
        let argv = host.muxaForwardInvocation(remoteSocketPath: "/run/user/1000/muxa.sock")
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        XCTAssertTrue(argv.contains("-N"))
        XCTAssertTrue(argv.contains("ExitOnForwardFailure=yes"))
        guard let lIndex = argv.firstIndex(of: "-L") else {
            return XCTFail("missing -L")
        }
        XCTAssertEqual(argv[lIndex + 1], "\(host.muxaForwardSocketPath):/run/user/1000/muxa.sock")
        // `--` must guard the destination so a dash-prefixed destination can
        // never be parsed as an ssh option.
        XCTAssertEqual(Array(argv.suffix(2)), ["--", "alice@gpu-box"])
        XCTAssertTrue(argv.contains("BatchMode=yes"))
    }

    func testCanConnectIsFalseForMissingSocket() {
        XCTAssertFalse(
            AmuxRemoteMuxaForwarder.canConnect(
                unixSocketPath: NSTemporaryDirectory() + "cmux-test-nonexistent-\(UUID().uuidString).sock"
            )
        )
    }
}
