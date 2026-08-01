import Foundation

/// Per-account SuperGrok **weekly reset** timestamps so the tray can show
/// `machingclee / 2.33d` without a live API call.
///
/// Storage: JSON under Application Support (not milliseconds — see below).
///
/// ## Time format (Swift)
/// - Swift `Date` is based on **seconds** since 1970-01-01 UTC (`TimeInterval` = `Double`).
/// - We **persist ISO-8601 strings** (e.g. `2026-08-05T15:30:00.000Z`) for readability
///   and to match other tray/auth files. On load we convert to `Date`.
/// - You *could* store epoch **milliseconds** (`Int64(date.timeIntervalSince1970 * 1000)`),
///   but ISO-8601 is clearer for humans and fine for our precision needs.
///
/// File:
/// `~/Library/Application Support/Claude-Code-Proxy Token Monitor Tray/grok-weekly-resets.json`
enum GrokWeeklyResetStore {
    struct Record: Equatable {
        /// End of the SuperGrok weekly window (when usage resets).
        var weeklyEnd: Date
        /// Last known weekly used % (optional; updated on fetch).
        var weeklyPercent: Double?
        /// When we last wrote this record (local clock).
        var updatedAt: Date
    }

    private static var appSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude-Code-Proxy Token Monitor Tray",
                isDirectory: true
            )
    }

    private static var fileURL: URL {
        appSupportDir.appendingPathComponent("grok-weekly-resets.json")
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public API

    static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Local-part for compact UI: `machingclee@gmail.com` → `machingclee`
    static func shortName(_ email: String) -> String {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = e.firstIndex(of: "@") {
            return String(e[..<at])
        }
        return e
    }

    static func loadAll() -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: Record] = [:]
        for (email, value) in obj {
            guard let d = value as? [String: Any] else { continue }
            guard let endStr = d["weekly_end"] as? String,
                  let weeklyEnd = parseISO(endStr) else { continue }
            let pct: Double? = {
                if let n = d["weekly_percent"] as? Double { return n }
                if let n = d["weekly_percent"] as? Int { return Double(n) }
                if let n = d["weekly_percent"] as? NSNumber { return n.doubleValue }
                return nil
            }()
            let updated = (d["updated_at"] as? String).flatMap(parseISO) ?? Date()
            out[normalizeEmail(email)] = Record(
                weeklyEnd: weeklyEnd,
                weeklyPercent: pct,
                updatedAt: updated
            )
        }
        return out
    }

    static func record(for email: String?) -> Record? {
        guard let email, !email.isEmpty else { return nil }
        return loadAll()[normalizeEmail(email)]
    }

    /// Update cache after a successful usage fetch for `email`.
    static func update(email: String?, weeklyEnd: Date?, weeklyPercent: Double?) {
        guard let email, !email.isEmpty, let weeklyEnd else { return }
        var all = loadAll()
        let key = normalizeEmail(email)
        all[key] = Record(
            weeklyEnd: weeklyEnd,
            weeklyPercent: weeklyPercent,
            updatedAt: Date()
        )
        saveAll(all)
    }

    /// Compact fractional days (`1.23d`) from a stored weeklyEnd — for menu bar.
    static func remainingDaysCompact(for email: String?) -> String? {
        guard let rec = record(for: email) else { return nil }
        return UsageService.remainingDaysCompact(until: rec.weeklyEnd)
    }

    /// Human remaining (`4d 23h 54m`) from a stored weeklyEnd — for account list.
    static func remainingLabel(for email: String?) -> String? {
        guard let rec = record(for: email) else { return nil }
        return UsageService.remainingLabel(until: rec.weeklyEnd)
    }

    /// Panel account list: `padgnoehc / 4d 23h 54m`
    static func accountLabel(email: String) -> String {
        let name = shortName(email)
        if let rem = remainingLabel(for: email) {
            return "\(name) / \(rem)"
        }
        return name
    }

    // MARK: - Persist

    private static func saveAll(_ map: [String: Record]) {
        var obj: [String: Any] = [:]
        for (email, rec) in map {
            var entry: [String: Any] = [
                "weekly_end": formatISO(rec.weeklyEnd),
                "updated_at": formatISO(rec.updatedAt),
            ]
            if let p = rec.weeklyPercent {
                entry["weekly_percent"] = p
            }
            obj[email] = entry
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try? FileManager.default.moveItem(at: tmp, to: fileURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func formatISO(_ date: Date) -> String {
        isoFrac.string(from: date)
    }

    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFrac.date(from: s) { return d }
        return iso.date(from: s)
    }
}
