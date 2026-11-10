import SwiftUI

@main
struct TokenMonitorTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        StartupLog.mark("TokenMonitorTrayApp.init")
    }

    var body: some Scene {
        // SwiftUI host only; UI is AppKit status item + popover (see AppDelegate).
        Settings {
            EmptyView()
        }
    }
}
