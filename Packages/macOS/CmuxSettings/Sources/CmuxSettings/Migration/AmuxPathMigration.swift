public import Foundation
import Darwin
import os

/// Imports legacy cmux files into amux-owned paths without overwriting amux data.
///
/// The migration is idempotent, crash-safe, and safe to invoke concurrently
/// from multiple processes:
///
/// - A **persisted, version-stamped marker file** records that migration version
///   ``migrationVersion`` finished, so the whole migration is skipped on every
///   subsequent process start. This is what keeps the CLI (which runs on every
///   agent hook) and the app from re-copying files on every launch.
/// - A **cross-process advisory lock** (`flock` on a lockfile in the amux state
///   directory / project `.amux` directory) serializes concurrent processes; the
///   loser observes the stamp under the lock and skips.
/// - Every file copy is **atomic**: bytes land in a temp file inside the
///   destination directory and are then published with a single `rename(2)`. A
///   crash therefore strands only a temp file, never a half-written destination,
///   and a leftover temp is treated as re-copyable rather than fatal.
public enum AmuxPathMigration {
    /// Completed-migration version recorded in the stamp file. Bump this whenever
    /// the migration logic changes so older stamps no longer satisfy the guard and
    /// the migration re-runs once against the new logic.
    static let migrationVersion = 1

    /// Diagnostic log for the migration. These are developer/support logs, not
    /// user-facing UI strings, so they are intentionally not localized.
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "AmuxPathMigration")

    /// Stamp file name. The `-v1` suffix is the stamp *format* version; the
    /// completed migration version is stored as the file's contents.
    private static let stampFileName = ".migration-state-v1"

    /// Advisory-lock file name colocated with the stamp.
    private static let lockFileName = ".migration.lock"

    /// Suffix for the in-place temp file used by the atomic copy. Deterministic so
    /// a leftover temp from an interrupted run can be recognized and reclaimed.
    private static let tempSuffix = ".amux-migrate.tmp"

    private enum AmuxMigrationError: Error {
        case renameFailed(path: String, code: Int32)
    }

    // MARK: - User data

    /// Imports global configuration, support files, runtime data, and saved
    /// sessions into the amux-owned home directories.
    ///
    /// Legacy sources remain untouched so the migration is reversible. Subsequent
    /// reads and writes use only the amux destinations. Runs at most once per
    /// ``migrationVersion`` (see the type-level documentation).
    public static func migrateUserData(
        homeDirectory: URL,
        fileManager: FileManager
    ) throws {
        let stateDirectory = homeDirectory.appending(path: ".local/state/amux")
        let stampFile = stateDirectory.appending(path: stampFileName)

        // Fast path: the stamp already records the current version. This is the
        // common case on every process start after the first migration, so it
        // must not touch anything beyond one small file read.
        if isMigrationCurrent(stampFile: stampFile, fileManager: fileManager) { return }

        // Create the private state directory (0700) up front so the lock, the
        // stamp, and everything copied into it live in a directory that is private
        // from the moment it exists — not narrowed only after secrets have landed.
        try makePrivateDirectory(stateDirectory, restrictExisting: true, fileManager: fileManager)

        let lockFile = stateDirectory.appending(path: lockFileName)
        try withMigrationLock(at: lockFile, fileManager: fileManager) {
            // Double-checked under the lock: a racing process may have finished
            // while we waited to acquire it.
            if isMigrationCurrent(stampFile: stampFile, fileManager: fileManager) { return }
            try performUserDataMigration(
                homeDirectory: homeDirectory,
                stateDirectory: stateDirectory,
                fileManager: fileManager
            )
            writeStamp(to: stampFile, fileManager: fileManager)
        }
    }

    private static func performUserDataMigration(
        homeDirectory: URL,
        stateDirectory: URL,
        fileManager: FileManager
    ) throws {
        let newConfigDirectory = homeDirectory.appending(path: ".config/amux")
        let amuxDirectory = homeDirectory.appending(path: ".amux")

        // Create the private destination directories with 0700 up front, before
        // any secret-bearing file (socket password, relay auth) is copied in.
        // The config directory only gets 0700 when we create it, so we never
        // tighten permissions on a pre-existing user config directory.
        try makePrivateDirectory(newConfigDirectory, restrictExisting: false, fileManager: fileManager)
        try makePrivateDirectory(amuxDirectory, restrictExisting: true, fileManager: fileManager)
        try makePrivateDirectory(stateDirectory, restrictExisting: true, fileManager: fileManager)

        try mergeDirectory(
            from: homeDirectory.appending(path: ".config/cmux"),
            to: newConfigDirectory,
            excluding: ["cmux.json", "settings.json"],
            fileManager: fileManager
        )

        try importGlobalConfig(homeDirectory: homeDirectory, fileManager: fileManager)

        try mergeDirectory(
            from: homeDirectory.appending(path: ".cmux"),
            to: amuxDirectory,
            excluding: [],
            fileManager: fileManager
        )
        try mergeDirectory(
            from: homeDirectory.appending(path: ".cmuxterm"),
            to: amuxDirectory,
            excluding: [],
            fileManager: fileManager
        )
        try mergeDirectory(
            from: homeDirectory.appending(path: ".local/state/cmux"),
            to: stateDirectory,
            excluding: [],
            fileManager: fileManager
        )
    }

    /// Imports the global config file, keeping the Application Support fallback in
    /// its own do/catch. That fallback lives inside another app's container, so
    /// reading it can trip the macOS "access data from other apps" TCC denial; a
    /// failure there must not abort the rest of the migration.
    private static func importGlobalConfig(
        homeDirectory: URL,
        fileManager: FileManager
    ) throws {
        let locations = CmuxConfigLocation(home: homeDirectory)
        let destination = locations.userConfigFile
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let applicationSupportMarker = "/Library/Application Support/"
        let localSources = locations.legacyConfigFiles.filter {
            !$0.path.contains(applicationSupportMarker)
        }
        let applicationSupportSources = locations.legacyConfigFiles.filter {
            $0.path.contains(applicationSupportMarker)
        }

        // Same-container legacy sources first.
        if try copyFirstExisting(localSources, to: destination, fileManager: fileManager) {
            try normalizeSchemaURL(in: destination)
            return
        }

        // Application Support fallback, isolated so a TCC denial cannot abort the
        // remaining migration work.
        guard !applicationSupportSources.isEmpty else { return }
        do {
            if try copyFirstExisting(applicationSupportSources, to: destination, fileManager: fileManager) {
                try normalizeSchemaURL(in: destination)
            }
        } catch {
            logger.error(
                "Skipping Application Support legacy config import (likely macOS TCC denial): \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Project data

    /// Imports one project's `.cmux` directory and root `cmux.json` file into the
    /// amux-owned `.amux` directory and `amux.json` file.
    ///
    /// Does nothing when the directory has no legacy cmux data, so callers that
    /// walk ancestor directories never create empty `.amux` directories or stamps
    /// in unrelated parents. When there is legacy data, the migration is guarded
    /// by a per-project stamp and cross-process lock, and every copy is atomic.
    public static func migrateProjectData(
        at projectDirectory: URL,
        fileManager: FileManager,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let legacyDirectory = projectDirectory.appending(path: ".cmux")
        let legacyRootConfig = projectDirectory.appending(path: "cmux.json")
        let hasLegacyData = fileManager.fileExists(atPath: legacyDirectory.path)
            || fileManager.fileExists(atPath: legacyRootConfig.path)
        guard hasLegacyData else { return }

        // The stamp and lock live under the private home state directory, keyed
        // by the project's path — NOT inside the project's `.amux/`, which is a
        // repo directory the user commits (a `.migration.lock`/stamp landing in
        // a tracked tree is noise at best, an accidentally-committed lockfile at
        // worst). Only migrated *data* lands in `.amux/`.
        let projectMigrationsDirectory = homeDirectory
            .appending(path: ".local/state/amux/project-migrations")
        let projectKey = stableHash(projectDirectory.standardizedFileURL.path)
        let stampFile = projectMigrationsDirectory.appending(path: "\(projectKey).migration-state-v1")
        if isMigrationCurrent(stampFile: stampFile, fileManager: fileManager) { return }

        try makePrivateDirectory(projectMigrationsDirectory, restrictExisting: true, fileManager: fileManager)
        // The project `.amux` directory is a repo directory, not a secret store,
        // so it is created with default permissions (unlike the private home
        // directories), matching the pre-migration behavior.
        let destinationDirectory = projectDirectory.appending(path: ".amux")

        let lockFile = projectMigrationsDirectory.appending(path: "\(projectKey).migration.lock")
        try withMigrationLock(at: lockFile, fileManager: fileManager) {
            if isMigrationCurrent(stampFile: stampFile, fileManager: fileManager) { return }
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try performProjectDataMigration(
                projectDirectory: projectDirectory,
                legacyDirectory: legacyDirectory,
                destinationDirectory: destinationDirectory,
                fileManager: fileManager
            )
            writeStamp(to: stampFile, fileManager: fileManager)
        }
    }

    private static func performProjectDataMigration(
        projectDirectory: URL,
        legacyDirectory: URL,
        destinationDirectory: URL,
        fileManager: FileManager
    ) throws {
        try mergeDirectory(
            from: legacyDirectory,
            to: destinationDirectory,
            excluding: ["cmux.json"],
            fileManager: fileManager
        )
        let importedNestedConfig = try copyFirstExisting(
            [legacyDirectory.appending(path: "cmux.json")],
            to: destinationDirectory.appending(path: "amux.json"),
            fileManager: fileManager
        )
        if importedNestedConfig {
            try normalizeSchemaURL(in: destinationDirectory.appending(path: "amux.json"))
        }
        let importedRootConfig = try copyFirstExisting(
            [projectDirectory.appending(path: "cmux.json")],
            to: projectDirectory.appending(path: "amux.json"),
            fileManager: fileManager
        )
        if importedRootConfig {
            try normalizeSchemaURL(in: projectDirectory.appending(path: "amux.json"))
        }
    }

    // MARK: - Stamp / lock

    /// Reads the completed migration version recorded in the stamp, if any.
    private static func completedMigrationVersion(atStampFile url: URL) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the stamp records a version that already covers ``migrationVersion``.
    private static func isMigrationCurrent(stampFile url: URL, fileManager: FileManager) -> Bool {
        guard let completed = completedMigrationVersion(atStampFile: url) else { return false }
        return completed >= migrationVersion
    }

    /// Records that ``migrationVersion`` finished. Written atomically so a partial
    /// stamp can never be mistaken for a completed migration.
    private static func writeStamp(to url: URL, fileManager: FileManager) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try String(migrationVersion).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error(
                "Failed to write migration stamp at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Stable, seed-independent hash of a path, so a project's migration-marker
    /// filename is deterministic across processes and launches (Swift's `Hasher`
    /// is per-run randomized and unusable for a persisted name). FNV-1a.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Runs `body` while holding an exclusive advisory lock on `lockURL` so that
    /// concurrent processes serialize their migration. Best-effort: if the lock
    /// file cannot be opened or locked, `body` still runs (the stamp alone keeps
    /// the common case idempotent), and the failure is logged.
    private static func withMigrationLock<T>(
        at lockURL: URL,
        fileManager: FileManager,
        _ body: () throws -> T
    ) rethrows -> T {
        try? fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var openErrno: Int32 = 0
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let result = open(path, O_CREAT | O_RDWR, 0o600)
            if result < 0 { openErrno = errno }
            return result
        }
        guard descriptor >= 0 else {
            logger.error(
                "Could not open migration lock at \(lockURL.path, privacy: .public) (errno \(openErrno, privacy: .public)); proceeding without a cross-process lock"
            )
            return try body()
        }
        defer { close(descriptor) }

        if flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            logger.error(
                "Could not acquire migration lock at \(lockURL.path, privacy: .public) (errno \(code, privacy: .public)); proceeding without a cross-process lock"
            )
            return try body()
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    // MARK: - Copying

    @discardableResult
    private static func copyFirstExisting(
        _ sources: [URL],
        to destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: destination.path),
              let source = sources.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return false
        }
        return try atomicCopyFile(from: source, to: destination, fileManager: fileManager)
    }

    /// Copies a regular file to `destination` atomically. The bytes are copied to
    /// a temp file in the destination directory and then published with a single
    /// `rename(2)`, so a crash strands only the temp file and the destination is
    /// never observed half-written. A leftover temp from an interrupted run is
    /// removed first so the copy is not blocked. Never overwrites an existing
    /// destination.
    @discardableResult
    private static func atomicCopyFile(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: destination.path) else { return false }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let tempURL = parent.appending(path: destination.lastPathComponent + tempSuffix)
        // A leftover temp is stale (an earlier run crashed between copy and
        // rename); reclaim it so the fresh copy proceeds.
        if fileManager.fileExists(atPath: tempURL.path) {
            try? fileManager.removeItem(at: tempURL)
        }

        do {
            try fileManager.copyItem(at: source, to: tempURL)
        } catch CocoaError.fileWriteFileExists {
            // Raced with another temp appearing after our existence check; drop it
            // and copy once more.
            try? fileManager.removeItem(at: tempURL)
            try fileManager.copyItem(at: source, to: tempURL)
        }

        var renameErrno: Int32 = 0
        let published = tempURL.withUnsafeFileSystemRepresentation { tempPath -> Bool in
            guard let tempPath else { return false }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Bool in
                guard let destinationPath else { return false }
                if rename(tempPath, destinationPath) == 0 { return true }
                renameErrno = errno
                return false
            }
        }
        guard published else {
            try? fileManager.removeItem(at: tempURL)
            throw AmuxMigrationError.renameFailed(path: destination.path, code: renameErrno)
        }
        return true
    }

    private static func normalizeSchemaURL(in configFile: URL) throws {
        let source: String
        do {
            source = try String(contentsOf: configFile, encoding: .utf8)
        } catch {
            // Log rather than silently returning: a failure here means the
            // imported config keeps its legacy cmux schema URL and template text.
            logger.error(
                "Could not read imported config for schema normalization at \(configFile.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        var normalized = source
        let oldSchemaURLs = [
            "https://raw.githubusercontent.com/Open330/amux/main/web/data/cmux.schema.json",
            "https://raw.githubusercontent.com/Open330/amux/main/web/data/cmux-settings.schema.json",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json",
        ]
        for oldURL in oldSchemaURLs {
            normalized = normalized.replacingOccurrences(
                of: oldURL,
                with: "https://raw.githubusercontent.com/Open330/amux/main/web/data/amux.schema.json"
            )
        }
        normalized = normalized
            .replacingOccurrences(of: "cmux creates this template", with: "amux creates this template")
            .replacingOccurrences(
                of: "when both settings file locations are missing",
                with: "when the settings file is missing"
            )
            .replacingOccurrences(
                of: "~/.config/cmux/settings.json takes precedence over the Application Support fallback.",
                with: "~/.config/amux/amux.json is the active settings file."
            )
        try normalized.write(to: configFile, atomically: true, encoding: .utf8)
    }

    private static func mergeDirectory(
        from source: URL,
        to destination: URL,
        excluding excludedNames: Set<String>,
        fileManager: FileManager
    ) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) where !excludedNames.contains(item.lastPathComponent) {
            let target = destination.appending(path: item.lastPathComponent)
            let values = try item.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                // Symlink policy: never reproduce links. A recreated link could
                // dangle or resolve outside the source tree (into arbitrary,
                // possibly sensitive, locations) once placed under a private amux
                // directory. Legacy cmux data is plain files and directories, so
                // skipping links loses nothing in practice.
                logger.debug(
                    "Skipping symlink during migration: \(item.lastPathComponent, privacy: .public)"
                )
                continue
            }
            if values.isDirectory == true {
                try mergeDirectory(
                    from: item,
                    to: target,
                    excluding: [],
                    fileManager: fileManager
                )
            } else if values.isRegularFile == true {
                try atomicCopyFile(from: item, to: target, fileManager: fileManager)
            }
        }
    }

    // MARK: - Directories

    /// Ensures `url` exists as a directory. When it must be created, it is created
    /// with 0700 permissions so secrets copied into it are never briefly readable.
    /// When it already exists, permissions are tightened to 0700 only when
    /// `restrictExisting` is true.
    private static func makePrivateDirectory(
        _ url: URL,
        restrictExisting: Bool,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            if restrictExisting {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            return
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
