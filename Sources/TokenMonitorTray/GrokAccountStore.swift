import Foundation

/// Multi-account SuperGrok CLI logins.
/// Active: `~/.grok/auth.json` (what `grok login` / `gm` / tray use).
/// Profiles: `~/.grok/profiles/<email>.json` (saved copies for switching).
///
/// Claude Code proxy uses a **separate** file:
/// `~/.config/claude-code-proxy/grok/auth.json` (from `claude-code-proxy grok auth login`).
/// Activating a tray account must sync into that path or the proxy keeps the old identity → 402.
enum GrokAccountStore {
    static var profilesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/profiles")
    }

    static var activeAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    /// Auth used by `claude-code-proxy` for Grok upstream.
    static var proxyAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-code-proxy/grok/auth.json")
    }

    struct Profile: Identifiable, Equatable {
        let id: String // filename
        let email: String
        let url: URL
        var isActive: Bool
    }

    // MARK: - Read

    static func activeEmail() -> String? {
        email(in: activeAuthURL)
    }

    static func listProfiles() -> [Profile] {
        let fm = FileManager.default
        try? fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let active = activeEmail()
        guard let files = try? fm.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [Profile] = []
        for url in files where url.pathExtension.lowercased() == "json" {
            let name = url.lastPathComponent
            // skip internal backup snapshots
            if name.hasPrefix("_backup-") { continue }
            let email = email(in: url) ?? url.deletingPathExtension().lastPathComponent
            out.append(
                Profile(
                    id: name,
                    email: email,
                    url: url,
                    isActive: active.map { emailEquals($0, email) } ?? false
                )
            )
        }
        // Also surface active auth even if never saved as profile
        if let active, !out.contains(where: { emailEquals($0.email, active) }) {
            out.insert(
                Profile(
                    id: "__active__",
                    email: active,
                    url: activeAuthURL,
                    isActive: true
                ),
                at: 0
            )
        }
        // Alphabetical by email only — switching active account must not reorder the list.
        return out.sorted {
            $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
        }
    }

    // MARK: - Save / switch

    /// Copy current `auth.json` into profiles as `<email>.json`.
    @discardableResult
    static func saveActiveAsProfile() throws -> Profile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: activeAuthURL.path) else {
            throw StoreError.noActiveAuth
        }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        guard let email = activeEmail() else {
            throw StoreError.noEmailInAuth
        }
        let safe = safeFileName(email)
        let dest = profilesDir.appendingPathComponent("\(safe).json")
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: activeAuthURL, to: dest)
        return Profile(id: dest.lastPathComponent, email: email, url: dest, isActive: true)
    }

    /// Install a profile as the active `~/.grok/auth.json`, then sync into the proxy auth path.
    static func switchTo(profileId: String) throws {
        let fm = FileManager.default
        let source: URL
        if profileId == "__active__" {
            // Still push current CLI auth into the proxy file.
            try syncActiveAuthToProxy()
            return
        }
        source = profilesDir.appendingPathComponent(profileId)
        guard fm.fileExists(atPath: source.path) else {
            throw StoreError.profileMissing(profileId)
        }
        // backup current before overwrite
        if fm.fileExists(atPath: activeAuthURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let bak = profilesDir.appendingPathComponent("_backup-switch-\(stamp).json")
            try? fm.copyItem(at: activeAuthURL, to: bak)
        }
        // atomic-ish replace
        let tmp = activeAuthURL.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: source, to: tmp)
        if fm.fileExists(atPath: activeAuthURL.path) {
            try fm.removeItem(at: activeAuthURL)
        }
        try fm.moveItem(at: tmp, to: activeAuthURL)
        // Proxy reads a different file — keep it aligned with the tray-selected account.
        try syncActiveAuthToProxy()
    }

    /// Convert active `~/.grok/auth.json` (CLI map) → `~/.config/claude-code-proxy/grok/auth.json`.
    /// Returns the email written when successful.
    @discardableResult
    static func syncActiveAuthToProxy() throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: activeAuthURL.path) else {
            throw StoreError.noActiveAuth
        }
        guard let data = try? Data(contentsOf: activeAuthURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.badAuthFormat
        }

        guard let creds = extractProxyCredentials(from: obj) else {
            throw StoreError.badAuthFormat
        }

        let dir = proxyAuthURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Backup existing proxy auth (helps recover after a bad overwrite).
        if fm.fileExists(atPath: proxyAuthURL.path) {
            let bak = dir.appendingPathComponent("auth.backup.json")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: proxyAuthURL, to: bak)
        }

        let out: [String: Any] = [
            "access": creds.access,
            "refresh": creds.refresh,
            "expires_at_ms": creds.expiresAtMs,
            "issuer": creds.issuer,
            "client_id": creds.clientId,
        ]
        let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let tmp = proxyAuthURL.appendingPathExtension("tmp")
        try json.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: proxyAuthURL.path) {
            try fm.removeItem(at: proxyAuthURL)
        }
        try fm.moveItem(at: tmp, to: proxyAuthURL)
        // Restrict permissions like the proxy does.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proxyAuthURL.path)
        return creds.email
    }

    // MARK: - Helpers

    private struct ProxyCreds {
        let access: String
        let refresh: String
        let expiresAtMs: Int64
        let issuer: String
        let clientId: String
        let email: String
    }

    /// Parse either CLI multi-issuer map or already-flat proxy-style JSON.
    private static func extractProxyCredentials(from obj: [String: Any]) -> ProxyCreds? {
        // Already proxy-flat?
        if let access = stringVal(obj["access"]) ?? stringVal(obj["access_token"]) ?? stringVal(obj["key"]),
           !access.isEmpty {
            let refresh = stringVal(obj["refresh"]) ?? stringVal(obj["refresh_token"]) ?? ""
            let expiresMs: Int64 = {
                if let n = obj["expires_at_ms"] as? Int64 { return n }
                if let n = obj["expires_at_ms"] as? Int { return Int64(n) }
                if let n = obj["expires_at_ms"] as? Double { return Int64(n) }
                if let s = stringVal(obj["expires_at"]), let d = parseISODate(s) {
                    return Int64(d.timeIntervalSince1970 * 1000)
                }
                // Default: 6h from now (proxy will refresh if refresh token is good).
                return Int64((Date().timeIntervalSince1970 + 6 * 3600) * 1000)
            }()
            return ProxyCreds(
                access: access,
                refresh: refresh,
                expiresAtMs: expiresMs,
                issuer: stringVal(obj["issuer"]) ?? stringVal(obj["oidc_issuer"]) ?? "https://auth.x.ai",
                clientId: stringVal(obj["client_id"]) ?? stringVal(obj["oidc_client_id"]) ?? "",
                email: stringVal(obj["email"]) ?? "proxy-auth"
            )
        }

        // CLI map: { "https://auth.x.ai::client_id": { key, refresh_token, ... } }
        for (mapKey, value) in obj {
            guard let entry = value as? [String: Any] else { continue }
            guard let access = stringVal(entry["key"])
                ?? stringVal(entry["access_token"])
                ?? stringVal(entry["access"]),
                  !access.isEmpty else { continue }
            let refresh = stringVal(entry["refresh_token"])
                ?? stringVal(entry["refresh"])
                ?? ""
            let expiresMs: Int64 = {
                if let s = stringVal(entry["expires_at"]), let d = parseISODate(s) {
                    return Int64(d.timeIntervalSince1970 * 1000)
                }
                return Int64((Date().timeIntervalSince1970 + 6 * 3600) * 1000)
            }()
            var issuer = stringVal(entry["oidc_issuer"]) ?? "https://auth.x.ai"
            var clientId = stringVal(entry["oidc_client_id"]) ?? ""
            // Key form: "https://auth.x.ai::b1a00492-..."
            if mapKey.contains("::") {
                let parts = mapKey.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                // split on "::"
                if let r = mapKey.range(of: "::") {
                    issuer = String(mapKey[..<r.lowerBound])
                    if clientId.isEmpty {
                        clientId = String(mapKey[r.upperBound...])
                    }
                }
                _ = parts
            }
            let email = stringVal(entry["email"]) ?? stringVal(entry["user_id"]) ?? "grok-cli"
            return ProxyCreds(
                access: access,
                refresh: refresh,
                expiresAtMs: expiresMs,
                issuer: issuer,
                clientId: clientId,
                email: email
            )
        }
        return nil
    }

    private static func stringVal(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func parseISODate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func email(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // multi-issuer map (official grok login)
        for (_, value) in obj {
            if let entry = value as? [String: Any] {
                if let e = entry["email"] as? String, !e.isEmpty { return e }
                if let e = entry["user_id"] as? String, !e.isEmpty { return e }
            }
        }
        // flat proxy-style
        if let e = obj["email"] as? String, !e.isEmpty { return e }
        return nil
    }

    private static func safeFileName(_ email: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._@+-"))
        return String(email.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func emailEquals(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    enum StoreError: LocalizedError {
        case noActiveAuth
        case noEmailInAuth
        case profileMissing(String)
        case badAuthFormat

        var errorDescription: String? {
            switch self {
            case .noActiveAuth:
                return "No ~/.grok/auth.json. Run: grok login  (or Grok login in the tray)"
            case .noEmailInAuth:
                return "Active auth has no email field."
            case .profileMissing(let id):
                return "Profile not found: \(id)"
            case .badAuthFormat:
                return "Could not parse ~/.grok/auth.json for the proxy. Use Grok login (browser)."
            }
        }
    }
}
