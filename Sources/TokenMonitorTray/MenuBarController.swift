import AppKit
import SwiftUI
import Combine

/// Owns the menu bar status item and dropdown panel.
@MainActor
final class MenuBarController: NSObject {
    private let model: UsageViewModel
    private var statusItem: NSStatusItem
    private let dropdown: DropdownPanelController
    private var cancellables = Set<AnyCancellable>()
    private var visibilityGuard: Timer?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var workspaceWakeObserver: NSObjectProtocol?

    init(model: UsageViewModel) {
        self.model = model
        dropdown = DropdownPanelController(model: model)
        if MenuBarAllowListMonitor.controlCenterMarkedHidden() {
            MenuBarAllowListMonitor.clearControlCenterVisibilityOverrides()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName("TokenMonitorTray.v2")
        super.init()
        configureStatusItem()
        bindMenuBarLabel()
        startVisibilityGuard()
        startAllowListMonitoring()
        listenForShowPanelRequests()
        logStatusItemGeometry()
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.reassertMenuBarLabel()
                self?.applyStatusItemLabel()
            }
        }
    }

    func shutdown() {
        visibilityGuard?.invalidate()
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
        removeGlobalClickMonitor()
        dropdown.close(animated: false)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Status item

    private func startAllowListMonitoring() {
        let appName =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Claude-Code-Proxy Token Monitor Tray"
        MenuBarAllowListMonitor.scheduleVisibilityChecks(
            buttonProvider: { [weak self] in self?.statusItem.button }
        ) { [weak self] in
            guard let self else { return }
            MenuBarAllowListMonitor.presentBlockedBySystemAlert(appName: appName) {
                MenuBarAllowListMonitor.clearControlCenterVisibilityOverrides()
                self.recreateStatusItem()
            }
        }
    }

    func recreateStatusItem() {
        dropdown.close(animated: false)
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName("TokenMonitorTray.v2")
        configureStatusItem()
        applyStatusItemLabel()
    }

    func showPanel() {
        if dropdown.isVisible {
            dropdown.close()
            return
        }
        let click = NSEvent.mouseLocation
        dropdown.showBelowMenuBar(
            itemScreenRect: statusItemScreenRect(),
            clickScreenPoint: click,
            trustClick: false
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.installGlobalClickMonitor()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyStatusItemLabel()
    }

    private func bindMenuBarLabel() {
        model.$menuBarRevision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyStatusItemLabel()
            }
            .store(in: &cancellables)
    }

    private func applyStatusItemLabel() {
        statusItem.length = NSStatusItem.variableLength
        guard let button = statusItem.button else { return }
        button.image = model.menuBarIcon
        button.imagePosition = .imageLeading
        button.title = model.menuBarTitle
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.appearsDisabled = false
        button.toolTip = "Claude-Code-Proxy Token Monitor — \(model.menuBarTitle)"
        statusItem.isVisible = true
    }

    private func logStatusItemGeometry() {
        guard let button = statusItem.button else {
            StartupLog.mark("statusItem: no button")
            return
        }
        let screen = button.window?.screen != nil ? "yes" : "nil"
        let frame = button.window?.frame.debugDescription ?? "no-window"
        StartupLog.mark("statusItem screen=\(screen) frame=\(frame) title=\(model.menuBarTitle)")
    }

    private func listenForShowPanelRequests() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPanelFromNotification),
            name: .tokenMonitorShowPanel,
            object: nil
        )
    }

    @objc private func showPanelFromNotification() {
        showPanel()
    }

    private func startVisibilityGuard() {
        visibilityGuard?.invalidate()
        visibilityGuard = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reassertStatusItemIfNeeded()
            }
        }
    }

    private func reassertStatusItemIfNeeded() {
        guard let button = statusItem.button else { return }
        statusItem.isVisible = true
        if MenuBarAllowListMonitor.looksBlockedByControlCenter(button: button) {
            MenuBarAllowListMonitor.clearControlCenterVisibilityOverrides()
            recreateStatusItem()
            return
        }
        if button.image == nil || button.image?.size.width ?? 0 < 2 || button.title.isEmpty {
            applyStatusItemLabel()
        }
        if MenuBarAllowListMonitor.controlCenterMarkedHidden() {
            StartupLog.mark("visibility guard: Control Center marked hidden — recreating status item")
            MenuBarAllowListMonitor.clearControlCenterVisibilityOverrides()
            recreateStatusItem()
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if dropdown.isVisible {
            dismissPanel()
            return
        }
        let click = NSEvent.mouseLocation
        dropdown.showBelowMenuBar(
            itemScreenRect: statusItemScreenRect(),
            clickScreenPoint: click,
            trustClick: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.installGlobalClickMonitor()
        }
    }

    private func statusItemScreenRect() -> CGRect {
        guard let button = statusItem.button else { return .zero }
        // Tahoe hosts the item in Control Center. `window.frame` is often (0,0,w,0).
        // Accessibility frame is the on-screen menu bar rect.
        let ax = button.accessibilityFrame()
        if MenuBarAnchor.isPlausible(ax) {
            return ax
        }
        if let window = button.window {
            let local = button.convert(button.bounds, to: nil)
            let converted = window.convertToScreen(local)
            if MenuBarAnchor.isPlausible(converted) {
                return converted
            }
        }
        if let listed = MenuBarAnchor.windowListMatch(buttonWidth: button.bounds.width, title: button.title) {
            return listed
        }
        return .zero
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.dropdown.isVisible else { return }
                self.dismissPanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            Task { @MainActor in
                self?.dismissPanel()
            }
            return nil
        }
    }

    private func dismissPanel() {
        dropdown.close()
        removeGlobalClickMonitor()
    }

    private func removeGlobalClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}
