import Foundation

/// Keeps `~/.grok/auth.json` fresh via the same OIDC refresh grant the Grok CLI uses,
/// so the tray / `gm` can keep calling billing APIs without browser login every ~6h.
enum GrokAuthRefresh {
    private static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!
    /// Refresh a bit before access expiry so polling does not hit 401.
    private static let refreshSkew: TimeInterval = 15 * 60
    private static let refreshActor = Refresher()

    // MARK: - Public

    /// Proactive refresh when the access token is missing, expired, or near expiry.
    static func ensureFreshCLIAuth() async {
        _ = await refreshActor.refreshIfNeeded(force: false)
    }

    /// Force refresh (e.g. after billing API returned 401/403).
    @discardableResult
    static func refreshAfterUnauthorized() async -> Bool {
        await refreshActor.refreshIfNeeded(force: true)
    }

    // MARK: - Core

    private actor Refresher {
        private var inFlight = false

        func refreshIfNeeded(force: Bool) async -> Bool {
            if inFlight { return false }
            inFlight = true
            defer { inFlight = false }
            return await Task.detached(priority: .utility) {
                GrokAuthRefresh.refreshOnDiskIfNeeded(force: force)
            }.value
        }
    }

    private static func refreshOnDiskIfNeeded(force: Bool) -> Bool {
        let authURL = GrokAccountStore.activeAuthURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: authURL.path) else { return false }

        guard let parsed = parseCLIAuth(at: authURL) else { return false }
        if !force, let exp = parsed.expiresAt, exp.timeIntervalSinceNow > refreshSkew {
            return false
        }
        guard !parsed.refreshToken.isEmpty else { return false }

        AuthJSONLock.cleanupStaleLock(nextTo: authURL)

        // Re-read — another process may have refreshed while we waited on the actor.
        guard let latest = parseCLIAuth(at: authURL) else { return false }
        if !force, let exp = latest.expiresAt, exp.timeIntervalSinceNow > refreshSkew {
            return true
        }

        do {
            let tokens = try exchangeRefreshToken(
                refreshToken: latest.refreshToken,
                clientID: latest.clientID
            )
            try writeRefreshedCLIAuth(
                authURL: authURL,
                mapKey: latest.mapKey,
                entry: latest.entry,
                tokens: tokens
            )
            _ = try? GrokAccountStore.syncActiveAuthToProxy()
            // Keep saved multi-account snapshots from going stale after silent refresh.
            _ = try? GrokAccountStore.saveActiveAsProfile()
            return true
        } catch {
            return false
        }
    }

    private struct ParsedCLIAuth {
        let mapKey: String
        var entry: [String: Any]
        var refreshToken: String
        var clientID: String
        var expiresAt: Date?
    }

    private struct TokenBundle {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    private static func parseCLIAuth(at url: URL) -> ParsedCLIAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (mapKey, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let refresh = stringVal(entry["refresh_token"]) ?? stringVal(entry["refresh"]) ?? ""
            guard !refresh.isEmpty else { continue }

            let clientID: String = {
                if let id = stringVal(entry["oidc_client_id"]), !id.isEmpty { return id }
                if let r = mapKey.range(of: "::") {
                    return String(mapKey[r.upperBound...])
                }
                return ""
            }()
            guard !clientID.isEmpty else { continue }

            var expiresAt: Date?
            if let s = stringVal(entry["expires_at"]) {
                expiresAt = parseISO8601(s)
            }
            return ParsedCLIAuth(
                mapKey: mapKey,
                entry: entry,
                refreshToken: refresh,
                clientID: clientID,
                expiresAt: expiresAt
            )
        }
        return nil
    }

    private static func exchangeRefreshToken(refreshToken: String, clientID: String) throws -> TokenBundle {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        guard let bodyData = body.percentEncodedQuery?.data(using: .utf8) else {
            throw RefreshError.encode
        }

        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try URLSession.shared.synchronousData(for: request)
        } catch {
            throw RefreshError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.network("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw RefreshError.http(http.statusCode, snippet)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = stringVal(obj["access_token"]), !access.isEmpty else {
            throw RefreshError.decode
        }
        let expiresIn = intVal(obj["expires_in"]) ?? 21_600
        let newRefresh = stringVal(obj["refresh_token"])
        return TokenBundle(accessToken: access, refreshToken: newRefresh, expiresIn: expiresIn)
    }

    private static func writeRefreshedCLIAuth(
        authURL: URL,
        mapKey: String,
        entry: [String: Any],
        tokens: TokenBundle
    ) throws {
        var updated = entry
        updated["key"] = tokens.accessToken
        if let rt = tokens.refreshToken, !rt.isEmpty {
            updated["refresh_token"] = rt
        }
        let expires = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        updated["expires_at"] = formatExpiresAt(expires)

        var root: [String: Any]
        if let data = try? Data(contentsOf: authURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
            root[mapKey] = updated
        } else {
            root = [mapKey: updated]
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = authURL.appendingPathExtension("tray-refresh")
        let fm = FileManager.default
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: authURL.path) {
            try fm.removeItem(at: authURL)
        }
        try fm.moveItem(at: tmp, to: authURL)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    // MARK: - Helpers

    private enum RefreshError: Error {
        case encode
        case network(String)
        case http(Int, String)
        case decode
    }

    private static func stringVal(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intVal(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func formatExpiresAt(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}

// MARK: - Stale Grok CLI lock cleanup

private enum AuthJSONLock {
    static func cleanupStaleLock(nextTo authURL: URL) {
        let lockURL = authURL.deletingLastPathComponent().appendingPathComponent("auth.json.lock")
        guard let text = try? String(contentsOf: lockURL, encoding: .utf8),
              let pidPart = text.split(separator: ":").first,
              let pid = Int32(pidPart) else { return }
        if kill(pid, 0) != 0 {
            try? FileManager.default.removeItem(at: lockURL)
        }
    }
}

// MARK: - URLSession sync helper (refresh runs off the main actor)

private extension URLSession {
    func synchronousData(for request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let sem = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        switch result {
        case .success(let pair):
            return pair
        case .failure(let error):
            throw error
        case .none:
            throw URLError(.unknown)
        }
    }
}
