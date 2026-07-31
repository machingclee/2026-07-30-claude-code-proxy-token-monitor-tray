import Foundation
import SQLite3

/// Mirrors `ds` (~/.local/bin/ds): DeepSeek prepaid balance via GET /user/balance.
enum DeepSeekService {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    struct Auth {
        let token: String
        let source: String
    }

    struct BalanceLine: Equatable {
        var currency: String
        var total: String
        var granted: String
        var toppedUp: String

        var displayTotal: String {
            "\(total) \(currency)"
        }
    }

    struct Snapshot: Equatable {
        var source: String
        var isAvailable: Bool
        var balances: [BalanceLine]
        var fetchedAt: Date

        var primaryTotal: String {
            balances.first?.displayTotal ?? "—"
        }

        /// Compact menu-bar label, e.g. "$28" or "¥110".
        var menuBarLabel: String {
            guard let first = balances.first else { return "—" }
            let raw = first.total.trimmingCharacters(in: .whitespaces)
            let num = Double(raw) ?? 0
            let symbol: String
            switch first.currency.uppercased() {
            case "USD": symbol = "$"
            case "CNY": symbol = "¥"
            default: symbol = "\(first.currency) "
            }
            if abs(num - floor(num)) < 0.005 {
                return String(format: "%@%.0f", symbol, num)
            }
            return String(format: "%@%.2f", symbol, num)
        }
    }

    enum DSError: LocalizedError {
        case noAuth
        case http(Int, String)
        case network(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .noAuth:
                return "No DeepSeek API key.\nEnter one under DeepSeek in the tray (saved under Application Support), or set DEEPSEEK_API_KEY."
            case .http(let code, let body):
                if code == 401 || code == 403 {
                    return "DeepSeek auth failed (\(code)). Check the API key.\n\(body)"
                }
                return "DeepSeek HTTP \(code): \(body)"
            case .network(let msg):
                return "DeepSeek request failed: \(msg)"
            case .decode(let msg):
                return "DeepSeek bad response: \(msg)"
            }
        }
    }

    // MARK: - Key load (tray-local first; no CC Switch required)

    static func loadKey() throws -> Auth {
        // 1) Tray-owned config (Application Support / product name)
        let local = DeepSeekConfigStore.load()
        let localKey = local.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localKey.isEmpty {
            return Auth(token: localKey, source: "Application Support/…/deepseek.json")
        }

        // 2) Environment
        let env = ProcessInfo.processInfo.environment
        for name in ["DEEPSEEK_API_KEY", "DEEPSEEK_TOKEN"] {
            if let v = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return Auth(token: v, source: "env:\(name)")
            }
        }

        // 3) Live Claude settings if already on DeepSeek
        if let fromSettings = loadKeyFromClaudeSettings() {
            return fromSettings
        }

        // 4) Optional legacy CC Switch (read-only fallback)
        if let fromDB = loadKeyFromCCSwitch() {
            return fromDB
        }

        throw DSError.noAuth
    }

    private static func loadKeyFromCCSwitch() -> Auth? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT name, settings_config FROM providers
        WHERE app_type = 'claude'
        ORDER BY is_current DESC, name COLLATE NOCASE
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = stringColumn(stmt, 0) ?? ""
            let cfgRaw = stringColumn(stmt, 1) ?? "{}"
            guard let data = cfgRaw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let env = envDict(from: obj)
            let base = stringValue(env["ANTHROPIC_BASE_URL"]) ?? stringValue(env["BASE_URL"]) ?? ""
            let model = stringValue(env["ANTHROPIC_MODEL"]) ?? stringValue(env["MODEL"]) ?? ""
            guard looksDeepSeek(name: name, base: base, model: model) else { continue }
            if let key = extractKey(env) {
                return Auth(token: key, source: "cc-switch:\(name)")
            }
        }
        return nil
    }

    private static func loadKeyFromClaudeSettings() -> Auth? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = obj["env"] as? [String: Any] else {
            return nil
        }
        let base = stringValue(env["ANTHROPIC_BASE_URL"]) ?? ""
        let model = stringValue(env["ANTHROPIC_MODEL"]) ?? ""
        guard looksDeepSeek(name: "settings", base: base, model: model) || base.lowercased().contains("deepseek") else {
            return nil
        }
        if let key = extractKey(env) {
            return Auth(token: key, source: "~/.claude/settings.json")
        }
        return nil
    }

    private static func envDict(from settingsConfig: [String: Any]) -> [String: Any] {
        if let env = settingsConfig["env"] as? [String: Any] {
            return env
        }
        return settingsConfig
    }

    private static func looksDeepSeek(name: String, base: String, model: String) -> Bool {
        "\(name) \(base) \(model)".lowercased().contains("deepseek")
    }

    private static func extractKey(_ env: [String: Any]) -> String? {
        for k in [
            "DEEPSEEK_API_KEY", "DEEPSEEK_TOKEN",
            "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY", "API_KEY",
        ] {
            if let v = stringValue(env[k])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !v.isEmpty,
               !["unused", "none", "null"].contains(v.lowercased()) {
                return v
            }
        }
        return nil
    }

    private static func stringColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Fetch

    static func fetchSnapshot() async throws -> Snapshot {
        let auth = try loadKey()
        var request = URLRequest(url: balanceURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gm-tray/1.0 (deepseek-monitor)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DSError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DSError.network("Invalid response")
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DSError.http(http.statusCode, String(body.prefix(300)))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DSError.decode("Expected JSON object")
        }

        let available = obj["is_available"] as? Bool ?? false
        var lines: [BalanceLine] = []
        if let arr = obj["balance_infos"] as? [[String: Any]] {
            for info in arr {
                lines.append(
                    BalanceLine(
                        currency: stringValue(info["currency"]) ?? "?",
                        total: stringValue(info["total_balance"]) ?? "?",
                        granted: stringValue(info["granted_balance"]) ?? "0",
                        toppedUp: stringValue(info["topped_up_balance"]) ?? "0"
                    )
                )
            }
        }

        return Snapshot(
            source: auth.source,
            isAvailable: available,
            balances: lines,
            fetchedAt: Date()
        )
    }
}
