import Foundation

@main struct ProjectFolderChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-project-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Project 2", "Project 10", "it's a project", "$(touch SHOULD_NOT_EXIST)", "line\nbreak", ".hidden"]
        for name in names { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data().write(to: root.appendingPathComponent("regular-file.txt"))
        let listing = try await ProjectFolders.list(on: .local, path: root.path)
        assert(Set(listing.folders) == Set(names), "Only directories should appear, with names preserved")
        assert(listing.folders.firstIndex(of: "Project 2")! < listing.folders.firstIndex(of: "Project 10")!)
        let nested = try await ProjectFolders.list(on: .local, path: ProjectFolders.child("it's a project", in: listing.path))
        assert(nested.folders.isEmpty && nested.parent == listing.path)
        let home = try await ProjectFolders.list(on: .local, path: "")
        let tilde = try await ProjectFolders.list(on: .local, path: "~")
        assert(home.path == tilde.path)
        let relativeHome = try await ProjectFolders.list(on: .local, path: "~/.")
        assert(relativeHome.path == home.path)
        do { _ = try await ProjectFolders.list(on: .local, path: root.appendingPathComponent("missing").path); assertionFailure("Missing folders must fail") } catch {}
        do { try ProjectFolders.validate("relative/path"); assertionFailure("Relative path must fail") } catch {}
        do { try ProjectFolders.validate("/bad\0path"); assertionFailure("NUL must fail") } catch {}
        // Exercise the exact shell quoting used for SSH through a local login-shell equivalent.
        let quotedPath = root.appendingPathComponent("$(touch SHOULD_NOT_EXIST)").path
        let command = ["/bin/sh", "-c", ProjectFolders.script, "folder-browser", quotedPath].map(MachineTransport.quote).joined(separator: " ")
        let remoteStyle = try await ProcessRunner.run("/bin/sh", ["-c", command])
        assert(String(decoding: remoteStyle.split(separator: 0)[0], as: UTF8.self) == quotedPath)
        assert(!FileManager.default.fileExists(atPath: "SHOULD_NOT_EXIST"))
        let suite = "HerdrProjectFolderChecks-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BubbleModel(preferences: preferences)
        let a = Machine(id: "remote-a", label: "A", target: "a")
        let b = Machine(id: "remote-b", label: "B", target: "b")
        model.setProjectFolder(root.path, for: a)
        assert(model.projectFolder(for: b).isEmpty && model.projectFolder(for: .local).isEmpty)
        assert(BubbleModel(preferences: preferences).projectFolder(for: a) == root.path)
        var changed = a; changed.target = "different-host"
        assert(model.projectFolder(for: changed).isEmpty)
        model.setProjectFolder("", for: a)
        assert(model.projectFolder(for: a).isEmpty)
        print("Folder listing: local/home/navigation, hidden folders, names/quoting, missing-folder errors and per-device default persistence passed")
        if CommandLine.arguments.contains("--live") {
            for machine in try await HerdrClient.machines() where machine.id != "local" {
                let result = try await ProjectFolders.list(on: machine, path: "")
                print("Live read-only folder listing: \(machine.label), \(result.folders.count) subfolders")
            }
        }
    }
}
