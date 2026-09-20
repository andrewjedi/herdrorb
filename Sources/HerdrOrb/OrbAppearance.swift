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
        case .nebula: return "Living violet clouds"
        case .pearl: return "Ethereal teal and mint"
        case .eclipse: return "Fiery rose and gold"
        }
    }
}

struct OrbArtwork: View {
    var style: OrbStyle
    var hovered = false
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            PearlOrb(hovered: hovered, variant: style.shaderVariant)
                .frame(width: size, height: size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }.allowsHitTesting(false)
    }
}

struct FloatingOrb: View {
    @ObservedObject var model: BubbleModel
    var hovered = false
    @AppStorage("orbStyle") private var style = OrbStyle.nebula.rawValue
    @AppStorage("orbStatusDot") private var showStatus = true
    var body: some View {
        OrbArtwork(style: OrbStyle(rawValue: style) ?? .nebula, hovered: hovered)
            .overlay(alignment: .bottomTrailing) {
                if showStatus {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(red: 0.06, green: 0.07, blue: 0.10), lineWidth: 2))
                        .padding(24).accessibilityLabel(statusLabel)
                }
            }
            .help(statusLabel + " · Click to open agents · drag to move")
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
