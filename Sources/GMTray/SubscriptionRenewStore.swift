import Foundation

/// Manual SuperGrok subscription renew day, **per Grok account email**.
/// Not available from CLI billing APIs; copy from grok.com Billing
/// (`billingPeriodEnd` / “續訂”). We store one anchor per account and roll
/// it forward by whole months for the next renew after “now”.
enum SubscriptionRenewStore {
    private static let mapKey = "gm-tray.subscriptionRenewAnchorsByEmail"
    /// Legacy single-account key (migrated once into the map).
    private static let legacyKey = "gm-tray.subscriptionRenewAnchor"

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadMap() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String]) ?? [:]
    }

    private static func saveMap(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: mapKey)
    }

    /// Migrate legacy global anchor into the current account if needed.
    static func migrateLegacyIfNeeded(for email: String?) {
        guard let email, !email.isEmpty else { return }
        guard let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty else {
            return
        }
        var map = loadMap()
        let key = normalizeEmail(email)
        if map[key] == nil {
            map[key] = legacy
            saveMap(map)
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    static func anchorDate(for email: String?) -> Date? {
        guard let email, !email.isEmpty else { return nil }
        migrateLegacyIfNeeded(for: email)
        let s = loadMap()[normalizeEmail(email)]
        guard let s, !s.isEmpty else { return nil }
        return isoDay.date(from: s)
    }

    static func setAnchorDate(_ date: Date?, for email: String?) {
        guard let email, !email.isEmpty else { return }
        var map = loadMap()
        let key = normalizeEmail(email)
        if let d = date {
            map[key] = isoDay.string(from: d)
        } else {
            map.removeValue(forKey: key)
        }
        saveMap(map)
    }

    static func anchorDayString(for email: String?) -> String? {
        guard let d = anchorDate(for: email) else { return nil }
        return isoDay.string(from: d)
    }

    /// Parse user input: `yyyy-MM-dd` or `yyyy/MM/dd`.
    static func parseDay(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !s.isEmpty else { return nil }
        return isoDay.date(from: s)
    }

    /// Next renew for this account on/after start of today.
    static func nextRenewal(for email: String?, from now: Date = Date()) -> Date? {
        guard var next = anchorDate(for: email) else { return nil }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        next = cal.startOfDay(for: next)
        var guardCount = 0
        while next < startOfToday {
            guard let advanced = cal.date(byAdding: .month, value: 1, to: next) else {
                return nil
            }
            next = cal.startOfDay(for: advanced)
            guardCount += 1
            if guardCount > 240 { return nil }
        }
        return next
    }

    static func remainingLabel(until end: Date?) -> String {
        UsageService.remainingLabel(until: end)
    }

    static func formatDay(_ date: Date?) -> String {
        guard let date else { return "?" }
        return isoDay.string(from: date)
    }
}
