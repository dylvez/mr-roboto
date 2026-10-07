import Foundation

// M6 X1: the mix, as a part. A strip per part id, a master, and per-section gain overrides. Every
// move is a new mix version whose note says what moved and by how much.

/// One band of a strip's EQ.
public struct EQBand: Hashable, Codable, Sendable {
    public enum Shape: String, Codable, Sendable { case lowShelf, peak, highShelf }
    public var shape: Shape
    /// Hz.
    public var frequency: Double
    public var gainDB: Double
    /// Bandwidth for a peak, in octaves; ignored by the shelves.
    public var width: Double

    public init(shape: Shape, frequency: Double, gainDB: Double = 0, width: Double = 1) {
        self.shape = shape
        self.frequency = frequency
        self.gainDB = gainDB
        self.width = width
    }

    /// Three flat bands: a low shelf at 100, a peak at 1 k, a high shelf at 8 k.
    public static let flat: [EQBand] = [EQBand(shape: .lowShelf, frequency: 100), EQBand(shape: .peak, frequency: 1_000),
                                         EQBand(shape: .highShelf, frequency: 8_000)]
}

/// A strip's compressor. `ratio` sets how hard; the engine maps it onto its dynamics unit's knee.
public struct Compressor: Hashable, Codable, Sendable {
    public var thresholdDB: Double
    public var ratio: Double
    public var attackMS: Double
    public var releaseMS: Double
    public var makeupDB: Double

    public init(thresholdDB: Double = -18, ratio: Double = 3, attackMS: Double = 10, releaseMS: Double = 120, makeupDB: Double = 0) {
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.attackMS = attackMS
        self.releaseMS = releaseMS
        self.makeupDB = makeupDB
    }
}

/// One part's channel: level, pan, EQ, compression, a send to the bus.
public struct Strip: Hashable, Codable, Sendable, Identifiable {
    public var part: PartID
    /// What the strip is called on the surface: the part's label when it was made.
    public var label: String
    public var gainDB: Double
    /// −1 left … +1 right.
    public var pan: Double
    public var isMuted: Bool
    public var isSoloed: Bool
    public var eq: [EQBand]
    public var compressor: Compressor?
    /// Send to the bus, dB; nil is no send.
    public var sendDB: Double?
    /// What sits between the part and its EQ: an amp, a rotating speaker, or nothing. Nil is what
    /// the part's instrument brings — an organ its rotating speaker, most things nothing — so a
    /// mix that never touched it keeps the instrument's own, and `.off` takes it away. Omitted
    /// when nil, so older documents round-trip byte for byte.
    public var insert: StripInsert?
    /// Send to the echo, dB; nil is no send. Omitted when nil.
    public var echoDB: Double?

    public var id: PartID { part }

    public init(part: PartID, label: String, gainDB: Double = 0, pan: Double = 0, isMuted: Bool = false, isSoloed: Bool = false,
                eq: [EQBand] = EQBand.flat, compressor: Compressor? = nil, sendDB: Double? = nil,
                insert: StripInsert? = nil, echoDB: Double? = nil) {
        self.part = part
        self.label = label
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.eq = eq
        self.compressor = compressor
        self.sendDB = sendDB
        self.insert = insert
        self.echoDB = echoDB
    }

    /// True when the strip does nothing to the signal.
    public var isUnity: Bool {
        gainDB == 0 && pan == 0 && !isMuted && !isSoloed && eq.allSatisfy { $0.gainDB == 0 } && compressor == nil && sendDB == nil
            && insert == nil && echoDB == nil
    }
}

/// An insert on a strip, as a player names it: an amp set clean, crunchy or for a lead; a rotating
/// speaker turning slow or fast. Played by `CStripFX`.
public struct StripInsert: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case off, amp, rotary
    }

    public var kind: Kind
    /// The amp's gain into its clipping stage, or the rotating speaker's own preamp driven: 0…1.
    public var drive: Double
    /// The amp's tone, 0 dark … 1 bright.
    public var tone: Double
    /// The rotating speaker turning fast (tremolo) rather than slow (chorale).
    public var fast: Bool

    public init(kind: Kind, drive: Double = 0, tone: Double = 0.5, fast: Bool = false) {
        self.kind = kind
        self.drive = min(1, max(0, drive))
        self.tone = min(1, max(0, tone))
        self.fast = fast
    }

    public static let off = StripInsert(kind: .off)
    /// The cabinet and a little warmth: a clean guitar through an amp rather than into the desk.
    public static let ampClean = StripInsert(kind: .amp, drive: 0.12, tone: 0.55)
    /// Chords that break up when they are hit.
    public static let ampCrunch = StripInsert(kind: .amp, drive: 0.45, tone: 0.5)
    /// Sustain and saturation for a solo or a riff.
    public static let ampLead = StripInsert(kind: .amp, drive: 0.82, tone: 0.45)
    /// The organ's speaker turning slow: a chorus that moves.
    public static let rotarySlow = StripInsert(kind: .rotary)
    /// Turning fast: the tremolo of a gospel or rock organ at full tilt.
    public static let rotaryFast = StripInsert(kind: .rotary, fast: true)

    /// The named settings, as the Mixer and the band offer them.
    public static let named: [(id: String, insert: StripInsert)] = [
        ("off", .off), ("amp-clean", .ampClean), ("amp-crunch", .ampCrunch), ("amp-lead", .ampLead),
        ("rotary-slow", .rotarySlow), ("rotary-fast", .rotaryFast),
    ]

    /// Its name among `named`, or nil for settings nobody named.
    public var id: String? { Self.named.first { $0.insert == self }?.id }

    /// "an amp, crunch", "a rotating speaker, fast", "nothing": as a sentence says what a strip
    /// plays through.
    public var phrase: String {
        switch kind {
        case .off: return "nothing"
        case .amp: return "an " + words
        case .rotary: return "a " + words
        }
    }

    /// "amp, crunch", "rotating speaker, fast", "nothing".
    public var words: String {
        switch kind {
        case .off: return "nothing"
        case .amp:
            let character = drive < 0.25 ? "clean" : drive < 0.65 ? "crunch" : "lead"
            return "amp, \(character)"
        case .rotary: return "rotating speaker, \(fast ? "fast" : "slow")" + (drive > 0.05 ? ", driven" : "")
        }
    }
}

/// The echo every strip can send to: one tempo-synced delay on its own return.
public struct Echo: Hashable, Codable, Sendable {
    /// The time between repeats, in beats of the song: 0.75 is a dotted eighth in 4/4.
    public var beats: Double
    /// How much of each repeat comes round again, 0…0.9.
    public var feedback: Double
    /// The repeats' high cut, Hz: each one darker than the last, as tape does.
    public var toneHz: Double

    public init(beats: Double = 0.75, feedback: Double = 0.35, toneHz: Double = 3_500) {
        self.beats = min(4, max(0.0625, beats))
        self.feedback = min(0.9, max(0, feedback))
        self.toneHz = min(16_000, max(500, toneHz))
    }

    public static let standard = Echo()

    /// The times a player sets an echo to, by name.
    public static let times: [(name: String, beats: Double)] = [
        ("sixteenth", 0.25), ("eighth", 0.5), ("dotted eighth", 0.75), ("quarter", 1), ("dotted quarter", 1.5), ("half", 2),
    ]

    /// Its time's name, or the beats when it has none.
    public var timeName: String {
        Self.times.first { abs($0.beats - beats) < 1e-6 }?.name ?? String(format: "%g beats", beats)
    }
}

/// The space the reverb every strip sends to is.
public enum Room: String, Codable, Sendable, CaseIterable {
    case room, plate, chamber, hall, cathedral

    public var name: String {
        switch self {
        case .room: return "Room"
        case .plate: return "Plate"
        case .chamber: return "Chamber"
        case .hall: return "Hall"
        case .cathedral: return "Cathedral"
        }
    }

    public var about: String {
        switch self {
        case .room: return "a medium room: close, short, what every song had"
        case .plate: return "a plate: bright and dense, the vocal and snare reverb of soul and pop records"
        case .chamber: return "an echo chamber: warm and even, the sixties studio"
        case .hall: return "a hall: long and spacious, for strings and ballads"
        case .cathedral: return "a cathedral: very long, for pads, organ and ambient music"
        }
    }
}

/// What a strip's effects do in one section: the rotating speaker's speed, the echo send.
public struct SectionEffect: Hashable, Codable, Sendable {
    public var section: SectionID
    public var part: PartID
    /// The rotating speaker turning fast here (true) or slow (false); nil keeps the strip's.
    public var fast: Bool?
    /// The echo send here, dB; nil keeps the strip's.
    public var echoDB: Double?

    public init(section: SectionID, part: PartID, fast: Bool? = nil, echoDB: Double? = nil) {
        self.section = section
        self.part = part
        self.fast = fast
        self.echoDB = echoDB
    }
}

/// The master: gain before the limiter, the limiter's ceiling, and the loudness the song is
/// delivered at.
public struct Master: Hashable, Codable, Sendable {
    public var gainDB: Double
    public var ceilingDBTP: Double
    public var targetLUFS: Double
    /// How the song ends: its last this-many bars fade to silence. Nil is no fade — the song stops
    /// where its form does, as every song did before this was carried. Synthesized coding omits it
    /// when nil, so older documents round-trip byte for byte.
    public var fadeOutBars: Int?

    public init(gainDB: Double = 0, ceilingDBTP: Double = -1, targetLUFS: Double = -14, fadeOutBars: Int? = nil) {
        self.gainDB = gainDB
        self.ceilingDBTP = ceilingDBTP
        self.targetLUFS = targetLUFS
        self.fadeOutBars = fadeOutBars.map { max(1, $0) }
    }
}

/// A strip's gain in one section: the automation this milestone has.
public struct SectionGain: Hashable, Codable, Sendable {
    public var section: SectionID
    public var part: PartID
    public var gainDB: Double

    public init(section: SectionID, part: PartID, gainDB: Double) {
        self.section = section
        self.part = part
        self.gainDB = gainDB
    }
}

/// The mix: strips, master, section gains.
public struct Mix: Hashable, Codable, Sendable {
    public var strips: [Strip]
    public var master: Master
    public var sectionGains: [SectionGain]
    /// The echo's settings; nil is `Echo.standard`. Omitted when nil, as the three below are.
    public var echo: Echo?
    /// The reverb's space; nil is a room, which is what every song had.
    public var room: Room?
    /// What strips' effects do section by section.
    public var sectionEffects: [SectionEffect]?

    public init(strips: [Strip] = [], master: Master = Master(), sectionGains: [SectionGain] = [],
                echo: Echo? = nil, room: Room? = nil, sectionEffects: [SectionEffect]? = nil) {
        self.strips = strips
        self.master = master
        self.sectionGains = sectionGains
        self.echo = echo
        self.room = room
        self.sectionEffects = sectionEffects
    }

    /// Whether anything in the mix changes from one section to the next: a level, or what a
    /// strip's effects do. A transport or a render that moves section by section only has to when
    /// this is true.
    public var changesBySection: Bool { !sectionGains.isEmpty || !(sectionEffects ?? []).isEmpty }

    /// The echo as it plays.
    public var echoSettings: Echo { echo ?? .standard }
    /// The reverb's space as it plays.
    public var roomSetting: Room { room ?? .room }

    /// A strip's echo send in a section: the section's when it sets one, else the strip's own.
    public func echoDB(for part: PartID, in section: SectionID?) -> Double? {
        if let section, let own = sectionEffects?.first(where: { $0.section == section && $0.part == part }), let db = own.echoDB {
            return db
        }
        return strip(for: part)?.echoDB
    }

    /// A strip's insert as it plays in a section: the strip's own or `instrument`'s when it has
    /// none, with the speaker's speed the section sets.
    public func insert(for part: PartID, in section: SectionID?, instrument: StripInsert?) -> StripInsert? {
        guard var insert = strip(for: part)?.insert ?? instrument else { return nil }
        if insert.kind == .rotary, let section,
           let fast = sectionEffects?.first(where: { $0.section == section && $0.part == part })?.fast {
            insert.fast = fast
        }
        return insert
    }

    /// Sets what one strip's effects do in one section, dropping the entry when nothing is left
    /// in it.
    public mutating func setSectionEffect(_ effect: SectionEffect) {
        var effects = (sectionEffects ?? []).filter { !($0.section == effect.section && $0.part == effect.part) }
        if effect.fast != nil || effect.echoDB != nil { effects.append(effect) }
        sectionEffects = effects.isEmpty ? nil : effects
    }

    /// Nothing moved: every part at unity, the master at −14 / −1.
    public static let unity = Mix()

    public func strip(for part: PartID) -> Strip? { strips.first { $0.part == part } }

    /// The strip, or a fresh one at unity for a part the mix has not touched.
    public func strip(for part: PartID, label: String) -> Strip {
        strip(for: part) ?? Strip(part: part, label: label)
    }

    /// Puts a strip in, replacing the one for its part.
    public mutating func set(_ strip: Strip) {
        if let index = strips.firstIndex(where: { $0.part == strip.part }) { strips[index] = strip } else { strips.append(strip) }
    }

    /// A strip's gain in a section: the override when there is one, else the strip's.
    public func gainDB(for part: PartID, in section: SectionID?) -> Double {
        if let section, let override = sectionGains.first(where: { $0.section == section && $0.part == part }) { return override.gainDB }
        return strip(for: part)?.gainDB ?? 0
    }

    /// Whether any strip is soloed, which mutes the rest.
    public var hasSolo: Bool { strips.contains { $0.isSoloed } }

    /// The strip's effective level in dB, or nil for silence (muted, or another strip soloed).
    public func levelDB(for part: PartID, in section: SectionID? = nil) -> Double? {
        let strip = strip(for: part)
        if strip?.isMuted == true { return nil }
        if hasSolo, strip?.isSoloed != true { return nil }
        return gainDB(for: part, in: section)
    }
}
