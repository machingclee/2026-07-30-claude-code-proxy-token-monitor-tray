import Foundation
import SQLite3

/// Companion to CC Switch — reads/writes the same files as `ccs` / the GUI.
/// No independent provider or key storage.
///
/// Data sources:
/// - `~/.cc-switch/cc-switch.db`  providers + common_config_claude
/// - `~/.cc-switch/settings.json` currentProviderClaude
/// - `~/.claude/settings.json`    live Claude Code settings (written on activate)
enum CCSwitchService {
    static let appType = "claude"

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private static var dbURL: URL {
        home.appendingPathComponent(".cc-switch/cc-switch.db")
    }

    private static var ccSettingsURL: URL {
        home.appendingPathComponent(".cc-switch/settings.json")
    }

    private static var claudeSettingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    private static var backupDir: URL {
        home.appendingPathComponent(".cc-switch/backups")
    }

    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        var isCurrent: Bool
        let model: String
        let base: String
        /// Raw settings_config object from CC Switch (includes env).
        let settingsConfig: [String: Any]

        static func == (lhs: Provider, rhs: Provider) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.isCurrent == rhs.isCurrent
                && lhs.model == rhs.model
                && lhs.base == rhs.base
        }

        var shortBase: String {
            if base.isEmpty { return "—" }
            if base.contains("127.0.0.1") || base.contains("localhost") {
                return "local proxy"
            }
            if let host = URL(string: base)?.host {
                return host
            }
            return base
        }

        var kind: ProviderKind {
            let blob = "\(name) \(base) \(model)".lowercased()
            if blob.contains("deepseek") { return .deepseek }
            if blob.contains("grok") || base.contains("18765") { return .grok }
            return .other
        }
    }

    enum ProviderKind {
        case grok, deepseek, other
    }

    enum CCError: LocalizedError {
        case noDB
        case sql(String)
        case notFound(String)
        case write(String)

        var errorDescription: String? {
            switch self {
            case .noDB:
                return "CC Switch not found.\nInstall CC Switch or ensure ~/.cc-switch/cc-switch.db exists."
            case .sql(let m):
                return "CC Switch DB: \(m)"
            case .notFound(let m):
                return m
            case .write(let m):
                return "Failed to activate provider: \(m)"
            }
        }
    }

    // MARK: - List

    static func listProviders() throws -> [Provider] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw CCError.noDB
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw CCError.sql("cannot open database")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, name, is_current, settings_config
        FROM providers
        WHERE app_type = 'claude'
        ORDER BY COALESCE(sort_index, 9999), name COLLATE NOCASE
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CCError.sql("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Provider] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = colString(stmt, 0) ?? ""
            let name = colString(stmt, 1) ?? id
            let isCurrent = sqlite3_column_int(stmt, 2) != 0
            let cfgRaw = colString(stmt, 3) ?? "{}"
            let cfg = parseJSONObject(cfgRaw)
            let env = (cfg["env"] as? [String: Any]) ?? [:]
            let model = stringVal(env["ANTHROPIC_MODEL"]) ?? ""
            let base = stringVal(env["ANTHROPIC_BASE_URL"]) ?? ""
            out.append(
                Provider(
                    id: id,
                    name: name,
                    isCurrent: isCurrent,
                    model: model,
                    base: base,
                    settingsConfig: cfg
                )
            )
        }
        return out
    }

    static func currentProvider() throws -> Provider? {
        try listProviders().first(where: \.isCurrent)
    }

    // MARK: - Activate (same algorithm as ccs apply_provider)

    /// Merge common_config_claude + provider settings → ~/.claude/settings.json,
    /// update CC Switch is_current + currentProviderClaude. Backs up first.
    @discardableResult
    static func activate(providerId: String) throws -> Provider {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw CCError.noDB
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw CCError.sql("cannot open database for write")
        }
        defer { sqlite3_close(db) }

        let providers = try listProviders()
        guard let target = providers.first(where: { $0.id == providerId }) else {
            throw CCError.notFound("Provider not found: \(providerId)")
        }

        let common = loadCommonConfig(db: db)
        let merged = deepMerge(common, target.settingsConfig)
        var final = merged
        if final["env"] == nil || !(final["env"] is [String: Any]) {
            final["env"] = [String: Any]()
        }

        try backupClaudeSettings()
        try writeJSON(final, to: claudeSettingsURL)

        // Clear current flags, set target.
        exec(db, "UPDATE providers SET is_current = 0 WHERE app_type = 'claude'")
        var stmt: OpaquePointer?
        let sql = "UPDATE providers SET is_current = 1 WHERE app_type = 'claude' AND id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CCError.sql("prepare update failed")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (target.id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw CCError.sql("update is_current failed")
        }

        // CC Switch settings.json currentProviderClaude
        var appSettings: [String: Any] = [:]
        if let data = try? Data(contentsOf: ccSettingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            appSettings = obj
        }
        appSettings["currentProviderClaude"] = target.id
        try writeJSON(appSettings, to: ccSettingsURL)

        var updated = target
        updated.isCurrent = true
        return updated
    }

    // MARK: - Internals

    private static func loadCommonConfig(db: OpaquePointer) -> [String: Any] {
        let sql = "SELECT value FROM settings WHERE key = 'common_config_claude'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, let raw = colString(stmt, 0) {
            return parseJSONObject(raw)
        }
        return [:]
    }

    private static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (k, v) in override {
            if k == "env", let vEnv = v as? [String: Any] {
                var env = (result["env"] as? [String: Any]) ?? [:]
                for (sk, sv) in vEnv {
                    if !(sv is NSNull) {
                        env[sk] = sv
                    }
                }
                result["env"] = env
            } else if let vDict = v as? [String: Any], let baseDict = result[k] as? [String: Any] {
                result[k] = deepMerge(baseDict, vDict)
            } else {
                result[k] = v
            }
        }
        return result
    }

    private static func backupClaudeSettings() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeSettingsURL.path) else { return }
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let name = "claude_settings_\(fmt.string(from: Date())).json"
        let dest = backupDir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: claudeSettingsURL, to: dest)
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        _ = sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            sqlite3_free(err)
        }
    }

    private static func colString(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private static func parseJSONObject(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func stringVal(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}
