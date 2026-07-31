import Foundation

/// Local DeepSeek config for the tray — **not** CC Switch, **not** Grok.
///
/// File (0600):
/// `~/Library/Application Support/Claude-Code-Proxy Token Monitor Tray/deepseek.json`
///
/// (Legacy path `~/.grok/deepseek.json` is migrated once if present.)
/// Activate writes DeepSeek env into `~/.claude/settings.json` directly.
enum DeepSeekConfigStore {
    /// Product Application Support folder (matches CFBundleDisplayName / installed .app).
    static var appSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude-Code-Proxy Token Monitor Tray",
                isDirectory: true
            )
    }

    static var configURL: URL {
        appSupportDir.appendingPathComponent("deepseek.json")
    }

    /// Pre-rename location (do not store new DeepSeek data under ~/.grok).
    static var legacyConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/deepseek.json")
    }

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Built-in model presets (user can still edit model ids in the file).
    enum Variant: String, CaseIterable, Identifiable {
        case pro
        case flash

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pro: return "Pro"
            case .flash: return "Flash"
            }
        }

        /// Default Anthropic-compatible model id for Claude Code.
        /// Both use lowercase context tag `[1m]` for consistent UI (not mixed `1m` / `1M`).
        var defaultModel: String {
            switch self {
            case .pro: return "deepseek-v4-pro[1m]"
            case .flash: return "deepseek-v4-flash[1m]"
            }
        }
    }

    struct Config: Equatable {
        var apiKey: String
        /// DeepSeek OpenAPI base (balance API).
        var apiBaseURL: String
        /// Base URL Claude Code uses (Anthropic-compatible endpoint).
        var anthropicBaseURL: String
        var proModel: String
        var flashModel: String
        var activeVariant: Variant?

        static let `default` = Config(
            apiKey: "",
            apiBaseURL: "https://api.deepseek.com",
            anthropicBaseURL: "https://api.deepseek.com/anthropic",
            proModel: Variant.pro.defaultModel,
            flashModel: Variant.flash.defaultModel,
            activeVariant: nil
        )

        func model(for variant: Variant) -> String {
            switch variant {
            case .pro: return proModel.isEmpty ? variant.defaultModel : proModel
            case .flash: return flashModel.isEmpty ? variant.defaultModel : flashModel
            }
        }
    }

    enum StoreError: LocalizedError {
        case noAPIKey
        case write(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Enter a DeepSeek API key first."
            case .write(let msg):
                return "Could not write config: \(msg)"
            }
        }
    }

    // MARK: - Load / save

    /// Prefer new Application Support path; one-time migrate from ~/.grok/deepseek.json.
    private static func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configURL.path),
              fm.fileExists(atPath: legacyConfigURL.path) else { return }
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: legacyConfigURL, to: configURL)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        // Leave legacy file in place until user deletes it (safe); prefer not auto-rm secrets.
    }

    static func load() -> Config {
        migrateLegacyConfigIfNeeded()
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }
        var c = Config.default
        c.apiKey = string(obj["api_key"]) ?? string(obj["apiKey"]) ?? ""
        c.apiBaseURL = string(obj["api_base_url"]) ?? string(obj["apiBaseURL"]) ?? c.apiBaseURL
        c.anthropicBaseURL = string(obj["anthropic_base_url"])
            ?? string(obj["anthropicBaseURL"])
            ?? c.anthropicBaseURL
        c.proModel = normalizeContextTag(string(obj["pro_model"]) ?? string(obj["proModel"]) ?? c.proModel)
        c.flashModel = normalizeContextTag(string(obj["flash_model"]) ?? string(obj["flashModel"]) ?? c.flashModel)
        if let v = string(obj["active_variant"]) ?? string(obj["activeVariant"]),
           let variant = Variant(rawValue: v) {
            c.activeVariant = variant
        }
        return c
    }

    /// Normalize context-window suffix to lowercase `[1m]` (CC Switch Flash used `[1M]`).
    static func normalizeContextTag(_ model: String) -> String {
        model.replacingOccurrences(of: "[1M]", with: "[1m]")
    }

    static func save(_ config: Config) throws {
        var out: [String: Any] = [
            "api_key": config.apiKey,
            "api_base_url": config.apiBaseURL,
            "anthropic_base_url": config.anthropicBaseURL,
            "pro_model": config.proModel,
            "flash_model": config.flashModel,
        ]
        if let v = config.activeVariant {
            out["active_variant"] = v.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let tmp = configURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
        }
        try FileManager.default.moveItem(at: tmp, to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    static func hasAPIKey() -> Bool {
        !load().apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Activate → ~/.claude/settings.json (no CC Switch)

    /// Write DeepSeek env into Claude Code settings and mark variant active in local config.
    @discardableResult
    static func activate(variant: Variant) throws -> Config {
        var config = load()
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StoreError.noAPIKey }

        let model = normalizeContextTag(config.model(for: variant))
        let base = config.anthropicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = base.isEmpty ? Config.default.anthropicBaseURL : base

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var env = (root["env"] as? [String: Any]) ?? [:]

        // Claude Code Anthropic-compatible env for DeepSeek.
        // Use only ANTHROPIC_AUTH_TOKEN — setting both AUTH_TOKEN and API_KEY makes
        // Claude Code warn: "Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set".
        env["ANTHROPIC_BASE_URL"] = baseURL
        env["ANTHROPIC_AUTH_TOKEN"] = key
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env["ANTHROPIC_MODEL"] = model
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = model
        env["ANTHROPIC_SMALL_FAST_MODEL"] = model
        // Keep DEEPSEEK_API_KEY for tray balance fetch / non-Claude tools only.
        env["DEEPSEEK_API_KEY"] = key

        root["env"] = env

        let dir = claudeSettingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Backup
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            let bak = dir.appendingPathComponent("settings.backup-token-monitor-tray.json")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: claudeSettingsURL, to: bak)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = claudeSettingsURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            try FileManager.default.removeItem(at: claudeSettingsURL)
        }
        try FileManager.default.moveItem(at: tmp, to: claudeSettingsURL)

        config.activeVariant = variant
        try save(config)
        return config
    }

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}
