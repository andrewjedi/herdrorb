import AppKit

@main struct ArtifactChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("A report.txt")
        try Data("A local artifact".utf8).write(to: file)
        let url = try await ArtifactFiles.shared.fetch(ArtifactReference(path: "A report.txt"), machine: .local, cwd: directory.path)
        assert(url == file)
        let text = try String(contentsOf: url, encoding: .utf8)
        assert(text == "A local artifact")
        do {
            _ = try await ArtifactFiles.shared.fetch(ArtifactReference(path: "/missing/file.pdf"), machine: .local, cwd: nil)
            assertionFailure("Missing artifact must report failure")
        } catch {}
        assert(MachineTransport.quote("/tmp/a'b.png") == "'/tmp/a'\\''b.png'")
        let markdown = directory.appendingPathComponent("notes.md")
        try Data("# Notes\n\nActual document contents".utf8).write(to: markdown)
        let document = try ArtifactDocumentText.load(markdown)
        assert(document == "# Notes\n\nActual document contents")
        try Data(repeating: 65, count: 512_001).write(to: markdown)
        let oversized = try ArtifactDocumentText.load(markdown)
        assert(oversized == nil, "Oversized Markdown must retain Quick Look")
        try Data([0xff, 0xfe, 0x80]).write(to: markdown)
        let invalid = try ArtifactDocumentText.load(markdown)
        assert(invalid == nil, "Invalid UTF-8 must retain Quick Look")
        print("Local artifact retrieval, paths, missing-file recovery, quoting, and bounded Markdown loading passed")
        if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--remote" {
            let machines = try await HerdrClient.machines()
            let machine = machines.first { $0.id == CommandLine.arguments[2] }!
            let reference = ArtifactReference(path: CommandLine.arguments[3])
            let cwd = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
            let fetched = try await ArtifactFiles.shared.fetch(reference, machine: machine, cwd: cwd)
            let again = try await ArtifactFiles.shared.fetch(reference, machine: machine, cwd: cwd)
            assert(fetched == again, "Repeated inline images must reuse their download")
            let thumbnail = try await ArtifactThumbnail.load(fetched)
            assert(thumbnail.width > 0 && thumbnail.height > 0 && max(thumbnail.width, thumbnail.height) <= 1200)
            let data = try Data(contentsOf: fetched)
            assert(NSImage(data: data) != nil)
            print("Remote image artifact fetched and decoded: \(data.count) bytes")
        }
    }
}
