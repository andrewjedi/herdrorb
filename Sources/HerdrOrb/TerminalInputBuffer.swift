import Foundation

/// Herdr enables bracketed paste after attaching and entering raw mode. Until
/// then, preserve the initial slash and any keys typed during the connection.
struct TerminalInputBuffer {
    private(set) var ready = false
    private var initial: [UInt8]
    private var pending: [UInt8] = []
    private var probe: [UInt8] = []
    init(initial: String = "") { self.initial = Array(initial.utf8) }
    mutating func replaceInitial(_ text: String) { if !ready { initial = Array(text.utf8) } }
    mutating func input(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        if ready { return Array(bytes) }
        pending.append(contentsOf: bytes); return []
    }
    mutating func output(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        guard !ready else { return nil }
        probe.append(contentsOf: bytes)
        let marker = Array("\u{1b}[?2004h".utf8)
        let found = probe.indices.contains { index in
            index + marker.count <= probe.count && probe[index..<(index + marker.count)].elementsEqual(marker)
        }
        probe = Array(probe.suffix(marker.count))
        guard found else { return nil }
        ready = true
        let result = initial + pending; initial = []; pending = []; return result
    }
}
