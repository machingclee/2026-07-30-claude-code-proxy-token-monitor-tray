import AppKit
import SwiftUI

/// Monochrome Grok mark for the menu bar (template-tinted by the system).
enum GrokIcon {
    /// Template image for `MenuBarExtra` (drawn larger next to 12pt metrics).
    static var menuBar: NSImage {
        let source = loadVector() ?? fallbackSymbol()
        let size = NSSize(width: 20, height: 20)
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
        sized.accessibilityDescription = "Grok"
        return sized
    }

    private static func loadVector() -> NSImage? {
        // Prefer PDF vector.
        if let url = resourceURL(name: "GrokIcon", ext: "pdf"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        // PNG fallbacks (@2x preferred).
        if let url = resourceURL(name: "GrokIcon@2x", ext: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        if let url = resourceURL(name: "GrokIcon", ext: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        return nil
    }

    private static func resourceURL(name: String, ext: String) -> URL? {
        // Prefer Bundle.main (packaged .app). Avoid Bundle.module as the only path —
        // SPM looks for TokenMonitorTray_TokenMonitorTray.bundle at the .app root, which breaks codesign.
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        // Nested SPM bundle under Resources/ or MacOS/
        if let res = Bundle.main.resourceURL {
            let nested = res.appendingPathComponent("TokenMonitorTray_TokenMonitorTray.bundle/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }

        var roots: [URL] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exe) // Contents/MacOS
            roots.append(exe.deletingLastPathComponent().appendingPathComponent("Resources"))
            roots.append(exe.deletingLastPathComponent().deletingLastPathComponent()) // .app
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
        if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Grok") {
            img.isTemplate = true
            return img
        }
        return NSImage(size: NSSize(width: 17, height: 17))
    }
}
