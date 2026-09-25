import SwiftUI

enum OrbStyle: String, CaseIterable, Identifiable {
    case nebula, pearl, eclipse
    var id: String { rawValue }
    var title: String {
        switch self { case .nebula: return "Nebula"; case .pearl: return "Aurora"; case .eclipse: return "Supernova" }
    }
    var shaderVariant: Float {
        switch self { case .nebula: return 0; case .pearl: return 1; case .eclipse: return 2 }
    }
    var detail: String {
        switch self {
        case .nebula: return "Violet smoke"
        case .pearl: return "Teal and mint"
        case .eclipse: return "Rose and gold"
        }
    }
}

private struct OrbSnapshotTimeKey: EnvironmentKey { static let defaultValue: Float? = nil }
extension EnvironmentValues {
    var orbSnapshotTime: Float? {
        get { self[OrbSnapshotTimeKey.self] }
        set { self[OrbSnapshotTimeKey.self] = newValue }
    }
}

struct OrbArtwork: View {
    @Environment(\.orbSnapshotTime) private var snapshotTime
    var style: OrbStyle
    var hovered = false
    var glowPadding: CGFloat = 0
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let canvasScale = Float(size / max(1, size - glowPadding * 2))
            Group {
                if let time = snapshotTime, let image = OrbRenderer.snapshot(variant: style.shaderVariant, time: time, canvasScale: canvasScale) {
                    Image(nsImage: image).resizable()
                } else {
                    PearlOrb(hovered: hovered, variant: style.shaderVariant, canvasScale: canvasScale)
                }
            }.frame(width: size, height: size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }.allowsHitTesting(false)
    }
}

struct FloatingOrb: View {
    @ObservedObject var model: BubbleModel
    var hovered = false
    @AppStorage("orbStyle") private var style = OrbStyle.nebula.rawValue
    @AppStorage("orbStatusDot") private var showStatus = false
    var body: some View {
        GeometryReader { geometry in
            let padding = max(0, (min(geometry.size.width, geometry.size.height) - 112) / 2)
            OrbArtwork(style: OrbStyle(rawValue: style) ?? .nebula, hovered: hovered, glowPadding: padding)
            .overlay(alignment: .bottomTrailing) {
                if showStatus {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(red: 0.06, green: 0.07, blue: 0.10), lineWidth: 2))
                        .padding(24 + padding).accessibilityLabel(statusLabel)
                }
            }
            .help(statusLabel + " · Click to open agents · drag to move")
        }
    }
    private var statusColor: Color {
        switch model.connection["local"] {
        case .online: return .green
        case nil, .connecting: return .yellow
        default: return .red
        }
    }
    private var statusLabel: String {
        switch model.connection["local"] {
        case .online: return "Herdr on this Mac is online"
        case nil, .connecting: return "Connecting to Herdr on this Mac"
        default: return "Herdr on this Mac is offline"
        }
    }
}
