import SwiftUI
import AppKit

@main
struct TokenMonitorTrayApp: App {
    @StateObject private var model = UsageViewModel()

    init() {
        // Menu bar only — no Dock icon (also LSUIElement in Info.plist).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            // Composite label image: icon + weekly/monthly (or single metric).
            // Drawing text in SwiftUI VStack is unreliable inside MenuBarExtra.
            Image(nsImage: model.menuBarCompositeImage)
                .renderingMode(.template)
                .interpolation(.high)
        }
        .menuBarExtraStyle(.window)
    }
}
