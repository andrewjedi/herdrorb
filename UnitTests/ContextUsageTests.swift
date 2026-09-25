import XCTest
@testable import HerdrOrb

final class ContextUsageTests: XCTestCase {
    func testProviderFootersAndDirection() {
        XCTAssertEqual(ContextUsage.footer(in: "›\n gpt-5 · 72% context left · main", provider: "codex")?.usedPercent, 28)
        XCTAssertEqual(ContextUsage.footer(in: "›\n 100% context left", provider: "codex")?.usedPercent, 0)
        XCTAssertEqual(ContextUsage.footer(in: "❯\n Context: 25.5% used", provider: "claude")?.usedPercent, 25.5)
        XCTAssertEqual(ContextUsage.footer(in: "❯\n Opus | 30% context | main", provider: "claude")?.usedPercent, 30)
        XCTAssertEqual(ContextUsage.footer(in: "❯\n Context: 20% remaining", provider: "claude")?.usedPercent, 80)
    }
    func testMissingInvalidAndUnrelatedPercentagesStayUnknown() {
        for raw in ["", "• 72% context left", "›\n 20% weekly limit", "›\n 101% context left", "›\n -5% context left", "```\n›\n 20% context left\n```", "› Explain 20% context left"] {
            XCTAssertNil(ContextUsage.footer(in: raw, provider: "codex"), raw)
        }
        XCTAssertNil(ContextUsage.footer(in: "❯\n 25% used", provider: "codex"))
        XCTAssertNil(ContextUsage.footer(in: "❯\n 25% used | context unavailable", provider: "claude"))
        XCTAssertNil(ContextUsage.footer(in: "›\n 72% context left", provider: nil))
    }
    func testCompactionAndMissingFooterDoNotRetainPriorReading() {
        XCTAssertEqual(ContextUsage.footer(in: "›\n 10% context left", provider: "codex")?.usedPercent, 90)
        XCTAssertEqual(ContextUsage.footer(in: "›\n 80% context left", provider: "codex")?.usedPercent, 20)
        XCTAssertNil(ContextUsage.footer(in: "Approval required", provider: "codex"))
    }
    func testRepeatedLineOverlapAndEvolvingTail() {
        let old = "older\n" + Array(repeating: "repeated", count: 8000).joined(separator: "\n")
        let live = Array(repeating: "repeated", count: 7999).joined(separator: "\n") + "\nnew"
        XCTAssertEqual(TerminalPresentation.mergeHistory(old, live: live), old + "\nnew")
        XCTAssertEqual(TerminalPresentation.mergeHistory("a\nb\nc\nold", live: "a\nb\nc\nnew"), "a\nb\nc\nnew")
        XCTAssertEqual(TerminalPresentation.mergeHistory("a\nb", live: "x\ny"), "a\nb\n\n— Live terminal view —\n\nx\ny")
    }
}
