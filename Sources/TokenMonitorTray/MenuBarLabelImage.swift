import AppKit

/// Renders the menu-bar status image: Grok in the first column, DeepSeek in the second.
enum MenuBarLabelImage {
    /// One line per column, at menu-bar size. Two stacked rows had to shrink the type to fit.
    static func columns(
        leadingIcon: NSImage,
        leadingText: String,
        trailingIcon: NSImage,
        trailingText: String
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let leadingSize = (leadingText as NSString).size(withAttributes: attrs)
        let trailingSize = (trailingText as NSString).size(withAttributes: attrs)
        let iconSide: CGFloat = 18
        let iconGap: CGFloat = 3
        let columnGap: CGFloat = 12
        let padX: CGFloat = 1

        func columnWidth(_ textSize: NSSize) -> CGFloat {
            iconSide + iconGap + ceil(textSize.width)
        }

        let width = padX + columnWidth(leadingSize) + columnGap + columnWidth(trailingSize) + padX
        let height = max(iconSide, ceil(leadingSize.height), ceil(trailingSize.height))
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size, flipped: true) { _ in
            func drawColumn(icon: NSImage, text: String, textSize: NSSize, x: CGFloat) {
                let iconRect = NSRect(
                    x: x,
                    y: (height - iconSide) / 2,
                    width: iconSide,
                    height: iconSide
                )
                let painted = (icon.copy() as? NSImage) ?? icon
                painted.isTemplate = false
                painted.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                let textRect = NSRect(
                    x: x + iconSide + iconGap,
                    y: (height - textSize.height) / 2,
                    width: ceil(textSize.width) + 1,
                    height: textSize.height
                )
                (text as NSString).draw(in: textRect, withAttributes: attrs)
            }
            drawColumn(icon: leadingIcon, text: leadingText, textSize: leadingSize, x: padX)
            drawColumn(
                icon: trailingIcon,
                text: trailingText,
                textSize: trailingSize,
                x: padX + columnWidth(leadingSize) + columnGap
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Grok \(leadingText), DeepSeek \(trailingText)"
        return image
    }
}
