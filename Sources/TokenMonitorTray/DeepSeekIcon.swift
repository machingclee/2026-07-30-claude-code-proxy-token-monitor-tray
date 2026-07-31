import AppKit
import SwiftUI

/// Monochrome DeepSeek whale mark for the menu bar (template-tinted by the system).
enum DeepSeekIcon {
    /// 17 pt template image suitable for `MenuBarExtra`.
    static var menuBar: NSImage {
        let source = loadVector() ?? fallbackSymbol()
        let size = NSSize(width: 17, height: 17)
        let sized = NSImage(size: size)
        sized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: source.size == .zero ? size : source.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        sized.unlockFocus()
        sized.isTemplate = true
        sized.accessibilityDescription = "DeepSeek"
        return sized
    }

    private static func loadVector() -> NSImage? {
        if let url = resourceURL(name: "DeepSeekIcon", ext: "pdf"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        if let url = resourceURL(name: "DeepSeekIcon@2x", ext: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        if let url = resourceURL(name: "DeepSeekIcon", ext: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        return nil
    }

    private static func resourceURL(name: String, ext: String) -> URL? {
        // Prefer Bundle.main (packaged .app). Avoid relying on Bundle.module alone —
        // SPM looks for TokenMonitorTray_TokenMonitorTray.bundle at the .app root, which breaks codesign.
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let res = Bundle.main.resourceURL {
            let nested = res.appendingPathComponent("TokenMonitorTray_TokenMonitorTray.bundle/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }

        var roots: [URL] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exe)
            roots.append(exe.deletingLastPathComponent().appendingPathComponent("Resources"))
            roots.append(exe.deletingLastPathComponent().deletingLastPathComponent())
        }
        roots.append(Bundle.main.bundleURL)

        let relative = [
            "TokenMonitorTray_TokenMonitorTray.bundle/\(name).\(ext)",
            "Contents/Resources/\(name).\(ext)",
            "Contents/Resources/TokenMonitorTray_TokenMonitorTray.bundle/\(name).\(ext)",
            "Contents/MacOS/TokenMonitorTray_TokenMonitorTray.bundle/\(name).\(ext)",
            "Resources/\(name).\(ext)",
            "\(name).\(ext)",
        ]

        for root in roots {
            for rel in relative {
                let c = root.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: c.path) {
                    return c
                }
            }
        }
        return nil
    }

    private static func fallbackSymbol() -> NSImage {
        if let img = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "DeepSeek") {
            img.isTemplate = true
            return img
        }
        return NSImage(size: NSSize(width: 17, height: 17))
    }
}
