import AppKit

private final class PasteCheckEditor: ComposerTextView {
    let testPasteboard = NSPasteboard.withUniqueName()
    override func pasteAsPlainText(_ sender: Any?) {
        _ = readSelection(from: testPasteboard, type: .string)
    }
}

@main struct ConversationChecks {
    @MainActor static func main() async throws {
        let fixedID = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        assert(HerdrClient.sessionName(kind: "codex", id: fixedID) == "bubble-codex-abcdef12")
        for kind in ["codex", "claude"] {
            for _ in 0..<100 {
                let name = HerdrClient.sessionName(kind: kind)
                assert(name.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil)
            }
        }
        print("Herdr session-name validation passed for Codex and Claude")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = Agent(terminal_id: "terminal-1", agent: "codex", agent_status: "idle", pane_id: "pane-1", machineID: "machine-a")
        let suite = "HerdrOrbTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let names = SessionNames(defaults: preferences)
        assert(names.name(for: agent) == "1")
        assert(names.name(for: agent) == "1")
        var second = agent
        second.machineID = "machine-b"
        assert(names.name(for: second) == "2")
        names.rename(agent, to: "  Website work  ")
        names.rename(agent, to: "   ")
        let restoredNames = SessionNames(defaults: preferences)
        assert(restoredNames.name(for: agent) == "Website work")
        assert(restoredNames.name(for: second) == "2")
        second.terminal_id = "another-terminal"
        assert(restoredNames.name(for: second) == "3")
        print("Session numbering, renaming, machine isolation and persistence passed")
        let cache = ConversationCache(directory: directory)
        let missing = await cache.snapshot(for: agent)
        assert(missing == nil)
        await cache.save("› Hello\n\nA saved reply", for: agent)
        await cache.flush()
        let reopened = ConversationCache(directory: directory)
        let restored = await reopened.snapshot(for: agent)
        assert(restored?.text == "› Hello\n\nA saved reply")
        var other = agent
        other.machineID = "grogu"
        let differentMachine = await reopened.snapshot(for: other)
        assert(differentMachine == nil)
        other = agent; other.terminal_id = "new-terminal"
        let differentTerminal = await reopened.snapshot(for: other)
        assert(differentTerminal == nil)
        await reopened.save(String(repeating: "x", count: 250_010), for: agent)
        await reopened.flush()
        let limited = await reopened.snapshot(for: agent)
        assert(limited?.text.isEmpty == true, "Oversized raw diagnostics must not be sliced into a fake message")
        let writes = await reopened.writes
        await reopened.save(String(repeating: "x", count: 250_010), for: agent)
        await reopened.flush()
        let sameWrites = await reopened.writes
        assert(writes == sameWrites, "Unchanged content must not rewrite the cache")
        for i in 0..<45 {
            other.terminal_id = "terminal-\(i + 2)"
            await reopened.save("Reply \(i)", for: other)
            await reopened.flush()
        }
        let expired = await ConversationCache(directory: directory).snapshot(for: agent)
        assert(expired == nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        assert(files.count <= 40)
        for file in files { try Data("invalid JSON".utf8).write(to: file) }
        let corrupt = await ConversationCache(directory: directory).snapshot(for: other)
        assert(corrupt == nil)

        _ = NSApplication.shared
        let editor = PasteCheckEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        var sends = 0
        editor.send = { sends += 1 }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
        }
        editor.string = "Hello"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.keyDown(with: key(36))
        assert(sends == 1 && editor.string == "Hello")
        editor.keyDown(with: key(36, .shift))
        assert(sends == 1 && editor.string == "Hello\n")
        editor.keyDown(with: key(76))
        assert(sends == 2)
        editor.testPasteboard.setString("Dictated first line\nSecond line", forType: .string)
        defer { editor.testPasteboard.releaseGlobally() }
        editor.selectAll(nil)
        let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        assert(editor.performKeyEquivalent(with: paste))
        assert(editor.string == "Dictated first line\nSecond line")
        assert(sends == 2, "Pasting multiline text must not send it")
        print("Clipboard shortcut and multiline paste passed")
        print("Cache persistence, session isolation, bounds, corruption recovery, Return, Shift-Return, and keypad Enter passed")
    }
}
