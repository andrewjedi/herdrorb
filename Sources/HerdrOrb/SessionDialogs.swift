import SwiftUI

struct SessionRenameSheet: View {
    @Binding var name: String
    var cancel: () -> Void
    var rename: () -> Void
    var body: some View {
        OrbSheet(width: 470, inset: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: "pencil").font(.system(size: 26, weight: .light))
                        .frame(width: 48, height: 48).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(OrbTheme.controlEdge, lineWidth: 0.75))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rename session").font(.system(size: 17, weight: .semibold))
                        Text("Session name").font(.system(size: 13)).foregroundStyle(OrbTheme.secondary)
                        OrbField(placeholder: "Session name", text: $name, label: "Session name", onSubmit: { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rename() } })
                    }
                }
                OrbRule()
                HStack {
                    Spacer()
                    Button(action: cancel) { Text("Cancel").frame(minWidth: 72) }.buttonStyle(OrbButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(action: rename) { Text("Rename").frame(minWidth: 90) }.buttonStyle(OrbButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct SessionDeleteSheet: View {
    let name: String
    var cancel: () -> Void
    var delete: () -> Void
    var body: some View {
        OrbConfirmation(title: "Delete this session?", detail: "This closes the terminal for \(name) and ends any running command.", actionTitle: "Delete session", symbol: "exclamationmark.triangle", cancel: cancel, confirm: delete)
    }
}

struct OrbConfirmation: View {
    let title: String
    let detail: String
    let actionTitle: String
    var symbol = "trash"
    var cancel: () -> Void
    var confirm: () -> Void
    var body: some View {
        OrbSheet(width: 470, inset: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(OrbTheme.danger)
                        .frame(width: 48, height: 48).background(OrbTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 17, weight: .semibold))
                        Text(detail).font(.system(size: 12)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(1)
                    }
                }
                OrbRule()
                HStack {
                    Spacer()
                    Button(action: cancel) { Text("Cancel").frame(minWidth: 72) }.buttonStyle(OrbButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(role: .destructive, action: confirm) { Text(actionTitle).frame(minWidth: 100) }.buttonStyle(OrbButtonStyle(kind: .destructive))
                }
            }
        }
    }
}
