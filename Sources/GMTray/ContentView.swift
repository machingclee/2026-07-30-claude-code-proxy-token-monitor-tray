import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            providerSection
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
                sectionTitle("Grok", icon: GrokIcon.menuBar)
                if let snap = model.grok {
                    weeklySection(snap)
                    monthlySection(snap)
                    if let err = model.grokError {
                        Text(err).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                } else if let err = model.grokError {
                    errorInline(err)
                } else {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                sectionTitle("DeepSeek", icon: DeepSeekIcon.menuBar)
                if let snap = model.deepseek {
                    deepseekSection(snap)
                    if let err = model.deepseekError {
                        Text(err).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                } else if let err = model.deepseekError {
                    errorInline(err)
                } else {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.setPanelOpen(true) }
        .onDisappear { model.setPanelOpen(false) }
    }

    // MARK: - Header

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
            if model.isLoading || model.isSwitching {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Active provider (CC Switch)

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active Claude provider")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("→ settings.json")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("Data from ~/.cc-switch (same as CC Switch / ccs). Activate writes ~/.claude/settings.json.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.providersError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.providers.isEmpty {
                Text("No Claude providers in CC Switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.providers) { p in
                        providerRow(p)
                    }
                }
            }

            if let msg = model.switchMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(msg.contains("Activated") || msg.contains("Already") ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerRow(_ p: CCSwitchService.Provider) -> some View {
        HStack(alignment: .center, spacing: 8) {
            providerIcon(p.kind)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(p.name)
                        .font(.caption.weight(p.isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    if p.isCurrent {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text("\(p.model.isEmpty ? "—" : p.model) · \(p.shortBase)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if p.isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .imageScale(.small)
            } else {
                Button("Activate") {
                    model.activateProvider(p)
                }
                .controlSize(.small)
                .disabled(model.isSwitching)
                .help("Write this provider into ~/.claude/settings.json (same as ccs / CC Switch)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(p.isCurrent ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        )
    }

    // MARK: - Usage sections

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

    private func sectionTitle(_ title: String, icon: NSImage) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
            Text(title)
                .font(.subheadline.weight(.semibold))
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

    private func errorInline(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            Button("Retry") {
                Task { await model.refresh() }
            }
            .controlSize(.small)
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
