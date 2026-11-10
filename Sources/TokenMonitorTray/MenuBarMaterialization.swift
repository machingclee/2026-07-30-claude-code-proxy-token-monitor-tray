import AppKit
import CoreGraphics

/// Best-effort check whether Control Center is hosting on-screen menu bar items (macOS 26 Tahoe).
enum MenuBarMaterialization {
    /// Any Control Center layer window in the top menu-bar strip (not item-specific).
    static func controlCenterHasTopStripItems() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "ControlCenter" else {
                continue
            }
            guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let y = bounds["Y"] ?? 9999
            let height = bounds["Height"] ?? 0
            let width = bounds["Width"] ?? 0
            if y <= 80, height >= 16, height <= 52, width >= 20 {
                return true
            }
        }
        return false
    }
}
