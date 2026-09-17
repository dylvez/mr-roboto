import Foundation
import MusicTheory
import SongGraph

/// The on-disk kit format: `kit.json` beside the WAV files it names by **relative** path.
///
/// The format is a deliberate, strict subset of SFZ semantics — one region per `Zone`, the same
/// key/velocity/round-robin/choke rules, the same amplitude envelope — so a purchased SFZ pack
/// imports by *parsing* (see `SFZImporter`) rather than by translating into a foreign model.
/// Everything SFZ can express that we do not model is reported as skipped, never silently dropped.
///
/// A kit on disk is a folder:
///
///     MyKit/
///       kit.json
///       samples/kick_hard.wav
///       samples/kick_soft.wav
///
/// Sample paths are always relative to the folder holding `kit.json`, so moving or copying the
/// folder — or shipping it inside a `.roboto` package — keeps it working. `KitStore` rejects an
/// absolute path on both load and save rather than writing a kit that only works on one machine.
public struct KitManifest: Hashable, Codable, Sendable {
    /// The format version this build writes. Bump it together with a `KitMigration` in `KitSchema.swift`.
    public static let currentFormatVersion = 1

    /// The file name inside a kit folder.
    public static let fileName = "kit.json"

    /// Schema version of this document; migrated forward on load by `KitMigrator`.
    public var formatVersion: Int
    public var name: String
    /// Free text shown in a kit browser. Named `description` in JSON; the type deliberately does not
    /// conform to `CustomStringConvertible`, so this stays a plain data field.
    public var description: String?
    public var kind: KitKind
    public var zones: [Zone]
    /// Applied to incoming MIDI velocity unless a caller overrides it. `.squared` matches the fixed
    /// law `AVAudioUnitSampler` applies, so a kit can sound identical to the old sampler path.
    public var velocityCurve: VelocityCurve
    /// Drum-voice names (`DrumVoice.rawValue`) to the MIDI note they trigger, so a `Groove` addresses
    /// this kit without knowing its note layout. Keyed by string because JSON objects have string keys.
    public var voices: [String: Int]
    /// Seam for task A3. Synthesized voices are not modelled yet; `kind` may already say `.synthesized`
    /// or `.hybrid` and this stays `nil` until A3 fills it in. Present so the format version does not
    /// have to change when it lands.
    public var synthesis: SynthesizedVoiceSet?

    public init(
        formatVersion: Int = KitManifest.currentFormatVersion,
        name: String,
        description: String? = nil,
        kind: KitKind = .sampled,
        zones: [Zone] = [],
        velocityCurve: VelocityCurve = .squared,
        voices: [String: Int] = [:],
        synthesis: SynthesizedVoiceSet? = nil
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.description = description
        self.kind = kind
        self.zones = zones
        self.velocityCurve = velocityCurve
        self.voices = voices
        self.synthesis = synthesis
    }

    // MARK: Voice map

    /// The MIDI note a groove's drum voice triggers on this kit.
    public func note(for voice: DrumVoice) -> Int? { voices[voice.rawValue] }

    public mutating func setNote(_ note: Int, for voice: DrumVoice) { voices[voice.rawValue] = note }

    /// Every relative sample path the kit references, deduplicated, in first-use order.
    public var samplePaths: [String] {
        var seen = Set<String>()
        return zones.compactMap { seen.insert($0.sample).inserted ? $0.sample : nil }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, description, kind, zones, velocityCurve, voices, synthesis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Kit"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        kind = try container.decodeIfPresent(KitKind.self, forKey: .kind) ?? .sampled
        zones = try container.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        velocityCurve = try container.decodeIfPresent(VelocityCurve.self, forKey: .velocityCurve) ?? .squared
        voices = try container.decodeIfPresent([String: Int].self, forKey: .voices) ?? [:]
        synthesis = try container.decodeIfPresent(SynthesizedVoiceSet.self, forKey: .synthesis)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(kind, forKey: .kind)
        try container.encode(zones, forKey: .zones)
        try container.encode(velocityCurve, forKey: .velocityCurve)
        if !voices.isEmpty { try container.encode(voices, forKey: .voices) }
        try container.encodeIfPresent(synthesis, forKey: .synthesis)
    }
}

/// What makes sound in a kit.
public enum KitKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Every voice is a recorded sample.
    case sampled
    /// Every voice is synthesized (task A3).
    case synthesized
    /// Samples plus synthesized voices.
    case hybrid
}

/// The synthesized voices of a kit whose `kind` is `.synthesized` (A3).
///
/// A synthesized kit is an ordinary sampled kit on disk: `SynthesizedKit.build` renders each voice
/// at two or three velocity layers into WAV files and emits normal zones, so `KitStore`,
/// `SampleCache` and `VoiceSampler` need no special case. This block is the *recipe* those samples
/// came from, kept so a parameter change can re-render them (`SynthesizedKit.rerender`) rather than
/// leaving the kit as opaque audio.
///
/// Filling this in did **not** need `formatVersion` to change: the member was already optional, so
/// kits written before A3 decode unchanged and kits written after it are readable by a build that
/// ignores the field.
public struct SynthesizedVoiceSet: Hashable, Codable, Sendable {
    /// The machine preset the specs came from, e.g. `"tr808"`. Free text: a kit whose parameters
    /// have been edited still says where it started.
    public var machine: String
    /// The rate the WAVs were rendered at. Re-rendering at a different rate is allowed; recording it
    /// is what lets a re-render reproduce the originals.
    public var sampleRate: Double
    /// The velocity layers, in ascending order.
    public var layers: [SynthVelocityLayer]
    /// One spec per voice, in the order they were rendered.
    public var voices: [SynthVoiceSpec]

    public init(machine: String = "", sampleRate: Double = 48_000,
                layers: [SynthVelocityLayer] = [], voices: [SynthVoiceSpec] = []) {
        self.machine = machine
        self.sampleRate = sampleRate
        self.layers = layers
        self.voices = voices
    }

    /// The spec for a voice kind, if the kit has one.
    public func spec(for kind: SynthVoiceKind) -> SynthVoiceSpec? {
        voices.first { $0.kind == kind }
    }

    /// Replaces one voice's spec, leaving everything else alone. The kit's WAVs are stale until
    /// `SynthesizedKit.rerender` runs.
    public mutating func setSpec(_ spec: SynthVoiceSpec) {
        if let index = voices.firstIndex(where: { $0.kind == spec.kind }) {
            voices[index] = spec
        } else {
            voices.append(spec)
        }
    }

    private enum CodingKeys: String, CodingKey { case machine, sampleRate, layers, voices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decodeIfPresent(String.self, forKey: .machine) ?? ""
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48_000
        layers = try c.decodeIfPresent([SynthVelocityLayer].self, forKey: .layers) ?? []
        voices = try c.decodeIfPresent([SynthVoiceSpec].self, forKey: .voices) ?? []
    }
}

// MARK: - Zone

/// A stable, human-readable zone identifier. Stable because round robin, choke groups and
/// validation findings all refer to zones by id; renaming a file must not renumber anything.
public struct ZoneID: RawRepresentable, Hashable, Codable, Sendable, Comparable,
                      CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: ZoneID, rhs: ZoneID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a zone sits on the keyboard.
///
/// Drums use `.note`: one key, never transposed. Pitched zones use `.range` plus a `rootNote`
/// (SFZ `pitch_keycenter`), and play transposed by `note - rootNote` semitones.
public enum KeyPlacement: Hashable, Sendable {
    /// A single key, played at unity pitch — the drum case.
    case note(Int)
    /// A key range played transposed relative to `rootNote` — the pitched case.
    case range(ClosedRange<Int>, rootNote: Int)

    public var noteRange: ClosedRange<Int> {
        switch self {
        case .note(let note): return note...note
        case .range(let range, _): return range
        }
    }

    public var rootNote: Int {
        switch self {
        case .note(let note): return note
        case .range(_, let root): return root
        }
    }

    public func contains(_ note: Int) -> Bool { noteRange.contains(note) }

    /// Semitones to shift the sample by when `note` plays. Always 0 for a drum zone.
    public func transposition(forNote note: Int) -> Int {
        switch self {
        case .note: return 0
        case .range(_, let root): return note - root
        }
    }
}

/// One sample mapped to a key/velocity region: an SFZ `<region>` restricted to the opcodes we honour.
public struct Zone: Hashable, Codable, Sendable, Identifiable {
    public var id: ZoneID
    /// Path to the audio file, **relative to the kit folder**, using `/` separators.
    public var sample: String
    public var key: KeyPlacement
    /// MIDI velocity range, inclusive (SFZ `lovel`/`hivel`). The full range is `1...127`.
    public var velocity: ClosedRange<Int>
    /// 1-based position in the round-robin set, like SFZ `seq_position`.
    public var seqPosition: Int
    /// Length of the round-robin set, like SFZ `seq_length`. 1 means no round robin.
    public var seqLength: Int
    /// Choke group this zone belongs to (SFZ `group`). nil = ungrouped.
    public var group: Int?
    /// Playing this zone stops voices in this group (SFZ `off_by`). Hi-hats: `group=1 off_by=1`.
    public var offBy: Int?
    /// How a choked voice stops: `.fast` cuts with a short declick ramp, `.normal` uses the release.
    public var offMode: OffMode
    /// First frame to play (SFZ `offset`).
    public var sampleStart: Int
    /// Last frame to play, exclusive; nil plays to the end of the file (SFZ `end`).
    public var sampleEnd: Int?
    /// Gain in decibels (SFZ `volume`).
    public var gainDB: Float
    /// Constant pan, -1 hard left … +1 hard right (SFZ `pan`, which is -100…100).
    public var pan: Float
    /// Pitch offset in cents (SFZ `tune` plus `transpose` × 100).
    public var tuneCents: Float
    public var envelope: Envelope
    public var loop: Loop?

    public init(
        id: ZoneID,
        sample: String,
        key: KeyPlacement,
        velocity: ClosedRange<Int> = 1...127,
        seqPosition: Int = 1,
        seqLength: Int = 1,
        group: Int? = nil,
        offBy: Int? = nil,
        offMode: OffMode = .fast,
        sampleStart: Int = 0,
        sampleEnd: Int? = nil,
        gainDB: Float = 0,
        pan: Float = 0,
        tuneCents: Float = 0,
        envelope: Envelope = .default,
        loop: Loop? = nil
    ) {
        self.id = id
        self.sample = sample
        self.key = key
        self.velocity = velocity
        self.seqPosition = seqPosition
        self.seqLength = seqLength
        self.group = group
        self.offBy = offBy
        self.offMode = offMode
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
        self.gainDB = gainDB
        self.pan = pan
        self.tuneCents = tuneCents
        self.envelope = envelope
        self.loop = loop
    }

    /// A drum zone: one key, unity pitch.
    public static func drum(
        id: ZoneID, sample: String, note: Int, velocity: ClosedRange<Int> = 1...127,
        seqPosition: Int = 1, seqLength: Int = 1, group: Int? = nil, offBy: Int? = nil,
        gainDB: Float = 0, envelope: Envelope = .default
    ) -> Zone {
        Zone(id: id, sample: sample, key: .note(note), velocity: velocity, seqPosition: seqPosition,
             seqLength: seqLength, group: group, offBy: offBy, gainDB: gainDB, envelope: envelope)
    }

    public func contains(note: Int, velocity value: Int) -> Bool {
        key.contains(note) && velocity.contains(value)
    }

    /// Pitch ratio for `note`, combining key transposition and `tuneCents`.
    public func pitchRatio(forNote note: Int) -> Double {
        let semitones = Double(key.transposition(forNote: note)) + Double(tuneCents) / 100
        return pow(2, semitones / 12)
    }

    /// Linear amplitude for `gainDB`.
    public var gain: Float { gainDB == 0 ? 1 : pow(10, gainDB / 20) }

    // MARK: Codable
    //
    // Hand written so the JSON keeps SFZ-familiar names (`lovel`, `hivel`, `offset`-style frames),
    // flattens key placement into the zone object, and tolerates omitted keys — a kit.json can be
    // written by hand with only the fields that differ from the defaults.

    private enum CodingKeys: String, CodingKey {
        case id, sample, note, lowNote, highNote, rootNote, lovel, hivel
        case seqPosition, seqLength, group, offBy, offMode
        case sampleStart, sampleEnd, gainDB, pan, tuneCents, envelope, loop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ZoneID.self, forKey: .id)
        sample = try c.decode(String.self, forKey: .sample)
        if let note = try c.decodeIfPresent(Int.self, forKey: .note) {
            key = .note(note)
        } else {
            let low = try c.decode(Int.self, forKey: .lowNote)
            let high = try c.decode(Int.self, forKey: .highNote)
            let root = try c.decodeIfPresent(Int.self, forKey: .rootNote) ?? low
            key = .range(min(low, high)...max(low, high), rootNote: root)
        }
        let low = try c.decodeIfPresent(Int.self, forKey: .lovel) ?? 1
        let high = try c.decodeIfPresent(Int.self, forKey: .hivel) ?? 127
        velocity = min(low, high)...max(low, high)
        seqPosition = try c.decodeIfPresent(Int.self, forKey: .seqPosition) ?? 1
        seqLength = try c.decodeIfPresent(Int.self, forKey: .seqLength) ?? 1
        group = try c.decodeIfPresent(Int.self, forKey: .group)
        offBy = try c.decodeIfPresent(Int.self, forKey: .offBy)
        offMode = try c.decodeIfPresent(OffMode.self, forKey: .offMode) ?? .fast
        sampleStart = try c.decodeIfPresent(Int.self, forKey: .sampleStart) ?? 0
        sampleEnd = try c.decodeIfPresent(Int.self, forKey: .sampleEnd)
        gainDB = try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        tuneCents = try c.decodeIfPresent(Float.self, forKey: .tuneCents) ?? 0
        envelope = try c.decodeIfPresent(Envelope.self, forKey: .envelope) ?? .default
        loop = try c.decodeIfPresent(Loop.self, forKey: .loop)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sample, forKey: .sample)
        switch key {
        case .note(let note):
            try c.encode(note, forKey: .note)
        case .range(let range, let root):
            try c.encode(range.lowerBound, forKey: .lowNote)
            try c.encode(range.upperBound, forKey: .highNote)
            try c.encode(root, forKey: .rootNote)
        }
        try c.encode(velocity.lowerBound, forKey: .lovel)
        try c.encode(velocity.upperBound, forKey: .hivel)
        try c.encode(seqPosition, forKey: .seqPosition)
        try c.encode(seqLength, forKey: .seqLength)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(offBy, forKey: .offBy)
        try c.encode(offMode, forKey: .offMode)
        try c.encode(sampleStart, forKey: .sampleStart)
        try c.encodeIfPresent(sampleEnd, forKey: .sampleEnd)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(pan, forKey: .pan)
        try c.encode(tuneCents, forKey: .tuneCents)
        try c.encode(envelope, forKey: .envelope)
        try c.encodeIfPresent(loop, forKey: .loop)
    }
}

/// How a choked voice is stopped (SFZ `off_mode`).
public enum OffMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Cut immediately (with a declick ramp in the renderer). SFZ's default.
    case fast
    /// Let the envelope release run.
    case normal
}

// MARK: - Envelope

/// The amplitude envelope, mirroring SFZ `ampeg_*`. All times in seconds; `sustain` is a level 0…1
/// (SFZ stores it as a percentage, the importer divides by 100).
public struct Envelope: Hashable, Codable, Sendable {
    public var delay: Float
    public var attack: Float
    public var hold: Float
    public var decay: Float
    /// Sustain level, 0…1.
    public var sustain: Float
    public var release: Float

    public init(delay: Float = 0, attack: Float = 0, hold: Float = 0,
                decay: Float = 0, sustain: Float = 1, release: Float = 0) {
        self.delay = delay
        self.attack = attack
        self.hold = hold
        self.decay = decay
        self.sustain = min(1, max(0, sustain))
        self.release = release
    }

    /// SFZ's own defaults: no delay/attack/hold/decay, full sustain, no release.
    public static let `default` = Envelope()

    /// A one-shot drum shape: no sustain, a short release to avoid a click on note-off.
    public static func percussive(decay: Float, release: Float = 0.005) -> Envelope {
        Envelope(decay: decay, sustain: 0, release: release)
    }

    private enum CodingKeys: String, CodingKey { case delay, attack, hold, decay, sustain, release }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delay = try c.decodeIfPresent(Float.self, forKey: .delay) ?? 0
        attack = try c.decodeIfPresent(Float.self, forKey: .attack) ?? 0
        hold = try c.decodeIfPresent(Float.self, forKey: .hold) ?? 0
        decay = try c.decodeIfPresent(Float.self, forKey: .decay) ?? 0
        sustain = min(1, max(0, try c.decodeIfPresent(Float.self, forKey: .sustain) ?? 1))
        release = try c.decodeIfPresent(Float.self, forKey: .release) ?? 0
    }
}

// MARK: - Loop

/// Loop points in frames, with SFZ's `loop_mode`. `end` is inclusive, as in SFZ.
public struct Loop: Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        case noLoop = "no_loop"
        case oneShot = "one_shot"
        case loopContinuous = "loop_continuous"
        case loopSustain = "loop_sustain"
    }

    public var mode: Mode
    public var start: Int
    /// Inclusive last frame of the loop, like SFZ `loop_end`.
    public var end: Int

    public init(mode: Mode = .loopContinuous, start: Int, end: Int) {
        self.mode = mode
        self.start = start
        self.end = end
    }

    public var frameCount: Int { max(0, end - start + 1) }

    private enum CodingKeys: String, CodingKey { case mode, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .loopContinuous
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Int.self, forKey: .end) ?? 0
    }
}

// MARK: - Velocity curve

/// How MIDI velocity maps to gain.
public enum VelocityCurve: Hashable, Sendable {
    /// `(v/127)²` — the fixed law `AVAudioUnitSampler` applies, kept so kits can match what the
    /// Apple-sampler path sounded like.
    case squared
    /// `v/127`.
    case linear
    /// `(v/127)^e`.
    case exponent(Float)
    /// An arbitrary lookup, linearly interpolated across `v/127`. 128 entries gives one per velocity.
    case table([Float])

    /// Linear gain for a MIDI velocity. Velocity 0 is silence (it is a note-off in MIDI 1.0).
    public func gain(forVelocity velocity: Int) -> Float {
        let v = Float(min(127, max(0, velocity))) / 127
        switch self {
        case .squared: return v * v
        case .linear: return v
        case .exponent(let e): return powf(v, e)
        case .table(let table):
            guard !table.isEmpty else { return v }
            guard table.count > 1 else { return table[0] }
            let x = v * Float(table.count - 1)
            let i = Int(x)
            if i >= table.count - 1 { return table[table.count - 1] }
            let t = x - Float(i)
            return table[i] * (1 - t) + table[i + 1] * t
        }
    }
}

extension VelocityCurve: Codable {
    private enum CodingKeys: String, CodingKey { case kind, exponent, table }
    private enum Kind: String, Codable { case squared, linear, exponent, table }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .squared: self = .squared
        case .linear: self = .linear
        case .exponent: self = .exponent(try c.decode(Float.self, forKey: .exponent))
        case .table: self = .table(try c.decode([Float].self, forKey: .table))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .squared: try c.encode(Kind.squared, forKey: .kind)
        case .linear: try c.encode(Kind.linear, forKey: .kind)
        case .exponent(let e):
            try c.encode(Kind.exponent, forKey: .kind)
            try c.encode(e, forKey: .exponent)
        case .table(let table):
            try c.encode(Kind.table, forKey: .kind)
            try c.encode(table, forKey: .table)
        }
    }
}
