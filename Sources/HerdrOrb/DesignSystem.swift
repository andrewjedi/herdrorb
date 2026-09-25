import AppKit
import SwiftUI

/// Measurements are macOS points. Reference comps are 1520 × 1035 pixels,
/// mapped to a 900 × 613 point panel; controls remain native and accessible.
enum OrbTheme {
    static let canvas = Color(hex: 0x111216)
    static let sidebar = Color(hex: 0x18191E)
    static let surface = Color(hex: 0x1D1E24)
    static let raised = Color(hex: 0x25262E)
    static let text = Color(hex: 0xE8E9ED)
    static let secondary = Color(hex: 0xADB0BC)
    static let muted = Color(hex: 0x9498A6)
    static let accent = Color(hex: 0xB5A8E4)
    static let accentLight = Color(hex: 0xCAB8F3)
    static let selection = Color(hex: 0x49405F)
    static let selectionEdge = Color(hex: 0x8775AC)
    static let line = Color(hex: 0x34363E)
    static let controlEdge = Color(hex: 0x51535F)
    static let online = Color(hex: 0x63CE77)
    static let warning = Color(hex: 0xF1C44D)
    static let danger = Color(hex: 0xEF6A76)
    static let sidebarWidth: CGFloat = 234
    static let panelWidth: CGFloat = 928 // includes the pointer's 14pt reserve on each side
    static let panelHeight: CGFloat = 613
    static let headerHeight: CGFloat = 70
    static let inset: CGFloat = 24
    static let bodyFont = Font.system(size: 15)
    static let smallFont = Font.system(size: 12)
    static let titleFont = Font.system(size: 22, weight: .semibold)
    static let nsCanvas = NSColor(srgbRed: 17/255, green: 18/255, blue: 22/255, alpha: 1)
    static let nsText = NSColor(srgbRed: 232/255, green: 233/255, blue: 237/255, alpha: 1)
    static let nsAccent = NSColor(srgbRed: 181/255, green: 168/255, blue: 228/255, alpha: 1)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1)
    }
}

struct OrbRule: View {
    var body: some View { Rectangle().fill(OrbTheme.line).frame(height: 1).accessibilityHidden(true) }
}

enum OrbButtonKind { case secondary, primary, destructive, quiet, selected }
struct OrbButtonStyle: ButtonStyle {
    var kind: OrbButtonKind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        OrbButtonBody(configuration: configuration, kind: kind, compact: compact, enabled: enabled)
    }
}
private struct OrbButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: OrbButtonKind
    let compact: Bool
    let enabled: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var foreground: Color {
        guard enabled else { return OrbTheme.muted }
        return kind == .primary ? OrbTheme.canvas : kind == .destructive ? .white : OrbTheme.text
    }
    private var fill: Color {
        guard enabled else { return OrbTheme.raised }
        switch kind {
        case .primary: return hovered ? OrbTheme.accentLight : OrbTheme.accent
        case .destructive: return Color(hex: hovered ? 0xB72B3E : 0xA42133)
        case .selected: return OrbTheme.selection
        case .quiet: return hovered ? OrbTheme.raised : .clear
        case .secondary: return hovered ? OrbTheme.raised : OrbTheme.surface
        }
    }
    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: kind == .primary ? .medium : .regular))
            .foregroundStyle(foreground).lineLimit(1)
            .padding(.horizontal, compact ? 10 : 17).frame(minHeight: compact ? 28 : 36)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .quiet ? .clear : (!enabled ? OrbTheme.line : kind == .primary ? OrbTheme.accentLight : kind == .selected ? OrbTheme.selectionEdge : contrast == .increased ? OrbTheme.secondary : OrbTheme.controlEdge), lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.62)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct OrbIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(width: 28, height: 30) }
            .buttonStyle(OrbButtonStyle(kind: .quiet, compact: true))
            .help(label).accessibilityLabel(label)
    }
}

struct OrbField: View {
    let placeholder: String
    @Binding var text: String
    var label: String
    var monospaced = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundColor(OrbTheme.muted))
            .textFieldStyle(.plain).font(.system(size: 15, design: monospaced ? .monospaced : .default))
            .foregroundStyle(OrbTheme.text).padding(.horizontal, 13).frame(height: 36)
            .background(OrbTheme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? OrbTheme.accent : OrbTheme.controlEdge, lineWidth: focused ? 1.5 : 0.75))
            .focused($focused).onSubmit(onSubmit).accessibilityLabel(label).opacity(enabled ? 1 : 0.6)
    }
}

struct OrbSegment: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    var fillsWidth = false
    var compact = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol { Image(systemName: symbol).font(.system(size: compact ? 12 : 18)) }
                Text(title).font(.system(size: compact ? 12 : 14, weight: selected ? .medium : .regular))
            }.foregroundStyle(OrbTheme.text).padding(.horizontal, compact ? 10 : 16)
                .frame(maxWidth: fillsWidth ? .infinity : nil).frame(height: compact ? 26 : 32)
                .background(selected ? OrbTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? OrbTheme.selectionEdge : .clear, lineWidth: 0.8))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct OrbStatus: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 8) { Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true); Text(text) }
            .font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
    }
}

struct OrbSheet<Content: View>: View {
    var width: CGFloat = 570
    var inset: CGFloat = 28
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(inset).frame(width: width).background(OrbTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(OrbTheme.controlEdge, lineWidth: 0.75))
            .foregroundStyle(OrbTheme.text).font(OrbTheme.bodyFont).tint(OrbTheme.accent)
            .preferredColorScheme(.dark)
    }
}

struct OrbSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Loading conversation…", systemImage: "desktopcomputer").font(OrbTheme.bodyFont)
            ForEach([0.86, 0.92], id: \.self) { fraction in
                HStack(alignment: .top, spacing: 14) {
                    Circle().fill(OrbTheme.line).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { proxy in Capsule().fill(OrbTheme.line).frame(width: proxy.size.width * fraction, height: 11) }.frame(height: 11)
                        GeometryReader { proxy in Capsule().fill(OrbTheme.line).frame(width: proxy.size.width * fraction * 0.8, height: 10) }.frame(height: 10)
                    }.padding(.top, 2)
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading conversation")
    }
}

struct PendingMessageView: View {
    let text: String
    let state: String
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(text).font(OrbTheme.bodyFont).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if state.hasPrefix("Sending") { ProgressView().controlSize(.small) }
                else { Image(systemName: state.hasPrefix("Delivered") ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(OrbTheme.secondary) }
                Text(state).font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
                Spacer()
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .medium))
                    .foregroundStyle(OrbTheme.canvas).frame(width: 32, height: 32)
                    .background(OrbTheme.accent.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
        }.padding(15).background(OrbTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbTheme.controlEdge, lineWidth: 0.8))
    }
}

struct CachedConversationNotice: View {
    var body: some View {
        Label("Showing saved conversation while reconnecting", systemImage: "clock.arrow.circlepath")
            .font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A switch with the panel's accent and consistent alignment, including when
/// the utility panel is not the key window. Accessibility remains a Toggle.
struct OrbSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 12)
                Capsule().fill(configuration.isOn ? OrbTheme.accent : OrbTheme.line)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(OrbTheme.text).padding(2).shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    }.frame(width: 38, height: 22)
            }.contentShape(Rectangle()).opacity(enabled ? 1 : 0.55)
        }.buttonStyle(.plain)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}


struct ProviderLogo: View {
    let provider: String?
    private static let codex = load("ProviderCodex")
    private static let claude = load("ProviderClaude")
    private static func load(_ name: String) -> NSImage? {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("HerdrOrb_HerdrOrb.bundle")) }
        #if SWIFT_PACKAGE
        let resources = packaged ?? Bundle.module
        #else
        let resources = packaged ?? Bundle.main
        #endif
        guard let url = resources.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }
    var body: some View {
        Group {
            if let icon = provider == "codex" ? Self.codex : provider == "claude" ? Self.claude : nil {
                Image(nsImage: icon).resizable().scaledToFit()
            } else { Image(systemName: "terminal").resizable().scaledToFit() }
        }.accessibilityHidden(true)
    }
}
