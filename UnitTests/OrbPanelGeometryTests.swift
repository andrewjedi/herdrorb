import XCTest
import AppKit
import QuartzCore
@testable import HerdrOrb

final class OrbPanelGeometryTests: XCTestCase {
    func testOrbRemainsAboveEffectAndMaskExcludesItsWholeHoverSilhouette() {
        XCTAssertGreaterThan(OrbWindowLevels.orb.rawValue, OrbWindowLevels.panel.rawValue)
        for panelX: CGFloat in [250, -1000] {
            let geometry = OrbPanelGeometry(orb: CGRect(x: 20, y: 200, width: 152, height: 152), panel: CGRect(x: panelX, y: 80, width: 900, height: 613))
            let bounds = CGRect(x: -1200, y: 0, width: 2500, height: 900)
            let mask = geometry.effectMask(in: bounds)
            for angle in stride(from: 0.0, to: Double.pi * 2, by: 0.1) {
                let point = CGPoint(x: geometry.orb.midX + cos(angle) * 47.5, y: geometry.orb.midY + sin(angle) * 47.5)
                XCTAssertFalse(mask.contains(point, using: .evenOdd), "No effect pixels may cover the hovering orb")
            }
            XCTAssertFalse(mask.contains(CGPoint(x: geometry.orb.midX, y: geometry.orb.midY), using: .evenOdd))
            XCTAssertTrue(mask.contains(CGPoint(x: geometry.orb.midX + 55, y: geometry.orb.midY), using: .evenOdd), "Connection remains visible outside the glass")
        }
    }
    @MainActor func testRapidReversalCancelsStaleCompletionAndReusesSnapshot() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: -5000, y: -5000, width: 720, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 480))
        let effect = OrbPanelEffect()
        let orb = CGRect(x: -5180, y: -4800, width: 112, height: 112)
        effect.prepareSnapshot(panel: panel)
        var completed: [String] = []
        effect.animate(open: true, panel: panel, orb: orb, connected: true) { completed.append("stale open") }
        XCTAssertEqual(effect.lastCaptureMilliseconds, 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        effect.animate(open: false, panel: panel, orb: orb, connected: true) { completed.append("stale close") }
        try await Task.sleep(nanoseconds: 60_000_000)
        effect.animate(open: true, panel: panel, orb: orb, connected: true) { completed.append("final open") }
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(completed, ["final open"])
        effect.hide()
    }
    @MainActor func testDraggingMovesPanelAndEffectDuringOpeningWithoutRebuildingLayers() async throws {
        _ = NSApplication.shared
        let orb = NSPanel(contentRect: CGRect(x: -5200, y: -4700, width: 152, height: 152), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: CGRect(x: -5000, y: -4800, width: 720, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        let effect = OrbPanelEffect()
        defer { effect.hide(); panel.orderOut(nil) }
        effect.animate(open: true, panel: panel, orb: orb.frame, connected: true) {}
        let effectWindow = try XCTUnwrap(NSApp.windows.first { ($0.contentView as? OrbPanelEffectView) != nil && $0.isVisible })
        let art = try XCTUnwrap(effectWindow.contentView as? OrbPanelEffectView)
        let originalLayers = art.layer?.sublayers ?? []
        let originalEffect = effectWindow.frame
        let originalPanel = panel.frame
        let originalOrb = orb.frame
        for i in 1...20 {
            let dx = CGFloat(i) * 3, dy = CGFloat(i) * -4
            effect.move(orb: orb, panel: panel, to: originalOrb.offsetBy(dx: dx, dy: dy).origin, connected: true)
            XCTAssertEqual(panel.frame, originalPanel.offsetBy(dx: dx, dy: dy))
            XCTAssertEqual(effectWindow.frame, originalEffect.offsetBy(dx: dx, dy: dy))
            XCTAssertEqual(art.layer?.sublayers, originalLayers)
        }
        let attachedPanel = panel.frame
        effect.move(orb: orb, panel: panel, to: originalOrb.origin, connected: false)
        XCTAssertEqual(panel.frame, attachedPanel, "A menu-bar panel should not follow the orb")
        try await Task.sleep(nanoseconds: 450_000_000)
    }
    func testNebulaFlowsInBothDirectionsAndRespectsReducedMotion() {
        for right in [true, false] {
            let geometry = OrbPanelGeometry(orb: CGRect(x: 0, y: 200, width: 152, height: 152), panel: CGRect(x: right ? 220 : -1000, y: 80, width: 900, height: 600))
            for flowing in [true, false] {
                let scene = EtherealMembrane.make(geometry: geometry, frames: [geometry.panel], connected: true, bounds: geometry.orb.union(geometry.panel), flowing: flowing)
                let clouds = scene.sublayers?.first { $0.name == "nebula" }?.sublayers ?? []
                XCTAssertEqual(clouds.count, 3)
                for cloud in clouds {
                    let flow = cloud.animation(forKey: "nebulaFlow") as? CAAnimationGroup
                    XCTAssertEqual(flow != nil, flowing)
                    if let travel = flow?.animations?.first as? CAKeyframeAnimation,
                       let start = (travel.values?.first as? NSValue)?.pointValue,
                       let end = (travel.values?.last as? NSValue)?.pointValue {
                        XCTAssertEqual(end.x > start.x, right)
                    }
                }
            }
        }
    }
    func testSmallOrbMaskAndNeckScaleTogether() {
        for size: CGFloat in [76, 152] {
            let geometry = OrbPanelGeometry(orb: CGRect(x: 0, y: 200, width: size, height: size), panel: CGRect(x: 220, y: 80, width: 900, height: 600))
            XCTAssertEqual(geometry.orbOcclusionRect.width, 96 * size / 152)
            let neck = EtherealMembrane.point(geometry: geometry, frame: geometry.panel, t: 0, fraction: 1)
            XCTAssertEqual(neck.y - geometry.orb.midY, 34 * size / 152, accuracy: 0.001)
            let mask = geometry.effectMask(in: geometry.orb.union(geometry.panel))
            XCTAssertTrue(mask.contains(CGPoint(x: geometry.orb.midX + 50 * size / 152, y: geometry.orb.midY), using: .evenOdd))
        }
    }
    func testMenuPlacementAndThinAttachmentAtScreenEdges() {
        let screen = CGRect(x: -1200, y: -300, width: 1200, height: 800)
        for size: CGFloat in [76, 152] {
            for origin in [CGPoint(x: -1200, y: -300), CGPoint(x: -size, y: 500 - size)] {
                let orb = CGRect(origin: origin, size: CGSize(width: size, height: size))
                let menu = OrbMenuPlacement.frame(orb: orb, size: CGSize(width: 218, height: 180), screen: screen)
                XCTAssertTrue(screen.contains(menu))
                let geometry = OrbPanelGeometry(orb: orb, panel: menu, compact: true)
                XCTAssertTrue(geometry.canConnect)
                let top = EtherealMembrane.point(geometry: geometry, frame: menu, t: 1, fraction: 1)
                let bottom = EtherealMembrane.point(geometry: geometry, frame: menu, t: 1, fraction: 0)
                XCTAssertEqual(top.y - bottom.y, 18, accuracy: 0.001)
                XCTAssertLessThan(top.y, menu.maxY)
                XCTAssertGreaterThan(bottom.y, menu.minY)
            }
        }
    }
    @MainActor func testSettledConnectorHasNoRepeatingAnimations() {
        let art = OrbPanelEffectView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        art.geometry = OrbPanelGeometry(orb: CGRect(x: 0, y: 200, width: 76, height: 76), panel: CGRect(x: 220, y: 80, width: 900, height: 600))
        art.progress = 1
        art.startFlow()
        func verify(_ layer: CALayer) {
            XCTAssertTrue((layer.animationKeys() ?? []).isEmpty)
            layer.sublayers?.forEach(verify)
            if let mask = layer.mask { verify(mask) }
        }
        if let layer = art.layer { verify(layer) } else { XCTFail("Missing cached connector") }
    }
    func testSpringArrivesQuicklyAndSettlesWithoutLargeBounce() {
        let spring = PanelSpring(position: 0, velocity: 0, target: 1)
        XCTAssertGreaterThan(spring.sample(0.12).position, 0.8)
        let peak = (0...420).map { spring.sample(Double($0) / 1000).position }.max()!
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThan(peak, 1.035)
        XCTAssertEqual(spring.sample(0.42).position, 1, accuracy: 0.001)
    }
    func testReversalPreservesPositionAndVelocity() {
        let opening = PanelSpring(position: 0, velocity: 0, target: 1)
        let current = opening.sample(0.08)
        let closing = PanelSpring(position: current.position, velocity: current.velocity, target: 0)
        XCTAssertEqual(closing.sample(0).position, current.position, accuracy: 0.000001)
        XCTAssertEqual(closing.sample(0).velocity, current.velocity, accuracy: 0.000001)
        XCTAssertEqual(closing.sample(0.3).position, 0, accuracy: 0.002)
    }
    func testGalaxySoundsAreValidAndShort() {
        for opening in [true, false] {
            let sound = OrbChime.make(opening: opening)
            XCTAssertNotNil(sound)
            XCTAssertEqual(sound?.duration ?? 0, opening ? 0.7 : 0.5, accuracy: 0.04)
        }
    }
    func testUnfurlHasExactEndpointsAndClampedProgress() {
        let geometry = OrbPanelGeometry(orb: CGRect(x: 100, y: 200, width: 112, height: 112), panel: CGRect(x: 298, y: 80, width: 900, height: 613))
        XCTAssertEqual(geometry.frame(at: 1), geometry.panel)
        XCTAssertEqual(geometry.frame(at: 2), geometry.panel)
        XCTAssertEqual(geometry.frame(at: 0).midX, geometry.orb.midX)
        XCTAssertEqual(geometry.frame(at: -1), geometry.frame(at: 0))
        XCTAssertTrue(geometry.canConnect)
    }
    func testMirroredAndNegativeScreenCoordinates() {
        let geometry = OrbPanelGeometry(orb: CGRect(x: -160, y: -200, width: 112, height: 112), panel: CGRect(x: -1146, y: -450, width: 900, height: 613))
        XCTAssertFalse(geometry.panelOnRight)
        XCTAssertTrue(geometry.canConnect)
        XCTAssertEqual(geometry.frame(at: 1), geometry.panel)
        XCTAssertGreaterThan(geometry.frame(at: 0.5).width, geometry.frame(at: 0).width)
        XCTAssertLessThan(geometry.frame(at: 0.5).width, geometry.panel.width)
    }
    func testOverlappingPanelDoesNotDrawConnectionThroughContent() {
        let geometry = OrbPanelGeometry(orb: CGRect(x: 100, y: 200, width: 112, height: 112), panel: CGRect(x: 160, y: 80, width: 900, height: 613))
        XCTAssertFalse(geometry.canConnect)
    }
}
