import Foundation

/// Multi-account SuperGrok CLI logins.
/// Active: `~/.grok/auth.json` (what `grok login` / `gm` / tray use).
/// Profiles: `~/.grok/profiles/<email>.json` (saved copies for switching).
enum GrokAccountStore {
    static var profilesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/profiles")
    }

    static var activeAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
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

    /// Install a profile as the active `~/.grok/auth.json`.
    static func switchTo(profileId: String) throws {
        let fm = FileManager.default
        let source: URL
        if profileId == "__active__" {
            return // already active auth file
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
    }

    // MARK: - Helpers

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

        var errorDescription: String? {
            switch self {
            case .noActiveAuth:
                return "No ~/.grok/auth.json. Run: grok login"
            case .noEmailInAuth:
                return "Active auth has no email field."
            case .profileMissing(let id):
                return "Profile not found: \(id)"
            }
        }
    }
}
