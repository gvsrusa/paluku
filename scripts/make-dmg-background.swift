// Renders the DMG window background (1x + 2x): "Drag Paluku to Applications" with an arrow between the icon slots
// used by scripts/dmg-settings.py. With --unsigned the window is taller and points at the "If Paluku won't open" link,
// which opens a help page that jumps to System Settings › Privacy & Security.
// Usage: swift scripts/make-dmg-background.swift <out-dir> [--unsigned]   → <out-dir>/background.png, background@2x.png
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.dropFirst().first { !$0.hasPrefix("--") } ?? ".")
let unsigned = args.contains("--unsigned")
let canvas = NSSize(width: 640, height: unsigned ? 480 : 400)
// Icon centres in Finder's top-left coordinates (must match dmg-settings.py).
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 190

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas).fill()

    /// Centred line whose top sits `top` points below the window's top edge.
    func text(_ s: String, top: CGFloat, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 20, y: canvas.height - top - fontSize * 1.4, width: 600, height: fontSize * 1.4))
    }
    text("Drag Paluku to Applications", top: 34, fontSize: 22, weight: .semibold, color: NSColor(calibratedWhite: 0.12, alpha: 1))

    let y = canvas.height - iconY
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: appX + 90, y: y))
    arrow.line(to: NSPoint(x: appsX - 90, y: y))
    arrow.move(to: NSPoint(x: appsX - 108, y: y + 16))
    arrow.line(to: NSPoint(x: appsX - 90, y: y))
    arrow.line(to: NSPoint(x: appsX - 108, y: y - 16))
    NSColor(calibratedRed: 0.04, green: 0.4, blue: 0.85, alpha: 1).setStroke()
    arrow.stroke()

    if unsigned {
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSRect(x: 40, y: canvas.height - 292, width: 560, height: 1).fill()
        text("macOS says “Paluku” Not Opened? Double-click the link below:", top: 304, fontSize: 13, weight: .medium,
            color: NSColor(calibratedWhite: 0.3, alpha: 1))
        text("it opens System Settings › Privacy & Security, where you click Open Anyway.", top: 324, fontSize: 12, weight: .regular,
            color: NSColor(calibratedWhite: 0.45, alpha: 1))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: outDir.appending(path: "background.png"))
try render(scale: 2).write(to: outDir.appending(path: "background@2x.png"))
print("✓ \(outDir.path)/background.png (+@2x)\(unsigned ? " [unsigned]" : "")")
