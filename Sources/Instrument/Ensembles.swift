import Foundation

// Recorded instruments played the way players play them.
//
// Two things a single recording cannot do, and a library of them can. A trumpet's held notes and
// its staccato were recorded as two instruments, and a part on one of them played every note the
// same way: a stab cut from a held note is the slow front of a long one, chopped off. And a horn
// section was four instruments nobody could put on one part, so chords on brass were one trumpet
// playing all four notes of every chord.
//
// `Articulations` puts the two recordings of one instrument together: the notes let go quickly
// play on the short one. `Ensembles` puts several instruments together as a section: a chord is
// dealt out one note to a player, a line is doubled in unison and octaves. Both are made when the
// library is loaded, from what is in it, and neither writes anything to it.

// MARK: - Articulations

public enum Articulations {
    /// A note held for this long or less, in seconds, plays on an instrument's short recording
    /// when it has one. About an eighth note at 120: the stabs and off-beats of a horn part and a
    /// tongued run go short, a legato line of eighths at a ballad's tempo stays held.
    public static let shortNote = 0.25

    /// The words a short recording's name ends with.
    static let shortWords = ["staccato", "spiccato", "short"]
    /// The words after a comma that say how a held recording is played, not what it is: "Tenor
    /// Saxophone, Vibrato" is a tenor saxophone, and "Tenor Saxophone, Studio" is another one.
    static let styleWords = ["vibrato", "non-vibrato", "sustain", "sustained", "legato", "arco"]

    /// What a short recording is a short version of: "Trumpet Staccato" is the trumpet's,
    /// "Baritone Saxophone, 1926 Staccato" the 1926 baritone's. Nil when the name does not end
    /// with a word that says it is short.
    static func stem(ofShort name: String) -> String? {
        let lowered = name.lowercased()
        for word in shortWords {
            for joint in [" ", ", "] where lowered.hasSuffix(joint + word) {
                let stem = String(lowered.dropLast(joint.count + word.count)).trimmingCharacters(in: .whitespaces)
                return stem.isEmpty ? nil : stem
            }
        }
        return nil
    }

    /// The instrument a held recording is, without how it is played.
    static func stem(ofHeld name: String) -> String {
        let lowered = name.lowercased()
        guard let comma = lowered.range(of: ", ", options: .backwards) else { return lowered }
        let after = String(lowered[comma.upperBound...])
        return styleWords.contains(after) ? String(lowered[..<comma.lowerBound]) : lowered
    }

    /// Each held instrument's short partner, by id: a recording whose name says it is the short
    /// version of the instrument the held one is. A held recording with no partner is left out.
    public static func partners(among specs: [InstrumentVoiceSpec]) -> [String: InstrumentVoiceSpec] {
        let sampled = specs.filter { $0.engine == .sampled && $0.sampledKit != nil && !$0.isEnsemble }
        var shorts: [String: InstrumentVoiceSpec] = [:]
        for spec in sampled {
            if let stem = stem(ofShort: spec.name), shorts[stem] == nil { shorts[stem] = spec }
        }
        var out: [String: InstrumentVoiceSpec] = [:]
        for spec in sampled where stem(ofShort: spec.name) == nil {
            let name = spec.name.lowercased()
            if let short = shorts[name] ?? shorts[stem(ofHeld: name)] { out[spec.id] = short }
        }
        return out
    }
}

// MARK: - Ensembles

/// A section of recorded instruments, played as one: what a genre means by "horns" or "strings".
public struct Ensemble: Sendable, Hashable {
    /// One chair in the section.
    public struct Seat: Sendable, Hashable {
        /// What the player is called in a sentence: "trumpet", "violas".
        public var name: String
        /// The recordings that can sit in this chair, by name, the first in the library taken.
        public var recordings: [String]
        /// Where the player sounds best: a line dealt to it is moved toward here.
        public var centre: Int
        /// Where it sits in the stereo picture, -1 left … +1 right, as a section is set up.
        public var pan: Float
        /// How far under the lead it plays, in decibels: the inner voices sit in the chord.
        public var gainDB: Float

        public init(_ name: String, _ recordings: [String], centre: Int, pan: Float, gainDB: Float = 0) {
            self.name = name
            self.recordings = recordings
            self.centre = centre
            self.pan = pan
            self.gainDB = gainDB
        }
    }

    public var id: String
    public var name: String
    public var family: String
    public var summary: String
    /// Top to bottom.
    public var seats: [Seat]
    /// The top note of a chord is the chord tone nearest this.
    public var lead: Int
    /// Whether the bottom player takes the chord's bass note in its own register rather than a
    /// note of the close voicing above: cellos under the violins and violas.
    public var rootBelow: Bool

    /// A trumpet, alto and tenor saxophones and a trombone: the four-horn section of soul, funk
    /// and the big band's saxes and brass in miniature. Close voicings under the trumpet.
    public static let hornSection = Ensemble(
        id: "ensemble-horn-section", name: "Horn Section", family: "brass",
        summary: "Recorded trumpet, alto and tenor saxophones and trombone as one section: a chord is dealt out a note "
            + "each, close under the trumpet; a line is played in unison and octaves. Short notes are tongued.",
        seats: [
            Seat("trumpet", ["Trumpet"], centre: 72, pan: 0.12),
            Seat("alto saxophone", ["Alto Saxophone", "Alto Saxophone, Close"], centre: 67, pan: -0.3, gainDB: -3),
            Seat("tenor saxophone", ["Tenor Saxophone, Vibrato", "Tenor Saxophone, Non-Vibrato", "Tenor Saxophone, Studio"],
                 centre: 62, pan: 0.32, gainDB: -2),
            Seat("trombone", ["Trombone"], centre: 55, pan: -0.14, gainDB: -2),
        ],
        lead: 74, rootBelow: false)

    /// A trumpet, a tenor saxophone and a trombone: the small section of reggae, ska, salsa and
    /// Afrobeat.
    public static let hornTrio = Ensemble(
        id: "ensemble-horn-trio", name: "Horn Trio", family: "brass",
        summary: "Recorded trumpet, tenor saxophone and trombone as one section: three-note chords under the trumpet, "
            + "and lines in unison and octaves. Short notes are tongued.",
        seats: [
            Seat("trumpet", ["Trumpet"], centre: 72, pan: 0.15),
            Seat("tenor saxophone", ["Tenor Saxophone, Vibrato", "Tenor Saxophone, Non-Vibrato", "Tenor Saxophone, Studio"],
                 centre: 63, pan: -0.28, gainDB: -2),
            Seat("trombone", ["Trombone"], centre: 56, pan: 0.25, gainDB: -2),
        ],
        lead: 74, rootBelow: false)

    /// Violins in two parts, violas and cellos: the string section, the cellos on the bass of
    /// the chord.
    public static let stringSection = Ensemble(
        id: "ensemble-string-section", name: "String Section", family: "strings",
        summary: "Recorded violins in two parts, violas and cellos as one section: the upper three close under the "
            + "first violins, the cellos on the chord's bass; a line in octaves. Short notes are spiccato.",
        seats: [
            Seat("first violins", ["Violin Section"], centre: 74, pan: -0.38),
            Seat("second violins", ["Violin Section"], centre: 67, pan: -0.14, gainDB: -2),
            Seat("violas", ["Viola Section"], centre: 60, pan: 0.18, gainDB: -2),
            Seat("cellos", ["Cello Section"], centre: 48, pan: 0.36, gainDB: -1),
        ],
        lead: 72, rootBelow: true)

    public static let all: [Ensemble] = [hornSection, hornTrio, stringSection]

    public static func ensemble(id: String) -> Ensemble? { all.first { $0.id == id } }

    /// The sections the library can seat, as instruments: every chair filled from what is in it.
    /// A section missing a player is not offered rather than offered short.
    public static func available(among specs: [InstrumentVoiceSpec]) -> [InstrumentVoiceSpec] {
        let byName = Dictionary(specs.filter { $0.engine == .sampled && $0.sampledKit != nil && !$0.isEnsemble }
                                    .map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return all.compactMap { ensemble in
            var members: [String] = []
            for seat in ensemble.seats {
                guard let found = seat.recordings.lazy.compactMap({ byName[$0.lowercased()] }).first else { return nil }
                members.append(found.id)
            }
            var spec = InstrumentVoiceSpec(id: ensemble.id, name: ensemble.name, family: ensemble.family, engine: .sampled,
                                           summary: ensemble.summary)
            spec.members = members
            return spec
        }
    }
}

// MARK: - A section in a kit

/// The players of a section as a kit that holds them all knows them, and the rule that deals a
/// chord out to them. Kept in the kit (`KitManifest.ensemble`), so whatever plays notes on it —
/// the transport, a Compare, the Chords surface, a controller — is heard as the section.
public struct KitEnsemble: Hashable, Codable, Sendable {
    public struct Player: Hashable, Codable, Sendable {
        public var name: String
        /// The notes it has recordings of.
        public var range: ClosedRange<Int>
        public var centre: Int

        public init(name: String, range: ClosedRange<Int>, centre: Int) {
            self.name = name
            self.range = range
            self.centre = centre
        }
    }

    /// Top to bottom; a player's index is its `Zone.layer`.
    public var players: [Player]
    public var lead: Int
    public var rootBelow: Bool

    public init(players: [Player], lead: Int, rootBelow: Bool) {
        self.players = players
        self.lead = lead
        self.rootBelow = rootBelow
    }

    /// Notes struck within this many seconds of each other are one chord.
    static let together = 0.002

    /// `hits` as the section plays them. Notes struck together with more than one pitch class
    /// between them are a chord, voiced again for the section (`voiced(_:)`) and dealt out a note
    /// to a player; a note struck alone, or in octaves, is a line, played by every player that
    /// reaches it (`doubled(_:)`). Each struck note is as hard as the hardest of its chord and as
    /// long as the longest. A drum hit, or one already dealt, is left as it is.
    ///
    /// A key held on a controller has no length and comes alone even when it is one of a chord,
    /// so it is played as it is, by the one player whose register it is in (`nearest(_:)`): a
    /// chord played by hand is heard as that chord across the section.
    public func dealt(_ hits: [VoiceSampler.Hit]) -> [VoiceSampler.Hit] {
        guard !players.isEmpty else { return hits }
        let sorted = hits.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        var out: [VoiceSampler.Hit] = []
        var start = 0
        while start < sorted.count {
            var end = start + 1
            while end < sorted.count, sorted[end].time - sorted[start].time < Self.together { end += 1 }
            let group = sorted[start..<end]
            start = end
            out += group.filter { $0.note == nil || $0.layer != nil }
            let struck = group.filter { $0.note != nil && $0.layer == nil }
            guard let first = struck.first else { continue }
            let notes = struck.compactMap(\.note)
            let velocity = struck.map(\.velocity).max() ?? first.velocity
            let durations = struck.compactMap(\.duration)
            let duration = durations.isEmpty ? nil : durations.max()
            let classes = Set(notes.map(Self.pitchClass))
            let parts: [(layer: Int, pitch: Int)]
            if duration == nil {
                parts = notes.compactMap { note in nearest(note).map { ($0, note) } }
            } else {
                parts = classes.count > 1 ? voiced(notes) : doubled(notes.max() ?? notes[0])
            }
            for (layer, pitch) in parts {
                out.append(VoiceSampler.Hit(note: pitch, velocity: velocity, at: first.time, duration: duration, layer: layer))
            }
        }
        return out
    }

    static func pitchClass(_ note: Int) -> Int { ((note % 12) + 12) % 12 }

    /// The player a note sounds in the register of: of those that reach it, the one whose centre
    /// is nearest; nil when none reaches it.
    func nearest(_ note: Int) -> Int? {
        players.indices.filter { players[$0].range.contains(note) }
            .min { (abs(note - players[$0].centre), $0) < (abs(note - players[$1].centre), $1) }
    }

    /// A line: the top player where it is written, when it reaches it; every other player in the
    /// octave nearest its own register and never over the player above. A tune round middle C
    /// is unison; one round C5 is trumpet and alto in unison over tenor and trombone an octave
    /// down.
    func doubled(_ written: Int) -> [(layer: Int, pitch: Int)] {
        var out: [(Int, Int)] = []
        var above = Int.max
        for (layer, player) in players.enumerated() {
            let octaves = stride(from: written - 48, through: written + 48, by: 12)
                .filter { player.range.contains($0) && $0 <= above }
            let pick: Int?
            if layer == 0, octaves.contains(written) {
                pick = written
            } else {
                pick = octaves.min { (abs($0 - player.centre), $0) < (abs($1 - player.centre), $1) }
            }
            guard let pick else { continue }
            out.append((layer, pick))
            above = pick
        }
        return out
    }

    /// A chord: its tones from the notes as struck, the lowest taken for its bass; the ones that
    /// say what it is kept when there are more than the players (the third and the seventh, then
    /// the colours, then the root, the fifth last); stacked close down from a top note near
    /// `lead`, the top doubled an octave down when the players outnumber the tones. Of the ways
    /// to stack it, the one with fewest semitone rubs, then the fewest players moved out of their
    /// range, then the top nearest `lead`. With `rootBelow` the bottom player takes the bass in
    /// its own register under the others.
    func voiced(_ notes: [Int]) -> [(layer: Int, pitch: Int)] {
        guard let lowest = notes.min() else { return [] }
        let bass = Self.pitchClass(lowest)
        var classes: [Int] = []
        for note in notes.sorted() where !classes.contains(Self.pitchClass(note)) { classes.append(Self.pitchClass(note)) }
        let below = rootBelow && players.count > 1
        let upperCount = below ? players.count - 1 : players.count
        func rank(_ pitchClass: Int) -> Int {
            switch (pitchClass - bass + 12) % 12 {
            case 3, 4, 10, 11: return 0
            case 0: return 3
            case 7: return 4
            default: return 1
            }
        }
        var kept = classes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .prefix(upperCount).map(\.element)
        // With the bass below, the upper voices need not repeat it when they have enough else.
        if below, kept.count > 1, kept.contains(bass), classes.count > kept.count {
            kept.removeAll { $0 == bass }
            if let next = classes.first(where: { !kept.contains($0) && $0 != bass }) { kept.append(next) }
        }
        guard !kept.isEmpty else { return [] }
        let top = players[0]
        var best: (rubs: Int, outside: Int, cost: Int, pitches: [Int])?
        for candidate in top.range where kept.contains(Self.pitchClass(candidate)) {
            var pitches = [candidate]
            var used: Set<Int> = [Self.pitchClass(candidate)]
            while pitches.count < upperCount {
                var next = pitches[pitches.count - 1] - 1
                // The next tone down not yet sounding; once every tone is, any tone: a doubling.
                let fresh = kept.contains { !used.contains($0) }
                while !(kept.contains(Self.pitchClass(next)) && (!fresh || !used.contains(Self.pitchClass(next)))) { next -= 1 }
                pitches.append(next)
                used.insert(Self.pitchClass(next))
            }
            let rubs = Self.rubs(in: pitches)
            let outside = pitches.enumerated().filter { !players[$0.offset].range.contains($0.element) }.count
            let cost = abs(candidate - lead)
            if let held = best, (held.rubs, held.outside, held.cost) <= (rubs, outside, cost) { continue }
            best = (rubs, outside, cost, pitches)
        }
        guard var pitches = best?.pitches else { return [] }
        // A voice its player cannot reach is moved by octaves into its range.
        for index in pitches.indices where !players[index].range.contains(pitches[index]) {
            let range = players[index].range
            var pitch = pitches[index]
            while pitch < range.lowerBound { pitch += 12 }
            while pitch > range.upperBound { pitch -= 12 }
            pitches[index] = pitch
        }
        var out = pitches.enumerated().filter { players[$0.offset].range.contains($0.element) }.map { ($0.offset, $0.element) }
        if below, let player = players.last {
            let ceiling = (pitches.min() ?? Int.max) - 1
            let octaves = stride(from: player.range.lowerBound, through: player.range.upperBound, by: 1)
                .filter { Self.pitchClass($0) == bass && $0 <= ceiling }
            if let pitch = octaves.min(by: { (abs($0 - player.centre), $0) < (abs($1 - player.centre), $1) }) {
                out.append((players.count - 1, pitch))
            }
        }
        return out
    }

    /// Voices a semitone apart, or a semitone and an octave: `Voicing.rubs`, which is the rule the
    /// keys player keeps.
    static func rubs(in pitches: [Int]) -> Int {
        let sorted = pitches.sorted()
        var count = 0
        for (index, low) in sorted.enumerated() {
            for high in sorted[(index + 1)...] where high - low == 1 || high - low == 13 { count += 1 }
        }
        return count
    }
}

// MARK: - Building their kits

public enum PlayedKits {

    /// The kit `spec` plays from: a section's players together, each on its own layer, or one
    /// instrument with its short recordings beside its held ones; nil for an instrument that is
    /// one recording and nothing else, whose kit is its own.
    ///
    /// Built in memory and never saved. Every recording stays in its own folder: the kit's
    /// folder is the first one's, and the others are reached from it as its neighbours (the
    /// library keeps every instrument in one directory), so a recording a section shares with
    /// the instrument on its own is the same file, decoded once.
    public static func kit(for spec: InstrumentVoiceSpec) throws -> LoadedKit? {
        if let members = spec.members {
            let ensemble = Ensemble.ensemble(id: spec.id)
            let players = members.compactMap { ImportedInstruments.spec(id: $0) }
            guard players.count == members.count, !players.isEmpty else {
                throw KitError.notADirectory(path: spec.id)
            }
            return try merged(players, seats: ensemble?.seats, lead: ensemble?.lead ?? 72,
                              rootBelow: ensemble?.rootBelow ?? false, name: spec.name)
        }
        guard spec.shortKit != nil else { return nil }
        return try merged([spec], seats: nil, lead: 72, rootBelow: false, name: spec.name)
    }

    static func merged(_ players: [InstrumentVoiceSpec], seats: [Ensemble.Seat]?, lead: Int, rootBelow: Bool,
                       name: String) throws -> LoadedKit {
        guard let first = players.first?.sampledKit else { throw KitError.notADirectory(path: name) }
        let base = URL(fileURLWithPath: first, isDirectory: true)
        let isSection = seats != nil
        var zones: [Zone] = []
        var described: [KitEnsemble.Player] = []
        var curve: VelocityCurve?
        for (layer, player) in players.enumerated() {
            guard let folder = player.sampledKit else { throw KitError.notADirectory(path: player.id) }
            let seat = seats.flatMap { layer < $0.count ? $0[layer] : nil }
            var parts: [(kit: LoadedKit, longest: Double?)] = [(try KitStore.load(from: URL(fileURLWithPath: folder, isDirectory: true)), nil)]
            if let short = player.shortKit {
                parts.append((try KitStore.load(from: URL(fileURLWithPath: short, isDirectory: true)), Articulations.shortNote))
            }
            curve = curve ?? parts[0].kit.manifest.velocityCurve
            for part in parts {
                let prefix = try reach(part.kit.folder, from: base)
                for zone in part.kit.manifest.zones {
                    var placed = zone
                    placed.id = ZoneID("\(isSection ? "p\(layer)-" : "")\(part.longest == nil ? "" : "short-")\(zone.id.rawValue)")
                    placed.sample = prefix + zone.sample
                    placed.layer = isSection ? layer : nil
                    placed.longest = part.longest
                    if let seat {
                        placed.pan = seat.pan
                        placed.gainDB += seat.gainDB
                    }
                    zones.append(placed)
                }
            }
            if let seat, let range = ImportedInstruments.noteRange(of: parts[0].kit.manifest) {
                described.append(KitEnsemble.Player(name: seat.name, range: range, centre: seat.centre))
            }
        }
        let manifest = KitManifest(
            name: name,
            description: isSection ? "A section of \(players.map(\.name).joined(separator: ", "))."
                                   : "\(name), held and short.",
            kind: .sampled, zones: zones, velocityCurve: curve ?? .squared,
            ensemble: isSection ? KitEnsemble(players: described, lead: lead, rootBelow: rootBelow) : nil)
        return LoadedKit(manifest: manifest, folder: base)
    }

    /// The way from `base` to a recording in `folder`: nothing when they are the same, the
    /// neighbour's name when they share a directory.
    static func reach(_ folder: URL, from base: URL) throws -> String {
        let here = base.standardizedFileURL, there = folder.standardizedFileURL
        if here.path == there.path { return "" }
        guard here.deletingLastPathComponent().path == there.deletingLastPathComponent().path else {
            throw KitError.notADirectory(path: there.path)
        }
        return "../\(there.lastPathComponent)/"
    }
}
