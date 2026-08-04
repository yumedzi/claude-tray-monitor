import Foundation

enum TooltipText {
    static func make(_ snapshot: UsageSnapshot) -> String {
        if snapshot.billingMode == .api {
            return "Claude Tray Monitor — API-key billing active"
        }
        if snapshot.tokenMissing {
            return "Claude Tray Monitor — no login found"
        }
        if snapshot.windows.isEmpty {
            return snapshot.errorMessage ?? "Claude Tray Monitor"
        }
        var text = snapshot.planLabel.map { "Claude \($0)" } ?? "Claude"
        for field in ["five_hour", "seven_day"] {
            guard let window = snapshot.windows[field] else { continue }
            let name = AppSettings.displayName(for: field)
            let countdown = window.resetsAt.map { " · resets \(UsageParser.formatCountdown(resetsAt: $0, now: Date()))" } ?? ""
            text += "\n\(name): \(Int(window.percent.rounded()))%\(countdown)"
        }
        if snapshot.stale { text += "\n(stale data)" }
        if let source = snapshot.tokenSource { text += "\nvia \(source)" }
        return text
    }
}