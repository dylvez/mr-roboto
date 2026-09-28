import Foundation
import MusicTheory

// What the app knows about a genre, as data.
//
// The bibles are the band's knowledge, and every one of them was written from one idiom: the
// sampled, behind-the-beat hip-hop and neo-soul the app started in. A persona holding a house track
// to Dilla's swing or a country master to Bob Katz's −14 LUFS is not wrong about Dilla or Katz; it
// is wrong about the song. A genre profile is the other half: what is normal *in this genre*, on the
// same features the personas already measure, so a reading can say both — the persona's number and
// the genre's — and the verdict follows the genre.
//
// The method is the bibles' method. Every claim says whether anybody wrote it down; a range with
// nothing behind it is left out rather than guessed; the numbers are in the feature's own unit.
// The profiles ship as `Resources/Genres/<id>.json`.

/// A genre's range on one feature: what a practitioner would not blink at.
public struct GenreRange: Hashable, Sendable, Codable {
    public var feature: Feature
    public var low: Double
    public var high: Double
    public var typical: Double?
    public var unit: String
    public var evidence: Evidence

    public init(_ feature: Feature, _ low: Double, _ high: Double, typical: Double? = nil, unit: String, evidence: Evidence) {
        self.feature = feature
        self.low = min(low, high)
        self.high = max(low, high)
        self.typical = typical
        self.unit = unit
        self.evidence = evidence
    }

    public func contains(_ value: Double) -> Bool { value >= low && value <= high }

    /// "118–128 BPM", or "124 BPM" when the range is one number.
    public var span: String {
        func f(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.3g", x) }
        return (low == high ? f(low) : "\(f(low))–\(f(high))") + (unit.isEmpty ? "" : " \(unit)")
    }

    private enum CodingKeys: String, CodingKey { case feature, low, high, typical, unit, evidence }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(Feature(try c.decode(String.self, forKey: .feature)), try c.decode(Double.self, forKey: .low),
                  try c.decode(Double.self, forKey: .high), typical: try c.decodeIfPresent(Double.self, forKey: .typical),
                  unit: try c.decodeIfPresent(String.self, forKey: .unit) ?? "", evidence: try c.decode(Evidence.self, forKey: .evidence))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(feature.rawValue, forKey: .feature)
        try c.encode(low, forKey: .low)
        try c.encode(high, forKey: .high)
        try c.encodeIfPresent(typical, forKey: .typical)
        try c.encode(unit, forKey: .unit)
        try c.encode(evidence, forKey: .evidence)
    }
}

/// One thing true of the genre that is not a number: where the kick goes, how the form turns.
public struct GenreNote: Hashable, Sendable, Codable {
    /// groove, form, harmony, bass, arrangement, sound, mix, melody, lyrics.
    public var area: String
    public var text: String
    public var evidence: Evidence
}

/// A typical arrangement, section by section.
public struct GenreForm: Hashable, Sendable, Codable {
    public struct Section: Hashable, Sendable, Codable {
        public var name: String
        public var bars: Int
    }
    public var sections: [Section]
    public var evidence: Evidence

    public var bars: Int { sections.reduce(0) { $0 + $1.bars } }
}

/// A progression the genre leans on, in numerals.
public struct GenreProgression: Hashable, Sendable, Codable {
    public var roman: String
    public var mode: String?
    public var text: String
    public var evidence: Evidence
}

/// The app's sounds that suit the genre, by id.
public struct GenreSounds: Hashable, Sendable, Codable {
    public var machines: [String]
    public var bass: [String]
    public var instruments: [String]

    public init(machines: [String] = [], bass: [String] = [], instruments: [String] = []) {
        self.machines = machines
        self.bass = bass
        self.instruments = instruments
    }
}

/// A named practitioner whose working method is documented.
public struct GenreLineage: Hashable, Sendable, Codable {
    public var name: String
    public var period: String
    public var why: String
    public var evidence: Evidence
}

/// A record that shows the genre, and what to listen for in it.
public struct GenreReference: Hashable, Sendable, Codable {
    public var artist: String
    public var title: String
    public var year: Int?
    public var listenFor: String
    public var features: [String]
    public var evidence: Evidence
}

/// What someone new to the genre gets wrong.
public struct GenrePitfall: Hashable, Sendable, Codable {
    public var text: String
    public var evidence: Evidence
}

/// Everything the app knows about one genre.
public struct GenreProfile: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var aliases: [String]
    /// A broad family — electronic, hip-hop, latin — for grouping in a picker.
    public var family: String
    /// A genre this one grew from, when the profile says so.
    public var parent: String?
    public var summary: String
    public var summaryEvidence: Evidence
    /// The feel library's style tags this genre covers: how a groove's feel names its genre.
    public var idioms: [String]
    /// Feels in the library that belong to it, by name.
    public var feels: [String]
    public var meters: [String]
    public var ranges: [GenreRange]
    public var notes: [GenreNote]
    public var form: GenreForm?
    public var progressions: [GenreProgression]
    /// The bass writer's hands that fit.
    public var bassHands: [String]
    public var sounds: GenreSounds
    public var lineages: [GenreLineage]
    public var references: [GenreReference]
    public var pitfalls: [GenrePitfall]

    private enum CodingKeys: String, CodingKey {
        case id, name, aliases, family, parent, summary, summaryEvidence, idioms, feels, meters, ranges, notes, form
        case progressions, bassHands, sounds, lineages, references, pitfalls
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        family = try c.decodeIfPresent(String.self, forKey: .family) ?? id
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        summary = try c.decode(String.self, forKey: .summary)
        summaryEvidence = try c.decode(Evidence.self, forKey: .summaryEvidence)
        idioms = try c.decodeIfPresent([String].self, forKey: .idioms) ?? []
        feels = try c.decodeIfPresent([String].self, forKey: .feels) ?? []
        meters = try c.decodeIfPresent([String].self, forKey: .meters) ?? ["4/4"]
        ranges = try c.decodeIfPresent([GenreRange].self, forKey: .ranges) ?? []
        notes = try c.decodeIfPresent([GenreNote].self, forKey: .notes) ?? []
        form = try c.decodeIfPresent(GenreForm.self, forKey: .form)
        progressions = try c.decodeIfPresent([GenreProgression].self, forKey: .progressions) ?? []
        bassHands = try c.decodeIfPresent([String].self, forKey: .bassHands) ?? []
        sounds = try c.decodeIfPresent(GenreSounds.self, forKey: .sounds) ?? GenreSounds()
        lineages = try c.decodeIfPresent([GenreLineage].self, forKey: .lineages) ?? []
        references = try c.decodeIfPresent([GenreReference].self, forKey: .references) ?? []
        pitfalls = try c.decodeIfPresent([GenrePitfall].self, forKey: .pitfalls) ?? []
    }

    /// The genre's range on a feature, when it states one.
    public func range(_ feature: Feature) -> GenreRange? { ranges.first { $0.feature == feature } }

    /// The tempo range, when the profile states one.
    public var tempo: GenreRange? { range(.tempoBPM) }

    public func notes(_ area: String) -> [GenreNote] { notes.filter { $0.area == area } }

    /// The ways a song's tempo can be counted against this genre's: as written, in half time and
    /// double time (trap written at 140 or felt at 70; salsa written, as the feel library does, at
    /// half the quarter note the sources count), and a compound meter's eighth notes as its dotted
    /// quarters (a 12/8 slow blues at 165 is the 55 a blues player counts).
    public func readings(of tempo: Double, in meter: TimeSignature) -> [Double] {
        var out = [tempo, tempo / 2, tempo * 2]
        if meter.beatUnit == 8, meter.beatsPerBar % 3 == 0 { out.append(tempo / 3) }
        return out
    }

    /// Whether a song at this tempo and meter is at a tempo the genre plays, counted any of the ways
    /// `readings` allows. True when the profile states no tempo.
    public func fits(tempo: Double, meter: TimeSignature) -> Bool {
        guard let range = self.tempo else { return true }
        return readings(of: tempo, in: meter).contains(where: range.contains)
    }

    /// Every claim in the profile, for the method's count.
    public var evidence: [Evidence] {
        [summaryEvidence] + ranges.map(\.evidence) + notes.map(\.evidence) + (form.map { [$0.evidence] } ?? [])
            + progressions.map(\.evidence) + lineages.map(\.evidence) + references.map(\.evidence) + pitfalls.map(\.evidence)
    }
}
