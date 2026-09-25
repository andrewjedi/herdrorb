import AppKit
import QuartzCore

/// The orb always sits above both the panel and its animation companion window.
enum OrbWindowLevels {
    static let panel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let orb = NSWindow.Level(rawValue: panel.rawValue + 1)
}

/// Geometry is in desktop points; mirroring preserves the attachment on either side.
struct OrbPanelGeometry {
    var orb: CGRect
    var panel: CGRect
    // Includes the glass rim at maximum hover expansion; the halo remains translucent.
    var orbOcclusionRect: CGRect {
        CGRect(x: orb.midX - 48, y: orb.midY - 48, width: 96, height: 96)
    }
    func effectMask(in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: orbOcclusionRect)
        return path
    }
    var panelOnRight: Bool { panel.midX > orb.midX }
    var canConnect: Bool {
        panelOnRight ? panel.minX > orb.midX + 30 : panel.maxX < orb.midX - 30
    }
    func frame(at progress: CGFloat, spring: Bool = false) -> CGRect {
        let p = min(spring ? 1.035 : 1, max(0, progress))
        let seed = CGRect(x: orb.midX - 12, y: orb.midY - 18, width: 24, height: 36)
        return CGRect(x: seed.minX + (panel.minX - seed.minX) * p,
                      y: seed.minY + (panel.minY - seed.minY) * p,
                      width: seed.width + (panel.width - seed.width) * p,
                      height: seed.height + (panel.height - seed.height) * p)
    }
}

/// Analytic spring carries velocity across reversals, with one restrained opening overshoot.
struct PanelSpring {
    var position: CGFloat
    var velocity: CGFloat
    var target: CGFloat
    func sample(_ time: Double) -> (position: CGFloat, velocity: CGFloat) {
        let t = max(0, time)
        let x = Double(position - target), v = Double(velocity)
        let omega = target == 1 ? 27.0 : 34.0
        if target == 0 {
            let b = v + omega * x, decay = exp(-omega * t)
            return (target + CGFloat((x + b * t) * decay), CGFloat((b - omega * (x + b * t)) * decay))
        }
        let decayRate = omega * 0.79, frequency = omega * sqrt(1 - 0.79 * 0.79)
        let b = (v + decayRate * x) / frequency
        let wave = x * cos(frequency * t) + b * sin(frequency * t)
        let derivative = -x * frequency * sin(frequency * t) + b * frequency * cos(frequency * t)
        let decay = exp(-decayRate * t)
        return (target + CGFloat(decay * wave), CGFloat(decay * (derivative - decayRate * wave)))
    }
}

/// Core Animation composites a single snapshot and vector paths. No per-frame AppKit drawing.
@MainActor final class OrbPanelEffect {
    private let window: NSWindow
    private let art = OrbPanelEffectView()
    private var completionWork: DispatchWorkItem?
    private var generation = 0
    private var startTime: CFTimeInterval = 0
    private var spring = PanelSpring(position: 0, velocity: 0, target: 0)
    private var transitioning = false
    private(set) var lastCaptureMilliseconds = 0.0
    private(set) var lastPreparationMilliseconds = 0.0
    private var accessibilityObserver: NSObjectProtocol?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = OrbWindowLevels.panel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = art
        art.wantsLayer = true
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.art.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if !self.transitioning { self.art.startFlow() }
            }
        }
    }
    /// Translate the existing surfaces as a unit. Local paths and in-flight animations
    /// remain valid, including when the live panel is hidden during its opening.
    func move(orb: NSWindow, panel: NSWindow, to origin: NSPoint, connected: Bool) {
        let dx = origin.x - orb.frame.minX, dy = origin.y - orb.frame.minY
        NSDisableScreenUpdates()
        defer { NSEnableScreenUpdates() }
        orb.setFrameOrigin(origin)
        if connected && (window.isVisible || panel.isVisible) {
            panel.setFrameOrigin(panel.frame.offsetBy(dx: dx, dy: dy).origin)
            window.setFrameOrigin(window.frame.offsetBy(dx: dx, dy: dy).origin)
        }
    }

    func update(orb: CGRect, panel: NSWindow, connected: Bool) {
        let desktop = orb.union(panel.frame).insetBy(dx: -48, dy: -48)
        window.setFrame(desktop, display: false)
        art.frame = CGRect(origin: .zero, size: desktop.size)
        art.geometry = OrbPanelGeometry(orb: orb.offsetBy(dx: -desktop.minX, dy: -desktop.minY), panel: panel.frame.offsetBy(dx: -desktop.minX, dy: -desktop.minY))
        art.connected = connected && art.geometry.canConnect
        art.updateOrbMask()
        art.needsDisplay = true
        if !transitioning && art.progress == 1 { art.startFlow() }
    }
    func prepareSnapshot(panel: NSWindow) {
        guard !transitioning, let view = panel.contentView else { return }
        let start = CACurrentMediaTime()
        view.layoutSubtreeIfNeeded()
        // Reuse this one-point-resolution capture on the next opening; refresh it on closing.
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(bitmap)
            art.snapshot = image
        }
        lastCaptureMilliseconds = (CACurrentMediaTime() - start) * 1000
    }
    func animate(open: Bool, panel: NSWindow, orb: CGRect, connected: Bool, completion: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        let current = transitioning ? spring.sample(now - startTime) : (position: art.progress, velocity: CGFloat(0))
        completionWork?.cancel(); generation += 1
        update(orb: orb, panel: panel, connected: connected)
        lastCaptureMilliseconds = 0
        if !transitioning && (!open || art.snapshot == nil || art.snapshot?.size != panel.contentView?.bounds.size) {
            prepareSnapshot(panel: panel)
        }
        spring = PanelSpring(position: current.position, velocity: current.velocity, target: open ? 1 : 0)
        startTime = CACurrentMediaTime()
        art.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = art.reducedMotion ? 0.12 : (open ? 0.42 : 0.30)
        let count = max(2, Int(duration * 120))
        let samples: [CGFloat] = (0...count).map { index in
            if index == count { return spring.target }
            let fraction = Double(index) / Double(count)
            return art.reducedMotion ? current.position + (spring.target - current.position) * CGFloat(fraction) : spring.sample(fraction * duration).position
        }
        transitioning = true; art.stopFlow()
        art.installTransition(samples: samples, duration: duration)
        panel.orderOut(nil)
        window.orderFrontRegardless()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.transitioning = false
            self.art.progress = open ? 1 : 0
            // Show the live panel before removing the snapshot, avoiding a one-frame blank flash.
            if open { completion() } else { self.hide(); completion() }
            self.art.clearTransition()
            self.art.needsDisplay = true
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        lastPreparationMilliseconds = (CACurrentMediaTime() - now) * 1000
    }
    func showConnection(orb: CGRect, panel: NSWindow, connected: Bool) {
        update(orb: orb, panel: panel, connected: connected)
        guard !transitioning else { return }
        art.progress = 1; art.drawSnapshot = false
        window.order(.below, relativeTo: panel.windowNumber)
        art.startFlow()
    }
    func hide() {
        completionWork?.cancel(); completionWork = nil; generation += 1
        transitioning = false; art.progress = 0; art.stopFlow(); art.clearTransition()
        window.orderOut(nil)
    }
}

final class OrbPanelEffectView: NSView {
    var geometry = OrbPanelGeometry(orb: .zero, panel: .zero)
    var progress: CGFloat = 0
    var connected = true
    var drawSnapshot = false
    var reducedMotion = false
    var snapshot: NSImage?
    var time: Double = 0
    private var idleLayer: CALayer?
    private var transitionLayer: CALayer?
    override var isOpaque: Bool { false }

    func updateOrbMask() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if connected {
            let mask = CAShapeLayer(); mask.path = geometry.effectMask(in: bounds); mask.fillRule = .evenOdd
            layer?.mask = mask
        } else { layer?.mask = nil }
        CATransaction.commit()
    }
    func stopFlow() { idleLayer?.removeFromSuperlayer(); idleLayer = nil }
    func startFlow() {
        stopFlow()
        guard progress == 1 else { needsDisplay = true; return }
        wantsLayer = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scene = EtherealMembrane.make(geometry: geometry, frames: [geometry.panel], connected: connected, bounds: bounds, flowing: !reducedMotion)
        idleLayer = scene; layer?.addSublayer(scene)
        needsDisplay = true
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard transitionLayer == nil, idleLayer == nil, progress > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        if connected { context.addPath(geometry.effectMask(in: bounds)); context.clip(using: .evenOdd) }
        let body = reducedMotion || !connected ? geometry.panel : geometry.frame(at: progress)
        let scene = EtherealMembrane.make(geometry: geometry, frames: [body], connected: connected, bounds: bounds)
        scene.render(in: context)
        if drawSnapshot {
            NSBezierPath(roundedRect: body, xRadius: 20, yRadius: 20).addClip()
            snapshot?.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    func clearTransition() { transitionLayer?.removeFromSuperlayer(); transitionLayer = nil }
    func installTransition(samples: [CGFloat], duration: Double) {
        clearTransition()
        guard let layer, !samples.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frames = samples.map { reducedMotion || !connected ? geometry.panel : geometry.frame(at: $0, spring: true) }
        let root = EtherealMembrane.make(geometry: geometry, frames: frames, connected: connected, bounds: bounds, duration: duration)
        transitionLayer = root
        EtherealMembrane.animate(root, key: "opacity", values: samples.map { NSNumber(value: Double(min(1,max(0,$0 * (reducedMotion || !connected ? 1 : 4))))) }, duration: duration)
        let content = CALayer(); content.anchorPoint = .zero
        content.contents = snapshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        content.contentsGravity = .resize; content.masksToBounds = true; content.cornerRadius = 20
        content.backgroundColor = NSColor(srgbRed: 0.065, green: 0.07, blue: 0.086, alpha: 1).cgColor
        EtherealMembrane.animate(content, key: "position", values: frames.map { NSValue(point: $0.origin) }, duration: duration)
        EtherealMembrane.animate(content, key: "bounds", values: frames.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) }, duration: duration)
        root.addSublayer(content)
        layer.addSublayer(root); needsDisplay = true; displayIfNeeded()
        CATransaction.commit()
    }
}
