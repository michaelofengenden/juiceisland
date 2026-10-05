import Foundation

/// Juice's own three sounds (Settings › Sound, P1000), offered beside the macOS ones: made here, in code, from sine
/// tones and a soft bell envelope, never sampled from a recording or another app. Short (under half a second), soft (a
/// peak of a third of full scale, before Volume) and each with its own shape, so the owner tells them apart without
/// looking: Tap rises a fourth in two quick notes (something waits on you), Rise slides up a fifth in one (a question),
/// and Settle falls through three notes of a chord (done). The defaults stay the macOS ones: nothing sounds different
/// until the owner picks one.
enum JuiceSound: String, CaseIterable, Sendable {
    case tap, rise, settle

    /// The name its pop-up item shows.
    var title: String {
        switch self {
        case .tap: "Tap"
        case .rise: "Rise"
        case .settle: "Settle"
        }
    }

    /// Its notes, as `JuiceSoundSynth` plays them.
    var notes: [JuiceSoundSynth.Note] {
        typealias N = JuiceSoundSynth.Note
        switch self {
        case .tap:
            // E5 then A5: a rising fourth, the second note held a little longer.
            return [N(start: 0, length: 0.16, from: 659.26, decay: 0.07, level: 0.30),
                    N(start: 0.11, length: 0.27, from: 880.00, decay: 0.10, level: 0.30)]
        case .rise:
            // One note sliding up from D5 to A5 over its first 0.13 s, as a voice rises at a question's end.
            return [N(start: 0, length: 0.36, from: 587.33, to: 880.00, glide: 0.13, decay: 0.13, level: 0.30)]
        case .settle:
            // G5, E5, C5: a C major chord falling to its root, the softest of the three.
            return [N(start: 0, length: 0.14, from: 783.99, decay: 0.06, level: 0.24),
                    N(start: 0.075, length: 0.15, from: 659.26, decay: 0.07, level: 0.24),
                    N(start: 0.15, length: 0.34, from: 523.25, decay: 0.13, level: 0.26)]
        }
    }

    /// The sound as a WAV file in memory, made once per run and kept (a few tens of kilobytes): `NSSound(data:)` plays it.
    var wav: Data { JuiceSoundSynth.cache.wav(self) }
}

/// Makes Juice's sounds: 16-bit mono PCM at 44.1 kHz, each note a sine with a quieter octave and twelfth over it, a 6 ms
/// rise, an exponential fall and a 12 ms fade at its end, so no note starts or stops with a click.
enum JuiceSoundSynth {
    static let sampleRate = 44_100.0

    struct Note: Equatable, Sendable {
        /// Seconds from the sound's start.
        var start: Double
        var length: Double
        /// Its pitch in hertz, and the pitch it slides to over `glide` seconds (an exponential slide), if it slides.
        var from: Double
        var to: Double? = nil
        var glide: Double = 0
        /// The fall's time constant, in seconds.
        var decay: Double
        /// Its loudest, 0 to 1 of full scale.
        var level: Double

        /// Its pitch `t` seconds into it.
        func pitch(at t: Double) -> Double {
            guard let to, glide > 0 else { return from }
            return from * pow(to / from, min(t / glide, 1))
        }
    }

    /// The samples of `notes` mixed, -1 to 1.
    static func samples(_ notes: [Note]) -> [Double] {
        let end = notes.map { $0.start + $0.length }.max() ?? 0
        var out = [Double](repeating: 0, count: Int((end * sampleRate).rounded(.up)))
        let attack = 0.006, fade = 0.012
        for note in notes {
            let first = Int(note.start * sampleRate)
            let count = Int(note.length * sampleRate)
            var phase = 0.0
            for i in 0..<count where first + i < out.count {
                let t = Double(i) / sampleRate
                let envelope = min(t / attack, 1) * exp(-t / note.decay) * min((note.length - t) / fade, 1)
                phase += 2 * .pi * note.pitch(at: t) / sampleRate
                let tone = sin(phase) + 0.22 * sin(2 * phase) + 0.06 * sin(3 * phase)
                out[first + i] += note.level * envelope * tone / 1.28
            }
        }
        return out
    }

    /// `samples` as a WAV file.
    static func wav(_ samples: [Double]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(Int16((max(-1, min(1, sample)) * Double(Int16.max)).rounded())) }
        return data
    }

    /// Each sound made at most once a run.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [JuiceSound: Data] = [:]

        func wav(_ sound: JuiceSound) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let data = made[sound] { return data }
            let data = JuiceSoundSynth.wav(JuiceSoundSynth.samples(sound.notes))
            made[sound] = data
            return data
        }
    }

    static let cache = Cache()
}
