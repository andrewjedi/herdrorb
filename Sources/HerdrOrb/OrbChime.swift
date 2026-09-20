import AppKit

/// A short, quiet glassy chime with a falling shimmer, synthesized once in memory.
enum OrbChime {
    static func make() -> NSSound? {
        let rate = 44_100
        let count = Int(Double(rate) * 0.65)
        var pcm = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for sample in 0..<count {
            let t = Double(sample) / Double(rate)
            let attack = min(1, t / 0.018)
            let release = min(1, (0.65 - t) / 0.1)
            let envelope = attack * release * exp(-t * 6)
            let tone = sin(2 * .pi * 880 * t)
                + 0.4 * sin(2 * .pi * 1320 * t)
                + 0.22 * sin(2 * .pi * (2200 * t - 320 * t * t))
            append(Int16(tone * envelope * 0.16 * 32767), to: &pcm)
        }
        var wav = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt32(rate), to: &wav)
        append(UInt32(rate * 2), to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        let sound = NSSound(data: wav)
        sound?.volume = 0.55
        return sound
    }
}
