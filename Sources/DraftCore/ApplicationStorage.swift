import Darwin
import Foundation

/// User data never depends on the source checkout or the location of the app.
public enum ApplicationStorage {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PromptBridge", isDirectory: true)
    }
    public static var providers: URL { directory.appendingPathComponent("providers.json") }
    public static var preferences: URL { directory.appendingPathComponent("preferences.json") }

    /// Sources come from a verified previous installation; never scan for credentials.
    public static func migrate(from oldProviders: URL?, environment: URL? = nil,
                               to destination: URL = directory) throws {
        let manager = FileManager.default
        let providers = destination.appendingPathComponent("providers.json")
        let preferences = destination.appendingPathComponent("preferences.json")
        if !manager.fileExists(atPath: providers.path) {
            var library = try oldProviders.flatMap { try ProviderLibraryStore(fileURL: $0).load() }
            if library == nil, let environment,
               let config = try LocalEnvironment.configuration(fileURL: environment, environment: [:]) {
                let preset = ProviderPreset(name: "导入配置", configuration: config)
                library = ProviderLibrary(presets: [preset], activePresetID: preset.id)
            }
            if let library { try createOnly(JSONEncoder().encode(library), at: providers) }
        }
        if !manager.fileExists(atPath: preferences.path), let oldProviders,
           let value = try TranslationPreferencesStore(fileURL: oldProviders.deletingLastPathComponent()
                .appendingPathComponent("preferences.json")).load() {
            try createOnly(JSONEncoder().encode(value), at: preferences)
        }
    }

    private static func createOnly(_ data: Data, at destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".migration-" + UUID().uuidString)
        defer { try? manager.removeItem(at: stage) }
        // A hard link publishes one complete regular file without replacing an
        // existing destination, even if another instance saved during migration.
        guard manager.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ProviderLibraryError.writeFailed
        }
        if Darwin.link(stage.path, destination.path) != 0 && errno != EEXIST {
            throw ProviderLibraryError.writeFailed
        }
    }
}
