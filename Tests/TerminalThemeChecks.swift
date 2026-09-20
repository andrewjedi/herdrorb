import Foundation
@main struct TerminalThemeChecks {
    static func main() {
        let esc = "\u{1b}["
        var filter = TerminalThemeFilter()
        func apply(_ text: String) -> String { String(decoding: filter.process(Array(text.utf8)[...]), as: UTF8.self) }
        assert(apply(esc + "48;2;244;244;244mhey") == esc + "48;2;43;46;57mhey")
        assert(apply(esc + "38;2;47;107;48m") == esc + "38;2;47;107;48m")
        assert(apply(esc + "48;5;255m") == esc + "48;2;43;46;57m")
        assert(apply(esc + "48;2;200;30;30m") == esc + "48;2;200;30;30m")
        assert(apply(esc + "48;2;244;").isEmpty)
        assert(apply("244;244m✓") == esc + "48;2;43;46;57m✓")
        assert(apply(esc + "0m" + esc + "2J") == esc + "0m" + esc + "2J")
        assert(apply("\u{1b}]11;?\u{7}") == "\u{1b}]11;?\u{7}")
        print("Terminal theme: light backgrounds, semantic colors, foreground RGB, split sequences and controls passed")
    }
}
