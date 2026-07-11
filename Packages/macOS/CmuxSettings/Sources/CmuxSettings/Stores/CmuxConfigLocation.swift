import Foundation

/// Conventional on-disk locations for the amux JSON config.
///
/// A small value-typed bundle of URLs. Construct one with an explicit `home`
/// directory and inject it into the parts of the app that need to know where
/// the config file lives. No shared singletons; tests use a custom `home` URL
/// pointing into a temp directory.
///
/// ```swift
/// let locations = CmuxConfigLocation()
/// let store = JSONConfigStore(fileURL: locations.userConfigFile)
/// ```
public struct CmuxConfigLocation: Sendable, Hashable {
    /// The primary amux config file: `<home>/.config/amux/amux.json`.
    public let userConfigFile: URL

    /// Configuration files imported once when the primary file is absent.
    public let legacyConfigFiles: [URL]

    /// Creates a location bundle anchored at the given home directory.
    ///
    /// - Parameter home: The home directory to anchor paths to. Defaults to
    ///   `FileManager.default.homeDirectoryForCurrentUser`. Pass a temp URL
    ///   in tests.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // `URL.appending(path:)` is the modern Foundation API (macOS 13+);
        // returns a non-optional URL without the legacy `isDirectory` flag.
        self.userConfigFile = home.appending(path: ".config/amux/amux.json")
        self.legacyConfigFiles = [
            home.appending(path: ".config/cmux/cmux.json"),
            home.appending(path: ".config/cmux/settings.json"),
            home.appending(path: "Library/Application Support/com.cmuxterm.app/settings.json"),
        ]
    }
}
