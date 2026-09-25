import XCTest
import MetalKit
@testable import HerdrOrb

final class OrbMotionTests: XCTestCase {
    @MainActor func testGalaxyMovesWhileGlassRimStaysStillAndHaloExtends() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let scale: Float = 152.0 / 112.0
        let first = try XCTUnwrap(OrbRenderer.snapshot(variant: 0, time: 0, pixels: 304, canvasScale: scale))
        let later = try XCTUnwrap(OrbRenderer.snapshot(variant: 0, time: 1, pixels: 304, canvasScale: scale))
        let a = NSBitmapImageRep(cgImage: try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let b = NSBitmapImageRep(cgImage: try XCTUnwrap(later.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        var interiorChange = 0.0, rimChange = 0.0, haloAlpha = 0.0
        var interiorCount = 0, rimCount = 0, haloCount = 0
        for y in stride(from: 0, to: 304, by: 2) {
            for x in stride(from: 0, to: 304, by: 2) {
                let r = hypot((Double(x) + 0.5) / 152 - 1, (Double(y) + 0.5) / 152 - 1) * Double(scale)
                let c = try XCTUnwrap(a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let d = try XCTUnwrap(b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let delta = Double(abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent) + abs(c.blueComponent - d.blueComponent)) / 3
                if r < 0.55 { interiorChange += delta; interiorCount += 1 }
                if r > 0.80 && r < 0.82 { rimChange += delta; rimCount += 1 }
                if r > 1.02 && r < 1.15 { haloAlpha += Double(c.alphaComponent); haloCount += 1 }
            }
        }
        XCTAssertGreaterThan(interiorChange / Double(interiorCount), 0.035, "Galaxy motion must be plainly visible within one second")
        XCTAssertLessThan(rimChange / Double(rimCount), 0.005, "Glass rim must not spin with the interior")
        XCTAssertGreaterThan(haloAlpha / Double(haloCount), 0.025, "Glow must extend beyond the old drawing area")
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("herdrorb-motion-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try a.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("orb-0.png"))
        try b.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("orb-1.png"))
        print("Orb motion renders: \(output.path)")
    }
}
