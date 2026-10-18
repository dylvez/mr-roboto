import CSignalsmithStretch
import Foundation

/// A sung take pulled onto the notes of its key: what Auto-Tune does, offline.
///
/// The voice is tracked (`PitchTracker`, YIN at a 10 ms hop), each moment's note is the nearest
/// note of the key to where the voice is centred, and the take is shifted, formants kept, by the
/// difference — eased in at the strength's speed. Three strengths:
///
/// - **Natural**: the note's centre is the voice smoothed over 120 ms, so vibrato and scoops are
///   left alone and only the note it sits on is moved; the correction eases in over 90 ms. What a
///   careful engineer does to a pop vocal, and what nobody hears.
/// - **Tight**: a 50 ms centre and a 30 ms ease. Every note lands, a little vibrato is left.
/// - **Hard**: no centre and no ease: every frame is snapped to its note and jumps to the next,
///   vibrato flattened — the stepped, robotic voice of T-Pain, of trap, drill and reggaetón, and
///   of the arabic pop the profiles describe as heavy Auto-Tune.
///
/// The shift is Signalsmith Stretch's, at a time factor of one, its transpose moved every 256
/// samples, with its formant compensation on so the voice keeps its size. Deterministic: the same
/// take and the same key give the same file.
public enum PitchCorrection {

    public enum Strength: String, CaseIterable, Codable, Sendable {
        case natural, tight, hard

        /// How long the note's centre is smoothed over, seconds; 0 is the voice as it is.
        var centreSeconds: Double {
            switch self { case .natural: return 0.12; case .tight: return 0.05; case .hard: return 0 }
        }
        /// How long the correction takes to settle on a new note, seconds.
        var retuneSeconds: Double {
            switch self { case .natural: return 0.09; case .tight: return 0.03; case .hard: return 0.002 }
        }
        /// The shifter's block: shorter for hard, so its steps are steps.
        func blockSamples(at sampleRate: Double) -> Int {
            let seconds = self == .hard ? 0.021 : 0.043
            var n = 256
            while Double(n) < seconds * sampleRate { n *= 2 }
            return n
        }

        public var words: String {
            switch self {
            case .natural: return "natural: the notes it sits on moved, its vibrato and scoops kept"
            case .tight: return "tight: every note landed, a little vibrato left"
            case .hard: return "hard: every note snapped and the jumps between them stepped, the Auto-Tune sound"
            }
        }
    }

    public struct Result: Sendable {
        public var planar: [[Float]]
        /// The voiced frames' mean distance from the nearest note of the key, in cents, before
        /// and after (as tracked again).
        public var centsBefore: Double
        public var centsAfter: Double
        /// Seconds of voice tracked.
        public var voicedSeconds: Double
        /// The largest shift applied anywhere, semitones.
        public var largestShift: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case noVoice
        case noScale
        case shifter
        public var description: String {
            switch self {
            case .noVoice: return "No sung pitch was found in the take."
            case .noScale: return "The key has no notes to tune to."
            case .shifter: return "The pitch shifter could not be made."
            }
        }
    }

    /// The take pulled onto `pitchClasses` (0 is C) at `strength`.
    public static func correct(_ planar: [[Float]], sampleRate: Double, pitchClasses: Set<Int>, strength: Strength) throws -> Result {
        guard !pitchClasses.isEmpty else { throw Failure.noScale }
        let channels = planar.count
        guard channels > 0, sampleRate > 0, let frames = planar.first?.count, frames > 0 else { throw Failure.noVoice }
        let mono = Self.mono(planar)
        let tracker = PitchTracker()
        let track = tracker.track(mono, sampleRate: sampleRate)
        let shifts = Self.shifts(for: track, pitchClasses: pitchClasses, strength: strength, hop: tracker.hopSeconds)
        let voiced = track.filter { $0.midi != nil }
        guard !voiced.isEmpty else { throw Failure.noVoice }
        let before = Self.meanCents(of: voiced, pitchClasses: pitchClasses)

        let out = try Self.shift(planar, sampleRate: sampleRate, shifts: shifts, hop: tracker.hopSeconds,
                                 block: strength.blockSamples(at: sampleRate))
        let after = Self.meanCents(of: tracker.track(Self.mono(out), sampleRate: sampleRate).filter { $0.midi != nil },
                                   pitchClasses: pitchClasses)
        return Result(planar: out, centsBefore: before, centsAfter: after,
                      voicedSeconds: Double(voiced.count) * tracker.hopSeconds,
                      largestShift: shifts.map { abs($0) }.max() ?? 0)
    }

    // MARK: The plan

    /// The shift at each tracked frame, semitones.
    static func shifts(for track: [PitchFrame], pitchClasses: Set<Int>, strength: Strength, hop: Double) -> [Double] {
        let midi = track.map(\.midi)
        let half = Int((strength.centreSeconds / hop / 2).rounded())
        // The voice's centre: a median over the window's voiced frames, so vibrato does not count.
        let centre: [Double?] = midi.indices.map { i in
            guard midi[i] != nil else { return nil }
            guard half > 0 else { return midi[i] }
            let around = midi[max(0, i - half)...min(midi.count - 1, i + half)].compactMap { $0 }.sorted()
            return around.isEmpty ? nil : around[around.count / 2]
        }
        var targets = [Double?](repeating: nil, count: midi.count)
        var held: Double?
        for i in midi.indices {
            // A new phrase picks its note afresh.
            guard let c = centre[i] else { held = nil; continue }
            // Hold the note it was on until the voice is well past the half-way point to another:
            // a voice at the boundary would otherwise flick between the two.
            if let note = held, abs(c - note) < 0.65 {
                targets[i] = note
            } else {
                let note = nearest(c, in: pitchClasses)
                targets[i] = note
                held = note
            }
        }
        // What each frame asks for: the target less where the voice is (hard: the voice itself,
        // natural: its centre, so the vibrato rides on top). Through a short gap — a consonant —
        // the last ask is held; past it, nothing is asked.
        var asks = [Double](repeating: 0, count: midi.count)
        var last = 0.0, gap = 0
        let holdFrames = Int(0.06 / hop)
        for i in midi.indices {
            if let target = targets[i], let from = strength == .hard ? midi[i] : centre[i] {
                last = max(-1.6, min(1.6, target - from))
                asks[i] = last
                gap = 0
            } else {
                gap += 1
                asks[i] = gap <= holdFrames ? last : 0
            }
        }
        // Eased in at the strength's speed.
        let alpha = 1 - exp(-hop / max(0.0005, strength.retuneSeconds))
        var eased = [Double](repeating: 0, count: asks.count)
        var now = 0.0
        for i in asks.indices {
            now += alpha * (asks[i] - now)
            eased[i] = now
        }
        return eased
    }

    /// The nearest MIDI note whose pitch class is allowed.
    static func nearest(_ midi: Double, in pitchClasses: Set<Int>) -> Double {
        let base = Int(midi.rounded())
        var best = Double(base), distance = Double.infinity
        for offset in -3...3 {
            let note = base + offset
            guard pitchClasses.contains(((note % 12) + 12) % 12) else { continue }
            let d = abs(Double(note) - midi)
            if d < distance { distance = d; best = Double(note) }
        }
        return best
    }

    static func meanCents(of frames: [PitchFrame], pitchClasses: Set<Int>) -> Double {
        let off = frames.compactMap(\.midi).map { abs($0 - nearest($0, in: pitchClasses)) * 100 }
        return off.isEmpty ? 0 : off.reduce(0, +) / Double(off.count)
    }

    static func mono(_ planar: [[Float]]) -> [Float] {
        guard let first = planar.first else { return [] }
        guard planar.count > 1 else { return first }
        var out = first
        for channel in planar.dropFirst() {
            for i in out.indices where i < channel.count { out[i] += channel[i] }
        }
        let scale = 1 / Float(planar.count)
        return out.map { $0 * scale }
    }

    // MARK: The shift

    /// `planar` shifted by `shifts` (one a tracker hop), its length and timing kept.
    static func shift(_ planar: [[Float]], sampleRate: Double, shifts: [Double], hop: Double, block: Int) throws -> [[Float]] {
        let channels = planar.count, frames = planar[0].count
        let interval = 256
        guard let handle = ss_stretch_create_configured(Int32(channels), sampleRate, Int32(block), Int32(interval), 1) else {
            throw Failure.shifter
        }
        defer { ss_stretch_destroy(handle) }
        ss_stretch_set_time_factor(handle, 1)
        ss_stretch_set_formant_semitones(handle, 0, true)
        let inputLatency = Int(ss_stretch_input_latency(handle))
        let outputLatency = Int(ss_stretch_output_latency(handle))
        let padded = frames + inputLatency + outputLatency + interval + 1
        var source = [Float](repeating: 0, count: channels * padded)
        for c in 0..<channels {
            for i in 0..<min(frames, planar[c].count) { source[c * padded + i] = planar[c][i] }
        }
        var result = [Float](repeating: 0, count: channels * frames)
        func shiftAt(_ sample: Int) -> Double {
            guard !shifts.isEmpty else { return 0 }
            let position = Double(sample) / sampleRate / hop
            let i = max(0, min(shifts.count - 1, Int(position)))
            let j = min(shifts.count - 1, i + 1)
            let t = max(0, min(1, position - Double(i)))
            return shifts[i] + (shifts[j] - shifts[i]) * t
        }
        source.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                func inputs(at frame: Int) -> [UnsafePointer<Float>?] { (0..<channels).map { src.baseAddress! + $0 * padded + frame } }
                func outputs(at frame: Int) -> [UnsafeMutablePointer<Float>?] { (0..<channels).map { dst.baseAddress! + $0 * frames + frame } }
                var done = inputLatency + outputLatency
                ss_stretch_set_transpose_semitones(handle, shiftAt(0), 0)
                inputs(at: 0).withUnsafeBufferPointer { ss_stretch_output_seek(handle, $0.baseAddress!, Int32(done)) }
                var y = 0
                while y < frames {
                    let count = min(interval, frames - y)
                    // The blocks made now are heard about `outputLatency` from here.
                    ss_stretch_set_transpose_semitones(handle, shiftAt(y + outputLatency), 0)
                    let target = min(padded, done + count)
                    inputs(at: done).withUnsafeBufferPointer { ip in
                        outputs(at: y).withUnsafeBufferPointer { op in
                            ss_stretch_process(handle, ip.baseAddress!, Int32(target - done), op.baseAddress!, Int32(count))
                        }
                    }
                    done = target
                    y += count
                }
            }
        }
        return (0..<channels).map { c in Array(result[(c * frames)..<((c + 1) * frames)]) }
    }
}
