public import Foundation

/// Imports legacy cmux files into amux-owned paths without overwriting amux data.
public enum AmuxPathMigration {
    /// Imports global configuration, support files, runtime data, and saved sessions.
    ///
    /// Legacy sources remain untouched so the migration is reversible. Subsequent
    /// reads and writes use only the amux destinations.
    public static func migrateUserData(
        homeDirectory: URL,
        fileManager: FileManager
    ) throws {
        let oldConfigDirectory = homeDirectory.appending(path: ".config/cmux")
        let newConfigDirectory = homeDirectory.appending(path: ".config/amux")
        let configDirectoryExisted = fileManager.fileExists(atPath: newConfigDirectory.path)
        try mergeDirectory(
            from: oldConfigDirectory,
            to: newConfigDirectory,
            excluding: ["cmux.json", "settings.json"],
            fileManager: fileManager
        )

        let locations = CmuxConfigLocation(home: homeDirectory)
        let importedGlobalConfig = try copyFirstExisting(
            locations.legacyConfigFiles,
            to: locations.userConfigFile,
            fileManager: fileManager
        )
        if importedGlobalConfig {
            try normalizeSchemaURL(in: locations.userConfigFile)
        }

        let amuxDirectory = homeDirectory.appending(path: ".amux")
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

        let stateDirectory = homeDirectory.appending(path: ".local/state/amux")
        try mergeDirectory(
            from: homeDirectory.appending(path: ".local/state/cmux"),
            to: stateDirectory,
            excluding: [],
            fileManager: fileManager
        )
        let privateDirectories = [
            (newConfigDirectory, !configDirectoryExisted),
            (amuxDirectory, true),
            (stateDirectory, true),
        ]
        for (directory, shouldRestrict) in privateDirectories
        where shouldRestrict && fileManager.fileExists(atPath: directory.path) {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Imports one project's `.cmux` directory and root `cmux.json` file.
    public static func migrateProjectData(
        at projectDirectory: URL,
        fileManager: FileManager
    ) throws {
        let legacyDirectory = projectDirectory.appending(path: ".cmux")
        let destinationDirectory = projectDirectory.appending(path: ".amux")
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
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch CocoaError.fileWriteFileExists {
            return false
        }
    }

    private static func normalizeSchemaURL(in configFile: URL) throws {
        guard var source = try? String(contentsOf: configFile, encoding: .utf8) else { return }
        let oldSchemaURLs = [
            "https://raw.githubusercontent.com/Open330/amux/main/web/data/cmux.schema.json",
            "https://raw.githubusercontent.com/Open330/amux/main/web/data/cmux-settings.schema.json",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
            "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json",
        ]
        for oldURL in oldSchemaURLs {
            source = source.replacingOccurrences(
                of: oldURL,
                with: "https://raw.githubusercontent.com/Open330/amux/main/web/data/amux.schema.json"
            )
        }
        source = source
            .replacingOccurrences(of: "cmux creates this template", with: "amux creates this template")
            .replacingOccurrences(
                of: "when both settings file locations are missing",
                with: "when the settings file is missing"
            )
            .replacingOccurrences(
                of: "~/.config/cmux/settings.json takes precedence over the Application Support fallback.",
                with: "~/.config/amux/amux.json is the active settings file."
            )
        try source.write(to: configFile, atomically: true, encoding: .utf8)
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
            if values.isDirectory == true, values.isSymbolicLink != true {
                try mergeDirectory(
                    from: item,
                    to: target,
                    excluding: [],
                    fileManager: fileManager
                )
            } else if values.isRegularFile == true || values.isSymbolicLink == true,
                      !fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.copyItem(at: item, to: target)
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
        }
    }
}
