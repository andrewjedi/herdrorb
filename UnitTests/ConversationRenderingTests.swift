import XCTest
import AppKit
@testable import HerdrOrb

final class ConversationRenderingTests: XCTestCase {
    func testGFMRetainsStructureAndInlineSemantics() throws {
        let source = """
        # Title

        ### Detail

        - [x] **Done**
          - Nested with `code`
        - [ ] Pending

        > A *quiet* quote and [link](https://example.com).

        | Name | Status |
        | :--- | ---: |
        | A \\| B | ~~old~~ |

        ~~~python
        print("hello")
        ~~~
        """
        let blocks = RichMarkdown.blocks(source)
        XCTAssertEqual(blocks.filter { $0.kind == .heading }.map(\.level), [1, 3])
        let items = blocks.filter { $0.kind == .listItem }
        XCTAssertEqual(items.map(\.checked), [true, false])
        XCTAssertTrue(items[0].children.contains { $0.kind == .listItem })
        XCTAssertTrue(items[0].children[0].runs.contains { $0.bold && $0.text == "Done" })
        let quote = try XCTUnwrap(blocks.first { $0.kind == .quote })
        XCTAssertTrue(quote.children[0].runs.contains { $0.link == "https://example.com" })
        let table = try XCTUnwrap(blocks.first { $0.kind == .table })
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[1][0].map(\.text).joined(), "A | B")
        XCTAssertEqual(table.alignments, [-1, 1])
        XCTAssertTrue(table.rows[1][1].contains { $0.strike })
        let code = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(code.language, "python")
        XCTAssertEqual(code.text, "print(\"hello\")")
    }
    func testIncompleteFenceAndInertHTMLPreserveContent() {
        let blocks = RichMarkdown.blocks("```swift\nlet answer = 42")
        XCTAssertEqual(blocks.last?.kind, .code)
        XCTAssertEqual(blocks.last?.text, "let answer = 42")
        let html = RichMarkdown.blocks("<script>alert('hello')</script>")
        XCTAssertEqual(html.first?.runs.map(\.text).joined(), "<script>alert('hello')</script>\n")
    }
    func testLanguageGrammarsPreserveEverySourceCharacter() {
        let samples = [
            ("swift", "// A comment\nlet value = \"<& hello>\"\nreturn 42"),
            ("json", "{\"name\": \"A & B\", \"count\": 12, \"ok\": true}"),
            ("python", "def hello():\n    return 'hello' # comment"),
            ("bash", "printf '%s\\n' \"$HOME\" && echo done"),
            ("diff", "--- before\n+++ after\n-old\n+new"),
            ("unknown-language", "anything <script> '& &amp; 🌌\n")
        ]
        for (language, source) in samples {
            let tokens = SyntaxHighlight.tokens(source, language: language)
            XCTAssertEqual(tokens.map(\.text).joined(), source, language)
            if language != "unknown-language" { XCTAssertTrue(tokens.contains { !$0.scope.isEmpty }, language) }
        }
        let swift = SyntaxHighlight.tokens(samples[0].1, language: "swift")
        XCTAssertTrue(swift.contains { $0.scope.contains("comment") })
        XCTAssertTrue(swift.contains { $0.scope.contains("string") })
        XCTAssertTrue(swift.contains { $0.scope.contains("number") })
    }
    func testBothProvidersFoldNarrationAndToolsAndKeepFinalAnswer() {
        for provider in ["claude", "codex"] {
            let user = SessionMessage(id: "user", fromUser: true, text: "Review", source: provider)
            let narration = SessionMessage(id: "progress", fromUser: false, text: "Checking", phase: provider == "codex" ? "commentary" : nil, source: provider)
            let tool = SessionMessage(id: "call", fromUser: false, text: "Command", source: provider,
                                      activity: .init(kind: .command, title: "swift test", input: "swift test", status: .failed))
            let answer = SessionMessage(id: "answer", fromUser: false, text: "One check needs attention.", phase: "final_answer", source: provider)
            let items = ConversationTimeline.items([user, narration, tool, answer], provider: provider, working: false)
            XCTAssertEqual(items.count, 3)
            XCTAssertEqual(items[1].kind, .work)
            XCTAssertEqual(items[1].messages.map(\.id), ["progress", "call"])
            XCTAssertEqual(items[2].messages.first?.text, answer.text)
            XCTAssertEqual(items[1].messages.last?.activity?.status, .failed)
        }
    }
    func testFinalAnswerIsNeverFoldedAndTurnBoundariesStayDistinct() {
        let user = SessionMessage(id: "u", fromUser: true, text: "Hello", source: "codex")
        let answer = SessionMessage(id: "a", fromUser: false, text: "Answer", phase: "final_answer", source: "codex")
        let progress = SessionMessage(id: "p", fromUser: false, text: "Later work", phase: "commentary", source: "codex")
        var next = user; next.id = "u2"
        var nextAnswer = answer; nextAnswer.id = "a2"
        let items = ConversationTimeline.items([user, answer, progress, next, nextAnswer], provider: "codex", working: true)
        XCTAssertEqual(items.map(\.id), ["message:u", "message:a", "work:p", "message:u2", "message:a2"])
    }
    @MainActor func testComposerMeasuresSoftWrappedLinesAndCapsHeight() async {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 38))
        editor.font = .systemFont(ofSize: 14.5)
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
        editor.string = String(repeating: "A prompt that wraps naturally. ", count: 8)
        let measured = expectation(description: "Measured text layout")
        editor.heightChanged = { height in
            XCTAssertGreaterThan(height, 38)
            XCTAssertLessThanOrEqual(height, 132)
            measured.fulfill()
        }
        editor.measureContent()
        await fulfillment(of: [measured], timeout: 2)
    }
}
