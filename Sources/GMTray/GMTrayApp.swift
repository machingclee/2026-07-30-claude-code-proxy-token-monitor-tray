import SwiftUI
import AppKit

@main
struct GMTrayApp: App {
    @StateObject private var model = UsageViewModel()

    init() {
        // Menu bar only — no Dock icon (also LSUIElement in Info.plist).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            // Icon follows active CC Switch provider (DeepSeek → whale, Grok → Grok mark).
            HStack(spacing: 3) {
                Image(nsImage: model.menuBarIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                Text(model.menuBarTitle)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
