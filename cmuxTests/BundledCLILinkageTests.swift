import XCTest

enum BundledCLITestSupport {
    static func bundledCLIPath(
        for bundleClass: AnyClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try bundledCLIURL(for: bundleClass, file: file, line: line).path
    }

    static func bundledCLIURL(
        for bundleClass: AnyClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: bundleClass)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedCLIURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("amux", isDirectory: false)

        if fileManager.isExecutableFile(atPath: expectedCLIURL.path) {
            return expectedCLIURL
        }
        let compatibilityCLIURL = expectedCLIURL.deletingLastPathComponent()
            .appendingPathComponent("cmux", isDirectory: false)
        if fileManager.isExecutableFile(atPath: compatibilityCLIURL.path) {
            return compatibilityCLIURL
        }

        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard ["amux", "cmux"].contains(item.lastPathComponent),
                  item.path.contains(".app/Contents/Resources/bin/"),
                  fileManager.isExecutableFile(atPath: item.path) else { continue }
            return item
        }

        let message = "Bundled amux CLI not found at \(expectedCLIURL.path)"
        XCTFail(message, file: file, line: line)
        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}

final class BundledCLILinkageTests: XCTestCase {
    deinit {}

    func testBundledCLIDynamicDependenciesResolveFromAppBundle() throws {
        let cliURL = try bundledCLIURL()
        let linkedLibraries = try linkedLibraries(for: cliURL)
        let privateRPathFrameworks = linkedLibraries.filter {
            $0.hasPrefix("@rpath/") && $0.contains(".framework/")
        }
        let missingFrameworks = privateRPathFrameworks.filter {
            !bundledFrameworkExists(for: $0, cliURL: cliURL)
        }

        XCTAssertEqual(
            missingFrameworks,
            [],
            "The bundled amux CLI must be able to resolve every private @rpath framework from the containing app bundle."
        )
    }

    func testBundledCLIRunsDirectlyAndThroughSymlink() throws {
        let cliURL = try bundledCLIURL()
        try assertCLIPrintsHelp(cliURL)

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let symlinkURL = tempDirectory.appendingPathComponent("amux")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: cliURL)
        try assertCLIPrintsHelp(symlinkURL)
    }

    private func bundledCLIURL() throws -> URL {
        try BundledCLITestSupport.bundledCLIURL(for: Self.self)
    }

    private func linkedLibraries(for executableURL: URL) throws -> [String] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", executableURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "otool failed: \(output)")

        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ")
                    .first
                    .map(String.init)
            }
    }

    private func bundledFrameworkExists(for rpathLibrary: String, cliURL: URL) -> Bool {
        let relativePath = rpathLibrary.replacingOccurrences(of: "@rpath/", with: "")
        let contentsURL = cliURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let frameworkURL = contentsURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        return FileManager.default.fileExists(atPath: frameworkURL.path)
    }

    private func assertCLIPrintsHelp(_ executableURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--help"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "CLI failed: \(output)", file: file, line: line)
        XCTAssertTrue(output.contains("amux - control amux"), "Unexpected CLI help output: \(output)", file: file, line: line)
    }
}
