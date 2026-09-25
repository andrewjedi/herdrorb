import AppKit
import SwiftUI
import QuickLookUI
import ImageIO

actor ArtifactFiles {
    static let shared = ArtifactFiles()
    private var downloads: [String: (url: URL, date: Date)] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var generation = 0
    private var clearing = false
    private let cacheDirectory: URL = {
        if AppPreferences.isDemo || AppPreferences.isSetupPreview {
            return FileManager.default.temporaryDirectory.appendingPathComponent("herdrorb-preview-artifacts-" + UUID().uuidString)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("herdrorb/Artifacts")
    }()
    func clear() async throws {
        guard !clearing else { return }
        clearing = true; defer { clearing = false }
        generation += 1
        let tasks = Array(inFlight.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
        inFlight.removeAll(); downloads.removeAll()
        if FileManager.default.fileExists(atPath: cacheDirectory.path) { try FileManager.default.removeItem(at: cacheDirectory) }
    }
    static func resolvedPath(_ reference: ArtifactReference, cwd: String?) throws -> String {
        let path = reference.path
        guard !path.contains("\0"), !path.contains("\n") else { throw BridgeError.message("Invalid file path") }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        guard let cwd, cwd.hasPrefix("/"), !path.hasPrefix("~") else { throw BridgeError.message("This file needs an absolute path from Codex.") }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
    func fetch(_ reference: ArtifactReference, machine: Machine, cwd: String?) async throws -> URL {
        guard !clearing else { throw BridgeError.message("Preview cache is being cleared. Try again shortly.") }
        let path = try Self.resolvedPath(reference, cwd: cwd)
        if machine.id == "local" {
            guard FileManager.default.isReadableFile(atPath: path) else { throw BridgeError.message("This file is no longer available on this Mac.") }
            return URL(fileURLWithPath: path)
        }
        let key = machine.identity + "|" + path
        if let saved = downloads[key], Date().timeIntervalSince(saved.date) < 60, FileManager.default.fileExists(atPath: saved.url.path) { return saved.url }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await self.download(path, machine: machine) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        downloads = downloads.filter { FileManager.default.fileExists(atPath: $0.value.url.path) }
        downloads[key] = (url, Date())
        return url
    }
    private func download(_ path: String, machine: Machine) async throws -> URL {
        let stamp = generation
        let target = try ConnectionCommands.target(machine)
        let quoted = MachineTransport.quote(path)
        // Only read a detected file. Never execute artifact content.
        let command = "test -f \(quoted) || { echo 'File not found on this Mac' >&2; exit 1; }; size=$(/usr/bin/stat -f %z \(quoted)) || exit 1; test \"$size\" -le 15000000 || { echo 'Preview supports remote files up to 15 MB' >&2; exit 1; }; exec /bin/cat < \(quoted)"
        let data = try await ProcessRunner.run("/usr/bin/ssh", MachineTransport.sshOptions + [target, command], timeout: 30)
        try Task.checkCancellation()
        guard stamp == generation else { throw CancellationError() }
        let root = cacheDirectory
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let old = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for expired in old.dropFirst(20) { try? FileManager.default.removeItem(at: expired) }
        return url
    }
}

enum ArtifactThumbnail {
    static func load(_ url: URL) async throws -> CGImage {
        try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary)
            else { throw BridgeError.message("This file could not be decoded as an image.") }
            return image
        }.value
    }
}

struct ArtifactCard: View {
    let artifact: ArtifactReference
    let machine: Machine
    let cwd: String?
    @State private var loading = false
    @State private var error: String?
    @State private var thumbnail: NSImage?
    @State private var imageError: String?
    @State private var imageLoadID: UUID?
    @AppStorage("automaticImagePreviews") private var automaticImages = true
    @State private var imageLoading = false
    private var imageTaskID: String { [machine.identity, cwd ?? "", artifact.path, String(automaticImages)].joined(separator: "|") }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if artifact.isImage { imagePreview }
            HStack(spacing: 10) {
                Image(systemName: artifact.isImage ? "photo" : "doc.richtext").font(.system(size: 20)).foregroundStyle(OrbTheme.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.isImage && artifact.path.contains("/generated_images/") ? "Generated image" : artifact.name)
                        .font(.system(size: 14, weight: .medium)).lineLimit(2)
                    Text(machine.label).font(.system(size: 12)).foregroundStyle(OrbTheme.secondary)
                }
                Spacer(minLength: 6)
                Button(action: openPreview) { Text(loading ? "Loading…" : "Preview").font(.system(size: 11)) }
                    .disabled(loading).buttonStyle(OrbButtonStyle(compact: true))
                    .help(machine.id == "local" ? "Preview this file" : "Fetch this file from \(machine.label) and preview it here")
            }
        }.padding(12).background(OrbTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(OrbTheme.controlEdge, lineWidth: 0.8))
            .help(artifact.path)
            .task(id: imageTaskID) {
                imageLoadID = nil; imageLoading = false; thumbnail = nil; imageError = nil
                if artifact.isImage && automaticImages { await loadImage() }
            }
            .sheet(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                OrbSheet(width: 470) {
                    ArtifactErrorView(title: "Couldn’t preview this file", detail: error ?? "", symbol: "doc", actionTitle: "OK", inlineAction: true) { error = nil }
                }
            }
    }
    private var imagePreview: some View {
                ZStack {
                    OrbTheme.canvas
                    if let thumbnail {
                        Button(action: openPreview) {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(loading)
                            .accessibilityLabel("Preview image: \(artifact.name)")
                            .accessibilityHint("Open a larger preview with full-screen controls")
                            .help("Click to enlarge · Full Screen and Open in Preview available")
                    } else if let imageError {
                        ArtifactErrorView(title: "Couldn’t load image", detail: imageError, symbol: "photo", actionTitle: "Retry image") {
                            Task { await loadImage() }
                        }.padding(20)
                    } else if imageLoading { ProgressView("Loading image…").controlSize(.small).font(.system(size: 11)) }
                    else { Button("Load image") { Task { await loadImage() } }.buttonStyle(OrbButtonStyle(compact: true)) }
                }.frame(height: 200).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func openPreview() {
        guard !loading else { return }
        loading = true; error = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                let file = try await ArtifactFiles.shared.fetch(artifact, machine: machine, cwd: cwd)
                ArtifactPreview.shared.show(file, source: machine.label)
            } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func loadImage() async {
        let request = UUID()
        imageLoadID = request
        imageLoading = true
        defer { if imageLoadID == request { imageLoading = false } }
        imageError = nil
        do {
            let file = try await ArtifactFiles.shared.fetch(artifact, machine: machine, cwd: cwd)
            let image = try await ArtifactThumbnail.load(file)
            try Task.checkCancellation()
            guard imageLoadID == request else { return }
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch is CancellationError { }
        catch { if imageLoadID == request { imageError = error.localizedDescription } }
    }
}

@MainActor final class ArtifactPreview: NSObject, NSWindowDelegate {
    static let shared = ArtifactPreview()
    private var windows: [NSWindow] = []
    func show(_ url: URL, source: String) {
        if let existing = windows.first(where: { $0.representedURL == url }) {
            NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = ArtifactPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.representedURL = url
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 420, height: 320)
        window.title = "\(url.lastPathComponent) · \(source)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OrbTheme.nsCanvas
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ArtifactPreviewContent(url: url, fullScreen: { [weak window] in
            window?.toggleFullScreen(nil)
        }, close: { [weak window] in window?.close() }).preferredColorScheme(.dark))
        window.delegate = self; windows.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            Task { @MainActor [weak window] in
                let markdown = await Task.detached(priority: .userInitiated) {
                    try? ArtifactDocumentText.load(url)
                }.value
                guard let window, window.isVisible, let markdown else { return }
                window.contentView = NSHostingView(rootView: MarkdownArtifactDocument(text: markdown).preferredColorScheme(.dark))
            }
        }
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        (notification.object as? NSWindow)?.level = .normal
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        (notification.object as? NSWindow)?.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows.removeAll { $0 === window } }
    }
}

/// Quick Look keeps the full-resolution file available without making the chat
/// retain a full-resolution bitmap. Space and Escape behave like Finder preview.
final class ArtifactPreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty) {
            close()
        } else { super.keyDown(with: event) }
    }
}

struct ArtifactQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
}

struct ArtifactPreviewContent: View {
    let url: URL
    var fullScreen: () -> Void
    var close: () -> Void
    @State private var openError: String?
    private var isImage: Bool { ArtifactReference(path: url.path).isImage }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button { openFile() } label: {
                    Label(isImage ? "Open in Preview" : "Open File", systemImage: "arrow.up.forward.app")
                }
                Button(action: fullScreen) { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Close preview")
            }.buttonStyle(OrbButtonStyle(compact: true)).padding(12)
            OrbRule()
            ArtifactQuickLook(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let openError { Text(openError).font(.system(size: 12)).foregroundStyle(OrbTheme.warning).padding(10) }
        }.background(OrbTheme.canvas).foregroundStyle(OrbTheme.text)
            .onExitCommand(perform: close)
    }
    private func openFile() {
        openError = nil
        if isImage, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
                if let error { Task { @MainActor in openError = error.localizedDescription } }
            }
        } else if !NSWorkspace.shared.open(url) { openError = "Couldn’t open this file. It may have been moved or deleted." }
    }
}

enum ArtifactDocumentText {
    static func load(_ url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 512_001), data.count <= 512_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The actual local or downloaded Markdown, rendered with the app's native text
/// components. Other file types and oversized/invalid text retain Quick Look.
struct MarkdownArtifactDocument: View {
    let text: String
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("DOCUMENT PREVIEW").font(.system(size: 10)).tracking(1.5).foregroundStyle(OrbTheme.secondary)
                    ConversationMarkdown(text: text, documentStyle: true)
                        .font(.system(size: 16)).lineSpacing(4)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(36)
            }
        }.background(OrbTheme.canvas).foregroundStyle(OrbTheme.text)
    }
}

struct ArtifactErrorView: View {
    let title: String
    let detail: String
    var symbol = "photo"
    var actionTitle = "Retry image"
    var inlineAction = false
    var action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(OrbTheme.secondary)
                .frame(width: 48, height: 48).background(OrbTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(OrbTheme.controlEdge, lineWidth: 0.75))
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(OrbTheme.secondary).fixedSize(horizontal: false, vertical: true)
                if !inlineAction { Button(actionTitle, action: action).buttonStyle(OrbButtonStyle(kind: .primary)).padding(.top, 4) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if inlineAction { Button(actionTitle, action: action).buttonStyle(OrbButtonStyle(kind: .primary)).padding(.top, 6) }
        }.foregroundStyle(OrbTheme.text)
    }
}
