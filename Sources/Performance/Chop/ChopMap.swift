import Foundation
import Instrument
import MusicTheory
import SongGraph

/// One slice on one pad: which note plays it, and what happens to it on the way out.
public struct SliceMapping: Hashable, Sendable, Codable {
    /// Index into `Chop.slices`.
    public var sliceIndex: Int
    /// The MIDI note that triggers this pad.
    public var note: Int
    /// Pitch offset in cents. Negative is down; -1200 is an octave down, which is the classic way
    /// to make a chopped break sit lower without changing its rhythm.
    public var tuneCents: Float
    public var gainDB: Float
    public var pan: Float
    /// Play the slice backwards.
    public var reverse: Bool
    /// Time-stretch the slice by this much before it is mapped (output duration over input).
    /// `nil` plays it at its natural length.
    public var stretchRatio: Double?
    public var envelope: Envelope
    /// Choke group, so a monophonic chop cuts itself the way a sampler's pad bank does.
    public var group: Int?
    public var offBy: Int?
    /// Free text for a UI: "kick 1", "the snare with the room on it".
    public var label: String?

    public init(sliceIndex: Int, note: Int, tuneCents: Float = 0, gainDB: Float = 0, pan: Float = 0,
                reverse: Bool = false, stretchRatio: Double? = nil, envelope: Envelope = .default,
                group: Int? = nil, offBy: Int? = nil, label: String? = nil) {
        self.sliceIndex = sliceIndex
        self.note = note
        self.tuneCents = tuneCents
        self.gainDB = gainDB
        self.pan = pan
        self.reverse = reverse
        self.stretchRatio = stretchRatio
        self.envelope = envelope
        self.group = group
        self.offBy = offBy
        self.label = label
    }

    /// True when the slice can be played straight out of the source buffer, with no rendered
    /// variant — which is the case this whole design exists to keep common.
    public var playsFromSource: Bool {
        !reverse && (stretchRatio.map { SliceStretch.quantise($0) == SliceStretch.quantise(1) } ?? true)
    }
}

/// Slices mapped to pads, and the `KitManifest` that makes them playable.
///
/// ## One buffer, many windows
///
/// A chop is **not** a folder of little WAVs. Every pad is a `Zone` over the same file with its own
/// `sampleStart`/`sampleEnd`, which is the whole reason the existing `VoiceSampler` can play a chop
/// with no new playback code: `SampleCache` decodes the file once, every zone gets the same
/// `SampleBuffer`, and the C core carries the window per zone (`vr_zone_t.sampleStart`/`sampleEnd`).
///
/// There is a well-known bug in Apple's own sampler where several regions over one file misbehave.
/// The render core here is ours, and `ChopKitTests` renders every pad offline and asserts
/// each one produces its own slice's samples — the assumption is verified, not assumed.
///
/// Reversed and stretched pads cannot be a window into the original audio, so their audio is
/// rendered and **appended to the same buffer**. The file stays one file; it just grows a tail.
public struct ChopMap: Hashable, Sendable {
    /// C1 — where an MPC's bottom-left pad has been since 1988.
    public static let firstPadNote = 36
    /// Frames of silence between appended variants, so nothing can interpolate across a seam.
    static let variantGuardFrames = 64

    /// The fade-in a chopped pad gets when its window does not begin near zero.
    ///
    /// `Chopper.zeroCrossingWindow` already backs a slice start up to the nearest quiet frame, and
    /// when it finds one there is nothing left to fade. But on dense material there is no quiet
    /// frame to find — a hat landing on top of a ringing kick starts wherever the transient is,
    /// part-way up a cycle — and a voice that begins at full amplitude steps the output from
    /// silence to that value in a single sample. That is the click.
    ///
    /// The fade is sized from the sample it has to climb rather than fixed, which is the point:
    /// a slice that starts at 0.003 gets nothing, and only a slice that starts at 0.8 pays the
    /// full millisecond. Sampler practice is a few hundred microseconds to about a millisecond —
    /// short enough that a kick still hits (a kick's own attack is tens of milliseconds, a hat's
    /// one or two), long enough that the step is gone. `maximumSeconds` is the hard ceiling, so
    /// no transient can ever be softened by more than that however loud the first sample is.
    public struct Declick: Hashable, Sendable {
        /// Largest amplitude change per sample the fade itself may contribute. Chosen well under
        /// the slope ordinary drum material already has, so the fade is never the steepest thing
        /// in the signal.
        public var slopePerSample: Float
        /// Ceiling on the fade, in seconds.
        public var maximumSeconds: Double
        /// A window starting quieter than this is at a crossing already and gets no fade, which
        /// keeps the transient completely untouched in the common case.
        public var floor: Float

        public init(slopePerSample: Float = 0.02, maximumSeconds: Double = 0.001,
                    floor: Float = 0.002) {
            self.slopePerSample = slopePerSample
            self.maximumSeconds = maximumSeconds
            self.floor = floor
        }

        public static let `default` = Declick()
        /// No fade at all. The chop then relies entirely on zero-crossing placement.
        public static let none = Declick(slopePerSample: 1, maximumSeconds: 0, floor: .infinity)

        /// Attack time for a window whose first sample is `first`, quantised to whole frames so
        /// the core's `(int32_t)(attack * sampleRate + 0.5)` recovers exactly this many.
        public func attack(forFirstSample first: Float, sampleRate: Double) -> Float {
            let height = abs(first)
            guard maximumSeconds > 0, sampleRate > 0, slopePerSample > 0,
                  height.isFinite, height > floor else { return 0 }
            let ceiling = (maximumSeconds * sampleRate).rounded(.down)
            let wanted = (Double(height / slopePerSample)).rounded(.up)
            let frames = min(wanted, ceiling)
            guard frames >= 1 else { return 0 }
            return Float(frames / sampleRate)
        }
    }

    public var name: String
    public var chop: Chop
    public var mappings: [SliceMapping]
    public var velocityCurve: VelocityCurve
    /// Drum-voice names to notes, so a `Groove` can address this chop without knowing its pad layout.
    public var voices: [String: Int]
    /// The one sample the kit references, relative to the kit folder.
    public var sampleFileName: String
    /// The fade-in applied by `render(source:stretch:)` to any pad whose mapping does not already
    /// ask for an attack of its own. `.none` turns it off.
    public var declick: Declick

    public init(name: String, chop: Chop, mappings: [SliceMapping],
                velocityCurve: VelocityCurve = .squared, voices: [String: Int] = [:],
                sampleFileName: String = "samples/chop.wav",
                declick: Declick = .default) {
        self.name = name
        self.chop = chop
        self.mappings = mappings
        self.velocityCurve = velocityCurve
        self.voices = voices
        self.sampleFileName = sampleFileName
        self.declick = declick
    }

    /// Every slice on its own pad, in order, from `firstNote` upwards, at unity everything.
    ///
    /// `velocityCurve` defaults to `.linear` here rather than the kit format's `.squared`: a chop
    /// played back at the velocities it was cut with should come out at the level it went in, and
    /// a squared curve would quietly duck everything below full velocity.
    public static func pads(_ chop: Chop, name: String = "Chop",
                            firstNote: Int = ChopMap.firstPadNote,
                            velocityCurve: VelocityCurve = .linear) -> ChopMap {
        let mappings = chop.slices.map {
            SliceMapping(sliceIndex: $0.index, note: firstNote + $0.index,
                         label: "slice \($0.index) (\($0.origin.rawValue))")
        }
        return ChopMap(name: name, chop: chop, mappings: mappings, velocityCurve: velocityCurve)
    }

    // MARK: Lookup

    public var noteRange: ClosedRange<Int>? {
        guard let low = mappings.map(\.note).min(), let high = mappings.map(\.note).max() else { return nil }
        return low...high
    }

    public func mapping(forSlice index: Int) -> SliceMapping? {
        mappings.first { $0.sliceIndex == index && $0.playsFromSource }
            ?? mappings.first { $0.sliceIndex == index }
    }

    /// The note that plays slice `index` at its natural length.
    public func note(forSlice index: Int) -> Int? { mapping(forSlice: index)?.note }

    public func slice(forNote note: Int) -> Slice? {
        guard let mapping = mappings.first(where: { $0.note == note }),
              chop.slices.indices.contains(mapping.sliceIndex) else { return nil }
        return chop.slices[mapping.sliceIndex]
    }

    /// The lowest note not already used by a pad — where a rendered variant goes.
    public var nextFreeNote: Int { (mappings.map(\.note).max() ?? (Self.firstPadNote - 1)) + 1 }

    /// Adds a pad and returns its note.
    @discardableResult
    public mutating func addPad(sliceIndex: Int, tuneCents: Float = 0, gainDB: Float = 0,
                                reverse: Bool = false, stretchRatio: Double? = nil,
                                label: String? = nil) -> Int {
        let note = nextFreeNote
        mappings.append(SliceMapping(sliceIndex: sliceIndex, note: note, tuneCents: tuneCents,
                                     gainDB: gainDB, reverse: reverse, stretchRatio: stretchRatio,
                                     label: label))
        return note
    }

    /// Names a drum voice for a note, so a `Groove` can address this chop by voice.
    public mutating func setVoice(_ voice: DrumVoice, note: Int) { voices[voice.rawValue] = note }

    /// Every slice triggered at its own position in the source — the chop played back in its
    /// original order.
    ///
    /// This is the self-check that matters: if the windows, the rate and the gains are right, this
    /// renders the source bar back sample for sample. If it does not, something in the chain is
    /// wrong and every re-groove built on it is wrong the same way.
    public func nativeHits(velocity: Int = 127, from origin: Double = 0) -> [VoiceSampler.Hit] {
        chop.slices.compactMap { slice in
            note(forSlice: slice.index).map {
                VoiceSampler.Hit(note: $0, velocity: velocity, at: origin + slice.startSeconds)
            }
        }
    }

    // MARK: Rendering

    /// The audio and the manifest: one buffer, one manifest, ready for `KitStore.save` and
    /// `VoiceSampler.prepare`.
    ///
    /// - Parameters:
    ///   - source: the planar audio the chop was cut from. Must be `chop.sourceFrameCount` frames.
    ///   - stretch: the cache used for stretched pads. A map with no stretched pad never touches it.
    public func render(source: [[Float]], stretch: SliceStretch? = nil) throws -> ChopKit {
        guard !source.isEmpty, let frames = source.first?.count, frames > 0 else {
            throw ChopError.emptySource
        }
        let channels = source.count
        guard source.allSatisfy({ $0.count == frames }) else { throw ChopError.raggedSource }
        let sampleRate = chop.sampleRate
        var audio = source
        var zones: [Zone] = []
        zones.reserveCapacity(mappings.count)
        let cache = stretch ?? SliceStretch()

        for (position, mapping) in mappings.enumerated() {
            guard chop.slices.indices.contains(mapping.sliceIndex) else {
                throw ChopError.sliceOutOfRange(mapping.sliceIndex, count: chop.slices.count)
            }
            let slice = chop.slices[mapping.sliceIndex]
            let start = max(0, min(slice.start, frames))
            let end = max(start, min(slice.end, frames))
            let window: (start: Int, end: Int)
            // The loudest first sample across the channels of whatever this pad will actually
            // play — for a reversed or stretched pad that is the rendered region, not the source.
            // It is what the fade-in has to climb.
            var firstSample: Float = 0

            if mapping.playsFromSource {
                window = (start, end)
                if start < end {
                    for c in 0..<channels { firstSample = max(firstSample, abs(source[c][start])) }
                }
            } else {
                // A reversed or stretched pad needs audio that does not exist in the source, so it
                // is rendered and appended to the tail of the same buffer. Still one file.
                var region = (0..<channels).map { Array(source[$0][start..<end]) }
                if mapping.reverse { region = region.map { $0.reversed() } }
                if let ratio = mapping.stretchRatio, SliceStretch.quantise(ratio) != SliceStretch.quantise(1) {
                    region = try cache.stretched(slice: mapping.sliceIndex, planar: region,
                                                 sampleRate: sampleRate, ratio: ratio,
                                                 reversed: mapping.reverse)
                }
                let appendedStart = (audio.first?.count ?? 0) + Self.variantGuardFrames
                let guardSilence = [Float](repeating: 0, count: Self.variantGuardFrames)
                let length = region.map(\.count).min() ?? 0
                for c in 0..<channels {
                    audio[c].append(contentsOf: guardSilence)
                    audio[c].append(contentsOf: region[c].prefix(length))
                }
                window = (appendedStart, appendedStart + length)
                if length > 0 {
                    for c in 0..<channels { firstSample = max(firstSample, abs(region[c][0])) }
                }
            }

            // A mapping that asks for its own attack keeps it; the declick only fills the gap the
            // SFZ default (`attack == 0`) leaves.
            var envelope = mapping.envelope
            if !(envelope.attack > 0) {
                envelope.attack = declick.attack(forFirstSample: firstSample, sampleRate: sampleRate)
            }

            zones.append(Zone(
                id: ZoneID(String(format: "slice-%03d", position)),
                sample: sampleFileName,
                key: .note(mapping.note),
                sampleStart: window.start,
                sampleEnd: window.end,
                gainDB: mapping.gainDB,
                pan: mapping.pan,
                tuneCents: mapping.tuneCents,
                envelope: envelope
            ))
            if let group = mapping.group { zones[zones.count - 1].group = group }
            if let offBy = mapping.offBy { zones[zones.count - 1].offBy = offBy }
        }

        let manifest = KitManifest(
            name: name,
            description: "Chopped from \(String(format: "%.3f", chop.sourceOffset)) s, "
                + "\(chop.count) slice\(chop.count == 1 ? "" : "s"), one buffer, \(zones.count) zones.",
            kind: .sampled,
            zones: zones,
            velocityCurve: velocityCurve,
            voices: voices
        )
        return ChopKit(manifest: manifest, audio: audio, sampleRate: sampleRate,
                       sampleFileName: sampleFileName)
    }
}

/// A rendered chop: one manifest, one buffer.
public struct ChopKit: Sendable {
    public var manifest: KitManifest
    /// The one buffer every zone points into, planar.
    public var audio: [[Float]]
    public var sampleRate: Double
    public var sampleFileName: String

    public init(manifest: KitManifest, audio: [[Float]], sampleRate: Double, sampleFileName: String) {
        self.manifest = manifest
        self.audio = audio
        self.sampleRate = sampleRate
        self.sampleFileName = sampleFileName
    }

    public var frameCount: Int { audio.first?.count ?? 0 }
    public var channelCount: Int { audio.count }

    /// Writes `kit.json` and the single WAV into `folder` and returns the loaded kit.
    @discardableResult
    public func write(to folder: URL) throws -> LoadedKit {
        try ChopAudio.writeWAV(audio, to: KitPath.resolve(sampleFileName, in: folder),
                               sampleRate: sampleRate)
        return try KitStore.save(manifest, to: folder)
    }
}

public enum ChopError: Error, CustomStringConvertible {
    case emptySource
    case raggedSource
    case sliceOutOfRange(Int, count: Int)

    public var description: String {
        switch self {
        case .emptySource: return "chop: the source buffer is empty"
        case .raggedSource: return "chop: the source channels differ in length"
        case .sliceOutOfRange(let i, let count): return "chop: slice \(i) of \(count) does not exist"
        }
    }
}
