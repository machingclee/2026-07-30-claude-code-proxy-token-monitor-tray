import AppKit
import Combine
import SwiftUI

/// Borderless panel under the menu bar — not a titled window (Tahoe-safe positioning via screen coords).
@MainActor
final class DropdownPanelController {
    private let model: UsageViewModel
    private var panel: NSPanel?
    private var isClosing = false
    private(set) var isShown = false
    private let fadeInDuration: TimeInterval = 0.16
    private let fadeOutDuration: TimeInterval = 0.2
    private var heightCancellable: AnyCancellable?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Last position chosen for the status item. Expand/collapse must not move this.
    private var pinnedX: CGFloat?
    private var pinnedTopY: CGFloat?
    private var isApplyingFrame = false
    private var width: CGFloat { TrayPanelMetrics.width }

    var isVisible: Bool { isShown }

    init(model: UsageViewModel) {
        self.model = model
        heightCancellable = model.$panelContentHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                self?.applyContentHeight(height)
            }
    }

    func close(animated: Bool = true) {
        guard isShown, let p = panel else {
            isShown = false
            model.setPanelOpen(false)
            return
        }
        guard animated else {
            p.orderOut(nil)
            p.alphaValue = 0
            isShown = false
            isClosing = false
            model.setPanelOpen(false)
            return
        }
        guard !isClosing else { return }
        isClosing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    p.orderOut(nil)
                    return
                }
                p.orderOut(nil)
                p.alphaValue = 0
                self.isClosing = false
                self.isShown = false
                self.model.setPanelOpen(false)
            }
        })
    }

    /// Drop the panel from the status item. `trustClick` is true for a real menu-bar click.
    func showBelowMenuBar(itemScreenRect: CGRect, clickScreenPoint: CGPoint, trustClick: Bool) {
        let screen = screenForAnchor(itemScreenRect: itemScreenRect, click: clickScreenPoint, trustClick: trustClick)
        guard let screen else { return }
        let vf = screen.visibleFrame
        // Upper-left of the menu sits on the status item’s bottom-left (Docker-style).
        // The menu grows right and down from that corner.
        let left = menuLeftEdge(
            itemScreenRect: itemScreenRect,
            click: clickScreenPoint,
            trustClick: trustClick,
            screen: screen
        )
        let top = menuTop(itemScreenRect: itemScreenRect, screen: screen)
        let h = windowHeight(for: vf)
        var x = left
        x = min(x, vf.maxX - width - 6)
        x = max(vf.minX + 6, x)
        let y = top - h
        StartupLog.mark("panel show x=\(Int(x)) y=\(Int(y)) h=\(Int(h)) left=\(Int(left)) top=\(Int(top)) item=\(itemScreenRect) click=\(clickScreenPoint) trustClick=\(trustClick)")
        present(frame: NSRect(x: x, y: y, width: width, height: h))
    }

    private func screenForAnchor(itemScreenRect: CGRect, click: CGPoint, trustClick: Bool) -> NSScreen? {
        if MenuBarAnchor.isPlausible(itemScreenRect),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(itemScreenRect) }) {
            return screen
        }
        if trustClick || MenuBarAnchor.isInMenuBar(click),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(click) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Left edge of the menu = left edge of the status item.
    private func menuLeftEdge(itemScreenRect: CGRect, click: CGPoint, trustClick: Bool, screen: NSScreen) -> CGFloat {
        if MenuBarAnchor.isPlausible(itemScreenRect) {
            return itemScreenRect.minX
        }
        if trustClick || MenuBarAnchor.isInMenuBar(click, on: screen) {
            return click.x
        }
        return screen.visibleFrame.maxX - width - 12
    }

    /// Top of the menu = bottom of the status item, flush under the menu bar.
    private func menuTop(itemScreenRect: CGRect, screen: NSScreen) -> CGFloat {
        if MenuBarAnchor.isPlausible(itemScreenRect) {
            return itemScreenRect.minY
        }
        return screen.visibleFrame.maxY
    }

    private func windowHeight(for visibleFrame: NSRect) -> CGFloat {
        if model.panelContentHeight > 40 {
            return model.panelContentHeight
        }
        return min(640, max(280, visibleFrame.height * 0.62))
    }

    private func applyContentHeight(_ content: CGFloat) {
        guard isShown, content > 40, pinnedTopY != nil else { return }
        enforcePin(height: content)
    }

    /// Keep the top-left corner fixed under the menu bar while height changes.
    private func enforcePin(height: CGFloat? = nil) {
        guard isShown, let p = panel, let pinnedX, let pinnedTopY, !isApplyingFrame else { return }
        let h = height ?? p.frame.height
        let frame = NSRect(x: pinnedX, y: pinnedTopY - h, width: width, height: h)
        let current = p.frame
        guard abs(current.origin.x - frame.origin.x) > 0.5
            || abs(current.origin.y - frame.origin.y) > 0.5
            || abs(current.width - frame.width) > 0.5
            || abs(current.height - frame.height) > 0.5
        else { return }
        isApplyingFrame = true
        p.animations = [:]
        p.contentMinSize = NSSize(width: width, height: h)
        p.contentMaxSize = NSSize(width: width, height: h)
        p.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    private func pin(to frame: NSRect) {
        pinnedX = frame.origin.x
        pinnedTopY = frame.maxY
    }

    private func startPinObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        if resizeObserver == nil {
            resizeObserver = center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.enforcePin() }
            }
        }
        if moveObserver == nil {
            moveObserver = center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.enforcePin() }
            }
        }
    }

    private func present(frame: NSRect) {
        let p: NSPanel
        if let panel {
            p = panel
        } else {
            p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.hasShadow = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = ClearHostingView(rootView: MenuBarDropdownRoot(model: model))
            // SwiftUI must not resize this panel; that was dropping it away from the menu bar.
            host.sizingOptions = []
            p.contentView = host
            panel = p
        }
        isClosing = false
        isShown = true
        pin(to: frame)
        startPinObservers(for: p)
        p.animations = [:]
        p.alphaValue = 0
        p.contentMinSize = NSSize(width: frame.width, height: frame.height)
        p.contentMaxSize = NSSize(width: frame.width, height: frame.height)
        p.setFrame(frame, display: true)
        p.invalidateShadow()
        p.orderFrontRegardless()
        p.makeKey()
        model.setPanelOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }
}

/// Non-opaque host so the window shadow follows the rounded card instead of a rectangle.
private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Screen-coordinate checks for a menu-bar status item. Tahoe's status-item window is often `(0, 0, width, 0)`.
enum MenuBarAnchor {
    static func isPlausible(_ rect: CGRect) -> Bool {
        guard rect.width >= 8, rect.height >= 10, rect.height <= 80 else { return false }
        return isInMenuBar(CGPoint(x: rect.midX, y: rect.midY))
    }

    static func isInMenuBar(_ point: CGPoint, on screen: NSScreen? = nil) -> Bool {
        let screens = screen.map { [$0] } ?? NSScreen.screens
        return screens.contains { s in
            point.x >= s.frame.minX - 2 && point.x <= s.frame.maxX + 2
                && point.y >= s.visibleFrame.maxY - 6
                && point.y <= s.frame.maxY + 6
        }
    }

    /// Last resort: an on-screen menu-bar window whose width matches the status button.
    static func windowListMatch(buttonWidth: CGFloat, title: String) -> CGRect? {
        guard buttonWidth >= 8,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryMaxY = (NSScreen.screens.first { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }
            ?? NSScreen.main)?.frame.maxY ?? 0
        guard primaryMaxY > 0 else { return nil }

        var widthMatch: CGRect?
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            func num(_ key: String) -> CGFloat? {
                if let n = bounds[key] as? CGFloat { return n }
                if let n = bounds[key] as? Double { return CGFloat(n) }
                if let n = bounds[key] as? NSNumber { return CGFloat(truncating: n) }
                return nil
            }
            guard let x = num("X"), let y = num("Y"), let w = num("Width"), let h = num("Height") else { continue }
            guard h >= 12, h <= 48, w >= 20, w < 420 else { continue }
            let rect = CGRect(x: x, y: primaryMaxY - y - h, width: w, height: h)
            guard isPlausible(rect) else { continue }
            let name = info[kCGWindowName as String] as? String ?? ""
            if !title.isEmpty, name.contains(title) { return rect }
            if abs(w - buttonWidth) < 6 { widthMatch = rect }
        }
        return widthMatch
    }
}
