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
    /// True when the `claude-code-proxy` binary is on disk / PATH (hides Launch UI if false).
    @Published private(set) var hasClaudeCodeProxy = false

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

    /// Local DeepSeek config (not CC Switch). Saved under Application Support for this app.
    @Published var deepseekAPIKeyDraft = ""
    @Published var deepseekBaseURLDraft = DeepSeekConfigStore.Config.default.anthropicBaseURL
    @Published var deepseekProModelDraft = DeepSeekConfigStore.Variant.pro.defaultModel
    @Published var deepseekFlashModelDraft = DeepSeekConfigStore.Variant.flash.defaultModel
    @Published private(set) var deepseekActiveVariant: DeepSeekConfigStore.Variant?
    @Published var deepseekConfigMessage: String?
    @Published private(set) var isActivatingDeepSeek = false
    @Published var showDeepSeekKey = false

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
        refreshClaudeCodeProxyAvailability()
        refreshProxyStatus()
        reloadSubscriptionRenew()
        reloadGrokProfiles()
        reloadDeepSeekConfig()
        Task { await refresh() }
        startBackgroundPolling()
    }

    func reloadDeepSeekConfig() {
        let c = DeepSeekConfigStore.load()
        // Don't overwrite a key the user is mid-editing with empty if already typing —
        // only load when draft is empty or matches previous load.
        deepseekAPIKeyDraft = c.apiKey
        deepseekBaseURLDraft = c.anthropicBaseURL
        deepseekProModelDraft = c.proModel
        deepseekFlashModelDraft = c.flashModel
        deepseekActiveVariant = c.activeVariant
    }

    func saveDeepSeekConfigFromDrafts() {
        var c = DeepSeekConfigStore.load()
        c.apiKey = deepseekAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        c.anthropicBaseURL = deepseekBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.anthropicBaseURL.isEmpty {
            c.anthropicBaseURL = DeepSeekConfigStore.Config.default.anthropicBaseURL
        }
        c.apiBaseURL = c.anthropicBaseURL
        c.proModel = DeepSeekConfigStore.normalizeContextTag(
            deepseekProModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        c.flashModel = DeepSeekConfigStore.normalizeContextTag(
            deepseekFlashModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if c.proModel.isEmpty { c.proModel = DeepSeekConfigStore.Variant.pro.defaultModel }
        if c.flashModel.isEmpty { c.flashModel = DeepSeekConfigStore.Variant.flash.defaultModel }
        deepseekProModelDraft = c.proModel
        deepseekFlashModelDraft = c.flashModel
        do {
            try DeepSeekConfigStore.save(c)
            deepseekActiveVariant = c.activeVariant
            deepseekConfigMessage =
                "Saved DeepSeek config → Application Support/Claude-Code-Proxy Token Monitor Tray/"
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if deepseekConfigMessage?.hasPrefix("Saved") == true {
                    deepseekConfigMessage = nil
                }
            }
            Task { await refresh(force: true) }
        } catch {
            deepseekConfigMessage = error.localizedDescription
        }
    }

    /// Activate DeepSeek Pro/Flash using tray-local key (writes ~/.claude/settings.json; no CC Switch).
    /// Inactivates the other DeepSeek variant and any Grok method (single active method).
    func activateDeepSeek(variant: DeepSeekConfigStore.Variant) {
        guard !isActivatingDeepSeek && !isSwitching else { return }
        isActivatingDeepSeek = true
        defer { isActivatingDeepSeek = false }

        // Persist drafts first so Activate uses what the user just typed.
        var c = DeepSeekConfigStore.load()
        c.apiKey = deepseekAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        c.anthropicBaseURL = deepseekBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.anthropicBaseURL.isEmpty {
            c.anthropicBaseURL = DeepSeekConfigStore.Config.default.anthropicBaseURL
        }
        c.apiBaseURL = c.anthropicBaseURL
        c.proModel = DeepSeekConfigStore.normalizeContextTag(
            deepseekProModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        c.flashModel = DeepSeekConfigStore.normalizeContextTag(
            deepseekFlashModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if c.proModel.isEmpty { c.proModel = DeepSeekConfigStore.Variant.pro.defaultModel }
        if c.flashModel.isEmpty { c.flashModel = DeepSeekConfigStore.Variant.flash.defaultModel }
        deepseekProModelDraft = c.proModel
        deepseekFlashModelDraft = c.flashModel

        do {
            try DeepSeekConfigStore.save(c)
            // activate(variant) sets only that variant active (Pro ↔ Flash exclusive).
            let activated = try DeepSeekConfigStore.activate(variant: variant)
            deepseekActiveVariant = activated.activeVariant

            // Stop Grok proxy if running — Claude is no longer on Grok.
            refreshProxyStatus()
            if isProxyRunning {
                stopClaudeCodeProxy()
                refreshProxyStatus()
            }

            reloadProviders()
            reloadGrokProfiles()
            let modelName: String = {
                switch variant {
                case .pro: return "deepseek-v4-pro[1m] + haiku/subagent deepseek-v4-flash"
                case .flash: return activated.model(for: .flash)
                }
            }()
            deepseekConfigMessage =
                "Activated DeepSeek \(variant.label) (\(modelName)) · other methods inactive · Restart Claude Code"
            Task {
                await refresh(force: true)
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if deepseekConfigMessage?.hasPrefix("Activated DeepSeek") == true {
                    deepseekConfigMessage = nil
                }
            }
        } catch {
            deepseekConfigMessage = error.localizedDescription
        }
    }

    /// Point Claude at local Grok proxy after Grok Activate.
    /// Always leaves **only** `ANTHROPIC_AUTH_TOKEN` (never also `ANTHROPIC_API_KEY`).
    private func applyGrokClaudeSettingsIfPossible() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var env = (root["env"] as? [String: Any]) ?? [:]
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:18765"
        // claude-code-proxy authenticates to Grok itself; Claude Code only needs a placeholder.
        env["ANTHROPIC_AUTH_TOKEN"] = "unused"
        // Critical: dual auth vars trigger Claude Code warning even on Grok/proxy.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        for k in [
            "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
        ] {
            env[k] = "grok-4.5"
        }
        env.removeValue(forKey: "DEEPSEEK_API_KEY")
        root["env"] = env
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// Active only if this variant is selected **and** Claude settings are on DeepSeek
    /// (so Grok Activate clears DeepSeek active state, and vice versa).
    func isDeepSeekVariantActive(_ variant: DeepSeekConfigStore.Variant) -> Bool {
        deepseekActiveVariant == variant && activeKind == .deepseek
    }

    /// Clear DeepSeek “active” marker when switching away (e.g. to Grok).
    private func clearDeepSeekActiveVariant() {
        var c = DeepSeekConfigStore.load()
        guard c.activeVariant != nil else {
            deepseekActiveVariant = nil
            return
        }
        c.activeVariant = nil
        try? DeepSeekConfigStore.save(c)
        deepseekActiveVariant = nil
    }

    /// Re-detect `claude-code-proxy` binary (Launch/Stop buttons depend on this).
    func refreshClaudeCodeProxyAvailability() {
        hasClaudeCodeProxy = resolveClaudeCodeProxy() != nil
    }

    /// Show Launch/Stop only when the binary exists, or something is already on :18765.
    var shouldShowClaudeCodeProxyControls: Bool {
        hasClaudeCodeProxy || isProxyRunning
    }

    /// Hide **Grok login** while weekly/monthly usage fetches successfully (auth is fine).
    /// Show it when there is no usable session or the last fetch failed.
    var shouldShowGrokLogin: Bool {
        if grok != nil { return false }
        // Avoid a flash of the button during the first load after open/Activate.
        if isLoading && grokError == nil { return false }
        return true
    }

    func reloadGrokProfiles() {
        grokProfiles = GrokAccountStore.listProfiles()
        activeGrokEmail = GrokAccountStore.activeEmail()
        // Renew date is per-account — refresh when profiles / active login change.
        reloadSubscriptionRenew()
    }

    /// True when the active CLI login is not yet stored under `~/.grok/profiles/`
    /// (listProfiles surfaces that as a synthetic `id == "__active__"` row).
    var shouldOfferSaveCurrentGrokProfile: Bool {
        grokProfiles.contains { $0.id == "__active__" }
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

    /// Whether this Grok profile row is fully active (CLI login + Claude currently on Grok).
    /// False when DeepSeek (or anything else) is the live Claude method.
    func isGrokAccountFullyActive(_ profile: GrokAccountStore.Profile) -> Bool {
        profile.isActive && activeKind == .grok
    }

    /// Activate a Grok account row:
    /// 1) switch `~/.grok/auth.json` to that profile if needed
    /// 2) **live** billing API probe (same as usage) — only re-login if that fails
    /// 3) if OK: sync proxy auth, set Grok provider, restart proxy if it was running
    /// 4) if auth expired/invalid: stop proxy, ask for Grok login (no auto re-login otherwise)
    func activateGrokAccount(profileId: String) {
        guard !isSwitchingGrokAccount && !isSwitching else { return }
        isSwitchingGrokAccount = true

        let needProfileSwitch: Bool = {
            if profileId == "__active__" { return false }
            return !grokProfiles.contains { $0.id == profileId && $0.isActive }
        }()

        do {
            if needProfileSwitch {
                try GrokAccountStore.switchTo(profileId: profileId)
                reloadGrokProfiles()
                grok = nil
            }
            // Probe before treating Activate as success (do not trust expires_at alone).
            grokAccountMessage = "Checking auth with usage API…"
            Task {
                defer { isSwitchingGrokAccount = false }
                await finishActivateGrokAccount(profileId: profileId)
            }
        } catch {
            isSwitchingGrokAccount = false
            grokAccountMessage = error.localizedDescription
            clearGrokAccountMessageLater()
        }
    }

    /// After profile is on disk as active: live API check → sync / re-login.
    private func finishActivateGrokAccount(profileId: String) async {
        let email = GrokAccountStore.activeEmail()
            ?? grokProfiles.first(where: { $0.id == profileId })?.email
            ?? profileId

        let probe = await UsageService.probeCLIAuthLive()
        switch probe {
        case .ok(let probedEmail):
            let shown = probedEmail.isEmpty ? email : probedEmail
            do {
                _ = try GrokAccountStore.syncActiveAuthToProxy()
                // Keep profile file fresh after a successful switch (optional copy).
                _ = try? GrokAccountStore.saveActiveAsProfile()
                reloadGrokProfiles()

                // Inactivate DeepSeek (Pro/Flash) — only one “method” active at a time.
                clearDeepSeekActiveVariant()

                if let grokProvider = provider(for: .grok), !grokProvider.isCurrent {
                    isSwitching = true
                    defer { isSwitching = false }
                    // May merge env from CC Switch (can reintroduce ANTHROPIC_API_KEY).
                    _ = try CCSwitchService.activate(providerId: grokProvider.id)
                    reloadProviders()
                }

                // Always last: force Grok proxy env and ensure only ANTHROPIC_AUTH_TOKEN
                // (never both AUTH_TOKEN + API_KEY — Claude Code warns / may mis-auth).
                try applyGrokClaudeSettingsIfPossible()

                refreshProxyStatus()
                let wasProxy = isProxyRunning
                if wasProxy {
                    // Valid new tokens: restart so in-memory identity matches Activate.
                    stopClaudeCodeProxy()
                    launchClaudeCodeProxy()
                } else if hasClaudeCodeProxy {
                    // Prefer proxy up so Claude/Grok method is usable after switch.
                    launchClaudeCodeProxy()
                }

                // Force a new usage fetch with the switched tokens (do not join an
                // in-flight poll that may still be using the previous account).
                await refresh(force: true)
                var msg = "Active: \(shown) · usage refreshed"
                if let g = grok {
                    msg += " · \(g.menuBarTitle)"
                }
                if wasProxy {
                    msg += " · proxy restarted"
                }
                msg += " · Restart Claude Code if needed."
                grokAccountMessage = msg
                clearGrokAccountMessageLater()
            } catch {
                grokAccountMessage = error.localizedDescription
                clearGrokAccountMessageLater()
            }

        case .authFailed(let status, let failedEmail):
            let shown = failedEmail ?? email
            refreshProxyStatus()
            if isProxyRunning {
                stopClaudeCodeProxy()
                refreshProxyStatus()
            }
            // Still sync failed tokens so paths stay aligned; login will replace them.
            _ = try? GrokAccountStore.syncActiveAuthToProxy()
            grok = nil
            grokError = "Auth failed (HTTP \(status)). Use Grok login."
            grokAccountMessage =
                "\(shown): auth failed (HTTP \(status)). Tokens expired or revoked — use Grok login."
            // Leave message visible longer than usual.
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if grokAccountMessage?.contains("auth failed") == true {
                    grokAccountMessage = nil
                }
            }

        case .noAuth:
            refreshProxyStatus()
            if isProxyRunning {
                stopClaudeCodeProxy()
                refreshProxyStatus()
            }
            grok = nil
            grokError = "No ~/.grok/auth.json"
            grokAccountMessage = "No usable ~/.grok/auth.json — use Grok login."
            clearGrokAccountMessageLater()

        case .networkOrOther(let detail):
            // Network blip: still switch/sync, then force-refresh usage anyway.
            do {
                _ = try GrokAccountStore.syncActiveAuthToProxy()
                if let grokProvider = provider(for: .grok), !grokProvider.isCurrent {
                    isSwitching = true
                    defer { isSwitching = false }
                    _ = try CCSwitchService.activate(providerId: grokProvider.id)
                    reloadProviders()
                }
                refreshProxyStatus()
                let wasProxy = isProxyRunning
                if wasProxy {
                    stopClaudeCodeProxy()
                    // Do not auto-restart on uncertain auth — user can Launch.
                }
                await refresh(force: true)
                grokAccountMessage =
                    "Switched to \(email) but usage API check failed (not necessarily expired): \(detail)"
                    + (wasProxy ? " · proxy stopped" : "")
                clearGrokAccountMessageLater()
            } catch {
                grokAccountMessage = error.localizedDescription
                clearGrokAccountMessageLater()
            }
        }
    }

    /// Switch active CLI login by copying a profile onto ~/.grok/auth.json
    func switchGrokAccount(profileId: String) {
        activateGrokAccount(profileId: profileId)
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
        refreshClaudeCodeProxyAvailability()
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

    /// All CC Switch Claude providers of a kind (e.g. DeepSeek Pro + Flash).
    func providers(for kind: CCSwitchService.ProviderKind) -> [CCSwitchService.Provider] {
        providers.filter { $0.kind == kind }
    }

    /// DeepSeek providers only — Pro / Flash / etc. for the in-panel switcher.
    /// Prefer Pro before Flash when both exist; otherwise keep CC Switch order.
    var deepseekProviders: [CCSwitchService.Provider] {
        let rank: (CCSwitchService.Provider) -> Int = { p in
            switch p.deepseekVariantLabel.lowercased() {
            case "pro": return 0
            case "flash": return 1
            case "reasoner": return 2
            case "chat": return 3
            default: return 10
            }
        }
        return providers(for: .deepseek).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// What the menu bar represents: prefer live Claude settings, then local DeepSeek, then CC Switch.
    var activeKind: CCSwitchService.ProviderKind {
        if Self.claudeSettingsLooksDeepSeek() { return .deepseek }
        if Self.claudeSettingsLooksGrok() { return .grok }
        if deepseekActiveVariant != nil { return .deepseek }
        return currentProvider?.kind ?? .other
    }

    private static func claudeSettingsLooksDeepSeek() -> Bool {
        guard let env = claudeEnv() else { return false }
        let blob = "\(env["ANTHROPIC_BASE_URL"] ?? "") \(env["ANTHROPIC_MODEL"] ?? "")".lowercased()
        return blob.contains("deepseek")
    }

    private static func claudeSettingsLooksGrok() -> Bool {
        guard let env = claudeEnv() else { return false }
        let base = (env["ANTHROPIC_BASE_URL"] ?? "").lowercased()
        let model = (env["ANTHROPIC_MODEL"] ?? "").lowercased()
        return base.contains("18765") || base.contains("localhost") || model.contains("grok")
    }

    private static func claudeEnv() -> [String: String]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = obj["env"] as? [String: Any] else {
            return nil
        }
        var out: [String: String] = [:]
        for (k, v) in env {
            if let s = v as? String { out[k] = s }
        }
        return out
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

    /// SuperGrok weekly usage % (the only rate-limit that matters day to day).
    var grokWeeklyLabel: String {
        if let grok { return grok.menuBarTitle }
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
    /// Grok: `88%/1.23d` = weekly used % / days until weekly reset. DeepSeek: balance (e.g. `$28`).
    var menuBarTitle: String {
        switch activeKind {
        case .deepseek:
            return deepseekMenuLabel
        case .grok:
            return grokWeeklyLabel
        case .other:
            if grok != nil { return grokWeeklyLabel }
            if deepseek != nil { return deepseekMenuLabel }
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
            refreshClaudeCodeProxyAvailability()
            refreshProxyStatus()
            reloadSubscriptionRenew()
            reloadGrokProfiles()
            reloadDeepSeekConfig()
            // Force re-read auth after possible external login/switch.
            Task { await refresh(force: true) }
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
    /// Syncs the tray-selected Grok login into the proxy auth file first (split auth stores).
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

        // ccs Grok Launch runs `grok login` first (browser). We instead push the
        // tray-active ~/.grok/auth.json into the proxy’s own auth file. Use
        // “Grok login (browser)” when you need a fresh OAuth popup.
        var syncNote = ""
        do {
            let email = try GrokAccountStore.syncActiveAuthToProxy()
            syncNote = " · auth: \(email)"
        } catch {
            setSwitchMessage(
                "No usable Grok auth for the proxy.\n"
                    + "\(error.localizedDescription)\n"
                    + "Use “Grok login (browser)” first, then Launch again."
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
                    setSwitchMessage("Started claude-code-proxy on :\(Self.proxyPort)\(syncNote).")
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

    /// Open Terminal for Grok OAuth using **device-code flow** + **normal Chrome**.
    ///
    /// Why not plain `grok auth login`?
    /// On macOS those CLIs open the default browser via Launch Services (ignore `$BROWSER`)
    /// and silently reuse whatever accounts.x.ai session is already signed in.
    ///
    /// We run device-code auth (prints a URL), then open **normal Chrome** after a quick
    /// accounts.x.ai logout so the next step is “pick Google account” — passwords stay
    /// saved for every Google account already signed into Chrome. No clean/incognito profile.
    func openGrokProxyBrowserLogin() {
        guard !isLaunchingProxy else { return }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeCodeProxyTokenMonitorTray")
        let scriptURL = logDir.appendingPathComponent("grok-login.command")
        // Keep historical filenames so old Terminal windows still find helpers if rewritten.
        let browserHelperURL = logDir.appendingPathComponent("open-incognito-browser.sh")
        let deviceLoginURL = logDir.appendingPathComponent("run-device-login-incognito.py")
        let saveProfileURL = logDir.appendingPathComponent("save-grok-profile-after-login.py")

        // Browser helper: ONLY open a single URL in the real Chrome profile.
        // Multi-step OAuth (logout → chooser → wait for Return → device URL) is
        // orchestrated by run-device-login so we can block on the Terminal TTY.
        // Optional: GROK_OAUTH_CLEAN=1 → temporary empty Chrome profile.
        let browserHelper = #"""
        #!/bin/zsh
        # Open $1 in YOUR real Chrome profile (last_used from Local State).
        set +e
        URL="${1:-}"
        if [[ -z "$URL" ]]; then
          echo "open-oauth-browser: missing URL" >&2
          exit 2
        fi

        temp_oauth_chrome_pids() {
          ps -axo pid=,command= 2>/dev/null | awk '
            /Google Chrome\.app\/Contents\// && /user-data-dir=/ && /grok-oauth-chrome/ { print $1 }
          '
        }
        real_chrome_main_pids() {
          ps -axo pid=,command= 2>/dev/null | awk '
            /Google Chrome\.app\/Contents\/MacOS\/Google Chrome/ && $0 !~ /user-data-dir=/ { print $1 }
            /Google Chrome\.app\/Contents\/MacOS\/Google Chrome/ && /Application Support\/Google\/Chrome/ { print $1 }
          '
        }
        kill_temp_oauth_chromes() {
          local pids
          pids="$(temp_oauth_chrome_pids)"
          if [[ -n "$pids" ]]; then
            echo "→ Force-closing leftover temp OAuth Chrome…" >&2
            # shellcheck disable=SC2086
            kill -9 $pids 2>/dev/null || true
            sleep 0.3
          fi
        }
        kill_temp_oauth_chromes

        resolve_chrome_profile_dir() {
          python3 -c 'import json;from pathlib import Path;p=Path.home()/"Library/Application Support/Google/Chrome/Local State";d=json.loads(p.read_text()) if p.exists() else {};last=(d.get("profile") or {}).get("last_used") or "Default";print(last if last=="Default" or str(last).startswith("Profile ") else "Default")' 2>/dev/null || echo Default
        }
        CHROME_PROFILE="$(resolve_chrome_profile_dir)"
        [[ -n "$CHROME_PROFILE" ]] || CHROME_PROFILE="Default"

        if [[ "${GROK_OAUTH_CLEAN:-0}" == "1" ]]; then
          echo "→ GROK_OAUTH_CLEAN=1: temporary Chrome profile" >&2
          _exe="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
          if [[ -x "$_exe" ]]; then
            _profile="$(mktemp -d "${TMPDIR:-/tmp}/grok-oauth-chrome.XXXXXX")"
            ("$_exe" --user-data-dir="$_profile" --no-first-run --no-default-browser-check \
              --disable-sync --incognito --new-window "$URL" >/dev/null 2>&1 &)
            exit 0
          fi
        fi

        if [[ ! -d "/Applications/Google Chrome.app" ]]; then
          open "$URL"; exit 0
        fi

        real_pids="$(real_chrome_main_pids)"
        if [[ -n "$real_pids" ]]; then
          if osascript -e "tell application \"Google Chrome\" to open location \"${URL//\"/\\\"}\"" >/dev/null 2>&1; then
            exit 0
          fi
          open -a "Google Chrome" "$URL"
          exit 0
        fi
        echo "→ Cold-start Chrome --profile-directory=$CHROME_PROFILE" >&2
        open -na "Google Chrome" --args --profile-directory="$CHROME_PROFILE" "$URL"
        exit 0
        """#

        // Device-code CLI + normal Chrome.
        // No local auth.json → first login, open device URL only (no logout).
        // Has auth.json → optional soft sign-out, then device URL.
        // Step 2 (CLI) skips sign-out entirely.
        let deviceLoginPy = #"""
        #!/usr/bin/env python3
        """Device-code OAuth in normal Chrome; skip logout when no local auth."""
        import os
        import re
        import subprocess
        import sys

        if len(sys.argv) < 3:
            print(
                "usage: run-device-login-incognito.py <browser-helper> <cmd> [args...]",
                file=sys.stderr,
            )
            raise SystemExit(2)

        helper = sys.argv[1]
        cmd = sys.argv[2:]
        url_re = re.compile(r"https://[^\s\)\]\"']+")
        expect = (os.environ.get("GROK_EXPECT_EMAIL") or "").strip().lower()
        # Default: normal Chrome. Opt in to empty profile only with GROK_OAUTH_CLEAN=1.
        use_clean = os.environ.get("GROK_OAUTH_CLEAN", "0") == "1"
        # Second step (CLI login) skips xAI logout — already done in step 1 (proxy).
        skip_signout = os.environ.get("GROK_SKIP_XAI_SIGNOUT", "0") == "1"
        # Fresh machine / wiped auth: no local session to leave — do not force logout.
        from pathlib import Path as _Path
        has_local_auth = (_Path.home() / ".grok" / "auth.json").is_file()

        def open_url(url: str, *, clean: bool = False) -> None:
            env = os.environ.copy()
            if clean:
                env["GROK_OAUTH_CLEAN"] = "1"
            else:
                env.pop("GROK_OAUTH_CLEAN", None)
            subprocess.run([helper, url], check=False, env=env)

        def pause(msg: str) -> None:
            print(msg, flush=True)
            try:
                with open("/dev/tty", "r") as tty:
                    tty.readline()
            except Exception:
                try:
                    input()
                except EOFError:
                    pass

        def active_email() -> str:
            import json
            from pathlib import Path

            p = Path.home() / ".grok" / "auth.json"
            if not p.is_file():
                return ""
            try:
                raw = json.loads(p.read_text())
            except Exception:
                return ""
            for v in raw.values():
                if isinstance(v, dict) and v.get("email"):
                    return str(v["email"]).strip().lower()
            return str(raw.get("email") or "").strip().lower()

        # Do not let the CLI open the default browser (we drive Chrome ourselves).
        env = os.environ.copy()
        env["BROWSER"] = "true"
        env["BROWSER_PATH"] = "true"

        print(f"$ {' '.join(cmd)}", flush=True)
        if expect:
            print(f"Expected SuperGrok account: {expect}", flush=True)
        if use_clean:
            print("GROK_OAUTH_CLEAN=1 → temporary empty Chrome profile\n", flush=True)
        else:
            print("Normal Chrome profile (saved Google accounts stay).\n", flush=True)

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        assert proc.stdout is not None
        opened = False
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if opened:
                continue
            m = url_re.search(line)
            if not m:
                continue
            url = m.group(0).rstrip(".,);")

            print("\n========== accounts.x.ai SESSION ==========", flush=True)
            print(
                "Device auth uses the SuperGrok account already signed into accounts.x.ai,",
                flush=True,
            )
            print(
                "not whichever Google account is selected on myaccount.google.com.",
                flush=True,
            )
            print("", flush=True)

            target_hint = expect or "the SuperGrok Google account you want"

            if use_clean:
                print(f"Opening device URL in clean Chrome:\n  {url}\n", flush=True)
                print(
                    f"Sign in with Google as {expect or 'the account you want'}, then Approve.",
                    flush=True,
                )
                open_url(url, clean=True)
            elif skip_signout:
                print(f"[step 2] Device URL (Approve in Chrome):\n  {url}\n", flush=True)
                open_url(url, clean=False)
            elif not has_local_auth:
                # First login after wipe / no account — do not force logout.
                print(
                    "[first login] No ~/.grok/auth.json — skipping accounts.x.ai logout.",
                    flush=True,
                )
                print(f"Opening device URL:\n  {url}\n", flush=True)
                print(
                    f"Sign in / Approve as {target_hint}. Waiting for CLI…\n",
                    flush=True,
                )
                open_url(url, clean=False)
            else:
                # Have local auth: soft optional sign-out only (not a hard requirement).
                print(
                    "[switch] Local auth exists. Opening logout pages only if you need to leave",
                    flush=True,
                )
                print(
                    "another SuperGrok session — not required if already signed out.",
                    flush=True,
                )
                open_url("https://accounts.x.ai/logout", clean=False)
                open_url("https://accounts.x.ai/", clean=False)
                pause(
                    f"\n>>> Target: {target_hint}"
                    "\n>>> If Chrome shows the wrong SuperGrok user, sign out there."
                    "\n>>> If you are already signed out / first time in this browser, ignore logout."
                    "\n>>> Press Return to open the device login page…\n"
                )
                print(f"Opening xAI device URL:\n  {url}\n", flush=True)
                open_url(url, clean=False)
                print(
                    f"Approve as {target_hint}. Waiting for CLI…\n",
                    flush=True,
                )

            opened = True

        code = proc.wait()
        if not opened:
            print("\nNo authorization URL was printed.", flush=True)
            raise SystemExit(code if code is not None else 1)

        if code != 0:
            raise SystemExit(code)

        # Only `grok login` writes ~/.grok/auth.json.
        is_cli_login = "login" in cmd
        if is_cli_login:
            got = active_email()
            if expect and got and got != expect:
                print("", flush=True)
                print("!!!!!!!!!! WRONG ACCOUNT !!!!!!!!!!", flush=True)
                print(f"  expected: {expect}", flush=True)
                print(f"  got:      {got}", flush=True)
                print("", flush=True)
                print(
                    "accounts.x.ai was almost certainly still signed in as the wrong user",
                    flush=True,
                )
                print(
                    "when you Approved. Retry: Activate target → Grok login →",
                    flush=True,
                )
                print(
                    "fully sign out of accounts.x.ai → Login with Google as the target",
                    flush=True,
                )
                print(
                    "→ confirm email on the device page → Approve.",
                    flush=True,
                )
                print(
                    "(Optional: GROK_OAUTH_CLEAN=1 for an empty Chrome window.)",
                    flush=True,
                )
                raise SystemExit(42)
            if got:
                print(f"\n✓ Active CLI login: {got}", flush=True)
        raise SystemExit(0)
        """#

        let saveProfilePy = #"""
        #!/usr/bin/env python3
        # After grok login: copy auth.json → profiles/<email>.json and sync proxy auth.
        import json
        import os
        import shutil
        import time
        from datetime import datetime
        from pathlib import Path

        home = Path.home()
        auth_path = home / ".grok" / "auth.json"
        profiles = home / ".grok" / "profiles"
        proxy_auth = home / ".config" / "claude-code-proxy" / "grok" / "auth.json"

        if not auth_path.is_file():
            print("  skip: no ~/.grok/auth.json")
            raise SystemExit(0)

        try:
            raw = json.loads(auth_path.read_text())
        except Exception as e:
            print(f"  skip profile save: cannot read auth.json ({e})")
            raise SystemExit(0)

        email = None
        entry = None
        for _, v in raw.items():
            if isinstance(v, dict) and v.get("email"):
                email = v["email"]
                entry = v
                break
        if not email:
            email = raw.get("email")
            entry = raw if email else None
        if not email or not isinstance(entry, dict):
            print("  skip profile save: no email in auth.json")
            raise SystemExit(0)

        profiles.mkdir(parents=True, exist_ok=True)
        safe = "".join(c if c.isalnum() or c in "._@+-" else "_" for c in email)
        dest = profiles / f"{safe}.json"
        shutil.copy2(auth_path, dest)
        os.chmod(dest, 0o600)
        print(f"  saved profile: {dest}")

        access = entry.get("key") or entry.get("access_token") or entry.get("access") or ""
        refresh = entry.get("refresh_token") or entry.get("refresh") or ""
        issuer = entry.get("oidc_issuer") or "https://auth.x.ai"
        client_id = entry.get("oidc_client_id") or entry.get("client_id") or ""
        expires_ms = None
        exp = entry.get("expires_at")
        if exp:
            try:
                s = str(exp).replace("Z", "+00:00")
                expires_ms = int(datetime.fromisoformat(s).timestamp() * 1000)
            except Exception:
                expires_ms = None
        if expires_ms is None:
            expires_ms = int((time.time() + 6 * 3600) * 1000)

        if access:
            proxy_auth.parent.mkdir(parents=True, exist_ok=True)
            out = {
                "access": access,
                "refresh": refresh,
                "expires_at_ms": expires_ms,
                "issuer": issuer,
                "client_id": client_id,
            }
            tmp = proxy_auth.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
            tmp.replace(proxy_auth)
            os.chmod(proxy_auth, 0o600)
            print(f"  synced proxy auth for {email}")
        print(f"  active login: {email}")
        """#

        // GROK_EXPECT_EMAIL is chosen interactively in Terminal (not from active auth.json).
        let shellBody = #"""
        #!/bin/zsh
        set +e
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.grok/bin:$PATH"
        LOG_DIR="$HOME/Library/Logs/ClaudeCodeProxyTokenMonitorTray"
        BROWSER_HELPER="$LOG_DIR/open-incognito-browser.sh"
        DEVICE_LOGIN="$LOG_DIR/run-device-login-incognito.py"
        SAVE_PROFILE="$LOG_DIR/save-grok-profile-after-login.py"
        clear
        echo "=== Grok login (normal Chrome) ==="
        echo ""
        echo "Uses your normal Chrome. Approve as the SuperGrok Google account you want."
        echo "Target is NOT taken from old active auth.json (that caused padgnoehc confusion)."
        echo ""

        # Optional target: only if you type one. Empty = accept whatever Chrome Approves.
        export GROK_EXPECT_EMAIL=""
        PROFILES_DIR="$HOME/.grok/profiles"
        typeset -a PROFILE_EMAILS
        PROFILE_EMAILS=()
        if [[ -d "$PROFILES_DIR" ]]; then
          for f in "$PROFILES_DIR"/*.json(N); do
            base="$(basename "$f" .json)"
            [[ "$base" == _backup* ]] && continue
            PROFILE_EMAILS+=("$base")
          done
        fi
        if (( ${#PROFILE_EMAILS[@]} > 0 )); then
          echo "Saved profiles (optional check after login):"
          i=1
          for e in "${PROFILE_EMAILS[@]}"; do
            echo "  $i) $e"
            (( i++ ))
          done
          echo "  (or type a full email)"
        fi
        echo -n "Login as which account? [Enter = any / no check]: "
        read -r TARGET_RAW
        TARGET_RAW="${TARGET_RAW// /}"
        if [[ -n "$TARGET_RAW" ]]; then
          if [[ "$TARGET_RAW" == <-> ]] && (( TARGET_RAW >= 1 && TARGET_RAW <= ${#PROFILE_EMAILS[@]} )); then
            export GROK_EXPECT_EMAIL="${PROFILE_EMAILS[$TARGET_RAW]}"
          else
            export GROK_EXPECT_EMAIL="$TARGET_RAW"
          fi
          echo "Will verify after CLI login: $GROK_EXPECT_EMAIL"
        else
          echo "No target check — will save whatever account OAuth returns."
        fi
        echo ""

        if ! command -v grok >/dev/null 2>&1; then
          echo "ERROR: grok CLI not on PATH. Expected: $HOME/.grok/bin/grok"
          echo "Press Return to close…"
          read -r _
          exit 1
        fi

        HAS_PROXY=0
        if command -v claude-code-proxy >/dev/null 2>&1; then HAS_PROXY=1; fi
        for p in /opt/homebrew/bin/claude-code-proxy /usr/local/bin/claude-code-proxy \
                 "$HOME/.local/bin/claude-code-proxy"; do
          [[ -x "$p" ]] && HAS_PROXY=1
        done

        USE_DEVICE_HELPER=0
        if [[ -x "$BROWSER_HELPER" && -f "$DEVICE_LOGIN" ]] && command -v python3 >/dev/null 2>&1; then
          USE_DEVICE_HELPER=1
        fi

        echo "======== Grok login (standard CLI) ========"
        if (( HAS_PROXY )); then
          echo "claude-code-proxy: found (will sync auth after login)"
        else
          echo "claude-code-proxy: not installed — CLI-only (no Launch button in tray)"
        fi
        echo ""

        if (( USE_DEVICE_HELPER )); then
          python3 "$DEVICE_LOGIN" "$BROWSER_HELPER" grok login --device-auth
          code=$?
        else
          echo "Device helper unavailable — running standard: grok login"
          grok login
          code=$?
        fi
        echo ""
        if [ "$code" -eq 42 ]; then
          echo "Stopped: wrong account vs your chosen target. Not saving."
        elif [ "$code" -ne 0 ]; then
          echo "Grok login failed (exit $code)."
        else
          if [[ -f "$SAVE_PROFILE" ]]; then
            if (( HAS_PROXY )); then
              echo "Saving profile + syncing proxy auth…"
              python3 "$SAVE_PROFILE" || true
            else
              echo "Saving profile only (no claude-code-proxy)…"
              python3 - <<'PY'
        import json, os, shutil
        from pathlib import Path
        home = Path.home()
        auth = home / ".grok" / "auth.json"
        profiles = home / ".grok" / "profiles"
        if not auth.is_file():
            raise SystemExit(0)
        raw = json.loads(auth.read_text())
        email = None
        for v in raw.values():
            if isinstance(v, dict) and v.get("email"):
                email = v["email"]
                break
        if not email:
            raise SystemExit(0)
        profiles.mkdir(parents=True, exist_ok=True)
        safe = "".join(c if c.isalnum() or c in "._@+-" else "_" for c in email)
        dest = profiles / f"{safe}.json"
        shutil.copy2(auth, dest)
        os.chmod(dest, 0o600)
        print(f"  saved profile: {dest}")
        print(f"  active login: {email}")
        PY
            fi
          fi
          echo ""
          echo "Done."
          echo "  1) Activate the account in the tray if needed"
          if (( HAS_PROXY )); then
            echo "  2) Launch claude-code-proxy if you use Claude Code via proxy"
            echo "  3) Restart Claude Code if needed"
          else
            echo "  2) Use Grok CLI / tray usage (no proxy)"
          fi
        fi
        echo ""
        echo "Press Return to close this window…"
        read -r _
        """#

        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            try browserHelper.write(to: browserHelperURL, atomically: true, encoding: .utf8)
            try deviceLoginPy.write(to: deviceLoginURL, atomically: true, encoding: .utf8)
            try saveProfilePy.write(to: saveProfileURL, atomically: true, encoding: .utf8)
            try shellBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            for url in [browserHelperURL, deviceLoginURL, saveProfileURL, scriptURL] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.path
                )
            }
            // Clear quarantine so double-open isn't blocked.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", logDir.path]
            xattr.standardOutput = Pipe()
            xattr.standardError = Pipe()
            try? xattr.run()
            xattr.waitUntilExit()

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            // Prefer Terminal explicitly; .command usually goes there anyway.
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open(
                    [scriptURL],
                    withApplicationAt: terminal,
                    configuration: config
                ) { _, error in
                    Task { @MainActor in
                        if let error {
                            self.setSwitchMessage(
                                "Terminal open failed: \(error.localizedDescription)\n"
                                    + "Run: grok login"
                            )
                        } else {
                            self.setSwitchMessage(
                                "Terminal opened for Grok login. Optional target email, then Approve in Chrome."
                            )
                        }
                    }
                }
            } else {
                // Fallback: open the .command file with default handler.
                NSWorkspace.shared.open(scriptURL, configuration: config) { _, error in
                    Task { @MainActor in
                        if let error {
                            self.setSwitchMessage(
                                "Could not open login script: \(error.localizedDescription)\n"
                                    + "Run in Terminal:\n  grok login"
                            )
                        } else {
                            self.setSwitchMessage(
                                "Opened grok-login.command. Finish login in Terminal / Chrome."
                            )
                        }
                    }
                }
            }
        } catch {
            setSwitchMessage(
                "Could not write login script: \(error.localizedDescription)\n"
                    + "Run manually in Terminal:\n  grok login"
            )
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

    /// Refresh usage. `force: true` always starts a new fetch after any in-flight one
    /// finishes — needed after Activate/switch so we do not keep the previous account’s numbers.
    func refresh(force: Bool = false) async {
        if let existing = fetchTask {
            await existing.value
            fetchTask = nil
            if !force { return }
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
        // Re-read active email so UI/subscription renew match the switched account.
        reloadGrokProfiles()

        async let grokResult = fetchGrok()
        async let dsResult = fetchDeepSeek()
        let (g, d) = await (grokResult, dsResult)

        switch g {
        case .success(let snap):
            grok = snap
            grokError = nil
        case .failure(let err):
            // Clear stale limits from the previous account on hard auth failure.
            if let ue = err as? UsageService.UsageError, case .http(let code, _) = ue, code == 401 || code == 403 {
                grok = nil
            }
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
