import Foundation

struct UsageWindow: Sendable {
    var percent: Double
    var resetsAt: Date?
}

struct SpendInfo: Sendable {
    var used: Double
    var limit: Double
    var percent: Double?
    var currency: String?
    var fromExtraUsage = false
    /// End of the billing period, if the API reports one; otherwise the calendar month is assumed.
    var resetsAt: Date?
}

enum BillingMode: Sendable {
    case subscription
    case api
    case unknown
}

struct UsageSnapshot: Sendable {
    var windows: [String: UsageWindow] = [:]
    var spend: SpendInfo?
    var planLabel: String?
    var accountLabel: String?
    /// `AccountSelection.id` of the account the data came from, used to relabel after a rename.
    var accountId: String?
    var billingMode: BillingMode = .unknown
    var fetchedAt: Date?
    var stale = false
    var tokenMissing = false
    var tokenSource: String?
    var errorMessage: String?

    static let empty = UsageSnapshot()
}

enum UsageParser {
    static let preferredFieldOrder = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]

    static func parseUsage(_ json: [String: Any]) -> [String: UsageWindow] {
        var windows = readWindows(json)
        if let limits = json["limits"] as? [[String: Any]] {
            windows = mergeScopedLimits(json: json, limits: limits, into: windows)
        }
        return windows
    }

    static func parseSpend(_ json: [String: Any]) -> SpendInfo? {
        if let spend = parseSpendObject(json["spend"] as? [String: Any]) {
            return spend
        }
        return parseExtraUsage(json["extra_usage"] as? [String: Any])
    }

    private static func parseSpendObject(_ spend: [String: Any]?) -> SpendInfo? {
        guard let spend else { return nil }
        guard let used = moneyAmount(spend["used"] as? [String: Any]),
              let limit = moneyAmount(spend["limit"] as? [String: Any])
        else { return nil }
        return SpendInfo(
            used: used,
            limit: limit,
            percent: number(spend["percent"]),
            currency: spend["currency"] as? String,
            resetsAt: periodEnd(spend)
        )
    }

    private static func parseExtraUsage(_ extra: [String: Any]?) -> SpendInfo? {
        guard let extra else { return nil }
        let usedCredits = number(extra["used_credits"])
        let monthlyLimit = number(extra["monthly_limit"])
        guard let usedCredits, let monthlyLimit, monthlyLimit > 0 else { return nil }
        let places = number(extra["decimal_places"]) ?? 0
        let divisor = pow(10, places)
        let used = usedCredits / divisor
        let limit = monthlyLimit / divisor
        return SpendInfo(
            used: used,
            limit: limit,
            percent: number(extra["utilization"]),
            currency: extra["currency"] as? String,
            fromExtraUsage: true,
            resetsAt: periodEnd(extra)
        )
    }

    private static func periodEnd(_ json: [String: Any]) -> Date? {
        for key in ["resets_at", "period_end", "current_period_end"] {
            if let date = parseDate(json[key] as? String) { return date }
        }
        return nil
    }

    private static func moneyAmount(_ amount: [String: Any]?) -> Double? {
        guard let amount, let minor = number(amount["amount_minor"]) else { return nil }
        let exponent = number(amount["exponent"]) ?? 0
        return minor / pow(10, exponent)
    }

    static func parseProfile(_ profile: [String: Any], tokenSubscriptionType: String?) -> String? {
        let orgType = (profile["organization"] as? [String: Any])?["organization_type"] as? String
        if let orgType, let plan = planLabelMap[orgType] { return plan }

        if let tokenSubscriptionType, let plan = planLabel(for: tokenSubscriptionType) {
            return plan
        }

        let account = profile["account"] as? [String: Any]
        if account?["has_claude_max"] as? Bool == true { return "Max" }
        if account?["has_claude_pro"] as? Bool == true { return "Pro" }
        return nil
    }

    static func planLabel(for subscriptionType: String) -> String? {
        let lower = subscriptionType.lowercased()
        if lower.contains("max") { return "Max" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") { return "Enterprise" }
        return subscriptionType
    }

    private static let planLabelMap = [
        "claude_pro": "Pro",
        "claude_max": "Max",
        "claude_team": "Team",
        "claude_enterprise": "Enterprise",
    ]

    static func formatCountdown(resetsAt: Date, now: Date) -> String {
        let totalMinutes = Int(resetsAt.timeIntervalSince(now) / 60)
        if totalMinutes <= 0 { return "Soon" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func formatDollars(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    static func formatDollarsCompact(_ value: Double) -> String {
        if value >= 1000 {
            let k = value / 1000
            return k == k.rounded() ? "$\(Int(k))k" : String(format: "$%.1fk", k)
        }
        if value >= 100 {
            return "$\(Int(value.rounded()))"
        }
        if value == value.rounded() {
            return "$\(Int(value))"
        }
        return String(format: "$%.1f", value)
    }

    private static func readWindows(_ json: [String: Any]) -> [String: UsageWindow] {
        var out: [String: UsageWindow] = [:]
        for (key, value) in json {
            guard let window = value as? [String: Any], let percent = number(window["utilization"]) else { continue }
            out[key] = UsageWindow(percent: percent, resetsAt: parseDate(window["resets_at"] as? String))
        }
        return out
    }

    private static func mergeScopedLimits(json: [String: Any], limits: [[String: Any]], into windows: [String: UsageWindow]) -> [String: UsageWindow] {
        var resetToField: [String: String] = [:]
        for (key, value) in json {
            guard let window = value as? [String: Any],
                  window["utilization"] != nil,
                  let resets = window["resets_at"] as? String,
                  resetToField[resets] == nil
            else { continue }
            resetToField[resets] = key
        }

        var groupPrefix: [String: String] = [:]
        for limit in limits {
            guard limit["scope"] == nil,
                  let group = limit["group"] as? String,
                  let resets = limit["resets_at"] as? String,
                  let prefix = resetToField[resets],
                  groupPrefix[group] == nil
            else { continue }
            groupPrefix[group] = prefix
        }

        var merged = windows
        for limit in limits {
            let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
            guard let displayName = model?["display_name"] as? String,
                  let group = limit["group"] as? String,
                  let prefix = groupPrefix[group],
                  let percent = number(limit["percent"])
            else { continue }
            let field = "\(prefix)_\(slug(displayName))"
            guard merged[field] == nil else { continue }
            merged[field] = UsageWindow(percent: percent, resetsAt: parseDate(limit["resets_at"] as? String))
        }
        return merged
    }

    private static func slug(_ displayName: String) -> String {
        let cleaned = displayName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: "_")
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
/// Pace markers: where usage "should" be if the limit were spread evenly over the period.
/// Weekly windows get day ticks (each = 1/7 of the limit); monthly spend gets a single pace marker.
enum Pace {
    static let onPaceTolerance = 3.0

    enum Status {
        case ahead, onPace, under

        /// SF Symbol shown next to the bar title in the popup.
        var symbol: String {
            switch self {
            case .ahead: return "hare.fill"
            case .onPace: return "checkmark.circle"
            case .under: return "tortoise.fill"
            }
        }
    }

    /// `delta` in percentage points of the limit (actual − expected).
    static func status(delta: Double) -> Status {
        if abs(delta) < onPaceTolerance { return .onPace }
        return delta > 0 ? .ahead : .under
    }

    /// A rolling usage window split into equal budget slices (days of a week, hours of a session).
    struct Window {
        let length: TimeInterval
        let slices: Int
        let sliceName: String   // "Day" / "Hour"
        let windowName: String  // "week" / "session"
        /// No slice ticks — just one "ideal by now" marker with its % (the 5h session is too short to plan in slices).
        var singleMarker = false

        static let weekly = Window(length: 7 * 86_400, slices: 7, sliceName: "Day", windowName: "week")
        static let session = Window(length: 5 * 3_600, slices: 5, sliceName: "Hour", windowName: "session", singleMarker: true)

        /// Fraction of the window elapsed (0…1), or nil if the reset time is unknown.
        func elapsed(resetsAt: Date?, now: Date) -> Double? {
            guard let resetsAt else { return nil }
            return Pace.clamp(1 - resetsAt.timeIntervalSince(now) / length)
        }

        /// Slice-boundary ticks as fractions of the bar, aligned to the actual reset time (not the clock).
        func ticks(resetsAt: Date?) -> [Double] {
            guard resetsAt != nil, !singleMarker else { return [] }
            return (1..<slices).map { Double($0) / Double(slices) }
        }

        /// 1-based slice of the window we are in now.
        func slice(elapsed: Double) -> Int {
            min(slices, max(1, Int((elapsed * Double(slices)).rounded(.down)) + 1))
        }

        /// The tick closing the current slice; nil in the last slice (that line is the bar's end).
        func currentTick(elapsed: Double) -> Double? {
            let n = slice(elapsed: elapsed)
            return n < slices ? Double(n) / Double(slices) : nil
        }

        /// Bar tooltip: which slice it is and its budget line.
        func barHelp(actual: Double, elapsed: Double) -> String {
            if singleMarker {
                return "Ideal by now: \(Pace.pct(elapsed * 100)) (\(windowName) elapsed)\n"
                    + "Now: \(Pace.pct(actual)) used (\(Pace.signedPct(actual - elapsed * 100)))"
            }
            let n = slice(elapsed: elapsed)
            return "\(sliceName) \(n)/\(slices) · end-of-\(sliceName.lowercased()) tick \(Pace.pct(Double(n) / Double(slices) * 100))\n"
                + "Now: \(Pace.pct(actual)) used, \(Pace.pct(elapsed * 100)) \(windowName) elapsed (\(Pace.signedPct(actual - elapsed * 100)))"
        }

        /// Icon tooltip: what the icon means plus actual vs ideal.
        func help(actual: Double, expected: Double) -> String {
            let delta = actual - expected
            let numbers = "\(Pace.pct(actual)) used vs \(Pace.pct(expected)) ideal by now (\(Pace.signedPct(delta)))."
            let per = "1/\(slices) per \(sliceName.lowercased())"
            switch Pace.status(delta: delta) {
            case .ahead: return "Ahead of pace — using faster than an even \(per); may hit the limit before reset.\n" + numbers
            case .onPace: return "On pace — usage matches an even spread over the \(windowName).\n" + numbers
            case .under: return "Under pace — using slower than an even spread; room to spare.\n" + numbers
            }
        }
    }

    /// Pace window for a usage field: weekly (`seven_day*`) or the 5-hour session.
    static func window(for field: String) -> Window? {
        if field.hasPrefix("seven_day") { return .weekly }
        if field == "five_hour" { return .session }
        return nil
    }

    /// Fraction of the billing period elapsed; falls back to the local calendar month.
    static func spendElapsed(_ spend: SpendInfo, now: Date) -> Double {
        let calendar = Calendar.current
        if let end = spend.resetsAt, let start = calendar.date(byAdding: .month, value: -1, to: end) {
            return clamp(now.timeIntervalSince(start) / end.timeIntervalSince(start))
        }
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return 0 }
        return clamp(now.timeIntervalSince(interval.start) / interval.duration)
    }

    static func spendPercent(_ spend: SpendInfo) -> Double {
        spend.percent ?? (spend.limit > 0 ? spend.used / spend.limit * 100 : 0)
    }

    /// Icon tooltip for monthly spend: what the icon means plus actual vs ideal.
    static func spendHelp(_ spend: SpendInfo, elapsed: Double) -> String {
        let delta = spend.used - spend.limit * elapsed
        let numbers = spendNumbers(spend, elapsed: elapsed)
        switch status(delta: spend.limit > 0 ? delta / spend.limit * 100 : 0) {
        case .ahead: return "Ahead of pace — spending faster than an even spread over the month.\n" + numbers
        case .onPace: return "On pace — spend matches an even spread over the month.\n" + numbers
        case .under: return "Under pace — spending slower than an even spread; budget to spare.\n" + numbers
        }
    }

    /// Pace-marker tooltip: the ideal value right now and the difference.
    static func spendMarkerHelp(_ spend: SpendInfo, elapsed: Double) -> String {
        "Ideal by now: \(UsageParser.formatDollars(spend.limit * elapsed)) (\(pct(elapsed * 100)) of \(UsageParser.formatDollars(spend.limit))).\n"
            + spendNumbers(spend, elapsed: elapsed)
    }

    private static func spendNumbers(_ spend: SpendInfo, elapsed: Double) -> String {
        let ideal = spend.limit * elapsed
        let delta = spend.used - ideal
        let diff = "\(UsageParser.formatDollars(abs(delta))) \(delta >= 0 ? "over" : "under")"
        return "Spent \(UsageParser.formatDollars(spend.used)) vs \(UsageParser.formatDollars(ideal)) ideal — \(diff)."
    }

    fileprivate static func pct(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    fileprivate static func signedPct(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)%" : rounded < 0 ? "−\(-rounded)%" : "±0%"
    }

    fileprivate static func clamp(_ value: Double) -> Double {
        max(0, min(1, value))
    }
}
