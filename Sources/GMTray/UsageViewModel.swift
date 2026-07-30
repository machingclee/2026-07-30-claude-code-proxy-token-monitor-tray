import Foundation
import Combine
import AppKit

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

    /// True while the menu bar panel is open (drives 5s polling).
    @Published var isPanelOpen = false

    private var pollTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5

    init() {
        reloadProviders()
        Task { await refresh() }
    }

    var currentProvider: CCSwitchService.Provider? {
        providers.first(where: \.isCurrent)
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

    var grokMenuLabel: String {
        if let grok { return grok.menuBarTitle }
        if grokError != nil { return "!" }
        return isLoading ? "…" : "—"
    }

    var deepseekMenuLabel: String {
        if let deepseek { return deepseek.menuBarLabel }
        if deepseekError != nil { return "!" }
        return isLoading ? "…" : "—"
    }

    /// Single value next to the active-provider icon.
    var menuBarTitle: String {
        switch activeKind {
        case .deepseek:
            return deepseekMenuLabel
        case .grok:
            return grokMenuLabel
        case .other:
            // Unknown provider: show both metrics if available.
            if grok != nil || deepseek != nil {
                return "\(grokMenuLabel) · \(deepseekMenuLabel)"
            }
            return isLoading ? "…" : "—"
        }
    }

    func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        if open {
            reloadProviders()
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
            switchMessage = "Already active: \(provider.name)"
            return
        }
        isSwitching = true
        switchMessage = nil
        defer { isSwitching = false }
        do {
            _ = try CCSwitchService.activate(providerId: provider.id)
            reloadProviders()
            switchMessage = "Activated \(provider.name). Restart Claude Code."
            Task { await refresh() }
        } catch {
            switchMessage = error.localizedDescription
        }
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
}
