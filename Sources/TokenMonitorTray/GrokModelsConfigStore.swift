import Foundation

/// Grok model ids written into `~/.claude/settings.json` on Grok Activate.
///
/// File (0600):
/// `~/Library/Application Support/Claude-Code-Proxy Token Monitor Tray/grok-models.json`
enum GrokModelsConfigStore {
    static var appSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude-Code-Proxy Token Monitor Tray",
                isDirectory: true
            )
    }

    static var configURL: URL {
        appSupportDir.appendingPathComponent("grok-models.json")
    }

    /// Defaults: SuperGrok main + fast subagent/Haiku.
    static let defaultMainModel = "grok-4.6"
    static let defaultFastModel = "grok-composer-2.5-fast"

    struct Config: Equatable {
        /// Main chat / Sonnet / Opus.
        var mainModel: String
        /// Haiku / small-fast / subagent.
        var fastModel: String

        static let `default` = Config(
            mainModel: defaultMainModel,
            fastModel: defaultFastModel
        )
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }
        let main = string(obj["main_model"] ?? obj["mainModel"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fast = string(obj["fast_model"] ?? obj["fastModel"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Config(
            mainModel: (main?.isEmpty == false) ? main! : defaultMainModel,
            fastModel: (fast?.isEmpty == false) ? fast! : defaultFastModel
        )
    }

    static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        var c = config
        c.mainModel = c.mainModel.trimmingCharacters(in: .whitespacesAndNewlines)
        c.fastModel = c.fastModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.mainModel.isEmpty { c.mainModel = defaultMainModel }
        if c.fastModel.isEmpty { c.fastModel = defaultFastModel }
        let obj: [String: Any] = [
            "main_model": c.mainModel,
            "fast_model": c.fastModel,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let tmp = configURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
        }
        try FileManager.default.moveItem(at: tmp, to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}
