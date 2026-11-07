import Foundation

/// Mirrors `gm` (~/.local/bin/gm): same auth sources + billing endpoints.
enum UsageService {
    static let billingCredits = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let billingMonthly = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    private static let clientHeaders: [String: String] = [
        "Accept": "application/json",
        "User-Agent": "TokenMonitorTray/1.0 (grok-monitor)",
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

        /// Compact “days until reset”, e.g. `1.23d`.
        var weeklyRemainingDaysCompact: String {
            remainingDaysCompact(until: weeklyEnd)
        }

        var monthlyRemainingLabel: String {
            remainingLabel(until: monthlyEnd)
        }

        /// Menu bar: `65% / 5.33d` = weekly used % · padded slash · days until weekly reset.
        var menuBarTitle: String {
            String(format: "%.0f%% / %@", weeklyPercent, weeklyRemainingDaysCompact)
        }

        /// Monthly usage as a percent string for the tray (calendar window).
        var menuBarMonthlyTitle: String {
            if let pct = monthlyPercent {
                return String(format: "%.0f%%", pct)
            }
            return "—"
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

    /// Load token from `~/.grok/auth.json` only (not proxy auth).
    static func loadCLIToken() throws -> Auth {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let grokAuth = home.appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: grokAuth),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.noAuth
        }
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
        throw UsageError.noAuth
    }

    /// Live check: load weekly credits with the active CLI token.
    /// Success ⇒ tokens work; 401/403 ⇒ need Grok login; other errors are network/API noise.
    enum LiveAuthStatus: Equatable {
        case ok(email: String)
        case authFailed(status: Int, email: String?)
        case noAuth
        case networkOrOther(String)
    }

    static func probeCLIAuthLive() async -> LiveAuthStatus {
        await GrokAuthRefresh.ensureFreshCLIAuth()
        let email = GrokAccountStore.activeEmail()
        return await probeCLIAuthLiveOnce(email: email)
    }

    private static func probeCLIAuthLiveOnce(email: String?) async -> LiveAuthStatus {
        let auth: Auth
        do {
            auth = try loadCLIToken()
        } catch {
            return .noAuth
        }
        do {
            _ = try await fetchWeeklyPayload(token: auth.token)
            return .ok(email: email ?? "ok")
        } catch let UsageError.http(code, _) where code == 401 || code == 403 {
            if await GrokAuthRefresh.refreshAfterUnauthorized() {
                return await probeCLIAuthLiveOnce(email: email)
            }
            return .authFailed(status: code, email: email)
        } catch let e as UsageError {
            return .networkOrOther(e.errorDescription ?? "\(e)")
        } catch {
            return .networkOrOther(error.localizedDescription)
        }
    }

    // MARK: - Fetch

    static func fetchSnapshot() async throws -> Snapshot {
        await GrokAuthRefresh.ensureFreshCLIAuth()
        do {
            return try await fetchSnapshotOnce()
        } catch let UsageError.http(code, body) where code == 401 || code == 403 {
            if await GrokAuthRefresh.refreshAfterUnauthorized() {
                return try await fetchSnapshotOnce()
            }
            throw UsageError.http(code, body)
        }
    }

    private static func fetchSnapshotOnce() async throws -> Snapshot {
        let auth = try loadToken()
        // SuperGrok rate limit is the weekly shared pool only — skip monthly billing window.
        let weekly = try await fetchWeeklyPayload(token: auth.token)
        return parse(weekly: weekly, source: auth.source)
    }

    /// REST `?format=credits` 500s with "Failed to serialize billing response" for some
    /// signed-in accounts. The grok.com gRPC credits call still returns the weekly percent.
    private static let creditsGRPC = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

    private static func fetchWeeklyPayload(token: String) async throws -> [String: Any] {
        do {
            return try await getJSON(url: billingCredits, token: token)
        } catch UsageError.http(let code, let body)
            where code == 500 && body.localizedCaseInsensitiveContains("Failed to serialize billing response") {
            return try await creditsConfigFromGRPC(token: token)
        }
    }

    private static func creditsConfigFromGRPC(token: String) async throws -> [String: Any] {
        var request = URLRequest(url: creditsGRPC, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
        request.setValue("1.0.60", forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
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
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.http(http.statusCode, "credits grpc")
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageError.http(http.statusCode, String(body.prefix(300)))
        }
        if let status = grpcStatus(in: data), status != 0 {
            throw UsageError.http(status == 16 ? 401 : 502, "grpc-status \(status)")
        }
        guard let config = creditsConfig(fromGRPCWeb: data) else {
            throw UsageError.decode("Grok credits response had no weekly percent")
        }
        return ["config": config]
    }

    /// First gRPC-web data frame → CreditsConfig (field 1) as the REST `config` object.
    private static func creditsConfig(fromGRPCWeb data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard let payload = firstGRPCDataFrame(bytes) ?? (bytes.isEmpty ? nil : bytes) else {
            return nil
        }
        guard let root = Proto.fields(in: payload) else { return nil }
        let configBytes = root.first { $0.number == 1 }?.bytes ?? payload
        guard let fields = Proto.fields(in: configBytes) else { return nil }

        guard let percent = fields.first(where: { $0.number == 1 })?.fixed32, percent.isFinite else {
            return nil
        }
        var config: [String: Any] = ["creditUsagePercent": Double(percent)]

        let start = fields.first { $0.number == 4 }?.bytes.flatMap(timestamp)
        let end = fields.first { $0.number == 5 }?.bytes.flatMap(timestamp)
        if let start { config["billingPeriodStart"] = iso8601(start) }
        if let end { config["billingPeriodEnd"] = iso8601(end) }
        if start != nil || end != nil {
            var period: [String: Any] = ["type": "USAGE_PERIOD_TYPE_WEEKLY"]
            if let start { period["start"] = iso8601(start) }
            if let end { period["end"] = iso8601(end) }
            config["currentPeriod"] = period
        }

        var products: [[String: Any]] = []
        for field in fields where field.number == 7 {
            guard let entry = field.bytes, let parsed = Proto.fields(in: entry) else { continue }
            guard let id = parsed.first(where: { $0.number == 1 })?.varint,
                  let pct = parsed.first(where: { $0.number == 2 })?.fixed32,
                  pct.isFinite else { continue }
            products.append([
                "product": productName(id),
                "usagePercent": Double(pct),
            ])
        }
        if !products.isEmpty {
            config["productUsage"] = products
        }
        return config
    }

    /// billing_product.proto: 1 API, 2 Build, 3 Plugins, 4 Chat, 5 Imagine, 6 Voice.
    private static func productName(_ id: UInt64) -> String {
        switch id {
        case 1: return "Api"
        case 2: return "GrokBuild"
        case 3: return "GrokPlugins"
        case 4: return "GrokChat"
        case 5: return "GrokImagine"
        case 6: return "GrokVoice"
        default: return "Product\(id)"
        }
    }

    private static func firstGRPCDataFrame(_ bytes: [UInt8]) -> [UInt8]? {
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return nil }
            if flags & 0x80 == 0 {
                return Array(bytes[start..<end])
            }
            index = end
        }
        return nil
    }

    private static func grpcStatus(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return nil }
            if flags & 0x80 != 0, let text = String(bytes: bytes[start..<end], encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "grpc-status" {
                        return Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            index = end
        }
        return nil
    }

    private static func timestamp(_ bytes: [UInt8]) -> Date? {
        guard let fields = Proto.fields(in: bytes) else { return nil }
        guard let seconds = fields.first(where: { $0.number == 1 })?.varint else { return nil }
        let nanos = fields.first(where: { $0.number == 2 })?.varint ?? 0
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct Proto {
        struct Field {
            var number: UInt64
            var varint: UInt64?
            var bytes: [UInt8]?
            var fixed32: Float?
        }

        static func fields(in bytes: [UInt8]) -> [Field]? {
            var index = 0
            var out: [Field] = []
            while index < bytes.count {
                guard let key = readVarint(bytes, &index) else { return nil }
                let number = key >> 3
                let wire = key & 7
                switch wire {
                case 0:
                    guard let value = readVarint(bytes, &index) else { return nil }
                    out.append(Field(number: number, varint: value, bytes: nil, fixed32: nil))
                case 1:
                    guard index + 8 <= bytes.count else { return nil }
                    index += 8
                case 2:
                    guard let length = readVarint(bytes, &index) else { return nil }
                    let count = Int(length)
                    guard index + count <= bytes.count else { return nil }
                    let slice = Array(bytes[index..<(index + count)])
                    index += count
                    out.append(Field(number: number, varint: nil, bytes: slice, fixed32: nil))
                case 5:
                    guard index + 4 <= bytes.count else { return nil }
                    let bits = UInt32(bytes[index])
                        | (UInt32(bytes[index + 1]) << 8)
                        | (UInt32(bytes[index + 2]) << 16)
                        | (UInt32(bytes[index + 3]) << 24)
                    index += 4
                    out.append(Field(number: number, varint: nil, bytes: nil, fixed32: Float(bitPattern: bits)))
                default:
                    return nil
                }
            }
            return out
        }

        private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift <= 63 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
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

    private static func parse(weekly: [String: Any], source: String) -> Snapshot {
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
            monthlyUsed: nil,
            monthlyLimit: nil,
            monthlyStart: nil,
            monthlyEnd: nil,
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
        // Local wall-clock time only — no zone abbreviation (e.g. HKT).
        f.dateFormat = "yyyy-MM-dd HH:mm"
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

    /// Account list: `Resets in 4d 23h 12m` (or `Reset due` when past end).
    static func resetsInLabel(until end: Date?) -> String {
        guard let end else { return "?" }
        let secs = Int(end.timeIntervalSinceNow)
        if secs <= 0 { return "Reset due" }
        return "Resets in \(remainingLabel(until: end))"
    }

    /// Fractional days until reset for compact UI, e.g. `1.23d`.
    static func remainingDaysCompact(until end: Date?) -> String {
        guard let end else { return "?" }
        let days = end.timeIntervalSinceNow / 86_400.0
        if days <= 0 { return "0d" }
        // Two decimals: 1.23d ≈ 1 day + ~5.5 hours.
        return String(format: "%.2fd", days)
    }
}
