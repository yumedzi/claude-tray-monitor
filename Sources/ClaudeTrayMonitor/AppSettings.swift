import Foundation
import Combine

enum AppSettings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "pollIntervalMinutes": 5.0,
            "refreshOnClick": true,
            "themeMode": "system",
            "showPercentages": true,
            "textColor": "white",
            "warnThreshold": 80.0,
            "errorThreshold": 90.0,
            "bar1Field": "five_hour",
            "bar2Field": "seven_day",
            "launchAtLogin": false,
        ])
    }

    static var pollIntervalMinutes: Double {
        get { UserDefaults.standard.double(forKey: "pollIntervalMinutes") }
    }

    static var refreshOnClick: Bool {
        get { UserDefaults.standard.bool(forKey: "refreshOnClick") }
    }

    static var themeMode: String {
        get { UserDefaults.standard.string(forKey: "themeMode") ?? "system" }
    }

    static var showPercentages: Bool {
        get { UserDefaults.standard.bool(forKey: "showPercentages") }
    }

    static var textColor: String {
        get { UserDefaults.standard.string(forKey: "textColor") ?? "white" }
    }

    static var warnThreshold: Double {
        get { UserDefaults.standard.double(forKey: "warnThreshold") }
    }

    static var errorThreshold: Double {
        get { UserDefaults.standard.double(forKey: "errorThreshold") }
    }

    static var bar1Field: String {
        get { UserDefaults.standard.string(forKey: "bar1Field") ?? "five_hour" }
    }

    static var bar2Field: String {
        get { UserDefaults.standard.string(forKey: "bar2Field") ?? "seven_day" }
    }

    static let barFieldDisplayNames: [String: String] = [
        "five_hour": "Session (5h)",
        "seven_day": "Weekly (7d)",
        "seven_day_sonnet": "Weekly Sonnet",
        "seven_day_opus": "Weekly Opus",
        "seven_day_fable": "Weekly Fable",
    ]

    static func displayName(for field: String) -> String {
        if let name = barFieldDisplayNames[field] { return name }
        return field.replacingOccurrences(of: "_", with: " ").capitalized
    }
}