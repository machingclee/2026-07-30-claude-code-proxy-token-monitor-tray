import SwiftUI
import AppKit

/// Fades the hosting `NSWindow` in when shown and out when it resigns key
/// (MenuBarExtra panel dismissed by click-outside or Esc).
struct PanelWindowFade: NSViewRepresentable {
    var fadeInDuration: TimeInterval = 0.18
    var fadeOutDuration: TimeInterval = 0.22
    /// When false, dismissal fade is handled by `DropdownPanelController` (avoids abrupt `orderOut`).
    var fadeOutOnResignKey: Bool = true

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.fadeInDuration = fadeInDuration
        view.fadeOutDuration = fadeOutDuration
        view.fadeOutOnResignKey = fadeOutOnResignKey
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.fadeInDuration = fadeInDuration
        nsView.fadeOutDuration = fadeOutDuration
        nsView.fadeOutOnResignKey = fadeOutOnResignKey
    }

    final class AnchorView: NSView {
        var fadeInDuration: TimeInterval = 0.18
        var fadeOutDuration: TimeInterval = 0.22
        var fadeOutOnResignKey: Bool = true

        private var resignObserver: NSObjectProtocol?
        private var becomeObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var attachedWindow: NSWindow?
        private var isFadingOut = false
        /// Keep the panel’s top edge stable when AppKit resizes the MenuBarExtra window.
        private var lockedTopY: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detachObservers()
            guard let window else { return }
            attachedWindow = window
            lockedTopY = window.frame.maxY
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
                guard let self, self.fadeOutOnResignKey else { return }
                self.fadeOut(window)
            }
            becomeObserver = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // The dropdown panel pins its own frame. Re-locking here captures a drifted origin.
                if self.fadeOutOnResignKey {
                    self.lockedTopY = window.frame.maxY
                }
                self.fadeIn(window)
            }
            // MenuBarExtra only. The dropdown panel resizes on expand/collapse and pins itself.
            if fadeOutOnResignKey {
                frameObserver = center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.reanchorTop(window)
                }
            }
        }

        private func reanchorTop(_ window: NSWindow) {
            guard let top = lockedTopY else {
                lockedTopY = window.frame.maxY
                return
            }
            var frame = window.frame
            let newTop = frame.maxY
            if abs(newTop - top) < 0.5 { return }
            // Keep top Y fixed; adjust origin.y so content grows/shrinks downward only.
            frame.origin.y = top - frame.size.height
            // Avoid horizontal drift if AppKit also shifted x.
            window.setFrame(frame, display: false)
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
            if let frameObserver {
                center.removeObserver(frameObserver)
                self.frameObserver = nil
            }
            attachedWindow = nil
            isFadingOut = false
            lockedTopY = nil
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
        fadeOut: TimeInterval = 0.22,
        fadeOutOnResignKey: Bool = true
    ) -> some View {
        background(
            PanelWindowFade(
                fadeInDuration: fadeIn,
                fadeOutDuration: fadeOut,
                fadeOutOnResignKey: fadeOutOnResignKey
            )
            .frame(width: 0, height: 0)
        )
    }
}
