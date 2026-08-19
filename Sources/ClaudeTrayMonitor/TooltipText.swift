import Foundation

enum TooltipText {
    static func make(_ snapshot: UsageSnapshot) -> String {
        if snapshot.billingMode == .api {
            return "Claude Tray Monitor — API-key billing active"
        }
        if snapshot.tokenMissing {
            return "Claude Tray Monitor — no login found"
        }
        if snapshot.windows.isEmpty && snapshot.spend == nil {
            return snapshot.errorMessage ?? "Claude Tray Monitor"
        }
        var text = snapshot.planLabel.map { "Claude \($0)" } ?? "Claude"
        if let spend = snapshot.spend {
            let percent = spend.percent ?? (spend.limit > 0 ? spend.used / spend.limit * 100 : 0)
            text += "\nMonthly spend: \(UsageParser.formatDollars(spend.used)) / \(UsageParser.formatDollars(spend.limit)) (\(Int(percent.rounded()))%)"
        }
        for field in ["five_hour", "seven_day"] {
            guard let window = snapshot.windows[field], snapshot.spend == nil || window.percent > 0 else { continue }
            let name = AppSettings.displayName(for: field)
            let countdown = window.resetsAt.map { " · resets \(UsageParser.formatCountdown(resetsAt: $0, now: Date()))" } ?? ""
            text += "\n\(name): \(Int(window.percent.rounded()))%\(countdown)"
        }
        if snapshot.stale { text += "\n(stale data)" }
        if let source = snapshot.tokenSource { text += "\nvia \(source)" }
        return text
    }
}