import AppKit

let size = NSSize(width: 1024, height: 1024)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no rep") }
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 230, yRadius: 230)
NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.22, alpha: 1).setFill()
background.fill()

func drawBar(x: CGFloat, fraction: CGFloat, color: NSColor) {
    let width: CGFloat = 190
    let height: CGFloat = 560
    let y: CGFloat = 190
    let radius: CGFloat = 60

    let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
    NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
    track.fill()

    let fillHeight = max(height * min(1, fraction), 26)
    let fill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: fillHeight), xRadius: radius, yRadius: radius)
    color.setFill()
    fill.fill()
}

let barWidth: CGFloat = 190
let gap: CGFloat = 84
let x1 = (1024 - barWidth * 2 - gap) / 2
drawBar(x: x1, fraction: 0.62, color: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.47, alpha: 1))
drawBar(x: x1 + barWidth + gap, fraction: 0.34, color: NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.20, alpha: 1))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")