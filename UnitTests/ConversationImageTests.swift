import XCTest
import AppKit
@testable import HerdrOrb

final class ConversationImageTests: XCTestCase {
    func testImageInstructionsSurviveFollowUpsWithoutAppearingInUserBubble() {
        for text in ["Generate an image of a planet.", "Make it blue.", "Explain this function.\n\nKeep it brief."] {
            let sent = ConversationImageInstructions.prompt(text, kind: "codex")
            let transcript = "› " + sent + "\n• Done."
            let messages = TerminalPresentation.messages(transcript, kind: "codex")
            XCTAssertEqual(messages.first?.text, text)
            XCTAssertEqual(messages.count, 2)
            XCTAssertTrue(sent.contains("native image generation tool"))
            XCTAssertEqual(ConversationImageInstructions.prompt(text, kind: "claude"), text)
            let indented = sent.components(separatedBy: "\n").joined(separator: "\n  ")
            let indentedMessages = TerminalPresentation.messages("› " + indented + "\n• Done.", kind: "codex")
            XCTAssertFalse(indentedMessages[0].text.contains(ConversationImageInstructions.start))
        }
    }

    func testRealCLIImageResponseProducesOneCardAndKeepsToolFilesHidden() {
        let path = "/Users/example/.codex/generated_images/session/exec-image.png"
        let transcript = """
        › Generate an image.
        • Generating your image.
        • Called image_gen.imagegen
        • Ran stat /tmp/unrelated.png
          └ /tmp/unrelated.png
        ─ Worked for 18s ───
        • Generated with the native tool.

        ![Small blue planet on a dark background](<\(path)>)
        """
        let messages = TerminalPresentation.messages(transcript, kind: "codex")
        XCTAssertEqual(messages.count, 2)
        for working in [false, true] {
            let response = TerminalPresentation.response(messages[1], kind: "codex", working: working)
            XCTAssertEqual(response.artifacts, [ArtifactReference(path: path)])
            XCTAssertTrue(response.artifacts[0].isImage)
            XCTAssertTrue(response.activity.contains("Called image_gen"))
        }
        let wrapped = "![Planet](</Users/example/.codex/generated_images/session/\n  exec-image.png>)"
        XCTAssertEqual(TerminalPresentation.artifacts(wrapped).map(\.path), [path])
        XCTAssertTrue(TerminalPresentation.artifacts("Image generation failed; no image was saved.").isEmpty)
    }

    @MainActor func testLocalImageThumbnailAndPreviewWindowLifecycle() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("planet.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let fetched = try await ArtifactFiles.shared.fetch(ArtifactReference(path: file.path), machine: .local, cwd: nil)
        let thumbnail = try await ArtifactThumbnail.load(fetched)
        XCTAssertEqual(thumbnail.width, 32)
        XCTAssertEqual(thumbnail.height, 16)

        ArtifactPreview.shared.show(fetched, source: "Test")
        try await Task.sleep(for: .milliseconds(100))
        let window = try XCTUnwrap(NSApp.windows.first { $0.representedURL == fetched })
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        ArtifactPreview.shared.show(fetched, source: "Test")
        XCTAssertEqual(NSApp.windows.filter { $0.representedURL == fetched && $0.isVisible }.count, 1)
        window.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(window.isVisible, "Escape must close the preview")
        ArtifactPreview.shared.show(fetched, source: "Test")
        try await Task.sleep(for: .milliseconds(100))
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.representedURL == fetched && $0.isVisible })
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: reopened.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        reopened.keyDown(with: space)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(reopened.isVisible, "Space must close the preview")
        try FileManager.default.removeItem(at: file)
        do {
            _ = try await ArtifactFiles.shared.fetch(ArtifactReference(path: file.path), machine: .local, cwd: nil)
            XCTFail("A deleted image must report an error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
    }
}
