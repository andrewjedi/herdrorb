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
    @State private var localFile: URL?
    @AppStorage("automaticImagePreviews") private var automaticImages = true
    @State private var imageLoading = false
    private var imageTaskID: String { [machine.identity, cwd ?? "", artifact.path, String(automaticImages)].joined(separator: "|") }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if artifact.isImage { imagePreview }
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").font(.system(size: 20)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(machine.label).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button {
                    loading = true; error = nil
                    Task { @MainActor in
                        defer { loading = false }
                        do {
                            let file: URL
                            if let localFile { file = localFile }
                            else { file = try await ArtifactFiles.shared.fetch(artifact, machine: machine, cwd: cwd) }
                            ArtifactPreview.shared.show(file, source: machine.label)
                        } catch { self.error = error.localizedDescription }
                    }
                } label: { Text(loading ? "Loading…" : "Preview").font(.system(size: 11)) }
                    .disabled(loading).buttonStyle(.bordered)
                    .help(machine.id == "local" ? "Preview this file" : "Fetch this file from \(machine.label) and preview it here")
            }
        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
            .help(artifact.path)
            .task(id: imageTaskID) {
                if artifact.isImage && automaticImages { await loadImage() }
            }
            .alert("Couldn’t preview this file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
    private var imagePreview: some View {
                ZStack {
                    Color.black.opacity(0.12)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .accessibilityLabel("Image: \(artifact.name)")
                            .onTapGesture { if let localFile { ArtifactPreview.shared.show(localFile, source: machine.label) } }
                    } else if let imageError {
                        VStack(spacing: 8) {
                            Text(imageError).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Retry image") { Task { await loadImage() } }.font(.system(size: 11))
                        }.padding(12)
                    } else if imageLoading { ProgressView("Loading image…").controlSize(.small).font(.system(size: 11)) }
                    else { Button("Load image") { Task { await loadImage() } }.buttonStyle(.bordered) }
                }.frame(height: 220).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 7))
    }
    @MainActor private func loadImage() async {
        guard !imageLoading else { return }
        imageLoading = true
        defer { imageLoading = false }
        imageError = nil
        do {
            let file = try await ArtifactFiles.shared.fetch(artifact, machine: machine, cwd: cwd)
            let image = try await ArtifactThumbnail.load(file)
            try Task.checkCancellation()
            localFile = file
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch is CancellationError { }
        catch { imageError = error.localizedDescription }
    }
}

@MainActor final class ArtifactPreview: NSObject, NSWindowDelegate {
    static let shared = ArtifactPreview()
    private var windows: [NSWindow] = []
    func show(_ url: URL, source: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) — \(source)"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        window.isReleasedWhenClosed = false
        let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.autostarts = false
        preview.previewItem = url as NSURL
        window.contentView = preview
        window.delegate = self; windows.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows.removeAll { $0 === window } }
    }
}
