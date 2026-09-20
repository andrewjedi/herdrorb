// Original vector artwork for herdrorb, distributed under the project MIT license.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
        NSGradient(colors: [NSColor(srgbRed: 0.12, green: 0.10, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.025, green: 0.03, blue: 0.075, alpha: 1)])!.draw(in: background, angle: -70)
        let orb = NSBezierPath(ovalIn: NSRect(x: 200, y: 200, width: 624, height: 624))
        NSGradient(colors: [NSColor(srgbRed: 0.83, green: 0.72, blue: 1, alpha: 1), NSColor(srgbRed: 0.43, green: 0.24, blue: 0.78, alpha: 1), NSColor(srgbRed: 0.12, green: 0.10, blue: 0.27, alpha: 1)])!.draw(in: orb, relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))
        NSColor(srgbRed: 0.8, green: 0.72, blue: 1, alpha: 0.6).setStroke(); orb.lineWidth = 5; orb.stroke()
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: 512, byY: 512)
        var rotation = transform; rotation.rotate(byDegrees: -24)
        (rotation as NSAffineTransform).concat()
        let ring = NSBezierPath(ovalIn: NSRect(x: -377, y: -115, width: 754, height: 230))
        NSColor(srgbRed: 0.85, green: 0.80, blue: 1, alpha: 0.8).setStroke(); ring.lineWidth = 17; ring.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setFill()
        for (x, y, size) in [(770.0, 796.0, 9.0), (233.0, 735.0, 5.0), (791.0, 266.0, 6.0)] {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
