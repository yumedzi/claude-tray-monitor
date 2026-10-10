import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                content(now: context.date)
                Divider()
                footer
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            statusBadge
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if store.snapshot.stale {
            badge("STALE", color: .orange)
        } else if store.snapshot.fetchedAt != nil {
            badge("FRESH", color: .green)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .clipShape(Capsule())
    }

    private var title: String {
        let snapshot = store.snapshot
        if snapshot.billingMode == .api { return "Claude (API billing)" }
        if snapshot.tokenMissing { return "Claude — not logged in" }
        if let plan = snapshot.planLabel { return "Claude \(plan)" }
        return "Claude"
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if store.snapshot.billingMode == .api {
            Text("API-key billing is active. Rate limits are not reported for API usage.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if store.snapshot.windows.isEmpty && store.snapshot.spend == nil {
            Text(store.snapshot.errorMessage ?? "No data yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            if let spend = store.snapshot.spend {
                spendSection(spend: spend, now: now)
            }
            ForEach(store.orderedFields, id: \.self) { field in
                if store.snapshot.spend == nil || store.snapshot.windows[field]?.percent ?? 0 > 0 {
                    row(field: field, now: now)
                }
            }
        }
    }

    private func spendSection(spend: SpendInfo, now: Date) -> some View {
        let percent = Pace.spendPercent(spend)
        let elapsed = Pace.spendElapsed(spend, now: now)
        let pace = AppSettings.showPaceMarkers
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Monthly spend").font(.callout)
                if pace {
                    paceIcon(delta: percent - elapsed * 100, help: Pace.spendHelp(spend, elapsed: elapsed))
                }
                Spacer()
                Text(UsageParser.formatDollars(spend.used))
                    .font(.callout.monospacedDigit())
            }
            bar(percent: percent, width: nil, marker: pace ? elapsed : nil, markerHelp: Pace.spendMarkerHelp(spend, elapsed: elapsed))
            HStack {
                Text("limit \(UsageParser.formatDollars(spend.limit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent.rounded()))% of limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func row(field: String, now: Date) -> some View {
        let window = store.snapshot.windows[field]
        let percent = window?.percent ?? 0
        let paced = AppSettings.showPaceMarkers && Pace.isWeekly(field)
        let elapsed = paced ? Pace.weeklyElapsed(resetsAt: window?.resetsAt, now: now) : nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(AppSettings.displayName(for: field)).font(.callout)
                    if let elapsed {
                        paceIcon(delta: percent - elapsed * 100, help: Pace.weeklyHelp(actual: percent, expected: elapsed * 100))
                    }
                }
                Text(window?.resetsAt.map { "resets in \(UsageParser.formatCountdown(resetsAt: $0, now: now))" } ?? "resets unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            bar(percent: percent, ticks: paced ? Pace.weeklyTicks(resetsAt: window?.resetsAt) : [])
            Text("\(Int(percent.rounded()))%")
                .font(.callout.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func bar(percent: Double, width: CGFloat? = 110, ticks: [Double] = [], marker: Double? = nil, markerHelp: String? = nil) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.trackColor))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: percent))
                    .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                ForEach(ticks, id: \.self) { fraction in
                    Rectangle()
                        .fill(tickColor(fraction: fraction, percent: percent, strong: false))
                        .frame(width: 1)
                        .offset(x: geo.size.width * CGFloat(fraction) - 0.5)
                }
                if let marker {
                    Rectangle()
                        .fill(tickColor(fraction: marker, percent: percent, strong: true))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * CGFloat(marker) - 0.75)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(maxWidth: width ?? .infinity, minHeight: 6, maxHeight: 6)
        // the marker itself is too thin to hover; the whole bar carries its tooltip
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(markerHelp ?? "")
        .padding(.vertical, -3)
    }

    /// Light on the coloured fill (already passed), dark-ish on the empty track — visible either way.
    private func tickColor(fraction: Double, percent: Double, strong: Bool) -> Color {
        let onFill = fraction * 100 < percent
        return onFill ? Color.white.opacity(strong ? 0.95 : 0.7) : Color.primary.opacity(strong ? 0.8 : 0.3)
    }

    private func paceIcon(delta: Double, help: String) -> some View {
        let status = Pace.status(delta: delta)
        let tint: Color = switch status {
        case .ahead: .orange
        case .onPace: .secondary
        case .under: .green
        }
        return Image(systemName: status.symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .help(help)
    }

    private func color(for percent: Double) -> Color {
        Color(nsColor: Theme.fillColor(for: percent, stale: store.snapshot.stale))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Updated \(formattedUpdated)")
                Spacer()
                if let source = footerSource {
                    Text(source).lineLimit(1).truncationMode(.middle)
                        .help(store.snapshot.tokenSource ?? source)
                }
            }
            Divider()
            HStack {
                Button { onSettings?() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                Button { onQuit?() } label: {
                    Label("Exit", systemImage: "power")
                }
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.secondary)
        .foregroundStyle(.secondary)
    }

    private var footerSource: String? {
        let snapshot = store.snapshot
        if let account = snapshot.accountLabel, !account.isEmpty { return account }
        if let source = snapshot.tokenSource, !source.isEmpty { return source }
        return nil
    }

    private var formattedUpdated: String {
        guard let date = store.snapshot.fetchedAt else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}