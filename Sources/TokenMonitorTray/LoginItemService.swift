import Foundation
import ServiceManagement

/// Launch at Login via macOS ServiceManagement (macOS 13+).
/// Works when running from an installed `.app` (not bare `swift run`).
enum LoginItemService {
    /// Current registration status for this app bundle.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "enabled"
        case .notRegistered:
            return "off"
        case .notFound:
            return "not found (run the installed .app)"
        case .requiresApproval:
            return "needs approval in System Settings → Login Items"
        @unknown default:
            return "unknown"
        }
    }

    /// Enable or disable “Open at Login”.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            if SMAppService.mainApp.status == .notRegistered { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
