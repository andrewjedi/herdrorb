import SwiftUI

struct FolderBrowser: View {
    let machine: Machine
    let initialPath: String
    var title = "Choose Folder"
    var demo = false
    var select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pathInput = ""
    @State private var requestedPath = ""
    @State private var requestID = UUID()
    @State private var listing: FolderListing?
    @State private var loading = true
    @State private var error: String?
    @State private var showHidden = false
    @State private var hovered: String?
    var body: some View {
        OrbSheet(width: 650, inset: 20) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    Text(machine.label).font(.system(size: 15)).foregroundStyle(OrbTheme.secondary)
                }
                OrbRule()
                HStack(spacing: 10) {
                    Button { navigate("") } label: { Image(systemName: "house").font(.system(size: 18)) }.buttonStyle(OrbButtonStyle()).help("Home folder on this Mac").accessibilityLabel("Home folder")
                    Button { if let listing { navigate(listing.parent) } } label: { Image(systemName: "arrow.up").font(.system(size: 18)) }.buttonStyle(OrbButtonStyle())
                        .disabled(listing == nil || listing?.path == "/").help("Parent folder").accessibilityLabel("Parent folder")
                    OrbField(placeholder: "Folder path on this Mac", text: $pathInput, label: "Folder path on this Mac", onSubmit: { navigate(pathInput) })
                    Button("Go") { navigate(pathInput) }.buttonStyle(OrbButtonStyle())
                }
                if loading { ProgressView("Reading folders…").controlSize(.small) }
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(OrbTheme.warning).textSelection(.enabled)
                    Button("Retry") { navigate(requestedPath) }.buttonStyle(OrbButtonStyle(compact: true))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let listing {
                            ForEach(listing.folders.filter { showHidden || !$0.hasPrefix(".") }, id: \.self) { name in
                                Button { navigate(ProjectFolders.child(name, in: listing.path)) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "folder").font(.system(size: 20, weight: .light))
                                        Text(name).font(.system(size: 15)).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(OrbTheme.secondary)
                                    }.padding(.horizontal, 16).frame(height: 45).background(hovered == name ? OrbTheme.raised : .clear)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).onHover { hovered = $0 ? name : nil }
                                OrbRule().opacity(0.5)
                            }
                            if listing.folders.filter({ showHidden || !$0.hasPrefix(".") }).isEmpty {
                                Text("No subfolders. You can still choose this folder.").foregroundStyle(OrbTheme.secondary).padding(16)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                OrbRule()
                Toggle("Show hidden folders", isOn: $showHidden).toggleStyle(.checkbox).font(.system(size: 14))
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(OrbButtonStyle()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Choose This Folder") { if let listing { select(listing.path); dismiss() } }
                        .buttonStyle(OrbButtonStyle(kind: .primary)).disabled(loading || listing == nil || pathInput != listing?.path)
                }
            }.frame(height: 498)
        }
        .onAppear { navigate(initialPath) }
        .task(id: requestID) { await load() }
    }
    private func navigate(_ path: String) { requestedPath = path; pathInput = path; listing = nil; loading = true; error = nil; requestID = UUID() }
    private func load() async {
        let request = requestID
        do {
            let result = demo ? FolderListing(path: requestedPath.isEmpty ? "~/Projects" : requestedPath, folders: requestedPath == "~/Projects" || requestedPath.isEmpty ? ["herdrorb", "website", "documentation", "experiments", ".config"] : []) : try await ProjectFolders.list(on: machine, path: requestedPath)
            guard !Task.isCancelled, requestID == request else { return }
            listing = result; pathInput = result.path; loading = false
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            self.error = error.localizedDescription; listing = nil; loading = false
        }
    }
}

struct DeviceProjectSettings: View {
    @ObservedObject var model: BubbleModel
    let machine: Machine
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var browsing = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        OrbSheet(width: 610) {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(machine.label) Settings").font(.system(size: 22, weight: .semibold))
                OrbRule()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default projects folder").font(.system(size: 18, weight: .semibold))
                    Text("New sessions start here. Its subfolders appear as projects you can choose from.").font(.system(size: 14)).foregroundStyle(OrbTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder path").foregroundStyle(OrbTheme.secondary)
                    HStack(spacing: 12) {
                        OrbField(placeholder: "Home folder (default)", text: $path, label: "Default projects folder path")
                        Button("Browse…") { browsing = true }.buttonStyle(OrbButtonStyle())
                    }
                    Button("Use Home Folder") { path = "" }.buttonStyle(.link).foregroundStyle(OrbTheme.accent)
                }
                if let error { Text(error).foregroundStyle(OrbTheme.warning).font(.system(size: 13)).textSelection(.enabled) }
                OrbRule()
                HStack {
                    Button { dismiss() } label: { Text("Cancel").frame(minWidth: 60) }.buttonStyle(OrbButtonStyle()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { Task { await save() } } label: { Text(saving ? "Checking…" : "Save").frame(minWidth: 60) }.buttonStyle(OrbButtonStyle(kind: .primary))
                }
            }
        }.disabled(saving)
            .onAppear { path = model.isDemo ? "~/Projects" : model.projectFolder(for: machine) }
            .sheet(isPresented: $browsing) { FolderBrowser(machine: machine, initialPath: path, title: "Default Projects Folder", demo: model.isDemo) { path = $0 } }
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        if model.isDemo { dismiss(); return }
        do {
            let resolved = path.isEmpty ? "" : try await ProjectFolders.list(on: machine, path: path).path
            model.setProjectFolder(resolved, for: machine); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SessionProjectChooser: View {
    let machine: Machine
    let basePath: String
    @Binding var directory: String
    var demo = false
    var showProjects = true
    @State private var listing: FolderListing?
    @State private var error: String?
    @State private var browsing = false
    @State private var reload = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project folder").font(.system(size: 13))
            if !showProjects { Text("Choose the project directory for this session.").font(.system(size: 12)).foregroundStyle(OrbTheme.secondary) }
            HStack(spacing: 10) {
                OrbField(placeholder: "Home folder on selected Mac", text: $directory, label: "Project folder")
                Button("Browse…") { browsing = true }.buttonStyle(OrbButtonStyle())
            }
            if showProjects {
            HStack {
                Button("Use Default Folder") { directory = basePath }.buttonStyle(.link).foregroundStyle(OrbTheme.accent)
                Spacer()
                Button { reload = UUID() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 17)) }.buttonStyle(.plain).help("Refresh project folders").accessibilityLabel("Refresh project folders")
            }.font(.system(size: 13))
            OrbRule().padding(.vertical, 1)
            if let listing {
                Text("Projects in \(listing.path)").font(.system(size: 13)).foregroundStyle(OrbTheme.secondary).lineLimit(2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(listing.folders.filter { !$0.hasPrefix(".") }, id: \.self) { name in
                            let path = ProjectFolders.child(name, in: listing.path)
                            Button { directory = path } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder").font(.system(size: 20, weight: .light))
                                    Text(name).font(.system(size: 15)).lineLimit(1)
                                    Spacer()
                                    if directory == path { Image(systemName: "checkmark").foregroundStyle(OrbTheme.accentLight) }
                                }.padding(.horizontal, 14).frame(height: 35).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(directory == path ? OrbTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(directory == path ? .isSelected : [])
                        }
                        if !listing.folders.contains(where: { !$0.hasPrefix(".") }) { Text("No project subfolders yet.").foregroundStyle(OrbTheme.secondary).padding(12) }
                    }
                }.frame(height: 105).background(OrbTheme.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(OrbTheme.line, lineWidth: 0.8))
            } else if let error { Text(error).font(.system(size: 12)).foregroundStyle(OrbTheme.warning).lineLimit(3) }
            else { ProgressView("Loading projects…").controlSize(.small) }
            }
        }
        .sheet(isPresented: $browsing) { FolderBrowser(machine: machine, initialPath: directory, demo: demo) { directory = $0 } }
        .task(id: "\(machine.identity)|\(basePath)|\(reload)") {
            listing = nil; error = nil
            do {
                let result = demo ? FolderListing(path: "~/Projects", folders: ["herdrorb", "website", "documentation"]) : try await ProjectFolders.list(on: machine, path: basePath)
                guard !Task.isCancelled else { return }; listing = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
