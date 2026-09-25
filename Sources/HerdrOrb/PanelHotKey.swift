import AppKit
import Carbon
import SwiftUI

/// RegisterEventHotKey works across applications without keyboard-monitoring permission.
@MainActor final class PanelHotKey: ObservableObject {
    static let shared = PanelHotKey()
    @Published var error: String?
    @Published var recording = false
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var preferences: UserDefaults?
    private var installed = ""
    private var localMonitor: Any?

    func configure(_ preferences: UserDefaults) {
        self.preferences = preferences
        preferences.register(defaults: ["panelHotKeyCode": Int(kVK_ANSI_D), "panelHotKeyModifiers": Int(cmdKey | shiftKey), "panelHotKeyLabel": "⇧⌘D"])
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<PanelHotKey>.fromOpaque(context).takeUnretainedValue().action?()
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, !self.recording, let preferences = self.preferences else { return event }
                var flags = 0
                if event.modifierFlags.contains(.command) { flags |= cmdKey }
                if event.modifierFlags.contains(.control) { flags |= controlKey }
                if event.modifierFlags.contains(.shift) { flags |= shiftKey }
                if event.modifierFlags.contains(.option) { flags |= optionKey }
                guard Int(event.keyCode) == preferences.integer(forKey: "panelHotKeyCode"), flags == preferences.integer(forKey: "panelHotKeyModifiers") else { return event }
                if !event.isARepeat { self.action?() }
                return nil
            }
        }
        refresh()
    }
    func refresh() {
        guard let preferences else { return }
        let code = preferences.integer(forKey: "panelHotKeyCode")
        let modifiers = preferences.integer(forKey: "panelHotKeyModifiers")
        let signature = "\(code):\(modifiers):\(recording)"
        guard signature != installed else { return }
        installed = signature
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        error = nil
        guard !recording else { return }
        let status = RegisterEventHotKey(UInt32(code), UInt32(modifiers), EventHotKeyID(signature: 0x484F5242, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { error = "This shortcut is unavailable. Record a different shortcut." }
    }
    func record(_ value: Bool) { recording = value; refresh() }
}

struct PanelShortcutSetting: View {
    @ObservedObject private var hotKey = PanelHotKey.shared
    @AppStorage("panelHotKeyLabel") private var label = "⇧⌘D"
    @State private var monitor: Any?
    @State private var hint: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Toggle panel").font(.system(size: 15))
                Spacer()
                Button(hotKey.recording ? "Press shortcut…" : label) { beginRecording() }
                    .buttonStyle(OrbButtonStyle()).accessibilityLabel("Record panel keyboard shortcut")
                Button("Reset") {
                    stopRecording()
                    let preferences = AppPreferences.current
                    preferences.set(Int(kVK_ANSI_D), forKey: "panelHotKeyCode")
                    preferences.set(Int(cmdKey | shiftKey), forKey: "panelHotKeyModifiers")
                    label = "⇧⌘D"; hotKey.refresh()
                }.buttonStyle(.plain).foregroundStyle(OrbTheme.secondary)
            }
            Text(hotKey.error ?? hint ?? "Open or close the panel from any app. Click the shortcut to change it.")
                .font(.system(size: 13)).foregroundStyle(hotKey.error == nil ? OrbTheme.secondary : OrbTheme.warning)
        }.onDisappear { stopRecording() }
    }
    private func beginRecording() {
        guard monitor == nil else { return }
        hint = "Press a key with Command or Control. Escape cancels."
        hotKey.record(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control), !event.isARepeat else { return nil }
            var modifiers = 0
            if flags.contains(.command) { modifiers |= cmdKey }
            if flags.contains(.control) { modifiers |= controlKey }
            if flags.contains(.shift) { modifiers |= shiftKey }
            if flags.contains(.option) { modifiers |= optionKey }
            let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            let preferences = AppPreferences.current
            preferences.set(Int(event.keyCode), forKey: "panelHotKeyCode")
            preferences.set(modifiers, forKey: "panelHotKeyModifiers")
            label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
            stopRecording()
            return nil
        }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        hint = nil
        hotKey.record(false)
    }
}
