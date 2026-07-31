import SwiftUI
import AppKit

/// Fades the hosting `NSWindow` in when shown and out when it resigns key
/// (MenuBarExtra panel dismissed by click-outside or Esc).
struct PanelWindowFade: NSViewRepresentable {
    var fadeInDuration: TimeInterval = 0.18
    var fadeOutDuration: TimeInterval = 0.22

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.fadeInDuration = fadeInDuration
        view.fadeOutDuration = fadeOutDuration
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.fadeInDuration = fadeInDuration
        nsView.fadeOutDuration = fadeOutDuration
    }

    final class AnchorView: NSView {
        var fadeInDuration: TimeInterval = 0.18
        var fadeOutDuration: TimeInterval = 0.22

        private var resignObserver: NSObjectProtocol?
        private var becomeObserver: NSObjectProtocol?
        private var attachedWindow: NSWindow?
        private var isFadingOut = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detachObservers()
            guard let window else { return }
            attachedWindow = window
            attachObservers(to: window)
            // Fresh open: start transparent then fade in.
            if window.alphaValue > 0.99 || window.alphaValue == 1 {
                window.alphaValue = 0
            }
            fadeIn(window)
        }

        deinit {
            detachObservers()
        }

        private func attachObservers(to window: NSWindow) {
            let center = NotificationCenter.default
            resignObserver = center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.fadeOut(window)
            }
            becomeObserver = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.fadeIn(window)
            }
        }

        private func detachObservers() {
            let center = NotificationCenter.default
            if let resignObserver {
                center.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            if let becomeObserver {
                center.removeObserver(becomeObserver)
                self.becomeObserver = nil
            }
            attachedWindow = nil
            isFadingOut = false
        }

        private func fadeIn(_ window: NSWindow) {
            isFadingOut = false
            // Cancel any in-flight animator and restore opacity.
            window.animations = [:]
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeInDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }

        private func fadeOut(_ window: NSWindow) {
            guard !isFadingOut else { return }
            // If already fully transparent, nothing to do.
            if window.alphaValue <= 0.01 { return }
            isFadingOut = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = fadeOutDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isFadingOut = false
                // Reset so the next open can fade in cleanly if the window is reused.
                if !(window.isKeyWindow || window.isVisible) {
                    window.alphaValue = 0
                }
            })
        }
    }
}

extension View {
    /// Fade the MenuBarExtra panel window when it appears / resigns key.
    func menuBarPanelFade(
        fadeIn: TimeInterval = 0.18,
        fadeOut: TimeInterval = 0.22
    ) -> some View {
        background(
            PanelWindowFade(fadeInDuration: fadeIn, fadeOutDuration: fadeOut)
                .frame(width: 0, height: 0)
        )
    }
}
