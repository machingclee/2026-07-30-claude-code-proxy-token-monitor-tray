import AppKit
import Foundation

/// macOS 26 (Tahoe) hosts third-party menu bar items in Control Center and can keep
/// `NSStatusItem VisibleCC Item-N = 0` even when the app is allowed in System Settings.
@MainActor
enum MenuBarAllowListMonitor {
    private static let guidanceShownKey = "hasShownMenuBarAllowListGuidance"
    private static let guidanceShownAtKey = "menuBarAllowListGuidanceShownAt"
    private static let guidanceCooldown: TimeInterval = 24 * 60 * 60

    /// Keys Control Center writes into the app's preferences domain when it hides an item.
    static func controlCenterVisibilityKeys() -> [String] {
        let domain = Bundle.main.bundleIdentifier ?? ""
        guard !domain.isEmpty else { return [] }
        let dict = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        return dict.keys.filter { $0.hasPrefix("NSStatusItem VisibleCC Item-") }.sorted()
    }

    static func controlCenterMarkedHidden(itemIndex: Int = 0) -> Bool {
        let key = "NSStatusItem VisibleCC Item-\(itemIndex)"
        return UserDefaults.standard.integer(forKey: key) == 0
            && UserDefaults.standard.object(forKey: key) != nil
    }

    static func clearControlCenterVisibilityOverrides() {
        for key in controlCenterVisibilityKeys() {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    /// Heuristic: app is running, we have a button, but Control Center recorded hidden.
    static func looksBlockedByControlCenter(button: NSStatusBarButton?) -> Bool {
        guard button != nil else { return false }
        if controlCenterMarkedHidden() { return true }
        return controlCenterVisibilityKeys().contains { key in
            UserDefaults.standard.integer(forKey: key) == 0
        }
    }

    /// Check shortly after launch — CC applies visibility asynchronously.
    static func scheduleVisibilityChecks(
        buttonProvider: @escaping @MainActor () -> NSStatusBarButton?,
        onBlocked: @escaping @MainActor () -> Void
    ) {
        for delay in [3.0, 8.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let button = buttonProvider()
                if looksBlockedByControlCenter(button: button) {
                    onBlocked()
                }
            }
        }
    }

    static func shouldShowGuidance() -> Bool {
        if !UserDefaults.standard.bool(forKey: guidanceShownKey) { return true }
        let t = UserDefaults.standard.double(forKey: guidanceShownAtKey)
        guard t > 0 else { return true }
        return Date().timeIntervalSince1970 - t > guidanceCooldown
    }

    static func markGuidanceShown() {
        UserDefaults.standard.set(true, forKey: guidanceShownKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: guidanceShownAtKey)
    }

    static func presentBlockedBySystemAlert(appName: String, onRetryAfterCleanup: @escaping () -> Void) {
        guard shouldShowGuidance() else { return }
        markGuidanceShown()

        let alert = NSAlert()
        alert.messageText = "\(appName) can’t show its menu bar icon"
        alert.informativeText = """
        On macOS 26, Control Center can hide menu bar apps even when “Allow in the Menu Bar” is ON (stale Control Center state).

        Try, in order:
        1. System Settings → Menu Bar → Allow in the Menu Bar → ensure “\(appName)” is on.
        2. Tap “Clear hidden flag & recreate icon” below (fixes NSStatusItem VisibleCC = 0).
        3. If it still vanishes: Menu Bar settings → “Reset Control Center…” at the bottom, then reopen this app.

        The app keeps running in the background; only the icon is hidden.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "Clear hidden flag & recreate icon")
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        switch choice {
        case .alertFirstButtonReturn:
            openMenuBarSettings()
        case .alertSecondButtonReturn:
            clearControlCenterVisibilityOverrides()
            onRetryAfterCleanup()
        default:
            break
        }
    }

    static func openMenuBarSettings() {
        let candidates = [
            "x-apple.systemsettings:com.apple.MenuBar-Settings.extension",
            "x-apple.systempreferences:com.apple.MenuBarSettings",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
