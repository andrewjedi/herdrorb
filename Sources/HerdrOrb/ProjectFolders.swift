import Foundation

struct FolderListing: Equatable {
    let path: String
    let folders: [String]
    var parent: String { (path as NSString).deletingLastPathComponent }
}

/// The same read-only listing runs locally or through the device's existing SSH profile.
/// NUL-delimited output preserves spaces, quotes and newlines in folder names.
enum ProjectFolders {
    static let script = #"""
    folder=${1:-"$HOME"}
    case "$folder" in
      '~') folder="$HOME" ;;
      '~/'*) folder="$HOME/${folder#\~/}" ;;
    esac
    cd "$folder" || exit 1
    if [ ! -r . ] || [ ! -x . ]; then echo 'This folder is not readable.' >&2; exit 1; fi
    printf '%s\000' "$PWD"
    for entry in ./* ./.[!.]* ./..?*; do
      if [ -d "$entry" ]; then printf '%s\000' "${entry#./}"; fi
    done
    """#
    static func validate(_ path: String) throws {
        guard !path.contains("\0"), path.isEmpty || path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            throw BridgeError.message("Enter an absolute folder path, ~/folder, or leave blank for this Mac’s home folder.")
        }
    }
    static func list(on machine: Machine, path: String) async throws -> FolderListing {
        try validate(path)
        let data: Data
        if machine.id == "local" {
            data = try await ProcessRunner.run("/bin/sh", ["-c", script, "folder-browser", path])
        } else {
            let target = try ConnectionCommands.target(machine)
            let command = ["/bin/sh", "-c", script, "folder-browser", path].map(MachineTransport.quote).joined(separator: " ")
            data = try await ProcessRunner.run("/usr/bin/ssh", MachineTransport.sshOptions + [target, command], timeout: 15)
        }
        try Task.checkCancellation()
        let parts = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard let root = parts.first, root.hasPrefix("/") else { throw BridgeError.message("Could not read the folder list from this device.") }
        return FolderListing(path: root, folders: parts.dropFirst().sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
    static func child(_ name: String, in path: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}
