import Foundation

extension Notification.Name {
    /// Post to open the tray panel when the menu bar icon is missing (`kill -USR1` or `token-monitor-tray --panel`).
    static let tokenMonitorShowPanel = Notification.Name("TokenMonitorTrayShowPanel")
}
