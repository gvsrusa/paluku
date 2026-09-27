// Renders the Paluku app icon (waveform on a dark squircle) into App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with ~185 corner radius
    let inset = s * 100 / 1024, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1))!.draw(in: path, angle: -90)
    let heights: [CGFloat] = [0.22, 0.42, 0.66, 0.9, 0.58, 0.34, 0.2]
    let barW = body.width * 0.07, gap = body.width * 0.045
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    for (i, h) in heights.enumerated() {
        let bh = body.height * 0.62 * h
        let r = NSRect(x: x, y: body.midY - bh / 2, width: barW, height: bh)
        (i == 3 ? NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.33, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(pt * scale).write(to: out.appending(path: name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "Contents.json"))
try! Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"))
print("icon written")
