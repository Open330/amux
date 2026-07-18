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
        let home = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        defer { try? FileManager.default.removeItem(at: home) }

        try write("legacy config", to: project.appending(path: ".cmux/cmux.json"))
        try write("legacy dock", to: project.appending(path: ".cmux/dock.json"))
        try write("new dock", to: project.appending(path: ".amux/dock.json"))

        try AmuxPathMigration.migrateProjectData(at: project, fileManager: .default, homeDirectory: home)

        #expect(try String(contentsOf: project.appending(path: ".amux/amux.json")) == "legacy config")
        #expect(try String(contentsOf: project.appending(path: ".amux/dock.json")) == "new dock")
        // The stamp and lock live under the private home state directory, never
        // in the committed project `.amux/` tree.
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".amux/.migration-state-v1").path))
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".amux/.migration.lock").path))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".local/state/amux/project-migrations").path))
    }

    @Test func skipsMigrationOnSecondRunWhenStampIsPresent() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        try write("v1", to: home.appending(path: ".config/cmux/dock.json"))
        try AmuxPathMigration.migrateUserData(homeDirectory: home, fileManager: .default)
        #expect(try String(contentsOf: home.appending(path: ".config/amux/dock.json")) == "v1")

        // The stamp must exist after a completed migration.
        #expect(FileManager.default.fileExists(
            atPath: home.appending(path: ".local/state/amux/.migration-state-v1").path
        ))

        // A newly-appearing legacy file must NOT be imported on a second run,
        // proving the whole migration is skipped once the stamp is present.
        try write("new", to: home.appending(path: ".config/cmux/late.json"))
        try AmuxPathMigration.migrateUserData(homeDirectory: home, fileManager: .default)
        #expect(!FileManager.default.fileExists(
            atPath: home.appending(path: ".config/amux/late.json").path
        ))
    }

    @Test func recoversLeftoverTempFileRatherThanStrandingIt() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        let fullConfig = #"{"$schema":"https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"}"#
        try write(fullConfig, to: home.appending(path: ".config/cmux/cmux.json"))

        // Simulate a crash between copy and rename in an earlier run: a leftover
        // deterministic temp file exists at the destination directory, but the
        // destination itself does not.
        let destination = home.appending(path: ".config/amux/amux.json")
        let leftoverTemp = home.appending(path: ".config/amux/amux.json.amux-migrate.tmp")
        try write("PARTIAL-TRUNCATED", to: leftoverTemp)
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        try AmuxPathMigration.migrateUserData(homeDirectory: home, fileManager: .default)

        // The destination is created from the full source (schema-normalized),
        // never from the stranded partial temp, and the temp is reclaimed.
        let imported = try String(contentsOf: destination)
        #expect(imported.contains("Open330/amux/main/web/data/amux.schema.json"))
        #expect(!imported.contains("PARTIAL-TRUNCATED"))
        #expect(!FileManager.default.fileExists(atPath: leftoverTemp.path))
    }

    @Test func destinationIsNeverAPartialFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        // A larger payload makes a non-atomic (direct) copy observably truncatable;
        // the atomic temp+rename guarantees the destination equals the full source
        // and leaves no temp behind.
        let payload = String(repeating: "amux-relay-token-", count: 4096)
        try write(payload, to: home.appending(path: ".cmux/relay/7000.auth"))

        try AmuxPathMigration.migrateUserData(homeDirectory: home, fileManager: .default)

        let destination = home.appending(path: ".amux/relay/7000.auth")
        #expect(try String(contentsOf: destination) == payload)
        #expect(!FileManager.default.fileExists(
            atPath: home.appending(path: ".amux/relay/7000.auth.amux-migrate.tmp").path
        ))
    }

    @Test func skipsProjectMigrationWhenNoLegacyDataPresent() throws {
        let project = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // A directory with no `.cmux`/`cmux.json` must not gain an `.amux`
        // directory or a stamp — this is what keeps ancestor-walking callers from
        // polluting unrelated parent directories.
        try AmuxPathMigration.migrateProjectData(at: project, fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".amux").path))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
