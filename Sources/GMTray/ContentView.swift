import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: UsageViewModel
    /// Sections start collapsed; click a row to expand (multiple allowed).
    @State private var expandedIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if model.grok == nil && model.deepseek == nil
                && model.grokError == nil && model.deepseekError == nil
                && model.isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
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
                    if let snap = model.grok {
                        weeklySection(snap)
                        monthlySection(snap)
                    } else if model.grokError == nil {
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
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
                    if let snap = model.deepseek {
                        deepseekSection(snap)
                    } else if model.deepseekError == nil {
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let msg = model.switchMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(
                        msg.contains("Activated") || msg.contains("Already")
                            ? Color.secondary : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = model.providersError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            settingsRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.setPanelOpen(true) }
        .onDisappear { model.setPanelOpen(false) }
    }

    // MARK: - Header / settings / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage Monitor")
                    .font(.headline)
                Text("CC Switch companion · no separate key store")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading || model.isSwitching || model.isLaunchingProxy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var settingsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launch at login")
                        .font(.caption.weight(.medium))
                    Text("Start GM Tray when you log in to macOS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Launch GM Tray when you log in to macOS")
            }

            if let msg = model.loginItemMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let t = model.lastRefresh {
                Text("Updated \(timeAgo(t))")
                    .font(.caption2)
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)

                    providerIcon(icon)
                        .frame(width: 14, height: 14)

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if provider?.isCurrent == true {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 4)

                    if !expanded {
                        Text(summary)
                            .font(.caption.monospacedDigit())
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
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .padding(.leading, 4)
                }

                activateControl(for: provider, kind: icon)
                    .padding(.top, 4)
                    .padding(.leading, 4)
            } else if let error {
                Text(error)
                    .font(.caption2)
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
            if let provider {
                if provider.isCurrent {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .imageScale(.small)
                        Text("Active in ~/.claude/settings.json")
                            .font(.caption2)
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
                    .controlSize(.small)
                    .disabled(model.isSwitching)
                    .help("Write \(provider.name) into ~/.claude/settings.json (CC Switch)")
                }
            } else {
                Text("No matching CC Switch provider")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Grok-only: Launch when :18765 is free, Stop when listening.
            if kind == .grok {
                if model.isProxyRunning {
                    Button {
                        model.stopClaudeCodeProxy()
                    } label: {
                        Text("Stop claude-code-proxy")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                    .controlSize(.small)
                    .disabled(model.isLaunchingProxy || model.isSwitching)
                    .help("Run: claude-code-proxy serve --no-monitor (brew install claude-code-proxy)")
                }
            }
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
                .font(.caption.weight(.medium))
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
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func monthlySection(_ snap: UsageService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monthly")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if let used = snap.monthlyUsed, let limit = snap.monthlyLimit {
                let pct = snap.monthlyPercent ?? 0
                Text(String(format: "%.0f / %.0f", used, limit))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                usageBar(percent: pct)
            } else {
                Text("No monthly data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                .font(.caption2)
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
                .font(.caption.monospacedDigit())
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
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
