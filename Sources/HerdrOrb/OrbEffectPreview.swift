import AppKit
import SwiftUI

/// Deterministic rendering of the production effect, using fictional demo content.
@MainActor enum OrbEffectPreview {
    static func render(model: BubbleModel, directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let panelSize = NSSize(width: 900, height: 613)
        let content = NSHostingView(rootView: PanelView(model: model, placement: PopoverPlacement(), close: {}, resize: { _ in }, nativeWindow: true).defaultAppStorage(model.preferences))
        content.frame = NSRect(origin: .zero, size: panelSize)
        content.layoutSubtreeIfNeeded()
        guard let panelBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: panelBitmap)
        let panelImage = NSImage(size: panelSize); panelImage.addRepresentation(panelBitmap)
        model.preferences.set(false, forKey: "orbStatusDot")
        let orbView = NSHostingView(rootView: FloatingOrb(model: model).environment(\.orbSnapshotTime, 0).defaultAppStorage(model.preferences))
        orbView.frame = NSRect(x: 0, y: 0, width: 112, height: 112)
        orbView.layoutSubtreeIfNeeded()
        guard let orbBitmap = orbView.bitmapImageRepForCachingDisplay(in: orbView.bounds) else { return }
        orbView.cacheDisplay(in: orbView.bounds, to: orbBitmap)
        let orbImage = NSImage(size: orbView.bounds.size); orbImage.addRepresentation(orbBitmap)
        for right in [true, false] {
            for (label, progress) in [("closed", CGFloat(0)), ("opening", CGFloat(0.55)), ("open", CGFloat(1))] {
                let effect = OrbPanelEffectView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
                let orb = NSRect(x: right ? 28 : 1060, y: 310, width: 112, height: 112)
                effect.geometry = OrbPanelGeometry(orb: orb, panel: NSRect(x: right ? 226 : 74, y: 54, width: 900, height: 613))
                effect.snapshot = panelImage; effect.drawSnapshot = true; effect.progress = progress; effect.time = 1
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1440, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
                graphics.cgContext.scaleBy(x: 2, y: 2)
                NSColor(srgbRed: 0.07, green: 0.08, blue: 0.105, alpha: 1).setFill(); effect.bounds.fill()
                effect.draw(effect.bounds)
                orbImage.draw(in: orb)
                NSGraphicsContext.restoreGraphicsState()
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(right ? "right" : "left")-\(label).png"))
                }
            }
        }
    }
}


extension OrbEffectPreview {
    static func benchmark(model: BubbleModel) async {
        let panel = FloatingPanel(contentRect: NSRect(x: 250, y: 100, width: 900, height: 613), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: PanelView(model: model, placement: PopoverPlacement(), close: {}, resize: { _ in }, nativeWindow: true).defaultAppStorage(model.preferences))
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let effect = OrbPanelEffect()
        let orb = CGRect(x: 40, y: 320, width: 112, height: 112)
        effect.prepareSnapshot(panel: panel)
        print("prewarm_capture_ms=\(String(format: "%.2f", effect.lastCaptureMilliseconds))")
        let startCPU = Double(clock()) / Double(CLOCKS_PER_SEC)
        let startWall = Date()
        for iteration in 0..<8 {
            let opening = iteration % 2 == 0
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                effect.animate(open: opening, panel: panel, orb: orb, connected: true) {
                    if opening { panel.orderFrontRegardless(); effect.showConnection(orb: orb, panel: panel, connected: true) }
                    continuation.resume()
                }
                print("effect \(opening ? "open" : "close") capture_ms=\(String(format: "%.2f", effect.lastCaptureMilliseconds)) prepare_ms=\(String(format: "%.2f", effect.lastPreparationMilliseconds))")
            }
        }
        let cpu = Double(clock()) / Double(CLOCKS_PER_SEC) - startCPU
        print("effect benchmark wall_s=\(String(format: "%.2f", Date().timeIntervalSince(startWall))) app_cpu_s=\(String(format: "%.3f", cpu))")
        effect.hide(); panel.orderOut(nil)
    }
}
