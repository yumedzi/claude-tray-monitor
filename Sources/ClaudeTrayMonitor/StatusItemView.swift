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
            let overlay = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            overlay.fill()
        }

        let showPercentages = AppSettings.showPercentages
        let labelHeight: CGFloat = showPercentages ? 9 : 0
        let labelFontSize: CGFloat = 7
        let barWidth: CGFloat = 7
        let gap: CGFloat = 6
        let totalBarsWidth = barWidth * 2 + gap
        let sideMargin = max(2, (bounds.width - totalBarsWidth) / 2)
        let barTop = labelHeight + 1
        let barBottom = bounds.height - 1.5
        let barHeight = barBottom - barTop

        func drawBar(at x: CGFloat, percent: Double?, label: String) {
            let trackRect = NSRect(x: x, y: barTop, width: barWidth, height: barHeight)
            let track = NSBezierPath(roundedRect: trackRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            Theme.trackColor.setFill()
            track.fill()

            if let percent {
                let fraction = CGFloat(max(0, min(1, percent / 100)))
                let fillHeight = fraction * barHeight
                if fillHeight > 0.5 {
                    let fillRect = NSRect(x: x, y: barBottom - fillHeight, width: barWidth, height: fillHeight)
                    let fill = NSBezierPath(roundedRect: fillRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                    Theme.fillColor(for: percent, stale: snapshot.stale).setFill()
                    fill.fill()
                }
            }

            if showPercentages {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .medium),
                    .foregroundColor: Theme.textColor,
                ]
                let attributed = NSAttributedString(string: label, attributes: attributes)
                let textSize = attributed.size()
                attributed.draw(at: NSPoint(x: x + (barWidth - textSize.width) / 2, y: 1))
            }
        }

        let percent1 = snapshot.windows[AppSettings.bar1Field]?.percent
        let percent2 = snapshot.windows[AppSettings.bar2Field]?.percent

        let unavailable = snapshot.billingMode == .api || snapshot.tokenMissing
        let label1 = unavailable || percent1 == nil ? "–" : formatPercent(percent1!)
        let label2 = unavailable || percent2 == nil ? "–" : formatPercent(percent2!)

        drawBar(at: sideMargin, percent: unavailable ? nil : percent1, label: label1)
        drawBar(at: sideMargin + barWidth + gap, percent: unavailable ? nil : percent2, label: label2)
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int(min(value, 99).rounded()))"
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