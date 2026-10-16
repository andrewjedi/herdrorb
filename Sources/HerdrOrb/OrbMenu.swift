import SwiftUI

/// Shared by the desktop orb and its always-available menu-bar entry.
struct OrbMenu: View {
    @ObservedObject var model: BubbleModel
    @AppStorage("showOrb") private var showOrb = true
    @AppStorage("smallOrb") private var smallOrb = false
    let toggle: () -> Void
    let resize: () -> Void
    let open: () -> Void
    let quit: () -> Void

    private var status: (String, Color) {
        switch model.connection["local"] {
        case .online: return ("Online", OrbTheme.online)
        case nil, .connecting: return ("Connecting", OrbTheme.warning)
        default: return ("Offline", OrbTheme.muted)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("herdrorb").font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle().fill(status.1).frame(width: 5, height: 5)
                Text(status.0).font(.system(size: 10))
                    .foregroundStyle(OrbTheme.secondary)
            }.padding(.horizontal, 9).padding(.top, 5).padding(.bottom, 9)
            VStack(spacing: 0) {
                action(showOrb ? "Hide orb" : "Show orb", icon: showOrb ? "eye.slash" : "eye", perform: toggle)
                action(smallOrb ? "Make orb normal size" : "Make orb smaller", icon: smallOrb ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left", perform: resize)
                action("Open agents", icon: "bubble.left.and.bubble.right", perform: open)
                Divider().overlay(OrbTheme.line).padding(.horizontal, 16)
                action("Quit herdrorb", icon: "power", perform: quit)
            }
            .background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(OrbTheme.line, lineWidth: 1))
        }
        .padding(8).frame(width: 218)
        .foregroundStyle(OrbTheme.text)
        .background(OrbTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OrbTheme.line, lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13, weight: .regular)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(OrbMenuButtonStyle())
    }
}

private struct OrbMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }
    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(OrbTheme.accent.opacity(configuration.isPressed ? 0.24 : hovered ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10))
                .onHover { hovered = $0 }
        }
    }
}

/// Keep the small menu a fixed distance from the visible rim, on either side of the screen.
enum OrbMenuPlacement {
    static func frame(orb: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let radius = 43 * orb.width / 152
        let gap: CGFloat = 22
        let rightX = orb.midX + radius + gap
        let leftX = orb.midX - radius - gap - size.width
        let x = rightX + size.width <= screen.maxX - 8 ? rightX : leftX
        return CGRect(x: max(screen.minX + 8, min(x, screen.maxX - size.width - 8)),
                      y: max(screen.minY + 8, min(orb.midY - size.height / 2, screen.maxY - size.height - 8)),
                      width: size.width, height: size.height)
    }
}
