import Foundation

/// Tahoe can permanently hide menu bar items keyed by bundle ID; we bumped the ID once (v1.0.4).
enum LegacyDefaultsMigration {
    private static let migratedKey = "didMigrateLegacyDefaults_v1"
    private static let oldBundle = "com.local.claude-code-proxy-token-monitor-tray"

    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(oldBundle).plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        for (key, value) in dict where !key.hasPrefix("NSStatusItem") {
            UserDefaults.standard.set(value, forKey: key)
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
        StartupLog.mark("migrated defaults from \(oldBundle)")
    }
}
