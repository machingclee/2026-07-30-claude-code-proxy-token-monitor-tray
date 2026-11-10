import AppKit

/// Invisible window so a menu-bar-only app is not treated as having zero windows and quit at launch.
@MainActor
final class KeepAliveWindow {
    private var window: NSWindow?

    func install() {
        guard window == nil else { return }
        let w = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.level = .normal
        w.backgroundColor = .clear
        w.isOpaque = false
        w.orderBack(nil)
        window = w
    }
}
