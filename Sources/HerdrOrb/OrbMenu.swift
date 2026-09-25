import SwiftUI

/// Shared by the desktop orb and its always-available menu-bar entry.
struct OrbMenu: View {
    @ObservedObject var model: BubbleModel
    @AppStorage("showOrb") private var showOrb = true
    let toggle: () -> Void
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
            FloatingOrb(model: model).frame(width: 150, height: 150).accessibilityHidden(true)
            Text("herdrorb").font(.system(size: 23, weight: .semibold)).padding(.top, -6)
            HStack(spacing: 7) {
                Circle().fill(status.1).frame(width: 8, height: 8)
                Text(status.0).font(.system(size: 14))
            }.foregroundStyle(OrbTheme.secondary).padding(.top, 7).padding(.bottom, 22)
            VStack(spacing: 0) {
                action(showOrb ? "Hide orb" : "Show orb", icon: showOrb ? "eye.slash" : "eye", perform: toggle)
                Divider().overlay(OrbTheme.line).padding(.horizontal, 16)
                action("Open agents", icon: "bubble.left.and.bubble.right", perform: open)
                Divider().overlay(OrbTheme.line).padding(.horizontal, 16)
                action("Quit herdrorb", icon: "power", perform: quit)
            }
            .background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(OrbTheme.line, lineWidth: 1))
        }
        .padding(20).frame(width: 280)
        .foregroundStyle(OrbTheme.text).background(OrbTheme.canvas)
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 19, weight: .regular)).frame(width: 25)
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
            }.padding(.horizontal, 16).frame(height: 49).contentShape(Rectangle())
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
