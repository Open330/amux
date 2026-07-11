import Foundation
import Testing
@testable import CmuxSettings

@Suite struct AmuxPathMigrationTests {
    @Test func importsLegacyDataWithoutOverwritingAmuxFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        try write(
            #"{"$schema":"https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"}"#,
            to: home.appending(path: ".config/cmux/cmux.json")
        )
        try write("legacy dock", to: home.appending(path: ".config/cmux/dock.json"))
        try write("new dock", to: home.appending(path: ".config/amux/dock.json"))
        try write("session", to: home.appending(path: ".cmuxterm/codex-hook-sessions.json"))
        try write("relay", to: home.appending(path: ".cmux/relay/7000.auth"))

        try AmuxPathMigration.migrateUserData(homeDirectory: home, fileManager: .default)

        #expect(
            try String(contentsOf: home.appending(path: ".config/amux/amux.json"))
                .contains("Open330/amux/main/web/data/amux.schema.json")
        )
        #expect(try String(contentsOf: home.appending(path: ".config/amux/dock.json")) == "new dock")
        #expect(try String(contentsOf: home.appending(path: ".amux/codex-hook-sessions.json")) == "session")
        #expect(try String(contentsOf: home.appending(path: ".amux/relay/7000.auth")) == "relay")
        let permissions = try FileManager.default.attributesOfItem(
            atPath: home.appending(path: ".amux").path
        )[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test func importsProjectConfigAndLeavesCanonicalFilesAuthoritative() throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }

        try write("legacy config", to: project.appending(path: ".cmux/cmux.json"))
        try write("legacy dock", to: project.appending(path: ".cmux/dock.json"))
        try write("new dock", to: project.appending(path: ".amux/dock.json"))

        try AmuxPathMigration.migrateProjectData(at: project, fileManager: .default)

        #expect(try String(contentsOf: project.appending(path: ".amux/amux.json")) == "legacy config")
        #expect(try String(contentsOf: project.appending(path: ".amux/dock.json")) == "new dock")
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
