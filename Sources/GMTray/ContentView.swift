import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: UsageViewModel
    /// Sections start collapsed; click a row to expand (multiple allowed).
    @State private var expandedIds: Set<String> = []
    /// Subscription renew editor shown only after Update.
    @State private var editingSubscriptionRenew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if model.grok == nil && model.deepseek == nil
                && model.grokError == nil && model.deepseekError == nil
                && model.isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading usage…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                collapsibleUsage(
                    id: "usage:grok",
                    title: "Grok",
                    icon: .grok,
                    summary: model.grokMenuLabel,
                    error: model.grokError,
                    provider: model.provider(for: .grok)
                ) {
                    // Accounts → Save (if needed) → Activate / proxy → usage.
                    grokAccountsSection
                    if let snap = model.grok {
                        weeklySection(snap)
                        monthlySection(snap)
                    } else if model.grokError == nil {
                        Text("Loading…").font(.body).foregroundStyle(.secondary)
                    }
                }

                collapsibleUsage(
                    id: "usage:deepseek",
                    title: "DeepSeek",
                    icon: .deepseek,
                    summary: model.deepseekMenuLabel,
                    error: model.deepseekError,
                    provider: model.provider(for: .deepseek)
                ) {
                    // Activate Pro / Flash (and any other DeepSeek CC Switch providers) first.
                    deepseekModelsSection
                    if let snap = model.deepseek {
                        deepseekSection(snap)
                    } else if model.deepseekError == nil {
                        Text("Loading…").font(.body).foregroundStyle(.secondary)
                    }
                }
            }

            if let msg = model.switchMessage {
                Text(msg)
                    .font(.body)
                    .foregroundStyle(
                        msg.contains("Activated") || msg.contains("Already")
                            ? Color.secondary : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = model.providersError {
                Text(err)
                    .font(.body)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            settingsRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 420)
        .menuBarPanelFade(fadeIn: 0.18, fadeOut: 0.22)
        .onAppear { model.setPanelOpen(true) }
        .onDisappear { model.setPanelOpen(false) }
    }

    // MARK: - Header / settings / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude-Code-Proxy Token Monitor")
                    .font(.title3.weight(.semibold))
                Text("Grok · DeepSeek · local proxy")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading || model.isSwitching || model.isLaunchingProxy {
                ProgressView()
                    .controlSize(.regular)
            }
        }
    }

    private var settingsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at login")
                        .font(.body.weight(.medium))
                    Text("Start this tray when you log in to macOS")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .help("Launch Claude-Code-Proxy Token Monitor Tray at login")
            }

            if let msg = model.loginItemMessage {
                Text(msg)
                    .font(.body)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let t = model.lastRefresh {
                Text("Updated \(timeAgo(t))")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoading)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Usage (collapsible) + Activate in detail

    private func collapsibleUsage<Content: View>(
        id: String,
        title: String,
        icon: CCSwitchService.ProviderKind,
        summary: String,
        error: String?,
        provider: CCSwitchService.Provider?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = expandedIds.contains(id)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle(id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)

                    providerIcon(icon)
                        .frame(width: 16, height: 16)

                    Text(title)
                        .font(.title3)
                        .fontWeight(.regular)
                        .foregroundStyle(.primary)

                    if provider?.isCurrent == true {
                        Text("active")
                            .font(.body)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 4)

                    if !expanded {
                        Text(summary)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            provider?.isCurrent == true
                                ? Color.accentColor.opacity(0.06)
                                : Color.primary.opacity(0.03)
                        )
                )
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.leading, 4)

                if let error {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .padding(.leading, 4)
                }

                // Grok: Activate + proxy sit under "Save current login" in grokAccountsSection.
                if icon != .grok {
                    activateControl(for: provider, kind: icon)
                        .padding(.top, 4)
                        .padding(.leading, 4)
                }
            } else if let error {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func activateControl(
        for provider: CCSwitchService.Provider?,
        kind: CCSwitchService.ProviderKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // DeepSeek multi-variant: Activate lives on each Pro/Flash row above.
            // Single DeepSeek (or Grok): keep the full-width Activate / active status.
            if kind == .deepseek && model.deepseekProviders.count > 1 {
                if let cur = model.currentProvider, cur.kind == .deepseek {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .imageScale(.small)
                        Text("Active: \(cur.deepseekVariantLabel) → ~/.claude/settings.json")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Choose Pro or Flash above, then Restart Claude Code.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else if let provider {
                if provider.isCurrent {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .imageScale(.small)
                        Text("Active in ~/.claude/settings.json")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        model.activateProvider(provider)
                    } label: {
                        Text("Activate")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isSwitching)
                    .help("Write \(provider.name) into ~/.claude/settings.json (CC Switch)")
                }
            } else {
                Text("No matching CC Switch provider")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }

        }
    }

    /// Grok accounts (Activate per row like DeepSeek), optional Save, then proxy.
    private var grokAccountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grok accounts")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)

            if model.grokProfiles.isEmpty {
                Text("No saved profiles yet. Save the current login, then grok login as the other account and Save again.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.grokProfiles) { p in
                    HStack(spacing: 6) {
                        Text(p.email)
                            .font(.body)
                            .lineLimit(1)
                        if model.isGrokAccountFullyActive(p) {
                            Text("active")
                                .font(.body)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 4)
                        if model.isGrokAccountFullyActive(p) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                                .symbolRenderingMode(.hierarchical)
                        } else if p.id != "__active__" || p.isActive {
                            // Saved profiles, or current login when Claude is not on Grok yet.
                            Button("Activate") {
                                model.activateGrokAccount(profileId: p.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(model.isSwitchingGrokAccount || model.isSwitching)
                            .help("Use this Grok login and activate Grok in ~/.claude/settings.json")
                        }
                    }
                }
            }

            // Only when current ~/.grok/auth.json is not already under profiles/.
            if model.shouldOfferSaveCurrentGrokProfile {
                Button {
                    model.saveCurrentGrokAccount()
                } label: {
                    Text("Save current login as profile")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 8)
                .help("Copy ~/.grok/auth.json → ~/.grok/profiles/<email>.json")
            }

            if let msg = model.grokAccountMessage {
                Text(msg)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Proxy — Activate lives on each account row (like DeepSeek Pro/Flash).
            // Auth: Launch syncs tray ~/.grok/auth.json → proxy auth. Browser login is separate
            // (ccs Grok Launch used to run `grok login` every time; we only popup on demand).
            Button {
                model.openGrokProxyBrowserLogin()
            } label: {
                Text("Grok login (browser)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.isLaunchingProxy || model.isSwitching)
            .help("Opens Terminal: claude-code-proxy grok auth login (+ optional grok login). Use when you get 402 or tokens expired.")
            .padding(.top, 8)

            if model.isProxyRunning {
                Button {
                    model.stopClaudeCodeProxy()
                } label: {
                    Text("Stop claude-code-proxy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isLaunchingProxy || model.isSwitching)
                .help("Port 18765 is in use — stop listeners (SIGTERM)")
            } else {
                Button {
                    model.launchClaudeCodeProxy()
                } label: {
                    Text("Launch claude-code-proxy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isLaunchingProxy || model.isSwitching)
                .help("Syncs active Grok login into proxy auth, then: claude-code-proxy serve --no-monitor")
            }

            Divider().padding(.vertical, 4)
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedIds.contains(id) {
                expandedIds.remove(id)
            } else {
                expandedIds.insert(id)
            }
        }
    }

    // MARK: - Icons & usage content

    @ViewBuilder
    private func providerIcon(_ kind: CCSwitchService.ProviderKind) -> some View {
        switch kind {
        case .grok:
            Image(nsImage: GrokIcon.menuBar)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .deepseek:
            Image(nsImage: DeepSeekIcon.menuBar)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .other:
            Image(systemName: "cpu")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func weeklySection(_ snap: UsageService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weekly")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            usageBar(percent: snap.weeklyPercent)
            row("Left", String(format: "~%.1f%%", snap.weeklyLeft))
            row("Reset", "\(UsageService.formatDate(snap.weeklyEnd))  (in \(snap.weeklyRemainingLabel))")
            if !snap.productLines.isEmpty {
                ForEach(Array(snap.productLines.enumerated()), id: \.offset) { _, p in
                    row(p.name, String(format: "%.1f%%", p.percent))
                }
            }
            Text(snap.source)
                .font(.body)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func monthlySection(_ snap: UsageService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monthly usage (API calendar window)")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if let used = snap.monthlyUsed, let limit = snap.monthlyLimit {
                let pct = snap.monthlyPercent ?? 0
                Text(String(format: "%.0f / %.0f", used, limit))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                usageBar(percent: pct)
            } else {
                Text("No monthly data")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            // Calendar usage window from CLI API — not SuperGrok card renew day.
            row("Period", "\(UsageService.formatDate(snap.monthlyStart)) → \(UsageService.formatDate(snap.monthlyEnd))")
            row(
                "Period ends",
                "\(UsageService.formatDate(snap.monthlyEnd))  (in \(snap.monthlyRemainingLabel))"
            )

            Text("Subscription renew")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(alignment: .center, spacing: 8) {
                Text("Next renew")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                if let next = model.subscriptionNextRenew {
                    Text("\(SubscriptionRenewStore.formatDay(next))  (in \(model.subscriptionRenewRemainingLabel))")
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text("Not set")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Update") {
                    model.reloadSubscriptionRenew()
                    editingSubscriptionRenew = true
                }
                .controlSize(.regular)
            }

            if editingSubscriptionRenew {
                HStack(spacing: 6) {
                    TextField("yyyy-MM-dd", text: $model.subscriptionRenewDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 140)
                        .onSubmit {
                            model.saveSubscriptionRenewDate()
                            editingSubscriptionRenew = false
                        }
                    Button("Save") {
                        model.saveSubscriptionRenewDate()
                        editingSubscriptionRenew = false
                    }
                    .controlSize(.regular)
                    Button("Clear") {
                        model.clearSubscriptionRenewDate()
                        editingSubscriptionRenew = false
                    }
                    .controlSize(.regular)
                }
            }
            if let msg = model.subscriptionRenewMessage {
                Text(msg)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.activeGrokEmail) { _ in
            editingSubscriptionRenew = false
        }
    }

    /// Activate among CC Switch DeepSeek providers (e.g. V4 Pro vs V4 Flash).
    /// Every non-active row is **Activate** (never "Switch").
    private var deepseekModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DeepSeek model")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)

            let list = model.deepseekProviders
            if list.isEmpty {
                Text("No DeepSeek provider in CC Switch. Add Pro / Flash there, then Refresh.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(list) { p in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(p.deepseekVariantLabel)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                if p.isCurrent {
                                    Text("active")
                                        .font(.body)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(p.shortModel)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .help(p.name)
                        }
                        Spacer(minLength: 4)
                        if p.isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                                .symbolRenderingMode(.hierarchical)
                        } else {
                            Button("Activate") {
                                model.activateProvider(p)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(model.isSwitching)
                            .help("Write \(p.name) into ~/.claude/settings.json (CC Switch)")
                        }
                    }
                }
            }

            Divider().padding(.vertical, 4)
        }
    }

    private func deepseekSection(_ snap: DeepSeekService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Ready", snap.isAvailable ? "yes" : "no")
            ForEach(Array(snap.balances.enumerated()), id: \.offset) { i, b in
                let label = i == 0 ? "Balance" : "Balance[\(i)]"
                row(label, b.displayTotal)
                row("  granted", b.granted)
                row("  topped-up", b.toppedUp)
            }
            Text(snap.source)
                .font(.body)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func usageBar(percent: Double) -> some View {
        let clamped = min(100, max(0, percent))
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor(clamped))
                        .frame(width: geo.size.width * CGFloat(clamped / 100.0))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.1f%% used", clamped))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func barColor(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .accentColor
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 2 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }
}
