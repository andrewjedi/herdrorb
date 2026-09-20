import Foundation

@main struct TerminalInputChecks {
    static func main() {
        var buffer = TerminalInputBuffer(initial: "/")
        assert(buffer.input(Array("mo".utf8)[...]).isEmpty)
        assert(buffer.output(Array("Connecting…\u{1b}[?200".utf8)[...]) == nil)
        assert(buffer.input(Array("del".utf8)[...]).isEmpty)
        let first = buffer.output(Array("4h".utf8)[...])!
        assert(String(decoding: first, as: UTF8.self) == "/model")
        assert(buffer.ready)
        assert(buffer.output(Array("\u{1b}[?2004h".utf8)[...]) == nil, "Seed must be sent only once")
        assert(buffer.input([13][...]) == [13], "Enter must reach the CLI unchanged")
        assert(buffer.input([27, 91, 65][...]) == [27, 91, 65], "Navigation keys must reach the CLI unchanged")
        var edited = TerminalInputBuffer(initial: "/")
        edited.replaceInitial("/help")
        assert(edited.output(Array("\u{1b}[?2004h".utf8)[...]) == Array("/help".utf8))
        edited.replaceInitial("/model")
        assert(edited.output(Array("\u{1b}[?2004h".utf8)[...]) == nil)
        print("Slash handoff: fast typing, split readiness marker, one-time delivery and unchanged CLI keys passed")
    }
}
