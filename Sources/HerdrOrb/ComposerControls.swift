import SwiftUI

/// The session owns the selected values. These controls only propose changes;
/// a selection is shown as active after the session confirms it.
struct ComposerControls: View {
    var provider = "codex"
    var showsAccess = true
    var showsModel = true
    var compactOnly = false
    let access: String?
    let model: String?
    let effort: String?
    let speed: String?
    let models: [String]
    let efforts: [String]
    var accessOptions: [String] = ["ask", "auto", "full"]
    var speeds: [String] = ["standard", "fast"]
    var defaultEffort: String? = nil
    var enabled = true
    var applying = false
    var onAccess: (String) -> Void
    var onModel: (String) -> Void
    var onEffort: (String) -> Void
    var onSpeed: (String) -> Void
    var onRefresh: (() -> Void)? = nil

    @State private var showingAccess = false
    @State private var showingSettings = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: compactOnly)
            controls(compact: true)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onChange(of: showingAccess) { _, open in
            if open && (accessOptions.isEmpty || access == nil) && !applying { onRefresh?() }
        }
        .onChange(of: showingSettings) { _, open in
            if open && (models.isEmpty || model == nil || effort == nil) && !applying { onRefresh?() }
        }
        .onChange(of: enabled) { _, enabled in
            if !enabled { showingAccess = false; showingSettings = false }
        }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if showsAccess {
            Button { showingAccess.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: accessChoice?.symbol ?? "shield")
                        .font(.system(size: 14))
                    if !compact { Text(accessChoice?.title ?? "Permissions") }
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.foregroundStyle((accessChoice == .full || accessChoice == .bypassPermissions) ? ComposerPalette.orange : ComposerPalette.secondary)
            }
            .buttonStyle(ComposerChipStyle(selected: showingAccess))
            .accessibilityLabel("Permissions: \(accessChoice?.title ?? "not selected")")
            .help("Change permissions")
            .popover(isPresented: $showingAccess, arrowEdge: .top) {
                ComposerAccessPopover(provider: provider, selection: accessChoice, options: accessOptions, applying: applying) { choice in
                    onAccess(choice.rawValue)
                    showingAccess = false
                }
            }

            }
            if showsAccess && showsModel { Spacer(minLength: 0) }
            if showsModel {
            Button { showingSettings.toggle() } label: {
                HStack(spacing: 5) {
                    if applying {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else if ComposerLabels.isFast(speed) {
                        Image(systemName: "bolt.fill").font(.system(size: 12))
                    }
                    if !compact {
                        Text(model.map(ComposerLabels.model) ?? "Model")
                            .foregroundStyle(ComposerPalette.text)
                    }
                    Text(effort.map({ ComposerLabels.effort($0, provider: provider) }) ?? "Effort")
                        .foregroundStyle(ComposerPalette.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ComposerPalette.secondary)
                }
            }
            .buttonStyle(ComposerChipStyle(selected: showingSettings))
            .accessibilityLabel("Model and effort: \(model.map(ComposerLabels.model) ?? "model not selected"), \(effort.map({ ComposerLabels.effort($0, provider: provider) }) ?? "effort not selected")")
            .help("Choose model, reasoning effort, and speed")
            .popover(isPresented: $showingSettings, arrowEdge: .top) {
                ComposerSettingsPopover(provider: provider, model: model, effort: effort, speed: speed,
                                        models: models, efforts: efforts, speeds: speeds, defaultEffort: defaultEffort, applying: applying,
                                        onModel: onModel, onEffort: onEffort, onSpeed: onSpeed)
            }
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    private var accessChoice: ComposerAccessChoice? { access.flatMap(ComposerAccessChoice.init(value:)) }
}

private enum ComposerPalette {
    static let panel = Color(hex: 0x2B2B2D)
    static let hover = Color.white.opacity(0.075)
    static let text = Color(hex: 0xF0F0F1)
    static let secondary = Color(hex: 0xA4A4A7)
    static let orange = Color(hex: 0xFF8545)
    static let blue = Color(hex: 0x4690FF)
    static let purple = Color(hex: 0xB27BFF)
}

private enum ComposerAccessChoice: String, CaseIterable {
    case ask, auto, full, manual, acceptEdits, plan, claudeAuto, bypassPermissions, dontAsk

    var isClaude: Bool { ![Self.ask, .auto, .full].contains(self) }

    init?(value: String) {
        switch value.lowercased() {
        case "manual": self = .manual
        case "acceptedits": self = .acceptEdits
        case "plan": self = .plan
        case "claudeauto": self = .claudeAuto
        case "bypasspermissions": self = .bypassPermissions
        case "dontask": self = .dontAsk
        case "ask", "ask for approval", "read-only", "untrusted": self = .ask
        case "auto", "approve for me", "on-request", "workspace-write": self = .auto
        case "full", "full access", "danger-full-access": self = .full
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .manual: return "Manual approval"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan mode"
        case .claudeAuto: return "Auto mode"
        case .bypassPermissions: return "Bypass permissions"
        case .dontAsk: return "Don’t ask"
        case .ask: return "Ask for approval"
        case .auto: return "Approve for me"
        case .full: return "Full access"
        }
    }

    var detail: String {
        switch self {
        case .manual: return "Ask before tools run unless an existing rule allows them."
        case .acceptEdits: return "Allow file edits; ask before other tools run."
        case .plan: return "Explore and plan without making changes."
        case .claudeAuto: return "Use Claude’s automatic review, when enabled for this session."
        case .bypassPermissions: return "Skip permission prompts. Requires a session started with bypass enabled."
        case .dontAsk: return "Deny tools that would require a permission prompt."
        case .ask: return "Ask before making changes or running commands."
        case .auto: return "Work within the project; ask when more access is needed."
        case .full: return "Allow access to files and the internet without approval."
        }
    }

    var symbol: String {
        switch self {
        case .manual, .dontAsk: return "hand.raised"
        case .acceptEdits, .claudeAuto: return "checkmark.shield"
        case .plan: return "list.bullet.clipboard"
        case .bypassPermissions: return "exclamationmark.shield"
        case .ask: return "hand.raised"
        case .auto: return "checkmark.shield"
        case .full: return "exclamationmark.shield"
        }
    }
}

enum ComposerLabels {
    static func model(_ value: String) -> String {
        guard value.lowercased().hasPrefix("gpt-") else { return value }
        let parts = value.split(separator: "-")
        return parts.enumerated().map { index, part in
            index == 0 ? "GPT" : index == 1 ? "-\(part)" : " \(part.capitalized)"
        }.joined()
    }

    static func effort(_ value: String, provider: String = "codex") -> String {
        if provider == "claude" { return value == "xhigh" ? "Extra high" : value == "ultracode" ? "Ultracode" : value.capitalized }
        switch value.lowercased() {
        case "none": return "None"
        case "minimal": return "Minimal"
        case "low", "light": return "Light"
        case "medium", "balanced": return "Balanced"
        case "high": return "High"
        case "xhigh": return "Very high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return value.capitalized
        }
    }

    static func isFast(_ value: String?) -> Bool {
        ["fast", "priority"].contains(value?.lowercased() ?? "")
    }
}

private struct ComposerChipStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        ComposerChipBody(configuration: configuration, selected: selected)
    }
}

private struct ComposerChipBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label.padding(.horizontal, 9).frame(height: 30)
            .background(selected || hovered || configuration.isPressed ? ComposerPalette.hover : .clear, in: Capsule())
            .contentShape(Capsule()).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

private struct ComposerPopoverSurface<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().padding(8).frame(width: width)
            .foregroundStyle(ComposerPalette.text)
            .background(ComposerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.11), lineWidth: 0.75))
            .preferredColorScheme(.dark)
    }
}

private struct ComposerAccessPopover: View {
    var provider = "codex"
    let selection: ComposerAccessChoice?
    let options: [String]
    let applying: Bool
    let select: (ComposerAccessChoice) -> Void

    var body: some View {
        ComposerPopoverSurface(width: 408) {
            VStack(alignment: .leading, spacing: 2) {
                Text("How should actions be approved?")
                    .font(.system(size: 13)).foregroundStyle(ComposerPalette.secondary)
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 10)
                ForEach(ComposerAccessChoice.allCases.filter { provider == "claude" ? ($0.isClaude && ($0 != .dontAsk || selection == .dontAsk)) : !$0.isClaude }, id: \.self) { choice in
                    Button { select(choice) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: choice.symbol).font(.system(size: 18)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.title).font(.system(size: 15, weight: .medium))
                                Text(choice.detail).font(.system(size: 12))
                                    .foregroundStyle((choice == .full || choice == .bypassPermissions) ? ComposerPalette.orange.opacity(0.9) : ComposerPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .medium))
                                .opacity(selection == choice ? 1 : 0)
                        }
                        .foregroundStyle((choice == .full || choice == .bypassPermissions) ? ComposerPalette.orange : ComposerPalette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ComposerOptionStyle(selected: selection == choice))
                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                    .disabled(applying || !options.contains(choice.rawValue))
                    .opacity(options.contains(choice.rawValue) ? 1 : 0.4)
                    .help(options.contains(choice.rawValue) ? choice.title : "This option is unavailable in this session.")
                }
            }
        }
    }
}

private struct ComposerOptionStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        ComposerOptionBody(configuration: configuration, selected: selected)
    }
}

private struct ComposerOptionBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected || hovered || configuration.isPressed ? ComposerPalette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11)).onHover { hovered = $0 }
    }
}

private struct ComposerSettingsPopover: View {
    var provider = "codex"
    let model: String?
    let effort: String?
    let speed: String?
    let models: [String]
    let efforts: [String]
    let speeds: [String]
    var defaultEffort: String? = nil
    let applying: Bool
    let onModel: (String) -> Void
    let onEffort: (String) -> Void
    let onSpeed: (String) -> Void

    @State private var showingModels = false
    @State private var previewIndex: Int?
    @State private var pendingModel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedIndex: Int? { efforts.firstIndex { $0 == effort } }
    private var visibleIndex: Int? {
        guard let index = previewIndex ?? selectedIndex, efforts.indices.contains(index) else { return nil }
        return index
    }
    private var progress: Double {
        guard let index = visibleIndex, efforts.count > 1 else { return 0 }
        return Double(index) / Double(efforts.count - 1)
    }
    private var accent: Color { progress > 0.45 ? ComposerPalette.purple : ComposerPalette.blue }
    private var resetEffort: String? { defaultEffort.flatMap { efforts.contains($0) ? $0 : nil } }

    var body: some View {
        ComposerPopoverSurface(width: 320) {
            Group {
                if showingModels { modelPicker }
                else { effortPicker }
            }
        }
        .onChange(of: effort) { _, _ in previewIndex = nil }
        .onChange(of: efforts) { _, _ in previewIndex = nil }
        .onChange(of: applying) { _, busy in
            if !busy { previewIndex = nil; pendingModel = nil }
        }
        .onExitCommand { showingModels = false }
    }

    private var effortPicker: some View {
        VStack(spacing: 17) {
            VStack(spacing: 7) {
                HStack {
                    Button { onSpeed(ComposerLabels.isFast(speed) ? "standard" : "fast") } label: {
                        Image(systemName: ComposerLabels.isFast(speed) ? "bolt.fill" : "bolt")
                            .font(.system(size: 17))
                            .foregroundStyle(ComposerLabels.isFast(speed) ? accent : ComposerPalette.secondary)
                            .frame(width: 30, height: 30).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(applying || speed == nil || !speeds.contains(ComposerLabels.isFast(speed) ? "standard" : "fast"))
                    .help(speed == nil || speeds.isEmpty ? "Fast mode is unavailable in this session" : ComposerLabels.isFast(speed) ? "Turn Fast mode off" : speeds.contains("fast") ? "Turn Fast mode on" : "Fast mode is unavailable in this session")
                    .accessibilityLabel("Fast mode")
                    .accessibilityValue(speed == nil ? "Unavailable" : ComposerLabels.isFast(speed) ? "On" : "Off")
                    Spacer(minLength: 0)
                    Text(visibleIndex.map { ComposerLabels.effort(efforts[$0], provider: provider) } ?? "Select effort")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(visibleIndex == nil ? ComposerPalette.secondary : accent)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Button {
                        guard let value = resetEffort else { return }
                        guard value != effort else { return }
                        previewIndex = efforts.firstIndex(of: value)
                        onEffort(value)
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 16))
                            .frame(width: 27, height: 28)
                    }
                    .buttonStyle(.plain).foregroundStyle(ComposerPalette.secondary)
                    .help(resetEffort.map { "Reset effort to \(ComposerLabels.effort($0, provider: provider))" } ?? "Reset reasoning effort")
                    .accessibilityLabel("Reset reasoning effort")
                    .disabled(applying || defaultEffort == nil || efforts.isEmpty)
                }
                Button { showingModels = true } label: {
                    HStack(spacing: 6) {
                        Text((pendingModel ?? model).map(ComposerLabels.model) ?? "Choose model").font(.system(size: 14))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    }.foregroundStyle(ComposerPalette.secondary).padding(.vertical, 3)
                }
                .buttonStyle(.plain).accessibilityLabel("Choose model, \(model.map(ComposerLabels.model) ?? "not selected")")
            }

            if efforts.count > 1 {
                ComposerEffortSlider(provider: provider, selection: visibleIndex, values: efforts) { index, commit in
                    previewIndex = index
                    if commit {
                        if efforts[index] == effort { previewIndex = nil }
                        else { onEffort(efforts[index]) }
                    }
                }.disabled(applying)
            } else {
                Text(efforts.isEmpty ? "Effort controls are unavailable for this model." : "This model uses \(ComposerLabels.effort(efforts[0], provider: provider).lowercased()) effort.")
                    .font(.system(size: 12)).foregroundStyle(ComposerPalette.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }

            if applying {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Applying…").font(.system(size: 12)).foregroundStyle(ComposerPalette.secondary)
                }.accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: visibleIndex)
    }

    fileprivate var modelPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { showingModels = false } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .medium))
                    Text("Select model").font(.system(size: 13))
                }.foregroundStyle(ComposerPalette.secondary).padding(12)
            }.buttonStyle(.plain).accessibilityLabel("Back to reasoning effort")
            if models.isEmpty {
                Text("Model choices are unavailable for this session.")
                    .font(.system(size: 13)).foregroundStyle(ComposerPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(models, id: \.self) { choice in
                            Button {
                                if choice != model { pendingModel = choice; onModel(choice) }
                                previewIndex = nil
                                showingModels = false
                            } label: {
                                HStack {
                                    Text(ComposerLabels.model(choice)).font(.system(size: 15))
                                    Spacer()
                                    if model == choice {
                                        Image(systemName: "checkmark").font(.system(size: 13, weight: .medium))
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(ComposerOptionStyle(selected: model == choice))
                                .accessibilityAddTraits(model == choice ? .isSelected : [])
                                .disabled(applying)
                        }
                    }
                }.frame(height: min(CGFloat(models.count) * 41, 328))
                    .scrollIndicators(.hidden)
            }
        }
    }
}

/// Uses the production controls with fictional state, without a session or a
/// terminal connection. The preview renderer can inspect every open panel.
struct ComposerControlsPreviewBoard: View {
    var provider = "codex"
    private var models: [String] { provider == "claude" ? ["Default (recommended)", "Opus (1M context)", "Sonnet", "Haiku"] : codexModels }
    private var efforts: [String] { provider == "claude" ? ["low", "medium", "high", "xhigh", "max", "ultracode"] : codexEfforts }
    private var accessOptions: [String] { provider == "claude" ? ["manual", "acceptEdits", "plan", "claudeAuto", "bypassPermissions"] : ["ask", "auto", "full"] }
    private let codexModels = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
    private let codexEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Conversation controls").font(.system(size: 22, weight: .semibold))
                Spacer()
                Text("herdrorb").foregroundStyle(OrbTheme.accent)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    caption("Permissions")
                    ComposerAccessPopover(provider: provider, selection: provider == "claude" ? .bypassPermissions : .full, options: accessOptions, applying: false, select: { _ in })
                    caption("Effort")
                    settings("low")
                    settings(provider == "claude" ? "ultracode" : "ultra")
                }
                VStack(alignment: .leading, spacing: 10) {
                    caption("Model")
                    ComposerPopoverSurface(width: 320) { settings("low").modelPicker }
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                Text("Do anything").font(.system(size: 17)).foregroundStyle(ComposerPalette.secondary)
                HStack(spacing: 10) {
                    ComposerControls(provider: provider, access: provider == "claude" ? "bypassPermissions" : "full", model: models[0], effort: "low", speed: "fast", models: models, efforts: efforts, accessOptions: accessOptions,
                                     onAccess: { _ in }, onModel: { _ in }, onEffort: { _ in }, onSpeed: { _ in })
                    Image(systemName: "mic").font(.system(size: 19)).frame(width: 28)
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.black).frame(width: 32, height: 32).background(.white, in: Circle())
                }
            }.padding(16).background(Color(hex: 0x333335), in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OrbTheme.canvas).foregroundStyle(ComposerPalette.text)
    }

    private func caption(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ComposerPalette.secondary)
            .padding(.leading, 2)
    }

    private func settings(_ effort: String) -> ComposerSettingsPopover {
        ComposerSettingsPopover(provider: provider, model: models[0], effort: effort, speed: "fast", models: models,
                                efforts: efforts, speeds: ["standard", "fast"], defaultEffort: "low", applying: false,
                                onModel: { _ in }, onEffort: { _ in }, onSpeed: { _ in })
    }
}

/// A discrete slider whose visual treatment follows the selected reasoning
/// effort. Arrow keys and VoiceOver use the same values as pointer dragging.
private struct ComposerEffortSlider: View {
    var provider = "codex"
    let selection: Int?
    let values: [String]
    let change: (Int, Bool) -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    private var index: Int { min(max(selection ?? 0, 0), values.count - 1) }
    private var fraction: CGFloat { CGFloat(index) / CGFloat(max(values.count - 1, 1)) }

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 15
            let travel = max(proxy.size.width - inset * 2, 1)
            let position = inset + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x444446))
                if selection != nil && fraction > 0 {
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0x364BC6), Color(hex: 0x8258EB), Color(hex: 0xBB88FF)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(position + inset, 30))
                        .overlay {
                            if fraction > 0.55 {
                                ZStack {
                                    Rectangle().fill(RadialGradient(colors: [Color(hex: 0xE5C4FF).opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 95))
                                    ComposerSliderStars()
                                }.clipShape(Capsule())
                            }
                        }
                }
                ForEach(values.indices, id: \.self) { step in
                    Circle().fill(Color.white.opacity(step <= index && selection != nil ? 0.45 : 0.26))
                        .frame(width: 4, height: 4)
                        .offset(x: inset + travel * CGFloat(step) / CGFloat(max(values.count - 1, 1)) - 2)
                }
                if selection != nil {
                    Circle().fill(.white).frame(width: 32, height: 32)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .offset(x: position - 16)
                }
            }
            .frame(height: 28)
            .overlay(Capsule().stroke(Color.white.opacity(focused ? 0.8 : 0.1), lineWidth: focused ? 2 : 0.75).padding(focused ? -4 : 0))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled else { return }
                    focused = true
                    change(step(at: value.location.x, travel: travel, inset: inset), false)
                }
                .onEnded { value in
                    guard enabled else { return }
                    change(step(at: value.location.x, travel: travel, inset: inset), true)
                })
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .onMoveCommand { direction in
                guard enabled else { return }
                switch direction {
                case .left, .down: adjust(-1)
                case .right, .up: adjust(1)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reasoning effort")
            .accessibilityValue(selection.map { ComposerLabels.effort(values[$0], provider: provider) } ?? "Not selected")
            .accessibilityHint("Use the arrow keys to change reasoning effort")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                switch direction {
                case .increment: adjust(1)
                case .decrement: adjust(-1)
                @unknown default: break
                }
            }
        }.frame(height: 32)
    }

    private func step(at x: CGFloat, travel: CGFloat, inset: CGFloat) -> Int {
        Int((min(max((x - inset) / travel, 0), 1) * CGFloat(values.count - 1)).rounded())
    }

    private func adjust(_ amount: Int) {
        let updated = selection == nil ? (amount > 0 ? 0 : values.count - 1) : min(max(index + amount, 0), values.count - 1)
        change(updated, true)
    }
}

/// Fixed stars keep the high-effort glow quiet and respect Reduce Motion.
private struct ComposerSliderStars: View {
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                for star in 0..<18 {
                    let x = CGFloat((star * 47 + 11) % 101) / 101 * size.width
                    let y = CGFloat((star * 19 + 7) % 29) / 29 * size.height
                    let diameter: CGFloat = star.isMultiple(of: 4) ? 2.5 : 1.5
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)), with: .color(.white.opacity(star.isMultiple(of: 3) ? 0.6 : 0.35)))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
