import SwiftUI

struct ConversationWorkGroup: View {
    let item: ConversationTimelineItem
    let working: Bool
    let blocked: Bool
    let disclosures: Set<String>
    let find: String
    var machine: Machine = .local
    var cwd: String? = nil
    let toggle: (String) -> Void
    private var tools: [SessionMessage] { item.messages.filter { $0.activity != nil } }
    private var failures: [SessionMessage] { tools.filter { $0.activity?.status == .failed } }
    private var searchExpanded: Bool { !find.isEmpty && item.messages.contains { $0.text.localizedCaseInsensitiveContains(find) } }
    private var expanded: Bool { disclosures.contains(item.id) || searchExpanded }
    private var summary: String {
        let files = Set(tools.compactMap { $0.activity?.file })
        var pieces: [String] = []
        if !tools.isEmpty { pieces.append("\(tools.count) \(tools.count == 1 ? "action" : "actions")") }
        if !files.isEmpty { pieces.append("\(files.count) \(files.count == 1 ? "file" : "files")") }
        return pieces.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { toggle(item.id) } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
                    else { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 14) }
                    Text(working ? "Working" : blocked ? "Waiting for you" : item.duration ?? "Work details")
                        .font(.system(size: 12.5, weight: .medium))
                    if !summary.isEmpty { Text(summary).font(.system(size: 11)).foregroundStyle(OrbTheme.muted) }
                    Spacer(minLength: 0)
                    if !failures.isEmpty { Label("\(failures.count) failed", systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(OrbTheme.danger) }
                }.foregroundStyle(OrbTheme.secondary).frame(minHeight: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(searchExpanded)
                .accessibilityLabel((expanded ? "Collapse " : "Expand ") + "work details")
                .accessibilityValue(summary)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.messages) { message in
                        if let activity = message.activity {
                            workRow(message, activity: activity)
                        } else {
                            ConversationMarkdown(text: String(message.text.prefix(LongMessagePresentation.limit)))
                                .foregroundStyle(OrbTheme.secondary).padding(.vertical, 4).padding(.leading, 24)
                        }
                    }
                }.padding(.leading, 6)
                    .overlay(alignment: .leading) { Rectangle().fill(OrbTheme.line.opacity(0.65)).frame(width: 1).padding(.leading, 6) }
            } else if !failures.isEmpty {
                // A failed action never disappears behind the completed-work fold.
                ForEach(failures) { message in if let activity = message.activity { workRow(message, activity: activity) } }
            } else if working, let last = tools.last, let activity = last.activity {
                HStack(spacing: 9) {
                    Image(systemName: activity.symbol).frame(width: 16).font(.system(size: 11))
                    Text(activity.title).lineLimit(1).font(.system(size: 12))
                }.foregroundStyle(OrbTheme.muted).padding(.leading, 22)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func workRow(_ message: SessionMessage, activity: ConversationActivity) -> some View {
        let open = disclosures.contains(message.id) || (!find.isEmpty && message.text.localizedCaseInsensitiveContains(find))
        return VStack(alignment: .leading, spacing: 6) {
            Button { toggle(message.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: activity.status == .failed ? "exclamationmark.circle" : activity.symbol)
                        .font(.system(size: 11)).frame(width: 18)
                        .foregroundStyle(activity.status == .failed ? OrbTheme.danger : OrbTheme.muted)
                    Text(activity.title).font(.system(size: 12.5, design: activity.kind == .command ? .monospaced : .default))
                        .foregroundStyle(OrbTheme.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let additions = activity.additions, let deletions = activity.deletions {
                        Text("+\(additions)").foregroundStyle(OrbTheme.online)
                        Text("−\(deletions)").foregroundStyle(OrbTheme.danger)
                    } else if let exit = activity.exitCode {
                        Text("exit \(exit)").foregroundStyle(exit == 0 ? OrbTheme.muted : OrbTheme.danger)
                    } else if activity.status == .running && !working {
                        Text("No result saved").foregroundStyle(OrbTheme.muted)
                    }
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundStyle(OrbTheme.muted)
                }.font(.system(size: 10, design: .monospaced)).frame(minHeight: 27).contentShape(Rectangle())
            }.buttonStyle(.plain).help(activity.title)
                .accessibilityLabel((open ? "Hide " : "Show ") + activity.title)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if let steps = activity.steps, !steps.isEmpty {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                                    .foregroundStyle(step.status == "completed" ? OrbTheme.accent : OrbTheme.muted)
                                Text(step.title).textSelection(.enabled)
                            }.font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                        }.padding(.vertical, 4)
                    } else if let diff = activity.diff, !diff.isEmpty {
                        ConversationCodeBlock(source: String(diff.prefix(12_000)), language: "diff")
                        if diff.count > 12_000 {
                            Button("Open complete diff") { FullMessageWindow.show(diff, plainText: true) }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OrbTheme.accent)
                        }
                    } else if !activity.input.isEmpty {
                        ConversationCodeBlock(source: String(activity.input.prefix(12_000)), language: activity.language ?? (activity.kind == .command ? "bash" : "json"))
                        if activity.input.count > 12_000 {
                            Button("Open complete input") { FullMessageWindow.show(activity.input, plainText: true) }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OrbTheme.accent)
                        }
                    }
                    if let file = activity.file, activity.kind == .edit {
                        ArtifactCard(artifact: .init(path: file), machine: machine, cwd: cwd)
                    }
                    if let output = activity.output, !output.isEmpty {
                        if output.count < 180 && !output.contains("\n") {
                            Text(output).font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(activity.status == .failed ? OrbTheme.danger : OrbTheme.muted).textSelection(.enabled)
                                .padding(.vertical, 3)
                        } else {
                            Text("Output").font(.system(size: 10, weight: .medium)).foregroundStyle(OrbTheme.muted)
                            ConversationCodeBlock(source: String(output.prefix(8_000)), language: "text")
                        }
                        if output.count > 8_000 {
                            Button("Open complete output") { FullMessageWindow.show(output, plainText: true) }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OrbTheme.accent)
                        }
                    }
                }.padding(.leading, 27).padding(.bottom, 8)
            }
        }.padding(.leading, 7)
    }
}

struct ConversationApprovalCard: View {
    let approval: ConversationApproval
    let provider: String
    let busy: Bool
    let choose: (Int) -> Void
    let openTerminal: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised").foregroundStyle(OrbTheme.warning)
                Text("\(provider) needs permission").font(.system(size: 13, weight: .medium))
                if busy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Button(action: openTerminal) { Image(systemName: "terminal") }
                    .buttonStyle(.plain).foregroundStyle(OrbTheme.secondary).help("Open request in Terminal").accessibilityLabel("Open request in Terminal")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(approval.context).font(.system(size: 11, design: .monospaced)).lineSpacing(3)
                        .foregroundStyle(OrbTheme.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(OrbTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
                    ForEach(approval.choices) { choice in
                        Button { choose(choice.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(choice.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbTheme.muted).frame(width: 14)
                                Text(choice.title).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(OrbTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(choice.id == approval.selected ? OrbTheme.accent.opacity(0.5) : OrbTheme.line, lineWidth: 0.75))
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(busy).accessibilityLabel(choice.title)
                    }
                }
            }.frame(height: 220)
        }.padding(13).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OrbTheme.warning.opacity(0.25), lineWidth: 0.75))
            .foregroundStyle(OrbTheme.text)
    }
}
