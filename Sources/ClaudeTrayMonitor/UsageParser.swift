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
            currency: spend["currency"] as? String
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
            fromExtraUsage: true
        )
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