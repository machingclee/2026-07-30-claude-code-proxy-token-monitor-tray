import SwiftUI

/// Borderless menu-bar dropdown chrome (no window title bar).
struct MenuBarDropdownRoot: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        ContentView(model: model)
            .menuBarPanelFade(fadeIn: 0.16, fadeOut: 0.2, fadeOutOnResignKey: false)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Hug the card to the top of the window so it sits under the menu bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
