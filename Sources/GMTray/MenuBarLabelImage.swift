import AppKit

/// Renders metric text as a template `NSImage` for `MenuBarExtra`.
enum MenuBarLabelImage {
    /// Single line (e.g. `88% / 59%` or `$28`).
    static func single(_ text: String) -> NSImage {
        // Menu bar stays compact (user preference); panel body is enlarged separately.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(
            width: max(8, ceil(textSize.width) + 2),
            height: max(14, ceil(textSize.height) + 2)
        )
        let image = NSImage(size: size, flipped: true) { rect in
            let y = (rect.height - textSize.height) / 2
            (text as NSString).draw(
                in: NSRect(x: 0, y: y, width: rect.width, height: textSize.height + 1),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text
        return image
    }
}
