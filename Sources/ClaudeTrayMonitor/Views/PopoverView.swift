import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

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
            if store.snapshot.stale {
                Text("STALE")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
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
        } else if store.snapshot.windows.isEmpty {
            Text(store.snapshot.errorMessage ?? "No data yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.orderedFields, id: \.self) { field in
                row(field: field, now: now)
            }
        }
    }

    private func row(field: String, now: Date) -> some View {
        let window = store.snapshot.windows[field]
        let percent = window?.percent ?? 0
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppSettings.displayName(for: field)).font(.callout)
                Text(window?.resetsAt.map { "resets in \(UsageParser.formatCountdown(resetsAt: $0, now: now))" } ?? "resets unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: percent, total: 100)
                .progressViewStyle(.linear)
                .frame(width: 110)
                .tint(color(for: percent))
            Text("\(Int(percent.rounded()))%")
                .font(.callout.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func color(for percent: Double) -> Color {
        if percent >= AppSettings.errorThreshold { return .red }
        if percent >= AppSettings.warnThreshold { return .orange }
        return .accentColor
    }

    private var footer: some View {
        HStack {
            Text("Updated \(formattedUpdated)")
            Spacer()
            if let source = store.snapshot.tokenSource, !source.isEmpty {
                Text(source).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var formattedUpdated: String {
        guard let date = store.snapshot.fetchedAt else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}