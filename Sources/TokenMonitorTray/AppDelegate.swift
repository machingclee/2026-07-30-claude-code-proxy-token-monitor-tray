import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: UsageViewModel?
    private var menuBar: MenuBarController?
    private var keepAlive: KeepAliveWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        StartupLog.mark("applicationWillFinishLaunching")
        installCrashLogging()
        LegacyDefaultsMigration.migrateIfNeeded()
        guard SingleInstanceGuard.shouldContinue() else {
            StartupLog.mark("duplicate instance — terminating")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let m = UsageViewModel()
            model = m
            let keeper = KeepAliveWindow()
            keepAlive = keeper
            keeper.install()
            menuBar = MenuBarController(model: m)
        }
        StartupLog.mark("menu bar controller installed")
        installPanelSignalHandler()
    }

    private func installCrashLogging() {
        NSSetUncaughtExceptionHandler { exception in
            StartupLog.mark("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "—")")
        }
    }

    private func installPanelSignalHandler() {
        signal(SIGUSR1) { _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .tokenMonitorShowPanel, object: nil)
            }
        }
    }

    /// Second-instance / CLI path: running app shows panel; otherwise launch fresh.
    static func requestShowPanelFromCLI() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            kill(running.processIdentifier, SIGUSR1)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .tokenMonitorShowPanel, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupLog.mark("applicationDidFinishLaunching")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StartupLog.mark("applicationShouldTerminate")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        StartupLog.mark("applicationWillTerminate")
        MainActor.assumeIsolated {
            menuBar?.shutdown()
        }
    }
}
