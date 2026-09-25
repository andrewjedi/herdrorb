import AppKit
import QuartzCore

/// Shaded sheets rather than line strands. Masks deform on the compositor;
/// no timer, per-frame rasterization, or external texture is needed.
enum EtherealMembrane {
    static let violet = NSColor(srgbRed: 0.57, green: 0.30, blue: 1, alpha: 1)
    static let pearl = NSColor(srgbRed: 0.94, green: 0.83, blue: 1, alpha: 1)

    static func point(geometry: OrbPanelGeometry, frame: CGRect, t: CGFloat, fraction: CGFloat, phase: CGFloat = 0) -> CGPoint {
        let direction: CGFloat = geometry.panelOnRight ? 1 : -1
        let startX = geometry.orb.midX + direction * 20
        let edge = geometry.panelOnRight ? frame.minX + 3 : frame.maxX - 3
        let reach = edge - startX, u = 1 - t
        let x = u*u*u*startX + 3*u*u*t*(startX+reach*0.65) + 3*u*t*t*(edge-reach*0.29) + t*t*t*edge
        let ease = t*t*(3-2*t)
        let bottom = (geometry.orb.midY - 34)*(1-ease) + (frame.minY+12)*ease
        let top = (geometry.orb.midY + 34)*(1-ease) + (frame.maxY-12)*ease
        let flutter = sin(.pi*t) * sin(t*5.3 + fraction*9 + phase) * 0.023 * sin(.pi*fraction)
        return CGPoint(x: x, y: bottom + (top-bottom)*(fraction+flutter))
    }
    static func sheet(geometry: OrbPanelGeometry, frame: CGRect, center: CGFloat, width: CGFloat, phase: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        for index in 0...32 {
            let t = CGFloat(index)/32
            let spread = width * (0.45 + 0.55*sin(.pi*t))
            let point = point(geometry: geometry, frame: frame, t: t, fraction: min(1,center+spread/2), phase: phase)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for index in stride(from: 32, through: 0, by: -1) {
            let t = CGFloat(index)/32
            let spread = width * (0.45 + 0.55*sin(.pi*t))
            path.addLine(to: point(geometry: geometry, frame: frame, t: t, fraction: max(0,center-spread/2), phase: phase))
        }
        path.closeSubpath(); return path
    }
    static func silhouette(geometry: OrbPanelGeometry, frame: CGRect) -> CGPath {
        let p = CGMutablePath()
        for i in 0...32 {
            let q = point(geometry: geometry, frame: frame, t: CGFloat(i)/32, fraction: 1)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        for i in stride(from: 32, through: 0, by: -1) {
            p.addLine(to: point(geometry: geometry, frame: frame, t: CGFloat(i)/32, fraction: 0))
        }
        p.closeSubpath(); return p
    }
    static func animate(_ layer: CALayer, key: String, values: [Any], duration: Double?) {
        layer.setValue(values.last, forKeyPath: key)
        guard let duration, values.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values; animation.duration = duration; animation.calculationMode = .linear
        layer.add(animation, forKey: key)
    }

    static func make(geometry: OrbPanelGeometry, frames: [CGRect], connected: Bool, bounds: CGRect, duration: Double? = nil, flowing: Bool = false) -> CALayer {
        let root = CALayer(); root.frame = bounds
        guard let final = frames.last else { return root }
        if connected {
            let outlines = frames.map { silhouette(geometry: geometry, frame: $0) }
            let neckBounds = outlines.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }.insetBy(dx: -14, dy: -14)
            var offset = CGAffineTransform(translationX: -neckBounds.minX, y: -neckBounds.minY)
            func gradient(paths: [CGPath], colors: [NSColor], locations: [NSNumber], horizontal: Bool) -> (CAGradientLayer, CAShapeLayer) {
                let surface = CAGradientLayer(); surface.frame = neckBounds
                surface.colors = colors.map(\.cgColor); surface.locations = locations
                surface.startPoint = horizontal ? CGPoint(x: 0, y: 0.2) : CGPoint(x: 0.3, y: 0)
                surface.endPoint = horizontal ? CGPoint(x: 1, y: 0.8) : CGPoint(x: 0.7, y: 1)
                let mask = CAShapeLayer(); mask.fillColor = NSColor.white.cgColor
                animate(mask, key: "path", values: paths.map { $0.copy(using: &offset)! }, duration: duration)
                surface.mask = mask; root.addSublayer(surface)
                return (surface, mask)
            }
            _ = gradient(paths: outlines,
                         colors: [violet.withAlphaComponent(0.47), NSColor(srgbRed: 0.075, green: 0.055, blue: 0.16, alpha: 0.72), violet.withAlphaComponent(0.39)],
                         locations: [0,0.49,1], horizontal: false)
            // Uneven broad folds have a dark trough, violet body and thin pearly crest.
            let folds: [(CGFloat, CGFloat)] = [(0.025,0.042),(0.085,0.085),(0.19,0.095),(0.36,0.07),(0.66,0.095),(0.83,0.11),(0.945,0.07),(0.988,0.026)]
            for (index, fold) in folds.enumerated() {
                let (center,width) = fold
                // Nested translucent sheets feather each fold across its width.
                // A narrow specular crest grows out of a broad, faint violet reflection.
                for band in 0..<8 {
                    let weight = CGFloat(band)/7
                    let breadth = width * (1.8 - 1.68*weight)
                    let paths = frames.map { sheet(geometry: geometry, frame: $0, center: center, width: breadth) }
                    let tint = violet.blended(withFraction: weight*0.9, of: pearl)!
                    let strength: CGFloat = (index == 0 || index == 7 ? 0.15 : 0.085)
                    let (surface, mask) = gradient(paths: paths,
                        colors: [tint.withAlphaComponent(strength*0.8),tint.withAlphaComponent(strength*0.12),tint.withAlphaComponent(strength),tint.withAlphaComponent(strength*0.2),tint.withAlphaComponent(strength*0.8)],
                        locations: [0,0.19,NSNumber(value: 0.46+Double(index%3)*0.06),0.78,1], horizontal: true)
                    if flowing {
                        let flex = CABasicAnimation(keyPath: "path")
                        flex.fromValue = paths.last!.copy(using: &offset)!
                        flex.toValue = sheet(geometry: geometry, frame: final, center: center, width: breadth, phase: 1.8).copy(using: &offset)!
                        flex.duration = 3.8 + Double(index)*0.19; flex.autoreverses = true; flex.repeatCount = .infinity
                        flex.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); mask.add(flex, forKey: "flex")
                        let breath = CABasicAnimation(keyPath: "opacity"); breath.fromValue = 1; breath.toValue = 0.68
                        breath.duration = 2.6+Double(index)*0.21; breath.autoreverses = true; breath.repeatCount = .infinity
                        surface.add(breath, forKey: "shimmer")
                    }
                }
            }
            // Soft nebula pockets drift from the orb into the panel. All motion runs
            // on Core Animation, and the shared silhouette keeps the light in the skin.
            let nebula = CALayer(); nebula.frame = neckBounds; nebula.name = "nebula"
            let nebulaMask = CAShapeLayer(); nebulaMask.fillColor = NSColor.white.cgColor
            animate(nebulaMask, key: "path", values: outlines.map { $0.copy(using: &offset)! }, duration: duration)
            nebula.mask = nebulaMask
            for index in 0..<6 {
                let fraction = CGFloat(index + 1) / 7
                let cloud = CAGradientLayer(); cloud.type = .radial
                cloud.bounds = CGRect(x: 0, y: 0, width: 90 + CGFloat(index % 3) * 24, height: 70 + CGFloat(index % 2) * 48)
                cloud.startPoint = CGPoint(x: 0.5, y: 0.5); cloud.endPoint = CGPoint(x: 1, y: 1)
                let tint = index % 2 == 0 ? NSColor(srgbRed: 0.35, green: 0.39, blue: 1, alpha: 1) : violet
                cloud.colors = [pearl.withAlphaComponent(0.16).cgColor, tint.withAlphaComponent(0.28).cgColor, tint.withAlphaComponent(0).cgColor]
                cloud.locations = [0, 0.28, 1]
                func localPoint(_ frame: CGRect, _ t: CGFloat) -> NSValue {
                    let p = point(geometry: geometry, frame: frame, t: t, fraction: fraction)
                    return NSValue(point: CGPoint(x: p.x - neckBounds.minX, y: p.y - neckBounds.minY))
                }
                animate(cloud, key: "position", values: frames.map { localPoint($0, 0.3 + fraction * 0.6) }, duration: duration)
                if flowing {
                    let travel = CAKeyframeAnimation(keyPath: "position")
                    travel.values = (0...40).map { localPoint(final, CGFloat($0) / 40) }
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = [0, 1, 0.8, 0]; fade.keyTimes = [0, 0.2, 0.75, 1]
                    let flow = CAAnimationGroup(); flow.animations = [travel, fade]
                    flow.duration = 4.5 + Double(index) * 0.37
                    travel.duration = flow.duration; fade.duration = flow.duration
                    flow.timeOffset = Double(index) * 0.91; flow.repeatCount = .infinity
                    cloud.add(flow, forKey: "nebulaFlow")
                }
                nebula.addSublayer(cloud)
            }
            root.addSublayer(nebula)
            // Small suspended lights make the translucent skin feel celestial.
            for (index, sample) in [(CGFloat(0.61),CGFloat(0.22)),(0.81,0.59),(0.46,0.78),(0.9,0.88)].enumerated() {
                let spark = CALayer(); spark.bounds = CGRect(x: 0, y: 0, width: 1.7, height: 1.7)
                spark.cornerRadius = 0.85; spark.backgroundColor = pearl.withAlphaComponent(0.85).cgColor
                spark.shadowColor = violet.cgColor; spark.shadowOpacity = 1; spark.shadowRadius = 5; spark.shadowOffset = .zero
                animate(spark, key: "position", values: frames.map { NSValue(point: point(geometry: geometry, frame: $0, t: sample.0, fraction: sample.1)) }, duration: duration)
                if flowing {
                    let shimmer = CABasicAnimation(keyPath: "opacity"); shimmer.fromValue = 0.2; shimmer.toValue = 0.85
                    shimmer.duration = 1.7+Double(index)*0.4; shimmer.autoreverses = true; shimmer.repeatCount = .infinity
                    spark.add(shimmer, forKey: "twinkle")
                    let drift = CAKeyframeAnimation(keyPath: "position")
                    drift.values = (0...40).map { NSValue(point: point(geometry: geometry, frame: final, t: CGFloat($0)/40, fraction: sample.1)) }
                    drift.duration = 3.4 + Double(index) * 0.6; drift.repeatCount = .infinity
                    drift.timeOffset = Double(index) * 0.8
                    spark.add(drift, forKey: "stardustFlow")
                }
                root.addSublayer(spark)
            }
            for fraction: CGFloat in [0,1] {
                let edges = frames.map { frame -> CGPath in
                    let p = CGMutablePath()
                    for i in 0...40 {
                        let q = point(geometry: geometry, frame: frame, t: CGFloat(i)/40, fraction: fraction)
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                    return p
                }
                for (width,alpha,blur): (CGFloat,CGFloat,CGFloat) in [(5,0.30,10),(2.3,0.6,4),(0.7,0.95,0)] {
                    let lip = CAShapeLayer(); lip.fillColor = nil; lip.lineWidth = width
                    lip.strokeColor = pearl.withAlphaComponent(alpha).cgColor
                    lip.shadowColor = violet.cgColor; lip.shadowOpacity = 0.85; lip.shadowRadius = blur; lip.shadowOffset = .zero
                    animate(lip, key: "path", values: edges, duration: duration); root.addSublayer(lip)
                }
            }
        }
        // A wide atmospheric bloom plus a sharp platinum edge frames the panel.
        let panelPaths = frames.map { CGPath(roundedRect: $0.insetBy(dx: -0.6, dy: -0.6), cornerWidth: 20, cornerHeight: 20, transform: nil) }
        for (width,alpha,blur): (CGFloat,CGFloat,CGFloat) in [(5,0.38,22),(2.8,0.65,10),(1,0.95,3)] {
            let halo = CAShapeLayer(); halo.fillColor = nil; halo.lineWidth = width
            halo.strokeColor = (width == 1 ? pearl : violet).withAlphaComponent(alpha).cgColor
            halo.shadowColor = violet.cgColor; halo.shadowOpacity = 0.95; halo.shadowRadius = blur; halo.shadowOffset = .zero
            animate(halo, key: "path", values: panelPaths, duration: duration); root.addSublayer(halo)
        }
        return root
    }
}
