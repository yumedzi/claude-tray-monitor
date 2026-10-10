import Foundation
import Combine

enum AppSettings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "autoRefresh": true,
            "pollIntervalMinutes": 5.0,
            "refreshOnClick": true,
            "themeMode": "system",
            "showPercentages": true,
            "showLabels": true,
            "barOrientation": "vertical",
            "warnThreshold": 80.0,
            "errorThreshold": 90.0,
            "bar1Field": "five_hour",
            "bar2Field": "seven_day",
            "showMonthlySpend": true,
            "showPaceMarkers": true,
            "launchAtLogin": false,
            "selectedAccountId": AccountSelection.autoId,
            // AppKit tooltip delay in ms (system default ~1.5s) — pace tooltips should show almost at once
            "NSInitialToolTipDelay": 150,
        ])
        migrateLegacyDataDir()
    }

    /// 0.7.x stored a single custom desktop folder; turn it into a manual profile pinned as the account.
    private static func migrateLegacyDataDir() {
        let legacy = desktopDataDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return }
        let dir = (legacy as NSString).expandingTildeInPath
        if !manualProfileDirs.contains(dir) {
            manualProfileDirs.append(dir)
        }
        selectedAccountId = AccountSelection.pinned(profileDir: dir, organizationId: nil).id
        desktopDataDir = ""
    }

    /// Off = no timer; data refreshes only on launch, tray click (if enabled) or right-click ▸ Check Now.
    static var autoRefresh: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRefresh") }
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

    static var showLabels: Bool {
        get { UserDefaults.standard.bool(forKey: "showLabels") }
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

    static var barOrientation: String {
        get { UserDefaults.standard.string(forKey: "barOrientation") ?? "vertical" }
    }

    static var showMonthlySpend: Bool {
        get { UserDefaults.standard.bool(forKey: "showMonthlySpend") }
    }

    /// Popup-only ideal-usage ticks: day ticks on weekly bars, a single pace marker on monthly spend.
    static var showPaceMarkers: Bool {
        get { UserDefaults.standard.bool(forKey: "showPaceMarkers") }
    }

    static var desktopDataDir: String {
        get { UserDefaults.standard.string(forKey: "desktopDataDir") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "desktopDataDir") }
    }

    static var selectedAccountId: String {
        get { UserDefaults.standard.string(forKey: "selectedAccountId") ?? AccountSelection.autoId }
        set { UserDefaults.standard.set(newValue, forKey: "selectedAccountId") }
    }

    static var manualProfileDirs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "manualProfileDirs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "manualProfileDirs") }
    }

    /// Account ids (`AccountSelection.id`) hidden from the tray menu and the main Settings list.
    static var hiddenAccountIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "hiddenAccountIds") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "hiddenAccountIds") }
    }

    /// User-chosen display names keyed by account id; replaces the org name.
    static var accountNames: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "accountNames") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "accountNames") }
    }

    static let barFieldDisplayNames: [String: String] = [
        "five_hour": "Session (5h)",
        "seven_day": "Weekly (7d)",
        "seven_day_sonnet": "Weekly Sonnet",
        "seven_day_opus": "Weekly Opus",
        "seven_day_fable": "Weekly Fable",
        "monthly_spend": "Monthly spend ($)",
    ]

    static func displayName(for field: String) -> String {
        if let name = barFieldDisplayNames[field] { return name }
        return field.replacingOccurrences(of: "_", with: " ").capitalized
    }
}