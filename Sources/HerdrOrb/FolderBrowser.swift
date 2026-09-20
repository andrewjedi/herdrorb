import SwiftUI

struct FolderBrowser: View {
    let machine: Machine
    let initialPath: String
    var title = "Choose Folder"
    var select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pathInput = ""
    @State private var requestedPath = ""
    @State private var requestID = UUID()
    @State private var listing: FolderListing?
    @State private var loading = true
    @State private var error: String?
    @State private var showHidden = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(machine.label).foregroundStyle(.secondary)
            HStack {
                Button { navigate("") } label: { Image(systemName: "house") }.help("Home folder on this Mac")
                Button { if let listing { navigate(listing.parent) } } label: { Image(systemName: "arrow.up") }
                    .disabled(listing == nil || listing?.path == "/").help("Parent folder")
                TextField("Folder path on this Mac", text: $pathInput).textFieldStyle(.roundedBorder).onSubmit { navigate(pathInput) }
                Button("Go") { navigate(pathInput) }
            }
            if loading { ProgressView("Reading folders…").controlSize(.small) }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                Button("Retry") { navigate(requestedPath) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let listing {
                        ForEach(listing.folders.filter { showHidden || !$0.hasPrefix(".") }, id: \.self) { name in
                            Button { navigate(ProjectFolders.child(name, in: listing.path)) } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.purple)
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(9).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if listing.folders.filter({ showHidden || !$0.hasPrefix(".") }).isEmpty {
                            Text("No subfolders. You can still choose this folder.").foregroundStyle(.secondary).padding(12)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Toggle("Show hidden folders", isOn: $showHidden).font(.callout)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose This Folder") { if let listing { select(listing.path); dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(loading || listing == nil || pathInput != listing?.path)
            }
        }.padding(24).frame(width: 550, height: 490)
            .onAppear { navigate(initialPath) }
            .task(id: requestID) { await load() }
    }
    private func navigate(_ path: String) {
        requestedPath = path; pathInput = path; listing = nil; loading = true; error = nil; requestID = UUID()
    }
    private func load() async {
        let request = requestID
        do {
            let result = try await ProjectFolders.list(on: machine, path: requestedPath)
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
        VStack(alignment: .leading, spacing: 18) {
            Text("\(machine.label) Settings").font(.title2.weight(.semibold))
            Text("Default projects folder").font(.headline)
            Text("New sessions start here. Its subfolders appear as projects you can choose from.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Home folder (default)", text: $path).textFieldStyle(.roundedBorder)
                Button("Browse…") { browsing = true }
            }
            Button("Use Home Folder") { path = "" }.buttonStyle(.link)
            if let error { Text(error).foregroundStyle(.orange).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "Checking…" : "Save") { Task { await save() } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 510).disabled(saving)
            .onAppear { path = model.projectFolder(for: machine) }
            .sheet(isPresented: $browsing) {
                FolderBrowser(machine: machine, initialPath: path, title: "Default Projects Folder") { path = $0 }
            }
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            // Resolve ~ on the selected device and verify access before persisting.
            let resolved = path.isEmpty ? "" : try await ProjectFolders.list(on: machine, path: path).path
            model.setProjectFolder(resolved, for: machine); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SessionProjectChooser: View {
    let machine: Machine
    let basePath: String
    @Binding var directory: String
    @State private var listing: FolderListing?
    @State private var error: String?
    @State private var browsing = false
    @State private var reload = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project folder").font(.system(size: 13, weight: .medium))
            HStack {
                TextField("Home folder on selected Mac", text: $directory).textFieldStyle(.roundedBorder)
                Button("Browse…") { browsing = true }
            }
            HStack {
                Button("Use Default Folder") { directory = basePath }
                Spacer()
                Button { reload = UUID() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh project folders")
            }.font(.system(size: 11))
            if let listing {
                Text("Projects in \(listing.path)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(listing.folders.filter { !$0.hasPrefix(".") }, id: \.self) { name in
                            let path = ProjectFolders.child(name, in: listing.path)
                            Button { directory = path } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    if directory == path { Image(systemName: "checkmark") }
                                }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(directory == path ? Color.purple.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if !listing.folders.contains(where: { !$0.hasPrefix(".") }) { Text("No project subfolders yet.").foregroundStyle(.secondary) }
                    }
                }.frame(height: 120)
            } else if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3) }
            else { ProgressView("Loading projects…").controlSize(.small) }
        }
        .sheet(isPresented: $browsing) {
            FolderBrowser(machine: machine, initialPath: directory) { directory = $0 }
        }
        .task(id: "\(machine.identity)|\(basePath)|\(reload)") {
            listing = nil; error = nil
            do {
                let result = try await ProjectFolders.list(on: machine, path: basePath)
                guard !Task.isCancelled else { return }; listing = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
