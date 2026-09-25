import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var model: BubbleModel
    var showPrivacyFirst = false
    @AppStorage("automaticImagePreviews") private var automaticImages = true
    @State private var confirmingClear = false
    @State private var clearing = false
    @AppStorage("automaticallyScrollToNewMessages") private var automaticallyScroll = true
    @AppStorage("orbStyle") private var style = OrbStyle.nebula.rawValue
    @AppStorage("orbStatusDot") private var showStatus = false
    @AppStorage("orbHoverSound") private var hoverSound = true
    @AppStorage("panelGalaxySound") private var galaxySound = true
    @AppStorage("showOrb") private var showOrb = true

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !(showPrivacyFirst && model.isDemo) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Orb").font(.system(size: 20, weight: .semibold))
                            Text("Your desktop shortcut to Herdr. Changes apply immediately.").font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
                        }.padding(.bottom, -4)
                        HStack(spacing: 10) {
                            ForEach(OrbStyle.allCases) { option in
                                Button { style = option.rawValue } label: {
                                    VStack(spacing: 5) {
                                        OrbArtwork(style: option).frame(height: 110)
                                        Text(option.title).font(.system(size: 14, weight: .semibold))
                                        Text(option.detail).font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                                    }.padding(.bottom, 12).frame(maxWidth: .infinity)
                                        .background(OrbTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style == option.rawValue ? OrbTheme.accentLight : OrbTheme.line, lineWidth: style == option.rawValue ? 1.2 : 0.8))
                                        .overlay(alignment: .topTrailing) {
                                            if style == option.rawValue { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(OrbTheme.canvas, OrbTheme.accentLight).font(.system(size: 20)).padding(10) }
                                        }
                                }.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(style == option.rawValue ? .isSelected : [])
                            }
                        }
                        VStack(spacing: 9) {
                            OrbRule()
                            setting("Show floating orb", detail: "Open herdrorb from the menu bar at any time.", value: $showOrb)
                            OrbRule()
                            VStack(alignment: .leading, spacing: 5) {
                                setting("Show connection status", value: $showStatus)
                                HStack(spacing: 20) {
                                    OrbStatus(text: "Online", color: OrbTheme.online)
                                    OrbStatus(text: "Connecting", color: OrbTheme.warning)
                                    OrbStatus(text: "Offline", color: OrbTheme.danger)
                                }
                            }
                            OrbRule()
                            PanelShortcutSetting()
                            OrbRule()
                            setting("Play galaxy sound when opening and closing", value: $galaxySound)
                            OrbRule()
                            setting("Play a sound on hover", value: $hoverSound)
                            OrbRule()
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Conversation").font(OrbTheme.titleFont)
                            setting("Automatically scroll to new messages", detail: "Scrolling up pauses following. Returning to the bottom resumes it.", value: $automaticallyScroll)
                        }
                        OrbRule()
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Privacy & saved data").font(OrbTheme.titleFont)
                        setting("Save conversations and drafts on this Mac", detail: "Saved text is stored locally with private file permissions, without application encryption. Turning saving off also removes existing saved copies. Live sessions stay open.", value: Binding(get: { model.savingConversations }, set: { value in Task { await model.setSavingConversations(value) } }))
                        setting("Automatically load image previews", detail: "Image paths printed by agents may be read locally or downloaded over SSH from the originating Mac. Turn this off to load each image yourself.", value: $automaticImages)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { privacyActions }.fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 10) { privacyActions }
                        }.buttonStyle(OrbButtonStyle())
                        if let notice = model.privacyNotice { Text(notice).font(.system(size: 12)).foregroundStyle(OrbTheme.secondary) }
                        Link("Privacy & uninstall guide ↗", destination: URL(string: "https://github.com/andrewjedi/herdrorb/blob/main/docs/PRIVACY.md")!).foregroundStyle(OrbTheme.accent)
                    }.id("privacy")
                    OrbRule().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 15) {
                        Text("herdrorb").font(OrbTheme.titleFont)
                        Text("Independent companion for Herdr").font(.system(size: 14)).foregroundStyle(OrbTheme.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { aboutActions }
                            VStack(alignment: .leading, spacing: 10) { aboutActions }
                        }.buttonStyle(OrbButtonStyle()).font(.system(size: 13))
                        OrbRule().padding(.top, 4)
                        Text("MIT licensed · Copyright © 2026 Andrew Thompson. Includes SwiftTerm (MIT); see bundled Third-Party Notices.")
                            .font(.system(size: 11)).foregroundStyle(OrbTheme.secondary)
                        Text("Version \((Bundle.main.object(forInfoDictionaryKey: "HerdrOrbReleaseVersion") ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")) as? String ?? "development")")
                            .font(.system(size: 11)).foregroundStyle(OrbTheme.muted)
                    }
                }.padding(.horizontal, 24).padding(.top, showPrivacyFirst ? 24 : 20).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if showPrivacyFirst && !model.isDemo { scroll.scrollTo("privacy", anchor: .top) } }
        }
        .sheet(isPresented: $confirmingClear) {
            OrbConfirmation(title: "Clear saved conversations?", detail: "Removes saved conversation history and drafts from disk. Live Herdr sessions and current in-memory drafts stay open. New activity can be saved again while saving is enabled.", actionTitle: "Clear saved data", cancel: { confirmingClear = false }) {
                confirmingClear = false
                Task { await model.clearSavedConversations() }
            }
        }
    }
    @ViewBuilder private var privacyActions: some View {
        Button { confirmingClear = true } label: { Label("Clear saved conversations…", systemImage: "trash") }
        Button {
            clearing = true
            Task {
                defer { clearing = false }
                do { try await ArtifactFiles.shared.clear(); model.privacyNotice = "Downloaded previews cleared. Already-open previews remain visible until closed." }
                catch { model.privacyNotice = error.localizedDescription }
            }
        } label: { Label("Clear downloaded previews", systemImage: "trash") }.disabled(clearing)
    }
    @ViewBuilder private var aboutActions: some View {
        Button { model.showingSetup = true } label: {
            Label("Connection setup", systemImage: "powerplug").frame(minWidth: 140, maxWidth: .infinity)
        }
        Button { SetupActions.copy(model.diagnostics) } label: {
            Label("Copy diagnostics", systemImage: "doc").frame(minWidth: 140, maxWidth: .infinity)
        }
        Link(destination: URL(string: "https://github.com/andrewjedi/herdrorb")!) {
            Label("Source & releases", systemImage: "arrow.up.right.square").frame(minWidth: 140, maxWidth: .infinity)
        }
    }
    private func setting(_ title: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: value) { Text(title).font(.system(size: 15)) }
                .toggleStyle(OrbSwitchStyle())
            if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(OrbTheme.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
