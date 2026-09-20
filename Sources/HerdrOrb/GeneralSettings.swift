import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var model: BubbleModel
    @AppStorage("automaticImagePreviews") private var automaticImages = true
    @State private var confirmingClear = false
    @State private var clearing = false
    @AppStorage("automaticallyScrollToNewMessages") private var automaticallyScroll = true
    @AppStorage("orbStyle") private var style = OrbStyle.nebula.rawValue
    @AppStorage("orbStatusDot") private var showStatus = true
    @AppStorage("orbHoverSound") private var hoverSound = true
    @AppStorage("showOrb") private var showOrb = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Orb").font(.system(size: 16, weight: .semibold))
                    Text("Your desktop shortcut to Herdr. Choose a look; changes apply immediately.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ForEach(OrbStyle.allCases) { option in
                        Button { style = option.rawValue } label: {
                            VStack(spacing: 6) {
                                OrbArtwork(style: option).frame(height: 92)
                                HStack(spacing: 5) {
                                    Text(option.title).fontWeight(.semibold)
                                    if style == option.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.75, green: 0.69, blue: 1)) }
                                }.font(.system(size: 12))
                                Text(option.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }.padding(.bottom, 14).frame(maxWidth: .infinity)
                                .background(.white.opacity(style == option.rawValue ? 0.09 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(style == option.rawValue ? 0.4 : 0.10), lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityLabel(option.title)
                            .accessibilityAddTraits(style == option.rawValue ? .isSelected : [])
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Show floating orb", isOn: $showOrb)
                    Text("You can always open Herdr from HERD in the menu bar.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("Show connection status", isOn: $showStatus)
                    Text("The dot tracks Herdr on this Mac, even when no terminal window is open.").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        legend("Online", color: .green)
                        legend("Connecting", color: .yellow)
                        legend("Offline", color: .red)
                    }
                    Toggle("Play a sound on hover", isOn: $hoverSound)
                }.font(.system(size: 12)).toggleStyle(.switch)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conversation").font(.system(size: 16, weight: .semibold))
                    Toggle("Automatically scroll to new messages", isOn: $automaticallyScroll).toggleStyle(.switch)
                    Text("Keep the latest reply in view. Scrolling up pauses this so you can read earlier messages; returning to the bottom resumes it. Turn it off to keep your reading position as replies arrive.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy & saved data").font(.system(size: 16, weight: .semibold))
                    Toggle("Save conversations and drafts on this Mac", isOn: Binding(get: { model.savingConversations }, set: { value in Task { await model.setSavingConversations(value) } }))
                    Text("Saved text is stored locally with private file permissions, without application encryption. Turning saving off also removes existing saved copies. Live sessions stay open.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Toggle("Automatically load image previews", isOn: $automaticImages)
                    Text("Image paths printed by agents may be read locally or downloaded over SSH from the originating Mac. Turn this off to load each image yourself.").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button("Clear saved conversations…") { confirmingClear = true }
                        Button("Clear downloaded previews") {
                            clearing = true
                            Task {
                                defer { clearing = false }
                                do { try await ArtifactFiles.shared.clear(); model.privacyNotice = "Downloaded previews cleared. Already-open previews remain visible until closed." }
                                catch { model.privacyNotice = error.localizedDescription }
                            }
                        }.disabled(clearing)
                    }.font(.system(size: 12))
                    if let notice = model.privacyNotice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Link("Privacy & uninstall guide", destination: URL(string: "https://github.com/andrewjedi/herdrorb/blob/main/docs/PRIVACY.md")!)
                }.toggleStyle(.switch)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("herdrorb").font(.system(size: 16, weight: .semibold))
                    Text("Version \((Bundle.main.object(forInfoDictionaryKey: "HerdrOrbReleaseVersion") ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")) as? String ?? "development") · Independent companion for Herdr")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button("Connection setup") { model.showingSetup = true }
                        Button("Copy diagnostics") { SetupActions.copy(model.diagnostics) }
                        Link("Source & releases", destination: URL(string: "https://github.com/andrewjedi/herdrorb")!)
                    }.font(.system(size: 12))
                    Text("MIT licensed · Copyright © 2026 Andrew Thompson. Includes SwiftTerm (MIT); see bundled Third-Party Notices.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Clear saved conversations?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) { }
            Button("Clear saved data", role: .destructive) { Task { await model.clearSavedConversations() } }
        } message: { Text("Removes saved conversation history and drafts from disk. Live Herdr sessions and current in-memory drafts stay open. New activity can be saved again while saving is enabled.") }
    }
    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(text) }.font(.system(size: 11))
    }
}
