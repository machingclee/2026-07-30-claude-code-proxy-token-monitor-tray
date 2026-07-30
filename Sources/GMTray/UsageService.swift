import Foundation

/// Mirrors `gm` (~/.local/bin/gm): same auth sources + billing endpoints.
enum UsageService {
    static let billingCredits = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let billingMonthly = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    private static let clientHeaders: [String: String] = [
        "Accept": "application/json",
        "User-Agent": "gm-tray/1.0 (grok-monitor)",
        "x-grok-client-identifier": "xai-grok-cli",
        "x-grok-client-version": "0.2.103",
        "x-grok-client-mode": "cli",
    ]

    struct Auth {
        let token: String
        let source: String
    }

    struct Snapshot: Equatable {
        var source: String
        var weeklyPercent: Double
        var weeklyLeft: Double
        var weeklyStart: Date?
        var weeklyEnd: Date?
        var productLines: [(name: String, percent: Double)]
        var prepaid: Double
        var onDemandUsed: Double
        var onDemandCap: Double
        var monthlyUsed: Double?
        var monthlyLimit: Double?
        var monthlyStart: Date?
        var monthlyEnd: Date?
        var fetchedAt: Date

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.source == rhs.source
                && lhs.weeklyPercent == rhs.weeklyPercent
                && lhs.weeklyLeft == rhs.weeklyLeft
                && lhs.weeklyStart == rhs.weeklyStart
                && lhs.weeklyEnd == rhs.weeklyEnd
                && lhs.productLines.map(\.name) == rhs.productLines.map(\.name)
                && lhs.productLines.map(\.percent) == rhs.productLines.map(\.percent)
                && lhs.prepaid == rhs.prepaid
                && lhs.onDemandUsed == rhs.onDemandUsed
                && lhs.onDemandCap == rhs.onDemandCap
                && lhs.monthlyUsed == rhs.monthlyUsed
                && lhs.monthlyLimit == rhs.monthlyLimit
                && lhs.monthlyStart == rhs.monthlyStart
                && lhs.monthlyEnd == rhs.monthlyEnd
        }

        var monthlyPercent: Double? {
            guard let used = monthlyUsed, let limit = monthlyLimit, limit > 0 else { return nil }
            return used / limit * 100.0
        }

        var weeklyRemainingLabel: String {
            remainingLabel(until: weeklyEnd)
        }

        var menuBarTitle: String {
            String(format: "%.0f%%", weeklyPercent)
        }
    }

    enum UsageError: LocalizedError {
        case noAuth
        case http(Int, String)
        case network(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .noAuth:
                return "No Grok auth found.\nRun: grok login"
            case .http(let code, let body):
                if code == 401 || code == 403 {
                    return "Auth failed (\(code)). Token may be expired.\nRun: grok login\n\(body)"
                }
                return "HTTP \(code): \(body)"
            case .network(let msg):
                return "Request failed: \(msg)"
            case .decode(let msg):
                return "Bad response: \(msg)"
            }
        }
    }

    // MARK: - Auth (same order as gm)

    static func loadToken() throws -> Auth {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let grokAuth = home.appendingPathComponent(".grok/auth.json")
        let proxyAuth = home.appendingPathComponent(".config/claude-code-proxy/grok/auth.json")

        if let data = try? Data(contentsOf: grokAuth),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (_, value) in obj {
                guard let entry = value as? [String: Any] else { continue }
                if let token = stringValue(entry["key"])
                    ?? stringValue(entry["access_token"])
                    ?? stringValue(entry["access"]) {
                    let email = stringValue(entry["email"])
                        ?? stringValue(entry["user_id"])
                        ?? "grok-cli"
                    return Auth(token: token, source: "~/.grok/auth.json (\(email))")
                }
            }
        }

        if let data = try? Data(contentsOf: proxyAuth),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let token = stringValue(obj["access"])
                ?? stringValue(obj["access_token"])
                ?? stringValue(obj["key"]) {
                return Auth(token: token, source: "~/.config/claude-code-proxy/grok/auth.json")
            }
        }

        throw UsageError.noAuth
    }

    static var hasAnyAuth: Bool {
        (try? loadToken()) != nil
    }

    // MARK: - Fetch

    static func fetchSnapshot() async throws -> Snapshot {
        let auth = try loadToken()
        async let weeklyRaw = getJSON(url: billingCredits, token: auth.token)
        async let monthlyRaw = getJSON(url: billingMonthly, token: auth.token)
        let (weekly, monthly) = try await (weeklyRaw, monthlyRaw)
        return parse(weekly: weekly, monthly: monthly, source: auth.source)
    }

    private static func getJSON(url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        for (k, v) in clientHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Invalid response")
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            let trimmed = String(body.prefix(300))
            throw UsageError.http(http.statusCode, trimmed)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decode("Expected JSON object")
        }
        return obj
    }

    // MARK: - Parse (aligned with gm)

    private static func parse(weekly: [String: Any], monthly: [String: Any], source: String) -> Snapshot {
        let wcfg = dict(weekly["config"]) ?? [:]
        let period = dict(wcfg["currentPeriod"]) ?? [:]
        let start = parseDate(stringValue(period["start"]) ?? stringValue(wcfg["billingPeriodStart"]))
        let end = parseDate(stringValue(period["end"]) ?? stringValue(wcfg["billingPeriodEnd"]))
        let pct = doubleValue(wcfg["creditUsagePercent"]) ?? 0

        var products: [(String, Double)] = []
        if let arr = wcfg["productUsage"] as? [[String: Any]] {
            for p in arr {
                let name = stringValue(p["product"]) ?? "?"
                let up = doubleValue(p["usagePercent"]) ?? 0
                products.append((name, up))
            }
        }

        let mcfg = dict(monthly["config"]) ?? [:]
        let mUsed = unwrapVal(mcfg["used"]).flatMap(doubleValue)
        let mLimit = unwrapVal(mcfg["monthlyLimit"]).flatMap(doubleValue)
        let mStart = parseDate(stringValue(mcfg["billingPeriodStart"]))
        let mEnd = parseDate(stringValue(mcfg["billingPeriodEnd"]))

        return Snapshot(
            source: source,
            weeklyPercent: pct,
            weeklyLeft: max(0, 100 - pct),
            weeklyStart: start,
            weeklyEnd: end,
            productLines: products,
            prepaid: doubleValue(unwrapVal(wcfg["prepaidBalance"])) ?? 0,
            onDemandUsed: doubleValue(unwrapVal(wcfg["onDemandUsed"])) ?? 0,
            onDemandCap: doubleValue(unwrapVal(wcfg["onDemandCap"])) ?? 0,
            monthlyUsed: mUsed,
            monthlyLimit: mLimit,
            monthlyStart: mStart,
            monthlyEnd: mEnd,
            fetchedAt: Date()
        )
    }

    // MARK: - Helpers

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// gm's `val()` — unwrap `{ "val": x }` single-key objects.
    private static func unwrapVal(_ any: Any?) -> Any? {
        if let d = any as? [String: Any], d.keys.count == 1, let v = d["val"] {
            return v
        }
        return any
    }

    private static func dict(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // Fallback: Python-style with offset
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f.date(from: s)
    }

    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm z"
        f.timeZone = .current
        return f.string(from: date)
    }

    static func remainingLabel(until end: Date?) -> String {
        guard let end else { return "?" }
        let secs = Int(end.timeIntervalSinceNow)
        if secs <= 0 { return "reset due / overdue" }
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let mins = (secs % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 || days > 0 { parts.append("\(hours)h") }
        parts.append("\(mins)m")
        return parts.joined(separator: " ")
    }
}
