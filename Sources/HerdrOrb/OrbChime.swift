import AppKit

/// A short, quiet glassy chime with a falling shimmer, synthesized once in memory.
enum OrbChime {
    static func make(opening: Bool? = nil) -> NSSound? {
        if let opening {
            let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("HerdrOrb_HerdrOrb.bundle")) }
            guard let url = (packaged ?? Bundle.module).url(forResource: opening ? "PanelOpen" : "PanelClose", withExtension: "wav") else { return nil }
            let sound = NSSound(contentsOf: url, byReference: false)
            sound?.volume = 0.32
            return sound
        }
        let rate = 44_100
        let duration = 0.65
        let count = Int(Double(rate) * duration)
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
            let value = tone * envelope * 0.16
            append(Int16(max(-1, min(1, value)) * 32767), to: &pcm)
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
