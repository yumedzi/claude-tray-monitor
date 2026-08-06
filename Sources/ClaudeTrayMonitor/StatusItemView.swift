import AppKit

@MainActor
final class StatusItemView: NSView {
    weak var store: UsageStore?
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 22)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let snapshot = store?.snapshot ?? UsageSnapshot.empty

        if pressed {
            let overlay = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            overlay.fill()
        }

        let field1 = AppSettings.bar1Field
        let field2 = AppSettings.bar2Field
        let unavailable = snapshot.billingMode == .api || snapshot.tokenMissing
        let p1 = unavailable ? nil : snapshot.windows[field1]?.percent
        let p2 = unavailable ? nil : snapshot.windows[field2]?.percent
        let n1 = p1 == nil ? "–" : formatNumber(p1!)
        let n2 = p2 == nil ? "–" : formatNumber(p2!)

        if AppSettings.barOrientation == "horizontal" {
            drawHorizontal(f1: field1, p1: p1, n1: n1, f2: field2, p2: p2, n2: n2, stale: snapshot.stale)
        } else {
            drawVertical(f1: field1, p1: p1, n1: n1, f2: field2, p2: p2, n2: n2, stale: snapshot.stale)
        }
    }

    // MARK: - Vertical mode: bars close together (||); numbers top corners, markers bottom corners.

    private func drawVertical(f1: String, p1: Double?, n1: String, f2: String, p2: Double?, n2: String, stale: Bool) {
        let show = AppSettings.showPercentages
        let barW: CGFloat = 4
        let pairGap: CGFloat = 2
        let total = barW * 2 + pairGap
        let x0 = (bounds.width - total) / 2

        let cxL: CGFloat = x0 / 2
        let cxR: CGFloat = bounds.width - x0 / 2
        let topY: CGFloat = 1
        let botY = bounds.height - 1 - TextH

        let pcts = [p1, p2]
        let values = [n1, n2]
        let markers = [marker(for: f1), marker(for: f2)]

        // corner labels sit outside the bars' x-range, so bars can span nearly full height
        drawVerticalBar(x: x0, y: 1, width: barW, height: bounds.height - 2, percent: pcts[0], stale: stale)
        drawVerticalBar(x: x0 + barW + pairGap, y: 1, width: barW, height: bounds.height - 2, percent: pcts[1], stale: stale)
        if show {
            if AppSettings.showLabels {
                drawText(values[0], centeredX: cxL, y: topY)
                drawText(values[1], centeredX: cxR, y: topY)
                drawText(markers[0], centeredX: cxL, y: botY)
                drawText(markers[1], centeredX: cxR, y: botY)
            } else {
                // no labels: center the values vertically
                let valueY = (bounds.height - TextH) / 2
                drawText(values[0], centeredX: cxL, y: valueY)
                drawText(values[1], centeredX: cxR, y: valueY)
            }
        }
    }

    // MARK: - Horizontal mode: 4 rows — labels top/bottom, two thin bars between, values at right edge.

    private func drawHorizontal(f1: String, p1: Double?, n1: String, f2: String, p2: Double?, n2: String, stale: Bool) {
        let show = AppSettings.showPercentages
        let leftX: CGFloat = 3
        let rightX = bounds.width - 3
        let barWidth = rightX - leftX

        // 4 separate rows: labels (top/bottom), two full-width bars (middle)
        let topY: CGFloat = 0
        let botY: CGFloat = 14
        let th: CGFloat = 2.5

        drawHorizontalBar(x: leftX, y: 8, width: barWidth, thickness: th, percent: p1, stale: stale)
        drawHorizontalBar(x: leftX, y: 11.5, width: barWidth, thickness: th, percent: p2, stale: stale)

        if show {
            let m1 = marker(for: f1)
            let m2 = marker(for: f2)
            if AppSettings.showLabels {
                drawTextRight(n1, rightX: rightX, y: topY)
                drawTextRight(n2, rightX: rightX, y: botY)
                drawText(m1, atX: leftX, y: topY)
                drawText(m2, atX: leftX, y: botY)
            } else {
                drawText(n1, centeredX: bounds.width / 2, y: topY)
                drawText(n2, centeredX: bounds.width / 2, y: botY)
            }
        }
    }

    // MARK: - Drawing primitives

    private func drawVerticalBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, percent: Double?, stale: Bool) {
        guard width > 0, height > 0 else { return }
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: width / 2, yRadius: width / 2)
        Theme.trackColor.setFill()
        track.fill()
        guard let percent else { return }
        let fillHeight = CGFloat(max(0, min(1, percent / 100))) * height
        if fillHeight > 0.7 {
            let fillRect = NSRect(x: x, y: y + height - fillHeight, width: width, height: fillHeight)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: width / 2, yRadius: width / 2)
            Theme.fillColor(for: percent, stale: stale).setFill()
            fill.fill()
        }
    }

    private func drawHorizontalBar(x: CGFloat, y: CGFloat, width: CGFloat, thickness: CGFloat, percent: Double?, stale: Bool) {
        guard width > 0, thickness > 0 else { return }
        let radius = thickness / 2
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: thickness), xRadius: radius, yRadius: radius)
        Theme.trackColor.setFill()
        track.fill()
        guard let percent else { return }
        let fillWidth = CGFloat(max(0, min(1, percent / 100))) * width
        if fillWidth > 0.7 {
            let fillRect = NSRect(x: x, y: y, width: fillWidth, height: thickness)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            Theme.fillColor(for: percent, stale: stale).setFill()
            fill.fill()
        }
    }

    private func drawText(_ string: String, centeredX: CGFloat, y: CGFloat) {
        let attr = NSAttributedString(string: string, attributes: textAttributes())
        let size = attr.size()
        attr.draw(at: NSPoint(x: centeredX - size.width / 2, y: y))
    }

    private func drawText(_ string: String, atX: CGFloat, y: CGFloat) {
        NSAttributedString(string: string, attributes: textAttributes()).draw(at: NSPoint(x: atX, y: y))
    }

    private func drawTextRight(_ string: String, rightX: CGFloat, y: CGFloat) {
        let attr = NSAttributedString(string: string, attributes: textAttributes())
        attr.draw(at: NSPoint(x: rightX - attr.size().width, y: y))
    }

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .medium),
            .foregroundColor: Theme.textColor(for: effectiveAppearance),
        ]
    }

    private var TextH: CGFloat {
        NSAttributedString(string: "0", attributes: textAttributes()).size().height
    }

    private func textWidth(_ string: String) -> CGFloat {
        NSAttributedString(string: string, attributes: textAttributes()).size().width
    }

    private func yCenter(forTextH textH: CGFloat) -> CGFloat {
        (bounds.height - textH) / 2
    }

    private func formatNumber(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }

    private func marker(for field: String) -> String {
        switch field {
        case "five_hour": return "s"
        case "seven_day": return "w"
        default: return String(field.replacingOccurrences(of: "_", with: " ").prefix(1)).uppercased()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { onClick?() }
    }

    override func rightMouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside { onRightClick?(event) }
    }
}