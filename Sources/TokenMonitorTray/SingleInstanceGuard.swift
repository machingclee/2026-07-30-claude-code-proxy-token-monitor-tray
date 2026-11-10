import AppKit

enum SingleInstanceGuard {
    /// If another copy is already running, activate it and return `false` (caller should terminate).
    static func shouldContinue() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return true }
        existing.activate(options: [.activateIgnoringOtherApps])
        return false
    }
}
