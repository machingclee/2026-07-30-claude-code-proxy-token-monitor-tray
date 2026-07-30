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
            HStack(spacing: 2) {
                Image(nsImage: model.menuBarIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                // Menu bar metrics: keep small — system bar often ignores large body fonts.
                Text(model.menuBarTitle)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .baselineOffset(-0.5)
                    .scaleEffect(0.85, anchor: .leading)
                    .padding(.trailing, -2)
            }
            .fixedSize()
        }
        .menuBarExtraStyle(.window)
    }
}
