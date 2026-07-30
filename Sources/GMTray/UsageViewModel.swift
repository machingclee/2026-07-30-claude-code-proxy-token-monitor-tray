import Foundation
import Combine
import AppKit
import ServiceManagement
import Darwin

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var grok: UsageService.Snapshot?
    @Published private(set) var deepseek: DeepSeekService.Snapshot?
    @Published private(set) var grokError: String?
    @Published private(set) var deepseekError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    @Published private(set) var providers: [CCSwitchService.Provider] = []
    @Published private(set) var providersError: String?
    @Published private(set) var isSwitching = false
    @Published var switchMessage: String?
    @Published private(set) var isLaunchingProxy = false
    /// True when something accepts TCP on 127.0.0.1:18765 (claude-code-proxy).
    @Published private(set) var isProxyRunning = false

    /// Open at Login (SMAppService).
    @Published var launchAtLogin = false
    @Published var loginItemMessage: String?

    /// Manual SuperGrok renew (from grok.com Billing / rest/subscriptions).
    @Published private(set) var subscriptionNextRenew: Date?
    @Published var subscriptionRenewDraft = ""
    @Published var subscriptionRenewMessage: String?

    /// Saved Grok CLI logins under ~/.grok/profiles/
    @Published private(set) var grokProfiles: [GrokAccountStore.Profile] = []
    @Published private(set) var activeGrokEmail: String?
    @Published var grokAccountMessage: String?
    @Published private(set) var isSwitchingGrokAccount = false

    /// True while the menu bar panel is open (drives faster 5s polling).
    @Published var isPanelOpen = false

    private var pollTask: Task<Void, Never>?
    private var backgroundPollTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var messageClearTask: Task<Void, Never>?
    /// Poll interval while the panel is open.
    private let pollInterval: TimeInterval = 5
    /// Poll interval while the tray is idle (keeps menu bar label fresh).
    private let backgroundPollInterval: TimeInterval = 20
    private let messageDisplaySeconds: TimeInterval = 5

    static let proxyPort: UInt16 = 18765

    /// Show a brief status line; auto-clears after 5 seconds.
    func setSwitchMessage(_ text: String?) {
        messageClearTask?.cancel()
        switchMessage = text
        guard text != nil else { return }
        messageClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(messageDisplaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if switchMessage == text {
                switchMessage = nil
            }
        }
    }

    init() {
        reloadLoginItem()
        reloadProviders()
        refreshProxyStatus()
        reloadSubscriptionRenew()
        reloadGrokProfiles()
        Task { await refresh() }
        startBackgroundPolling()
    }

    func reloadGrokProfiles() {
        grokProfiles = GrokAccountStore.listProfiles()
        activeGrokEmail = GrokAccountStore.activeEmail()
        // Renew date is per-account — refresh when profiles / active login change.
        reloadSubscriptionRenew()
    }

    /// Snapshot current ~/.grok/auth.json into ~/.grok/profiles/<email>.json
    func saveCurrentGrokAccount() {
        do {
            let p = try GrokAccountStore.saveActiveAsProfile()
            reloadGrokProfiles()
            grokAccountMessage = "Saved profile: \(p.email)"
            clearGrokAccountMessageLater()
        } catch {
            grokAccountMessage = error.localizedDescription
            clearGrokAccountMessageLater()
        }
    }

    /// Switch active CLI login by copying a profile onto ~/.grok/auth.json
    func switchGrokAccount(profileId: String) {
        guard !isSwitchingGrokAccount else { return }
        isSwitchingGrokAccount = true
        defer { isSwitchingGrokAccount = false }
        do {
            try GrokAccountStore.switchTo(profileId: profileId)
            reloadGrokProfiles()
            let email = GrokAccountStore.activeEmail() ?? profileId
            grokAccountMessage = "Switched to \(email). Refreshing usage…"
            // Usage tokens change; clear and refetch. Proxy may need restart for Claude.
            grok = nil
            Task {
                await refresh()
                grokAccountMessage =
                    "Active: \(GrokAccountStore.activeEmail() ?? email)"
                    + (isProxyRunning
                        ? " · Restart proxy if Claude still uses the old account."
                        : "")
                clearGrokAccountMessageLater()
            }
        } catch {
            grokAccountMessage = error.localizedDescription
            clearGrokAccountMessageLater()
        }
    }

    private func clearGrokAccountMessageLater() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            grokAccountMessage = nil
        }
    }

    func reloadSubscriptionRenew() {
        let email = activeGrokEmail ?? GrokAccountStore.activeEmail()
        subscriptionNextRenew = SubscriptionRenewStore.nextRenewal(for: email)
        if let s = SubscriptionRenewStore.anchorDayString(for: email) {
            subscriptionRenewDraft = s
        } else {
            subscriptionRenewDraft = ""
        }
    }

    /// Save anchor day for the **active** Grok account (`yyyy-MM-dd` from grok.com 續訂).
    /// Next renew is that day if still upcoming, otherwise +1 month repeatedly.
    func saveSubscriptionRenewDate() {
        let email = activeGrokEmail ?? GrokAccountStore.activeEmail()
        guard let email, !email.isEmpty else {
            subscriptionRenewMessage = "No active Grok login. Run grok login first."
            return
        }
        let raw = subscriptionRenewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let day = SubscriptionRenewStore.parseDay(raw) else {
            subscriptionRenewMessage = "Use date format yyyy-MM-dd (e.g. 2026-08-19)"
            return
        }
        SubscriptionRenewStore.setAnchorDate(day, for: email)
        subscriptionNextRenew = SubscriptionRenewStore.nextRenewal(for: email)
        subscriptionRenewDraft = SubscriptionRenewStore.anchorDayString(for: email) ?? raw
        if let next = subscriptionNextRenew {
            subscriptionRenewMessage =
                "Saved for \(email). Next renew: \(SubscriptionRenewStore.formatDay(next))"
        } else {
            subscriptionRenewMessage = "Saved for \(email)."
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if subscriptionRenewMessage?.hasPrefix("Saved") == true {
                subscriptionRenewMessage = nil
            }
        }
    }

    func clearSubscriptionRenewDate() {
        let email = activeGrokEmail ?? GrokAccountStore.activeEmail()
        SubscriptionRenewStore.setAnchorDate(nil, for: email)
        subscriptionNextRenew = nil
        subscriptionRenewDraft = ""
        subscriptionRenewMessage = email.map { "Cleared renew date for \($0)." }
            ?? "Cleared subscription renew date."
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if subscriptionRenewMessage?.hasPrefix("Cleared") == true {
                subscriptionRenewMessage = nil
            }
        }
    }

    var subscriptionRenewRemainingLabel: String {
        SubscriptionRenewStore.remainingLabel(until: subscriptionNextRenew)
    }

    func refreshProxyStatus() {
        isProxyRunning = Self.isListening(port: Self.proxyPort)
    }

    /// TCP connect probe to 127.0.0.1:port (same idea as ccs `_is_proxy_running`).
    static func isListening(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }

        var timeout = timeval(tv_sec: 0, tv_usec: 300_000) // 0.3s
        _ = setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        )

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        return rc == 0
    }

    func reloadLoginItem() {
        launchAtLogin = LoginItemService.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtLogin = LoginItemService.isEnabled
            loginItemMessage = nil
            // macOS may require user approval the first time.
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                loginItemMessage = "Allow Claude-Code-Proxy Token Monitor Tray under System Settings → General → Login Items"
            }
        } catch {
            launchAtLogin = LoginItemService.isEnabled
            loginItemMessage = error.localizedDescription
        }
    }

    var currentProvider: CCSwitchService.Provider? {
        providers.first(where: \.isCurrent)
    }

    /// First CC Switch Claude provider matching a kind (for Activate in usage detail).
    func provider(for kind: CCSwitchService.ProviderKind) -> CCSwitchService.Provider? {
        // Prefer current if it matches, else first match by name/base heuristics.
        if let cur = currentProvider, cur.kind == kind { return cur }
        return providers.first { $0.kind == kind }
    }

    /// Active CC Switch provider kind (drives tray icon).
    var activeKind: CCSwitchService.ProviderKind {
        currentProvider?.kind ?? .other
    }

    /// Tray icon matches the activated Claude provider.
    var menuBarIcon: NSImage {
        switch activeKind {
        case .deepseek:
            return DeepSeekIcon.menuBar
        case .grok:
            return GrokIcon.menuBar
        case .other:
            // Prefer Grok mark as generic fallback; still show usage for active context.
            return GrokIcon.menuBar
        }
    }

    /// Weekly usage % for Grok tray (upper line).
    var grokWeeklyLabel: String {
        if let grok { return grok.menuBarTitle }
        if grokError != nil { return "!" }
        return isLoading ? "…" : "—"
    }

    /// Monthly usage % for Grok tray (lower line).
    var grokMonthlyLabel: String {
        if let grok { return grok.menuBarMonthlyTitle }
        if grokError != nil { return "!" }
        return isLoading ? "…" : "—"
    }

    var grokMenuLabel: String {
        grokWeeklyLabel
    }

    var deepseekMenuLabel: String {
        if let deepseek { return deepseek.menuBarLabel }
        if deepseekError != nil { return "!" }
        return isLoading ? "…" : "—"
    }

    /// Single-line tray label next to the icon.
    /// Grok: `weekly% / monthly%` (e.g. `88% / 59%`).
    var menuBarTitle: String {
        switch activeKind {
        case .deepseek:
            return deepseekMenuLabel
        case .grok:
            return "\(grokWeeklyLabel) / \(grokMonthlyLabel)"
        case .other:
            if grok != nil {
                return "\(grokWeeklyLabel) / \(grokMonthlyLabel)"
            }
            if deepseek != nil {
                return deepseekMenuLabel
            }
            return isLoading ? "…" : "—"
        }
    }

    /// Brand icon + single-line metrics for the status item.
    var menuBarCompositeImage: NSImage {
        let icon = menuBarIcon
        let metrics = MenuBarLabelImage.single(menuBarTitle)
        let gap: CGFloat = 3
        // Match metrics height better — earlier 14pt looked tiny next to 12pt text.
        let iconSide: CGFloat = 20
        let w = iconSide + gap + max(metrics.size.width, 12)
        let h = max(iconSide, metrics.size.height, 20)
        let size = NSSize(width: w, height: h)

        let out = NSImage(size: size, flipped: true) { _ in
            let iconRect = NSRect(
                x: 0,
                y: (h - iconSide) / 2,
                width: iconSide,
                height: iconSide
            )
            icon.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            let metricsRect = NSRect(
                x: iconSide + gap,
                y: (h - metrics.size.height) / 2,
                width: metrics.size.width,
                height: metrics.size.height
            )
            metrics.draw(
                in: metricsRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        out.isTemplate = true
        out.accessibilityDescription = menuBarTitle
        return out
    }

    func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        if open {
            reloadLoginItem()
            reloadProviders()
            refreshProxyStatus()
            reloadSubscriptionRenew()
            reloadGrokProfiles()
            Task { await refresh() }
            startPolling()
        } else {
            stopPolling()
        }
    }

    func reloadProviders() {
        do {
            providers = try CCSwitchService.listProviders()
            providersError = nil
        } catch {
            providers = []
            providersError = error.localizedDescription
        }
    }

    /// Activate a CC Switch Claude provider → writes ~/.claude/settings.json
    /// (same merge algorithm as `ccs`). No separate key storage.
    func activateProvider(_ provider: CCSwitchService.Provider) {
        guard !isSwitching else { return }
        if provider.isCurrent {
            setSwitchMessage("Already active: \(provider.name)")
            return
        }
        isSwitching = true
        setSwitchMessage(nil)
        defer { isSwitching = false }
        do {
            _ = try CCSwitchService.activate(providerId: provider.id)
            reloadProviders()
            setSwitchMessage("Activated \(provider.name). Restart Claude Code.")
            Task { await refresh() }
        } catch {
            setSwitchMessage(error.localizedDescription)
        }
    }

    /// Toggle proxy: if :18765 is up → stop listeners, else start stock `claude-code-proxy serve`.
    func toggleClaudeCodeProxy() {
        refreshProxyStatus()
        if isProxyRunning {
            stopClaudeCodeProxy()
        } else {
            launchClaudeCodeProxy()
        }
    }

    /// Start official binary: `claude-code-proxy serve --no-monitor` (no `ccs` required).
    func launchClaudeCodeProxy() {
        guard !isLaunchingProxy else { return }
        isLaunchingProxy = true
        setSwitchMessage(nil)
        defer {
            isLaunchingProxy = false
            refreshProxyStatus()
        }

        refreshProxyStatus()
        if isProxyRunning {
            setSwitchMessage("claude-code-proxy already running on :\(Self.proxyPort).")
            return
        }

        guard let bin = resolveClaudeCodeProxy() else {
            setSwitchMessage(
                "claude-code-proxy not found.\n"
                    + "Install: brew install claude-code-proxy"
            )
            return
        }

        let logURL = proxyLogURL()
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            let header = "\n--- Claude-Code-Proxy Token Monitor Tray start \(ISO8601DateFormatter().string(from: Date())) \(bin) ---\n"
            if let data = header.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            // Stock CLI: serve starts the proxy; --no-monitor keeps it lightweight.
            proc.arguments = ["serve", "--no-monitor"]
            proc.standardOutput = handle
            proc.standardError = handle
            proc.environment = augmentedPATH()
            // Detach so closing the tray doesn't kill the proxy.
            proc.qualityOfService = .utility

            try proc.run()
            // Don't wait for serve to exit — wait for the port.
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.1)
                if Self.isListening(port: Self.proxyPort) {
                    setSwitchMessage("Started claude-code-proxy on :\(Self.proxyPort).")
                    return
                }
                if !proc.isRunning {
                    setSwitchMessage(
                        "claude-code-proxy exited early.\n"
                            + "Log: \(logURL.path)"
                    )
                    return
                }
            }
            setSwitchMessage(
                "Started \(bin) but :\(Self.proxyPort) did not open.\n"
                    + "Log: \(logURL.path)"
            )
        } catch {
            setSwitchMessage("Failed to start claude-code-proxy: \(error.localizedDescription)")
        }
    }

    /// Stop whatever is listening on :18765 (SIGTERM, then SIGKILL). No `ccs` required.
    func stopClaudeCodeProxy() {
        guard !isLaunchingProxy else { return }
        isLaunchingProxy = true
        setSwitchMessage(nil)
        defer {
            isLaunchingProxy = false
            refreshProxyStatus()
        }

        let pids = listenerPIDs(port: Self.proxyPort)
        if pids.isEmpty {
            setSwitchMessage("No process listening on :\(Self.proxyPort).")
            return
        }

        for pid in pids {
            kill(pid_t(pid), SIGTERM)
        }
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if listenerPIDs(port: Self.proxyPort).isEmpty {
                setSwitchMessage("Stopped proxy pid(s): \(pids.map(String.init).joined(separator: ", ")).")
                return
            }
        }
        for pid in listenerPIDs(port: Self.proxyPort) {
            kill(pid_t(pid), SIGKILL)
        }
        Thread.sleep(forTimeInterval: 0.2)
        if listenerPIDs(port: Self.proxyPort).isEmpty {
            setSwitchMessage("Force-stopped proxy on :\(Self.proxyPort).")
        } else {
            setSwitchMessage("Failed to free :\(Self.proxyPort); still listening.")
        }
    }

    private func proxyLogURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Logs/ClaudeCodeProxyTokenMonitorTray/claude-code-proxy.log")
    }

    private func augmentedPATH() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [path]).joined(separator: ":")
        return env
    }

    /// Resolve stock `claude-code-proxy` binary (Homebrew / PATH / ~/.local/bin).
    private func resolveClaudeCodeProxy() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude-code-proxy",
            "/usr/local/bin/claude-code-proxy",
            "\(NSHomeDirectory())/.local/bin/claude-code-proxy",
            "\(NSHomeDirectory())/.grok/bin/claude-code-proxy",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let full = "\(dir)/claude-code-proxy"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        // Also scan augmented PATH dirs
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"] {
            let full = "\(dir)/claude-code-proxy"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// PIDs listening on TCP port (via `lsof`, standard on macOS).
    private func listenerPIDs(port: UInt16) -> [Int] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -nP numeric, -iTCP:port, -sTCP:LISTEN, -t PIDs only
        proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        var pids: [Int] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                pids.append(pid)
            }
        }
        return Array(Set(pids)).sorted()
    }

    func refresh() async {
        if let existing = fetchTask {
            await existing.value
            return
        }
        let task = Task { await performRefresh() }
        fetchTask = task
        await task.value
        fetchTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        reloadProviders()
        refreshProxyStatus()

        async let grokResult = fetchGrok()
        async let dsResult = fetchDeepSeek()
        let (g, d) = await (grokResult, dsResult)

        switch g {
        case .success(let snap):
            grok = snap
            grokError = nil
        case .failure(let err):
            grokError = err.localizedDescription
        }

        switch d {
        case .success(let snap):
            deepseek = snap
            deepseekError = nil
        case .failure(let err):
            deepseekError = err.localizedDescription
        }

        if grok != nil || deepseek != nil {
            lastRefresh = Date()
        }
    }

    private func fetchGrok() async -> Result<UsageService.Snapshot, Error> {
        do { return .success(try await UsageService.fetchSnapshot()) }
        catch { return .failure(error) }
    }

    private func fetchDeepSeek() async -> Result<DeepSeekService.Snapshot, Error> {
        do { return .success(try await DeepSeekService.fetchSnapshot()) }
        catch { return .failure(error) }
    }

    /// Faster refresh while the dropdown panel is visible.
    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 5) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self, self.isPanelOpen else { break }
                await self.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Keep the menu bar label up to date even when the panel is closed.
    private func startBackgroundPolling() {
        backgroundPollTask?.cancel()
        backgroundPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64((self?.backgroundPollInterval ?? 20) * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                guard let self else { break }
                // Panel already polls every 5s — skip the slower tick while open.
                if self.isPanelOpen { continue }
                await self.refresh()
            }
        }
    }
}
