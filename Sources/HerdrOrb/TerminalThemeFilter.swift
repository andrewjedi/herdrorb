import Foundation

/// Remap only bright neutral SGR backgrounds in the embedded display. Preserve
/// bytes, control sequences, and foreground/semantic colors otherwise.
struct TerminalThemeFilter {
    private var pending: [UInt8] = []
    mutating func process(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        for byte in bytes {
            if pending.isEmpty {
                if byte == 27 { pending = [byte] } else { output.append(byte) }
            } else if pending.count == 1 {
                pending.append(byte)
                if byte != 91 { output += pending; pending = [] }
            } else {
                pending.append(byte)
                if (0x40...0x7e).contains(byte) {
                    if byte == 109 { output += remap(pending) } else { output += pending }
                    pending = []
                } else if pending.count > 256 {
                    output += pending; pending = []
                }
            }
        }
        return output
    }
    private func remap(_ sequence: [UInt8]) -> [UInt8] {
        let body = String(decoding: sequence.dropFirst(2).dropLast(), as: UTF8.self)
        let fields = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let dark = ["48", "2", "43", "46", "57"]
        func light(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            min(r, g, b) >= 180 && max(r, g, b) - min(r, g, b) <= 20
        }
        var result: [String] = [], index = 0
        while index < fields.count {
            let field = fields[index]
            if field == "47" || field == "107" { result += dark; index += 1; continue }
            // Consume foreground colors intact so their RGB values aren't read as SGR codes.
            if ["38", "48", "58"].contains(field), index + 2 < fields.count {
                if fields[index + 1] == "2", index + 4 < fields.count {
                    let components = fields[(index + 2)...(index + 4)].compactMap(Int.init)
                    if field == "48", components.count == 3, light(components[0], components[1], components[2]) { result += dark }
                    else { result += fields[index...(index + 4)] }
                    index += 5; continue
                }
                if fields[index + 1] == "5", let color = Int(fields[index + 2]) {
                    var bright = color == 7 || color == 15 || (250...255).contains(color)
                    if (16...231).contains(color) {
                        let n = color - 16, ramp = [0, 95, 135, 175, 215, 255]
                        bright = light(ramp[n / 36], ramp[(n / 6) % 6], ramp[n % 6])
                    }
                    result += field == "48" && bright ? dark : Array(fields[index...(index + 2)])
                    index += 3; continue
                }
            }
            result.append(field); index += 1
        }
        return Array(("\u{1b}[" + result.joined(separator: ";") + "m").utf8)
    }
}
