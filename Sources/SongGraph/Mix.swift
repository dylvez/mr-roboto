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
    /// A wah before the insert; nil is none. Omitted when nil, as the three below are.
    public var pedal: StripPedal?
    /// A chorus, phaser, flanger or vibrato after the insert. Nil is what the instrument brings — a
    /// Juno its chorus, most things nothing — and `.off` takes that away.
    public var modulation: StripModulation?
    /// A low-pass or high-pass after the modulation, whose corner sections can move; nil is none.
    public var filter: StripFilter?
    /// The strip ducked on the kick; nil is none.
    public var pump: StripPump?

    public var id: PartID { part }

    public init(part: PartID, label: String, gainDB: Double = 0, pan: Double = 0, isMuted: Bool = false, isSoloed: Bool = false,
                eq: [EQBand] = EQBand.flat, compressor: Compressor? = nil, sendDB: Double? = nil,
                insert: StripInsert? = nil, echoDB: Double? = nil, pedal: StripPedal? = nil, modulation: StripModulation? = nil,
                filter: StripFilter? = nil, pump: StripPump? = nil) {
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
        self.pedal = pedal
        self.modulation = modulation
        self.filter = filter
        self.pump = pump
    }

    /// True when the strip does nothing to the signal.
    public var isUnity: Bool {
        gainDB == 0 && pan == 0 && !isMuted && !isSoloed && eq.allSatisfy { $0.gainDB == 0 } && compressor == nil && sendDB == nil
            && insert == nil && echoDB == nil && pedal == nil && modulation == nil && filter == nil && pump == nil
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

/// A pedal before a strip's insert: a wah. Played by `CStripFX`.
///
/// An envelope filter opens with how hard a note is played and closes as it dies — the Mu-Tron
/// III on a funk clavinet or bass. A wah rocked in time sweeps the same resonant peak heel to toe
/// once every so many beats, the "wakka" of a rhythm guitar.
public struct StripPedal: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case envelope, wah
    }

    public var kind: Kind
    /// The envelope filter's sensitivity, or how far the wah sweeps: 0…1.
    public var amount: Double
    /// How sharp its peak is, 0…1.
    public var resonance: Double
    /// The wah: one rock of the foot every this many beats.
    public var beats: Double

    public init(kind: Kind, amount: Double = 0.6, resonance: Double = 0.65, beats: Double = 0.5) {
        self.kind = kind
        self.amount = min(1, max(0, amount))
        self.resonance = min(1, max(0, resonance))
        self.beats = min(4, max(0.125, beats))
    }

    public static let envelope = StripPedal(kind: .envelope, amount: 0.55, resonance: 0.6)
    public static let envelopeDeep = StripPedal(kind: .envelope, amount: 0.85, resonance: 0.8)
    public static let wahSixteenths = StripPedal(kind: .wah, amount: 0.7, resonance: 0.7, beats: 0.25)
    public static let wahEighths = StripPedal(kind: .wah, amount: 0.8, resonance: 0.7, beats: 0.5)
    public static let wahQuarters = StripPedal(kind: .wah, amount: 0.85, resonance: 0.7, beats: 1)

    public static let named: [(id: String, pedal: StripPedal)] = [
        ("envelope", .envelope), ("envelope-deep", .envelopeDeep),
        ("wah-sixteenths", .wahSixteenths), ("wah-eighths", .wahEighths), ("wah-quarters", .wahQuarters),
    ]

    public var id: String? { Self.named.first { $0.pedal == self }?.id }

    /// "envelope filter", "wah, every eighth".
    public var words: String {
        switch kind {
        case .envelope: return amount > 0.7 ? "envelope filter, deep" : "envelope filter"
        case .wah:
            let name = Echo.times.first { abs($0.beats - beats) < 1e-6 }?.name ?? String(format: "%g beats", beats)
            return "wah, rocked every \(name)"
        }
    }
}

/// What modulates a strip after its insert: a chorus, a phaser, a flanger or a vibrato. Played by
/// `CStripFX`.
public struct StripModulation: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case off, chorus, phaser, flanger, vibrato
    }

    public var kind: Kind
    /// How fast it sweeps, in turns a second.
    public var rateHz: Double
    /// How far, 0…1.
    public var depth: Double
    /// The phaser's and the flanger's feedback, 0…0.9.
    public var feedback: Double

    public init(kind: Kind, rateHz: Double = 0.5, depth: Double = 0.6, feedback: Double = 0) {
        self.kind = kind
        self.rateHz = min(12, max(0.02, rateHz))
        self.depth = min(1, max(0, depth))
        self.feedback = min(0.9, max(0, feedback))
    }

    public static let off = StripModulation(kind: .off)
    /// The Juno-60's chorus I: slow and gentle, a mono synth made wide.
    public static let chorus = StripModulation(kind: .chorus, rateHz: 0.513, depth: 0.6)
    /// Chorus II: quicker and deeper, the shimmer of a Juno pad.
    public static let chorusWide = StripModulation(kind: .chorus, rateHz: 0.863, depth: 0.85)
    public static let phaserSlow = StripModulation(kind: .phaser, rateHz: 0.35, depth: 0.85, feedback: 0.45)
    public static let phaserFast = StripModulation(kind: .phaser, rateHz: 1.8, depth: 0.7, feedback: 0.35)
    /// The jet: a sweep of nine seconds, fed back.
    public static let flangerSlow = StripModulation(kind: .flanger, rateHz: 0.11, depth: 0.9, feedback: 0.6)
    public static let flangerFast = StripModulation(kind: .flanger, rateHz: 0.5, depth: 0.7, feedback: 0.45)
    /// A pitch wobble with no dry signal: the combo organ's vibrato.
    public static let vibrato = StripModulation(kind: .vibrato, rateHz: 6.2, depth: 0.28)

    public static let named: [(id: String, modulation: StripModulation)] = [
        ("off", .off), ("chorus", .chorus), ("chorus-wide", .chorusWide), ("phaser-slow", .phaserSlow), ("phaser-fast", .phaserFast),
        ("flanger-slow", .flangerSlow), ("flanger-fast", .flangerFast), ("vibrato", .vibrato),
    ]

    public var id: String? { Self.named.first { $0.modulation == self }?.id }

    /// "chorus", "phaser, slow", "nothing".
    public var words: String {
        switch kind {
        case .off: return "nothing"
        case .chorus: return rateHz > 0.7 ? "chorus, wide" : "chorus"
        case .phaser: return rateHz > 1 ? "phaser, fast" : "phaser, slow"
        case .flanger: return rateHz > 0.3 ? "flanger, fast" : "flanger, slow"
        case .vibrato: return "vibrato"
        }
    }
}

/// A filter after a strip's modulation: a low-pass or a high-pass of four poles whose corner
/// stays where the strip sets it, or moves section by section (`SectionEffect.filterFromHz`).
public struct StripFilter: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case lowPass, highPass

        public var name: String { self == .lowPass ? "low-pass" : "high-pass" }
        /// Where it lets everything through.
        public var openHz: Double { self == .lowPass ? 20_000 : 20 }
    }

    public var kind: Kind
    /// Hz, where no section moves it.
    public var cutoffHz: Double
    /// 0 is a plain slope, 1 a ringing peak at the corner.
    public var resonance: Double

    public init(kind: Kind, cutoffHz: Double? = nil, resonance: Double = 0.3) {
        self.kind = kind
        self.cutoffHz = min(20_000, max(20, cutoffHz ?? kind.openHz))
        self.resonance = min(1, max(0, resonance))
    }

    /// Whether it is out of the way where no section moves it.
    public var isOpen: Bool { kind == .lowPass ? cutoffHz >= 19_000 : cutoffHz <= 21 }

    /// "low-pass at 800 Hz", "high-pass, open".
    public var words: String {
        isOpen ? "\(kind.name), open" : "\(kind.name) at \(Self.hz(cutoffHz))"
    }

    public static func hz(_ value: Double) -> String {
        value >= 1_000 ? String(format: value >= 10_000 ? "%.0f kHz" : "%.1f kHz", value / 1_000) : String(format: "%.0f Hz", value)
    }
}

/// A strip ducked on the kick and let back up: the sidechain pump of French house, techno,
/// afrobeats and lo-fi. Its triggers are the kick's own steps in the grooves the song plays, or
/// every beat. Played by `CStripFX`.
public struct StripPump: Hashable, Codable, Sendable {
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        case kick, beat
    }

    public var trigger: Trigger
    /// How far it ducks, dB.
    public var depthDB: Double
    /// How long it takes to come most of the way back, in beats.
    public var releaseBeats: Double

    public init(trigger: Trigger = .kick, depthDB: Double = 6, releaseBeats: Double = 0.5) {
        self.trigger = trigger
        self.depthDB = min(24, max(1, depthDB))
        self.releaseBeats = min(2, max(0.125, releaseBeats))
    }

    public static let standard = StripPump()
    public static let heavy = StripPump(depthDB: 12, releaseBeats: 0.75)

    /// "pumping 6 dB on the kick".
    public var words: String {
        String(format: "pumping %.0f dB on the %@", depthDB, trigger == .kick ? "kick" : "beat")
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
    /// The echo on tape, as an Echoplex or a Space Echo: the repeats wow and flutter, darken and
    /// thin each time round, and saturate as feedback is pushed. Nil is the clean digital delay.
    /// Omitted when nil, so older documents round-trip byte for byte.
    public var tape: Bool?

    public init(beats: Double = 0.75, feedback: Double = 0.35, toneHz: Double = 3_500, tape: Bool? = nil) {
        self.beats = min(4, max(0.0625, beats))
        self.feedback = min(0.9, max(0, feedback))
        self.toneHz = min(16_000, max(500, toneHz))
        self.tape = tape == true ? true : nil
    }

    public var isTape: Bool { tape == true }

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
    case room, plate, chamber, hall, cathedral, spring, gated

    public var name: String {
        switch self {
        case .room: return "Room"
        case .plate: return "Plate"
        case .chamber: return "Chamber"
        case .hall: return "Hall"
        case .cathedral: return "Cathedral"
        case .spring: return "Spring"
        case .gated: return "Gated"
        }
    }

    public var about: String {
        switch self {
        case .room: return "a medium room: close, short, what every song had"
        case .plate: return "a plate: bright and dense, the vocal and snare reverb of soul and pop records"
        case .chamber: return "an echo chamber: warm and even, the sixties studio"
        case .hall: return "a hall: long and spacious, for strings and ballads"
        case .cathedral: return "a cathedral: very long, for pads, organ and ambient music"
        case .spring: return "a spring: the boing of a guitar amp's tank, and the drums and guitar of reggae and dub"
        case .gated: return "a gated room: bright and dense, cut off a quarter of a second after every hit, the eighties snare; only hits sent to it ring"
        }
    }
}

/// What a strip's effects do in one section: the rotating speaker's speed, the echo send, where
/// the filter is, how hard the pump ducks.
public struct SectionEffect: Hashable, Codable, Sendable {
    public var section: SectionID
    public var part: PartID
    /// The rotating speaker turning fast here (true) or slow (false); nil keeps the strip's.
    public var fast: Bool?
    /// The echo send here, dB; nil keeps the strip's.
    public var echoDB: Double?
    /// The strip's filter here: at this corner from the section's first beat, Hz. Nil keeps the
    /// strip's. Omitted when nil, as the two below are.
    public var filterFromHz: Double?
    /// Swept to this corner by the section's last beat, on a logarithmic path; nil holds it at
    /// `filterFromHz`.
    public var filterToHz: Double?
    /// How far the pump ducks here, dB: 0 is no pump here; nil keeps the strip's.
    public var pumpDB: Double?

    public init(section: SectionID, part: PartID, fast: Bool? = nil, echoDB: Double? = nil,
                filterFromHz: Double? = nil, filterToHz: Double? = nil, pumpDB: Double? = nil) {
        self.section = section
        self.part = part
        self.fast = fast
        self.echoDB = echoDB
        self.filterFromHz = filterFromHz
        self.filterToHz = filterToHz
        self.pumpDB = pumpDB
    }

    /// Whether it sets nothing at all.
    public var isEmpty: Bool { fast == nil && echoDB == nil && filterFromHz == nil && filterToHz == nil && pumpDB == nil }

    /// "low-pass swept from 300 Hz to open", "held at 800 Hz", for a sentence about the section.
    public func filterWords(_ kind: StripFilter.Kind) -> String? {
        guard let from = filterFromHz else { return nil }
        func said(_ hz: Double) -> String {
            (kind == .lowPass ? hz >= 19_000 : hz <= 21) ? "open" : StripFilter.hz(hz)
        }
        if let to = filterToHz, abs(to - from) > 0.5 { return "\(kind.name) swept from \(said(from)) to \(said(to))" }
        return "\(kind.name) held at \(said(from))"
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

    /// A strip's modulation as it plays: its own, or `instrument`'s when it sets none; `.off`
    /// takes either away.
    public func modulation(for part: PartID, instrument: StripModulation?) -> StripModulation? {
        guard let modulation = strip(for: part)?.modulation ?? instrument, modulation.kind != .off else { return nil }
        return modulation
    }

    /// What a section does to a strip, when it does anything.
    public func sectionEffect(for part: PartID, in section: SectionID?) -> SectionEffect? {
        guard let section else { return nil }
        return sectionEffects?.first { $0.section == section && $0.part == part }
    }

    /// How far a strip's pump ducks in a section, dB; nil when it has no pump, 0 when the section
    /// turns it off.
    public func pumpDB(for part: PartID, in section: SectionID?) -> Double? {
        guard let pump = strip(for: part)?.pump else { return nil }
        return sectionEffect(for: part, in: section)?.pumpDB ?? pump.depthDB
    }

    /// Sets what one strip's effects do in one section, dropping the entry when nothing is left
    /// in it.
    public mutating func setSectionEffect(_ effect: SectionEffect) {
        var effects = (sectionEffects ?? []).filter { !($0.section == effect.section && $0.part == effect.part) }
        if !effect.isEmpty { effects.append(effect) }
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
