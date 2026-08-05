import AppKit

enum Theme {
    static func fillColor(for percent: Double, stale: Bool) -> NSColor {
        if stale { return NSColor.labelColor.withAlphaComponent(0.4) }
        if percent >= AppSettings.errorThreshold { return .systemRed }
        if percent >= AppSettings.warnThreshold { return .systemOrange }
        return .labelColor
    }

    static var trackColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.18)
    }

    static func textColor(for appearance: NSAppearance?) -> NSColor {
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .white : .black
    }

    static func appearance(for mode: String) -> NSAppearance? {
        switch mode {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }
}