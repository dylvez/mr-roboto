import Foundation
import MusicTheory
import Performance
import SongGraph

// M4 Gate C, P11: the three evals over every bible — goldens (GoldenRunner), disagreements and
// blind readings — and the one report `make evals` writes.

// MARK: - Disagreements

/// Every disagreement a bible declares, exercised: its proposal is put to both personas and the
/// two verdicts have to differ. A declared disagreement with no proposal on either side of the
/// pair is a failure, because a disagreement nobody can provoke is a sentence, not a rule.
public enum DisagreementRunner {

    public struct Result: Hashable, Sendable, CustomStringConvertible {
        public var persona: PersonaID
        public var with: PersonaID
        public var about: String
        /// Nil when neither side of the pair carries a proposal.
        public var proposal: PersonaProposal?
        public var mine: VerdictShape?
        public var theirs: VerdictShape?
        public var expected: DisagreementExpectation?
        public var problem: String?

        public var passed: Bool { problem == nil }

        public var description: String {
            let head = "\(passed ? "✔" : "✘") \(persona.rawValue) ↔ \(with.rawValue): \(about)"
            if let problem { return head + " — \(problem)" }
            return head + " — \(mine?.description ?? "?") vs \(theirs?.description ?? "?")"
        }
    }

    /// Every declaration in the cast, in bible order.
    public static func run(_ cast: Cast) -> [Result] {
        cast.personas.flatMap { persona in
            persona.bible.disagreements.map { run($0, of: persona, in: cast) }
        }
    }

    public static func run(_ disagreement: PersonaDisagreement, of persona: any Persona, in cast: Cast) -> Result {
        var result = Result(persona: persona.bible.id, with: disagreement.with, about: disagreement.about)
        guard let other = cast.persona(disagreement.with) else {
            result.problem = "\(disagreement.with.rawValue) is not in the cast"
            return result
        }
        // The proposal is this declaration's, or the reciprocal declaration's with the sides swapped.
        var proposal = disagreement.proposal
        var expected = disagreement.expects
        if proposal == nil,
           let back = other.bible.disagreements.first(where: { $0.with == persona.bible.id && $0.proposal != nil }) {
            proposal = back.proposal
            expected = back.expects.map { DisagreementExpectation(mine: $0.theirs, theirs: $0.mine) }
        }
        guard let proposal else {
            result.problem = "not exercised: neither side carries a proposal"
            return result
        }
        result.proposal = proposal
        result.expected = expected
        let mine = VerdictShape(persona.consider(proposal))
        let theirs = VerdictShape(other.consider(proposal))
        result.mine = mine
        result.theirs = theirs
        if mine == theirs {
            result.problem = "does not show: both said \(mine.description)"
        } else if case .defer_ = mine, case .defer_ = theirs {
            result.problem = "does not show: both deferred"
        } else if let expected, expected.mine != mine || expected.theirs != theirs {
            result.problem = "not the way the bible says: expected \(expected.mine.description) vs \(expected.theirs.description), got \(mine.description) vs \(theirs.description)"
        }
        return result
    }

    public static func failures(_ results: [Result]) -> [Result] { results.filter { !$0.passed } }
}

// MARK: - Blind readings

/// A labelled sheet: material a persona reads with its label hidden, and what a reading of it
/// should say. Lives in `Bench/personas/blind/<persona>.json`.
public struct BlindSheet: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var id: String
        /// What the sheet knows and the persona is not told.
        public var label: String
        public var material: BlindMaterial
        /// Rule id → whether the reading on it should hold.
        public var expects: [String: Bool]
        /// The genre the material is read in, by a profile's id: the readings go through its
        /// `GenreLens`, as they would in a song placed in it. Nil reads with the persona's own lines.
        public var genre: String?
    }
    public var persona: PersonaID
    public var items: [Item]

    public static func load(from url: URL) throws -> BlindSheet {
        try JSONDecoder().decode(BlindSheet.self, from: Data(contentsOf: url))
    }

    /// Every sheet in a directory, by file name.
    public static func loadAll(in directory: URL) throws -> [BlindSheet] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(load(from:))
    }
}

/// What a blind item is made of. The reading is built by `BlindRunner`, which knows how each
/// persona observes; the sheet only names the material.
public enum BlindMaterial: Codable, Hashable, Sendable {
    /// A feel from the library, at a tempo. The Beatmaker's material.
    case feel(name: String, tempo: Double?)
    /// A line the writer writes under a feel's groove. The Bassist's material.
    case bassline(hands: String, lagMS: Double, tempo: Double, feel: String, density: Double, seed: UInt64)
    /// A song's form: sections by name and length, at a tempo. The Peer's material.
    case form(sections: [FormSection], tempo: Double)
    /// Chords as a lead sheet writes them, in a key. The Harmonist's material.
    case progression(chords: String, key: String)
    /// A genre profile's progression in numerals, in a key. The Harmonist's material too.
    case numerals(roman: String, mode: String?, key: String)

    public struct FormSection: Codable, Hashable, Sendable {
        public var name: String
        public var bars: Int
    }

    private enum CodingKeys: String, CodingKey { case kind, name, tempo, hands, lagMS, feel, density, seed, sections, chords, key, roman, mode }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "feel":
            self = .feel(name: try c.decode(String.self, forKey: .name), tempo: try c.decodeIfPresent(Double.self, forKey: .tempo))
        case "bassline":
            self = .bassline(hands: try c.decode(String.self, forKey: .hands), lagMS: try c.decode(Double.self, forKey: .lagMS),
                             tempo: try c.decode(Double.self, forKey: .tempo), feel: try c.decode(String.self, forKey: .feel),
                             density: try c.decodeIfPresent(Double.self, forKey: .density) ?? 0.5,
                             seed: try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0xBA55_0001)
        case "form":
            self = .form(sections: try c.decode([FormSection].self, forKey: .sections), tempo: try c.decode(Double.self, forKey: .tempo))
        case "progression":
            self = .progression(chords: try c.decode(String.self, forKey: .chords), key: try c.decode(String.self, forKey: .key))
        case "numerals":
            self = .numerals(roman: try c.decode(String.self, forKey: .roman), mode: try c.decodeIfPresent(String.self, forKey: .mode),
                             key: try c.decode(String.self, forKey: .key))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown blind material \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .feel(let name, let tempo):
            try c.encode("feel", forKey: .kind); try c.encode(name, forKey: .name); try c.encodeIfPresent(tempo, forKey: .tempo)
        case .bassline(let hands, let lagMS, let tempo, let feel, let density, let seed):
            try c.encode("bassline", forKey: .kind); try c.encode(hands, forKey: .hands); try c.encode(lagMS, forKey: .lagMS)
            try c.encode(tempo, forKey: .tempo); try c.encode(feel, forKey: .feel); try c.encode(density, forKey: .density); try c.encode(seed, forKey: .seed)
        case .form(let sections, let tempo):
            try c.encode("form", forKey: .kind); try c.encode(sections, forKey: .sections); try c.encode(tempo, forKey: .tempo)
        case .progression(let chords, let key):
            try c.encode("progression", forKey: .kind); try c.encode(chords, forKey: .chords); try c.encode(key, forKey: .key)
        case .numerals(let roman, let mode, let key):
            try c.encode("numerals", forKey: .kind); try c.encode(roman, forKey: .roman)
            try c.encodeIfPresent(mode, forKey: .mode); try c.encode(key, forKey: .key)
        }
    }
}

public enum BlindRunner {

    public struct Result: Hashable, Sendable, CustomStringConvertible {
        public var persona: PersonaID
        public var item: String
        public var label: String
        /// Rule → (expected, read). Nil read means the persona said nothing on that rule.
        public var checks: [String: (expected: Bool, read: Bool?)]
        public var problem: String?

        public var matched: Int { checks.values.filter { $0.read == $0.expected }.count }
        public var score: Double { checks.isEmpty ? 0 : Double(matched) / Double(checks.count) }
        public var passed: Bool { problem == nil && matched == checks.count }

        public var description: String {
            if let problem { return "✘ \(item) (\(label)) — \(problem)" }
            let misses = checks.filter { $0.value.read != $0.value.expected }.keys.sorted()
            return "\(passed ? "✔" : "✘") \(item) (\(label)) — \(matched)/\(checks.count)"
                + (misses.isEmpty ? "" : " missed \(misses.joined(separator: ", "))")
        }

        public static func == (a: Result, b: Result) -> Bool { a.persona == b.persona && a.item == b.item }
        public func hash(into hasher: inout Hasher) { hasher.combine(persona); hasher.combine(item) }
    }

    /// Every item on a sheet, read blind: the observation's label is the item's number, never the
    /// sheet's label.
    public static func run(_ sheet: BlindSheet, feels: FeelLibrary = .standard, genres: GenreBook = .standard) -> [Result] {
        sheet.items.enumerated().map { index, item in
            var result = Result(persona: sheet.persona, item: item.id, label: item.label,
                                checks: item.expects.mapValues { ($0, nil) })
            let blind = "blind item \(index + 1)"
            let readings: [PersonaReading]
            do {
                let read = try read(item.material, as: sheet.persona, label: blind, feels: feels)
                if let name = item.genre {
                    guard let profile = genres.profile(named: name) else { throw Unreadable(description: "no genre called \(name)") }
                    guard let bible = Cast.standard.persona(sheet.persona)?.bible else { throw Unreadable(description: "no persona \(sheet.persona)") }
                    readings = GenreLens(profile).apply(read, bible: bible)
                } else {
                    readings = read
                }
            } catch {
                result.problem = "\(error)"
                return result
            }
            for reading in readings where result.checks[reading.rule] != nil {
                result.checks[reading.rule]?.read = reading.holds
            }
            return result
        }
    }

    public static func failures(_ results: [Result]) -> [Result] { results.filter { !$0.passed } }

    struct Unreadable: Error, CustomStringConvertible {
        var description: String
    }

    /// The persona's own observation of the material, built the way the app would build it.
    static func read(_ material: BlindMaterial, as persona: PersonaID, label: String, feels: FeelLibrary) throws -> [PersonaReading] {
        switch (material, persona) {
        case (.feel(let name, let tempo), .beatmaker):
            guard let feel = feels.feel(named: name) else { throw Unreadable(description: "no feel named \(name)") }
            var observation = GrooveObservation(feel, tempo: tempo)
            observation.label = label
            return Beatmaker().read(observation)
        case (.bassline(let hands, let lagMS, let tempo, let feelName, let density, let seed), .bassist):
            guard let feel = feels.feel(named: feelName) else { throw Unreadable(description: "no feel named \(feelName)") }
            guard let lineage = BassLineage(rawValue: hands) else { throw Unreadable(description: "no hands called \(hands)") }
            let request = BassRequest(key: Key(parsing: "E minor") ?? Key(tonic: NoteName(.e), mode: .aeolian), groove: feel.groove, tempo: tempo,
                                      timeSignature: feel.timeSignature, lineage: lineage, lagMS: lagMS, density: density, seed: seed)
            let line = BassWriter.write(request)
            let observation = BassObservation(label: label, bassline: line, groove: feel.groove, chords: [], tempo: tempo,
                                              timeSignature: feel.timeSignature, options: .feel(feel))
            return Bassist().read(observation)
        case (.form(let sections, let tempo), .peer):
            var song = Song(title: label, tempo: tempo)
            song.sections = sections.map { Section(name: $0.name, stitch: [], lengthInBars: $0.bars) }
            return Peer().read(FormObservation.of(song))
        case (.numerals(let roman, let mode, let keyName), .harmonist):
            guard let key = Key(parsing: keyName) else { throw Unreadable(description: "no key \(keyName)") }
            guard let line = GenreNumerals.symbols(roman, in: key, mode: mode) else { throw Unreadable(description: "unreadable numerals \(roman)") }
            return try read(.progression(chords: line, key: keyName), as: persona, label: label, feels: feels)
        case (.progression(let chords, let keyName), .harmonist):
            guard let key = Key(parsing: keyName) else { throw Unreadable(description: "no key \(keyName)") }
            switch Progression.parse(chords, key: key) {
            case .success(let progression): return Harmonist().read(HarmonyObservation.of(progression, label: label))
            case .failure(let error): throw Unreadable(description: "\(error)")
            }
        default:
            throw Unreadable(description: "\(persona.rawValue) does not read that material")
        }
    }
}

// MARK: - The report

public enum EvalReport {

    /// One Markdown document: every golden, disagreement and blind eval per persona, with a pass
    /// or the measured miss.
    public static func markdown(cast: Cast,
                                goldens: [GoldenRunner.Result],
                                disagreements: [DisagreementRunner.Result],
                                blind: [BlindRunner.Result],
                                date: Date = Date()) -> String {
        var out = "# Persona evals\n\n"
        let stamp = ISO8601DateFormatter().string(from: date)
        out += "Written by `make evals` on \(stamp). Goldens run through `GoldenRunner`, disagreements through "
            + "`DisagreementRunner`, blind sheets through `BlindRunner` (`Bench/personas/blind/`).\n\n"
        let g = goldens.filter(\.passed).count, d = disagreements.filter(\.passed).count, b = blind.filter(\.passed).count
        out += "| Eval | Passed | Of |\n|---|---:|---:|\n"
        out += "| Goldens | \(g) | \(goldens.count) |\n| Disagreements | \(d) | \(disagreements.count) |\n| Blind | \(b) | \(blind.count) |\n\n"
        for persona in cast.personas {
            let id = persona.bible.id
            out += "## \(persona.bible.name)\n\n"
            let mine = goldens.filter { $0.persona == id }
            let prose = persona.bible.goldens.count - mine.count
            out += "### Goldens (\(mine.filter(\.passed).count)/\(mine.count) executable, \(prose) prose-only)\n\n"
            for r in mine { out += "- \(r.description)\n" }
            let dis = disagreements.filter { $0.persona == id }
            out += "\n### Disagreements (\(dis.filter(\.passed).count)/\(dis.count))\n\n"
            for r in dis { out += "- \(r.description)\n" }
            let sheet = blind.filter { $0.persona == id }
            if !sheet.isEmpty {
                let matched = sheet.map(\.matched).reduce(0, +), total = sheet.map(\.checks.count).reduce(0, +)
                out += "\n### Blind (\(sheet.filter(\.passed).count)/\(sheet.count) items, \(matched)/\(total) readings)\n\n"
                for r in sheet { out += "- \(r.description)\n" }
            }
            out += "\n"
        }
        return out
    }
}
