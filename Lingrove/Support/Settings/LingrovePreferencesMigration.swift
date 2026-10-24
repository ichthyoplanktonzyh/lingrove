import Foundation

/// One-time namespace upgrade inside the existing Lingrove app's own preference domain. The app
/// delegate runs it before building any settings models or @AppStorage views. Reading only the
/// persistent domain excludes launch arguments, registered defaults, and another app's settings.
/// Legacy values remain available for recovery; the version prevents a later reset from reviving
/// them. This policy never opens the original Cotabby application's domain or Keychain service.
nonisolated enum LingrovePreferencesMigration {
    static let versionKey = "lingrovePreferencesNamespaceVersion"

    @discardableResult
    static func migrate(_ defaults: UserDefaults, domainName: String, backupDirectory: URL? = nil) -> Int {
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        guard (saved[versionKey] as? Int ?? 0) < 1 else { return 0 }
        let legacy = saved.filter { LingroveCompatibility.preferenceKey(forLegacy: $0.key) != nil }
        // The original keys are never removed, even if writing a supplemental backup fails.
        // Atomic replacement and private file permissions keep the snapshot local to this user.
        if !legacy.isEmpty, let backupDirectory {
            saveBackup(saved, directory: backupDirectory)
        }
        var copied = 0
        for (key, value) in legacy {
            guard let primary = LingroveCompatibility.preferenceKey(forLegacy: key), saved[primary] == nil else { continue }
            defaults.set(value, forKey: primary)
            copied += 1
        }
        defaults.set(1, forKey: versionKey)
        return copied
    }

    private static func saveBackup(_ values: [String: Any], directory: URL) {
        let manager = FileManager.default
        let file = directory.appendingPathComponent("preferences-before-lingrove-namespace-v1.plist")
        guard !manager.fileExists(atPath: file.path) else { return }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // A backup is supplemental: retaining all original persistent keys is the recovery
            // guarantee. No preference contents or credentials are emitted from this boundary.
        }
    }
}
