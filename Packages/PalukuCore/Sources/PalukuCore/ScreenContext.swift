import AppKit
import ScreenCaptureKit

/// Captures the window the user is looking at, with an optional pointing trail drawn on it.
public enum ScreenContext {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Converts AppKit (bottom-left origin) to CoreGraphics global (top-left origin) coordinates.
    public static func cgPoint(fromAppKit p: NSPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    /// JPEG of the frontmost app's window under the cursor (or its largest window). `trail` in CG global coords.
    public static func captureFrontWindow(pid: pid_t?, trail: [CGPoint] = [], maxWidth: CGFloat = 1400) async -> Data? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let mouse = cgPoint(fromAppKit: NSEvent.mouseLocation)
            let candidates = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
                    && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            let mine = candidates.filter { pid == nil || $0.owningApplication?.processID == pid }
            let window =
                mine.first(where: { $0.frame.contains(mouse) })
                ?? mine.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                ?? candidates.first(where: { $0.frame.contains(mouse) })
            guard let window else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(1, maxWidth / window.frame.width) * CGFloat(filter.pointPixelScale)
            config.width = Int(window.frame.width * min(scale, CGFloat(filter.pointPixelScale)))
            config.height = Int(window.frame.height * min(scale, CGFloat(filter.pointPixelScale)))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return jpeg(image, trail: trail, windowFrame: window.frame)
        } catch {
            return nil
        }
    }

    static func jpeg(_ image: CGImage, trail: [CGPoint], windowFrame: CGRect) -> Data? {
        let w = image.width, h = image.height
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pts = trail.filter { windowFrame.insetBy(dx: -20, dy: -20).contains($0) }
        if pts.count > 1 {
            let sx = CGFloat(w) / windowFrame.width, sy = CGFloat(h) / windowFrame.height
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(max(4, 5 * sx))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: pts.map { CGPoint(x: ($0.x - windowFrame.minX) * sx, y: CGFloat(h) - ($0.y - windowFrame.minY) * sy) })
            ctx.strokePath()
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
