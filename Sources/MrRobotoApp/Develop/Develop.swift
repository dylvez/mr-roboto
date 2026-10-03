import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// Developing a song: the loop, arranged.
//
// A song in this app starts as a loop — a groove, a bass line, chords, a tune — and a form laid
// over it played that loop at every length: the intro was the hook, shorter. What makes a form an
// arrangement is that its sections differ, and they differ mostly by the same parts played another
// way. This reads the song and its form and writes that: a variation of each part for the
// sections that want one, which parts sit out where, a level for each section, and the master's
// target. Nothing here makes a sound or asks anybody anything; it is worked out from the song.

/// Where the form a development uses came from.
public enum DevelopedForm: Equatable, Sendable {
    /// Asked for, as a line of sections.
    case given
    /// The song's own, as it was arranged.
    case kept
    /// The genre's usual arrangement.
    case genre(String)
    /// The app's: a song with no genre and no form of its own.
    case standard

    public var words: String {
        switch self {
        case .given: return "the form asked for"
        case .kept: return "the form it had"
        case .genre(let name): return "the way \(name) is usually arranged"
        case .standard: return "a verse-and-hook form"
        }
    }
}

/// What developing a song does, worked out before anything is written.
public struct Development: Equatable, Sendable {

    /// One section, as it will play.
    public struct Plays: Equatable, Sendable, Identifiable {
        public var id: SectionID
        public var name: String
        public var bars: Int
        public var role: SectionRole
        public var intensity: Double
        /// What it plays, each in a few words: "drums, thinned", "chords".
        public var parts: [String]
    }

    public var form: DevelopedForm
    /// The form as it will be.
    public var sections: [Section]
    /// What is written: the variations, in the order they are kept.
    public var versions: [PartVersion]
    /// The mix with each section's levels and the master's target, when either moves.
    public var mix: Mix?
    public var plays: [Plays]
    /// The loudness the master is brought to once everything is in.
    public var targetLUFS: Double
    /// The genre it was developed in, by name.
    public var genre: String?

    public var bars: Int { sections.reduce(0) { $0 + $1.lengthInBars } }

    /// "8 sections, 104 bars"
    public var shape: String {
        "\(sections.count) section\(sections.count == 1 ? "" : "s"), \(bars) bars"
    }

    /// What was written, by name: "Thinned drums, Drums with no kick, Held bass".
    public var written: [String] { versions.map(PartLabel.title(of:)) }
}

public enum Develop {

    /// How much developing does to the harmony and the tune beyond arranging them.
    public enum Harmony: Equatable, Sendable {
        /// As it first was: one bridge a mode, every chorus on the verse's chords, the tune held
        /// back in the verses and an octave up the last time.
        case plain
        /// More of the song made its own: the bridge is one of several, the last arrival's chords
        /// are said another way with the bass following them, a chorus in the middle leans on its
        /// bar lines, and a line answers the tune where it rests. The seed chooses among them, so
        /// two songs do not get the same bridge and one song gets the same one every time.
        case varied(seed: UInt64)

        var seed: UInt64? {
            if case .varied(let seed) = self { return seed }
            return nil
        }
    }

    /// A seed for a song: the same song always the same, another song another.
    public static func seed(for song: Song) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in song.id.rawValue.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// The form a song with no genre and none of its own is given.
    public static let standardForm: [(name: String, bars: Int)] = [
        ("Intro", 4), ("Verse", 16), ("Hook", 8), ("Verse", 16), ("Hook", 8), ("Bridge", 8), ("Hook", 8), ("Outro", 4),
    ]

    /// Who signs a variation when nobody else is named: arranging is the Producer's.
    public static let author = Author.persona("Producer")

    /// Whether the song's form is one somebody made, and so one to keep, however short: anything
    /// but the Intro, Verse and Hook a new song starts with, which is a shape to begin in. A form
    /// of four sections and twenty-six bars with a bridge in three-four is the song its writer
    /// asked for; how long it should be is theirs to say, in Structure or to the band.
    public static func hasOwnForm(_ song: Song) -> Bool {
        guard !song.sections.isEmpty else { return false }
        return song.sections.map(\.name) != Song.startingForm.map(\.name)
            || song.sections.map(\.lengthInBars) != Song.startingForm.map(\.bars)
    }

    /// Every part of its own that plays: the loop, without the variations written from it.
    public static func loop(of song: Song) -> [PartVersion] {
        song.partIDs.compactMap { id in
            guard !song.isVariation(id), let newest = song.latestVersion(of: id),
                  StructureModel.playableTypes.contains(newest.type), StructureModel.plays(newest) else { return nil }
            return newest
        }
    }

    /// Whether any section plays a variation, or holds a part at a version of its own: whether
    /// the song has been developed, here or by hand.
    public static func isDeveloped(_ song: Song) -> Bool {
        song.sections.contains { $0.stitch.contains { song.isVariation($0.part) || isHeld($0, in: song) } }
    }

    /// Whether a part of this kind belongs in a section of a developed form: what a part written
    /// after the song was developed joins. An intro arranged without its bass does not take the
    /// next bass line written, and the tune stays out of a bridge. A section nobody developed
    /// takes whatever it has none of, as it always did.
    static func wants(_ type: PartType, in section: Section, of song: Song) -> Bool {
        guard section.intensity != nil else { return true }
        return belongs(type, in: section, of: song)
    }

    /// Whether a part of this kind plays in a section of this name, as developing would have it:
    /// the bass out of an intro that has chords to stand on, the tune out of a bridge.
    static func belongs(_ type: PartType, in section: Section, of song: Song) -> Bool {
        let role = SectionRole.named(section.name)
        switch type {
        case .bassline:
            let others = song.versions(playing: section).contains { [.progression, .melody, .sample].contains($0.type) }
            return bassTreatment(for: role, othersSound: others) != nil
        case .melody:
            return tuneTreatment(for: role, hasPeak: song.sections.contains { SectionRole.named($0.name).isPeak },
                                 isLastPeak: false, nobodySings: isInstrumental(song)) != nil
        default:
            return true
        }
    }

    /// Whether a lane holds its part at one version. That is a decision somebody made about that
    /// section, and developing leaves it exactly as it is.
    static func isHeld(_ lane: Lane, in song: Song) -> Bool {
        if lane.pin.flatMap(song.version) != nil { return true }
        // A variation somebody asked for in this section by name — its chords said another way,
        // its tune pushed — is theirs the same way: it stays where it was put.
        return song.versions.first { $0.partID == lane.part }?.operation == Operation.placed
    }

    /// Whether a genre is dance music, which builds with a roll and lifts with an open hat.
    public static func isElectronic(_ genre: GenreProfile?) -> Bool {
        genre.map { ["electronic", "dance"].contains($0.family) } ?? false
    }

    /// - Parameters:
    ///   - form: the sections asked for, in order. Nil takes the song's own when it has one, then
    ///     the genre's, then `standardForm`.
    ///   - genre: the genre the song was placed in. Its form and its loudness are used, so it is
    ///     the genre somebody said, never one guessed from a feel: a shuffle at 131 guessed as
    ///     folk would be arranged as four verses and mastered for a guitar and a voice.
    ///   - electronic: whether the drums are treated as dance music's. Nil reads it off `genre`.
    ///     This much a guess is good for.
    ///   - instrumental: whether nobody sings. Nil reads it off the song: no words and no takes.
    /// - Returns: nil when nothing in the song plays.
    ///   - harmony: how far past arranging it goes; `.plain` is what developing always did.
    public static func plan(for song: Song, form given: [(name: String, bars: Int)]? = nil,
                            genre: GenreProfile? = nil, electronic: Bool? = nil, instrumental: Bool? = nil,
                            harmony varying: Harmony = .plain, by author: Author = Develop.author) -> Development? {
        let loop = loop(of: song)
        guard !loop.isEmpty else { return nil }
        let beats = song.timeSignature.beatsPerBar
        let electronic = electronic ?? isElectronic(genre)
        let nobodySings = instrumental ?? isInstrumental(song)

        // MARK: The form

        let source: DevelopedForm
        var shape: [Shape]
        if let given, !given.isEmpty {
            source = .given
            shape = matched(given, to: song)
        } else if hasOwnForm(song) {
            source = .kept
            shape = song.sections.map { Shape(name: $0.name, bars: $0.lengthInBars, existing: $0, role: .named($0.name)) }
        } else if let genre, let usual = genre.form, !usual.sections.isEmpty {
            source = .genre(genre.name)
            shape = split(matched(usual.sections.map { ($0.name, $0.bars) }, to: song))
        } else {
            source = .standard
            shape = split(matched(standardForm, to: song))
        }
        guard !shape.isEmpty else { return nil }

        // MARK: What the song plays, and where

        let mains = Set(loop.map(\.partID))
        let byPart = Dictionary(loop.map { ($0.partID, $0) }, uniquingKeysWith: { first, _ in first })
        func roots(of section: Section?) -> [PartID] {
            var seen = Set<PartID>()
            return (section?.stitch ?? []).filter { !isHeld($0, in: song) }
                .map { song.strip(of: $0.part) }.filter { mains.contains($0) && seen.insert($0).inserted }
        }
        /// The lanes of a section that hold a part at one version, kept as they are.
        func held(in section: Section?) -> [Lane] { (section?.stitch ?? []).filter { isHeld($0, in: song) } }
        let usual = usualParts(of: song, loop: loop)
        let placed = placedParts(of: song, loop: loop)
        func ordered(_ parts: [PartID]) -> [PartVersion] {
            StructureModel.playableTypes.flatMap { type in parts.compactMap { byPart[$0] }.filter { $0.type == type } }
        }
        func several(_ type: PartType) -> Bool { loop.count { $0.type == type } > 1 }

        let peaks = shape.indices.filter { shape[$0].role.isPeak }
        let lastPeak = peaks.last
        let chords = loop.last { $0.type == .progression && usual.contains($0.partID) } ?? loop.last { $0.type == .progression }
        var spans: [ChordSpan] = []
        var harmony: Progression?
        if let chords, case .progression(let progression) = chords.kind {
            spans = progression.bars.flatMap(\.chords)
            harmony = progression
        }
        // What a bridge's own chords are called: "bridge", and by their length when a second
        // bridge is another length and so has chords of its own.
        var bridges: [Int: String] = [:]
        let drums = loop.last { $0.type == .groove && usual.contains($0.partID) } ?? loop.last { $0.type == .groove }
        // The way the genre plays its chords, where the song arrives, when its chords are held.
        let lifted = genre.flatMap { KeysPattern.usual(inGenre: $0.id) }.flatMap { $0 == .held ? nil : $0 }

        // MARK: Variations, each written once

        var versions: [PartVersion] = []
        var made: [String: PartID] = [:]
        /// The part that plays `kind` as a variation of `root` — one the song has, one written in
        /// this pass, or a new one.
        func variation(of root: PartVersion, named name: String, kind: PartKind, note: String) -> PartID {
            let key = "\(root.partID)|\(name)"
            if let part = made[key] { return part }
            let existing = song.variations(of: root.partID).first { song.variation(of: $0)?.name == name }
            if let existing, let newest = song.latestVersion(of: existing) {
                // Yours, once you have changed it: a variation edited by hand is kept as it is.
                if newest.kind != kind, newest.operation == Operation.developed {
                    versions.append(newest.deriving(kind, by: author, operation: Operation.developed, note: note))
                }
                made[key] = existing
                return existing
            }
            let version = root.varying(kind, as: name, by: author, note: note)
            versions.append(version)
            made[key] = version.partID
            return version.partID
        }
        func label(_ word: String, _ root: PartVersion) -> String {
            several(root.type) ? "\(word) (\(PartLabel.title(of: root)))" : word
        }

        // MARK: Section by section

        var sections: [Section] = []
        var plays: [Development.Plays] = []
        var occurrences: [SectionRole: Int] = [:]
        var roles: [(section: SectionID, role: SectionRole)] = []
        /// The line that answers the tune in the last arrival, once written: its part, and where.
        var answering: (part: PartID, section: SectionID)?

        for (index, entry) in shape.enumerated() {
            let role = entry.role
            occurrences[role, default: 0] += 1
            let kept = held(in: entry.existing)
            let keptParts = Set(kept.map { song.strip(of: $0.part) })
            let named = roots(of: entry.existing)
            // A section that holds every part it plays at a version of its own was arranged by
            // hand, whole: nothing is added to it.
            let parts = ordered(named.isEmpty ? (kept.isEmpty ? usual : []) : named).filter { !keptParts.contains($0.partID) }
            let othersSound = parts.contains { [.progression, .melody, .sample].contains($0.type) }
                || kept.contains { lane in song.version(playing: lane).map { [.progression, .melody, .sample].contains($0.type) } ?? false }
            // A way in or a way out in two sections: the drums alone at the far end, the chords and
            // a lighter bass at the near one.
            let opens = role == .intro && index + 1 < shape.count && shape[index + 1].role == .intro
            let secondIn = role == .intro && index > 0 && shape[index - 1].role == .intro
            let closes = role == .outro && index > 0 && shape[index - 1].role == .outro
            var lanes: [Lane] = kept
            var said: [String] = kept.compactMap { lane in
                song.version(playing: lane).map { "\(StructureModel.name(of: $0.type).lowercased()), as it was set" }
            }
            var rolls = false
            // A bridge goes somewhere else, when everything pitched in it is the loop's and will
            // follow: a tune or a bass line written for this section, a part held at a version,
            // and a chop — whose notes nobody wrote down — all stay over the chords they were
            // written to.
            let pitched: Set<PartType> = [.bassline, .progression, .melody, .sample]
            // Somewhere else for it to go, when the song has chords to leave: as long as this
            // section, or a length that goes into it, so the chord that leads back is reached.
            let elsewhere = role == .bridge
                ? harmony.flatMap { bridge(from: $0, bars: entry.bars, variant: varying.seed.map { Int($0 % 97) }) } : nil
            let bridgeName = elsewhere.map { chords -> String in
                if let name = bridges[chords.bars.count] { return name }
                let name = bridges.isEmpty ? "bridge" : "bridge-\(chords.bars.count)"
                bridges[chords.bars.count] = name
                return name
            } ?? "bridge"
            let leaves = role == .bridge && kept.isEmpty && elsewhere != nil
                && parts.contains { $0.partID == chords?.partID }
                && !parts.contains { $0.type == .sample }
                && !parts.contains { pitched.contains($0.type) && placed.contains($0.partID) }

            // The last arrival's chords said another way, when the song is being varied: one move
            // the sheet has room for and the tune still sits on.
            var lastWay: Reharmonized?
            if let seed = varying.seed, index == lastPeak, !leaves, let chords, case .progression(let sheet) = chords.kind,
               parts.contains(where: { $0.partID == chords.partID }), !placed.contains(chords.partID),
               !parts.contains(where: { $0.type == .sample }) {
                let tunes = parts.compactMap { part -> Melody? in
                    if case .melody(let tune) = part.kind, !placed.contains(part.partID) { return tune }
                    return nil
                }
                lastWay = lastArrival(of: sheet, bars: entry.bars, beatsPerBar: beats, under: tunes, key: song.key ?? sheet.key, seed: seed)
            }

            for part in parts {
                // Written for the sections it is in: played there as it was written.
                if placed.contains(part.partID) {
                    // Once: the line that answers the tune is put in beside the tune it answers.
                    if !lanes.contains(part: part.partID) {
                        lanes.append(Lane(part: part.partID))
                        said.append(word(for: part.type))
                    }
                    continue
                }
                switch part.kind {
                case .groove(let groove):
                    let onChop = ChopSound.part(of: SongPlayback.drumSoundID(for: part.partID, in: song)) != nil
                    var treatment = grooveTreatment(for: role, electronic: electronic)
                    if onChop, let chosen = treatment, ![.thin, .noKick].contains(chosen) { treatment = nil }
                    let layers = role == .drop ? 2 : 1
                    if let treatment,
                       let varied = GrooveVariation.vary(groove, as: treatment, bars: entry.bars, beatsPerBar: beats,
                                                         layers: layers, electronic: electronic) {
                        let through = treatment == .build || treatment == .push
                        let name = treatment.rawValue + (through ? "-\(varied.bars)" : layers > 1 && treatment == .lift ? "-2" : "")
                        let id = variation(of: part, named: name, kind: .groove(varied),
                                           note: "\(label(grooveName(treatment, layers: layers), part)): \(grooveNote(treatment, bars: varied.bars))")
                        lanes.append(Lane(part: id))
                        said.append("drums, \(treatment.word)")
                        rolls = treatment == .build
                    } else {
                        lanes.append(Lane(part: part.partID))
                        said.append("drums")
                    }
                case .bassline(let line):
                    if opens || closes { continue }
                    if leaves, let elsewhere,
                       let followed = bass(line, over: elsewhere, under: drums, tempo: song.tempo, timeSignature: song.timeSignature) {
                        let id = variation(of: part, named: bridgeName, kind: .bassline(followed),
                                           note: "\(label("Bridge bass", part)): written to the bridge's chords, \(elsewhere.symbols())")
                        lanes.append(Lane(part: id))
                        said.append("bass, on the bridge's chords")
                        continue
                    }
                    guard let choice = secondIn ? .vary(.light) : bassTreatment(for: role, othersSound: othersSound) else { continue }
                    // Under chords said another way, the line follows them: the same rhythm, the
                    // notes that were the old chord's moved onto the new one.
                    if let lastWay, let harmony, case .plain = choice,
                       let followed = refit(line, from: harmony, to: lastWay.progression, beatsPerBar: beats) {
                        let id = variation(of: part, named: "last-\(lastWay.move.rawValue)", kind: .bassline(followed),
                                           note: "\(label("Last chorus bass", part)): the line, following \(lastWay.progression.symbols())")
                        lanes.append(Lane(part: id))
                        said.append("bass, following the chords")
                        continue
                    }
                    if case .vary(let treatment) = choice,
                       let varied = BassVariation.vary(line, as: treatment, chords: spans, bars: entry.bars, beatsPerBar: beats) {
                        let name = treatment.rawValue + (treatment == .pulse ? "-\(varied.lengthInBars ?? entry.bars)" : "")
                        let id = variation(of: part, named: name, kind: .bassline(varied),
                                           note: "\(label(bassName(treatment), part)): \(bassNote(treatment))")
                        lanes.append(Lane(part: id))
                        said.append("bass, \(treatment.word)")
                    } else {
                        lanes.append(Lane(part: part.partID))
                        said.append("bass")
                    }
                case .progression(let sheet):
                    if opens || closes { continue }
                    // Every player on the song's chords goes where the song goes: a guitar and a
                    // horn section left on the verse's chords under a bridge's are two harmonies at
                    // once. Each keeps how it plays; only what it plays changes.
                    let onTheSongsChords = part.partID == chords?.partID || (harmony.map { sheet.bars == $0.bars } ?? false)
                    if leaves, var elsewhere, onTheSongsChords {
                        if part.partID != chords?.partID { elsewhere.playing = sheet.playing }
                        let id = variation(of: part, named: bridgeName, kind: .progression(elsewhere),
                                           note: "\(label("Bridge chords", part)): \(elsewhere.symbols()), somewhere else for the bridge to go")
                        lanes.append(Lane(part: id))
                        // What the bridge plays: these, or the ones somebody wrote there by hand.
                        var plays = elsewhere
                        if case .progression(let kept)? = (versions.last { $0.partID == id } ?? song.latestVersion(of: id))?.kind { plays = kept }
                        said.append("chords, its own: \(plays.symbols())")
                        continue
                    }
                    let family = InstrumentVoiceSpec.preset(id: SongPlayback.instrumentID(for: part.partID, in: song))?.family ?? "keys"
                    if let lastWay, onTheSongsChords {
                        var played = lastWay.progression
                        played.playing = sheet.playing
                        if let treatment = chordsTreatment(for: role, playing: sheet.playing, lifted: lifted, family: family) {
                            played.playing = treatment.isPlain ? nil : treatment
                        }
                        let id = variation(of: part, named: "last-\(lastWay.move.rawValue)", kind: .progression(played),
                                           note: "\(label("Last chorus chords", part)): \(lastWay.says)")
                        lanes.append(Lane(part: id))
                        said.append("chords, \(lastWay.move.name.lowercased()): \(played.symbols())")
                        continue
                    }
                    if let treatment = chordsTreatment(for: role, playing: sheet.playing, lifted: lifted, family: family) {
                        var played = sheet
                        played.playing = treatment.isPlain ? nil : treatment
                        let name = treatment.keysPattern == .held ? "held" : "played-\(treatment.pattern)"
                        let id = variation(of: part, named: name, kind: .progression(played),
                                           note: "\(label(treatment.keysPattern == .held ? "Held chords" : "\(treatment.keysPattern.name) chords", part)): "
                                               + "\(sheet.symbols()), \(treatment.keysPattern.about.components(separatedBy: " (").first ?? treatment.keysPattern.name.lowercased())")
                        lanes.append(Lane(part: id))
                        said.append("chords, \(treatment.keysPattern.name.lowercased())")
                    } else {
                        lanes.append(Lane(part: part.partID))
                        said.append("chords")
                    }
                case .melody(let tune):
                    guard var choice = tuneTreatment(for: role, hasPeak: !peaks.isEmpty, isLastPeak: index == lastPeak,
                                                     nobodySings: nobodySings) else { continue }
                    // An arrival in the middle of a varied song is not the first one again: it is
                    // said twice with a second ending where there is room, and leans on its bar
                    // lines where there is not.
                    if varying.seed != nil, case .plain = choice, role.isPeak, index != peaks.first, index != lastPeak {
                        let loop = tune.loopBars(beatsPerBar: beats)
                        choice = .vary(entry.bars >= loop * 2 ? .answered : .pushed)
                    }
                    // An octave above what a recorded instrument has recordings of is silence: a
                    // tenor is not lifted past its top note. It leans on its bar lines instead, or
                    // is said twice with a second ending.
                    if case .vary(.lift) = choice, let top = tune.notes.map(\.pitch.midi).max(),
                       let reach = ImportedInstruments.spec(id: SongPlayback.instrumentID(for: part.partID, in: song)).flatMap(ImportedInstruments.highestNote(of:)),
                       top + 12 > reach {
                        let loop = tune.loopBars(beatsPerBar: beats)
                        choice = varying.seed != nil ? .vary(entry.bars >= loop * 2 ? .answered : .pushed) : .plain
                    }
                    if case .vary(let treatment) = choice,
                       let varied = TuneVariation.vary(tune, as: treatment, bars: entry.bars, beatsPerBar: beats,
                                                       key: song.key ?? harmony?.key, chords: spans) {
                        let twice = (varied.lengthInBars ?? 0) > tune.loopBars(beatsPerBar: beats)
                        let name = treatment == .lift ? (twice ? "lift" : "raised") : treatment.rawValue
                        let id = variation(of: part, named: name, kind: .melody(varied),
                                           note: "\(tuneTitle(treatment, twice: twice)) of \(PartLabel.title(of: part))")
                        lanes.append(Lane(part: id))
                        said.append("tune, \(tuneName(treatment, twice: twice))")
                    } else {
                        lanes.append(Lane(part: part.partID))
                        said.append("tune")
                    }
                    // And where the song arrives for the last time, a line answers it in its rests.
                    if varying.seed != nil, index == lastPeak, answering == nil,
                       let answers = TuneVariation.answers(to: tune, beatsPerBar: beats) {
                        let note = answerNote(to: part)
                        let existing = loop.first { isAnswer($0) }
                        let id: PartID
                        if let existing {
                            id = existing.partID
                            if existing.kind != .melody(answers) {
                                versions.append(existing.deriving(.melody(answers), by: author, operation: Operation.developed, note: note))
                            }
                        } else {
                            let version = PartVersion(partID: PartID(), kind: .melody(answers), author: author,
                                                      operation: Operation.developed, note: note)
                            versions.append(version)
                            id = version.partID
                        }
                        if !lanes.contains(part: id) { lanes.append(Lane(part: id)) }
                        said.append("a line answering the tune")
                        answering = (id, entry.existing?.id ?? SectionID())
                    }
                case .sample:
                    lanes.append(Lane(part: part.partID))
                    said.append("chop")
                default:
                    continue
                }
            }

            // A little more each time a kind of section comes round, and the last arrival the most.
            var intensity = min(1, role.intensity + 0.03 * Double(occurrences[role, default: 1] - 1))
            if index == lastPeak { intensity = max(intensity, 0.95) }
            var section = entry.existing ?? Section(name: entry.name, stitch: [], lengthInBars: entry.bars)
            section.name = entry.name
            section.lengthInBars = max(1, entry.bars)
            // The stems stay: a section that stood keeps the ones it played, a new one takes every
            // stem the form has. Developing arranges what is written and leaves the record be.
            let stems = entry.existing.map(song.stemLanes(in:)) ?? song.seatedStems.map { Lane(part: $0) }
            section.stitch = lanes + stems.filter { !lanes.contains(part: $0.part) }
            section.intensity = (intensity * 100).rounded() / 100
            // A build runs to the bar line: its roll is the way in, and a fill over it would stop it.
            section.transitionOut = rolls ? Transition(kind: .riser) : nil
            section.transitionIn = nil
            sections.append(section)
            roles.append((section.id, role))
            if let line = answering, index == lastPeak { answering = (line.part, section.id) }
            plays.append(Development.Plays(id: section.id, name: section.name, bars: section.lengthInBars, role: role,
                                           intensity: section.intensity ?? intensity, parts: said))
        }

        // MARK: The mix

        let before = Guidance.mix(in: song) ?? .unity
        var mix = before
        let kept = Set(sections.map(\.id))
        mix.sectionGains.removeAll { !kept.contains($0.section) }
        for (section, role) in zip(sections, roles.map(\.role)) {
            // A lane held at a version of its own was levelled by whoever held it there.
            for lane in section.stitch where !isHeld(lane, in: song) {
                let strip = strip(of: lane.part, in: song, written: versions)
                guard let type = byPart[strip]?.type else { continue }
                let offset = level(of: type, in: role)
                guard offset != 0, !mix.sectionGains.contains(where: { $0.section == section.id && $0.part == strip }) else { continue }
                let base = mix.strip(for: strip)?.gainDB ?? 0
                mix.sectionGains.append(SectionGain(section: section.id, part: strip, gainDB: max(-60, min(12, base + offset))))
            }
        }
        // The answering line sits under the tune it answers.
        if let answering, !mix.sectionGains.contains(where: { $0.section == answering.section && $0.part == answering.part }) {
            let base = mix.strip(for: answering.part)?.gainDB ?? 0
            mix.sectionGains.append(SectionGain(section: answering.section, part: answering.part, gainDB: base + answeringLevel))
        }
        let target = loudness(for: genre) ?? before.master.targetLUFS
        mix.master.targetLUFS = target
        if let last = shape.last, last.role == .outro, mix.master.fadeOutBars == nil {
            mix.master.fadeOutBars = min(8, max(1, last.bars))
        }

        return Development(form: source, sections: sections, versions: versions, mix: mix == before ? nil : mix,
                           plays: plays, targetLUFS: target, genre: genre?.name)
    }

    // MARK: - The form

    struct Shape {
        var name: String
        var bars: Int
        /// The section of the song this one was, when it had one by this name: its id and what it
        /// played are kept, so its levels, its words and its parts follow it.
        var existing: Section?
        var role: SectionRole
    }

    /// A line of sections laid against the song's own: each takes the first section of its name not
    /// already taken.
    static func matched(_ form: [(name: String, bars: Int)], to song: Song) -> [Shape] {
        var free = song.sections
        return form.map { entry in
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            var existing: Section?
            if let at = free.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                existing = free.remove(at: at)
            }
            return Shape(name: name, bars: max(1, entry.bars), existing: existing, role: .named(name))
        }
    }

    /// A long way in, a long way out and a long build, each in two: the first half of an intro is
    /// the drums alone and the second brings the chords; a build's roll is its last eight bars.
    /// Only for a form the app chose. A form you arranged or asked for is played as it stands.
    static func split(_ shape: [Shape]) -> [Shape] {
        shape.flatMap { entry -> [Shape] in
            switch entry.role {
            case .intro where entry.bars >= 16, .outro where entry.bars >= 16:
                let half = entry.bars / 2
                return [Shape(name: entry.name, bars: half, existing: entry.existing, role: entry.role),
                        Shape(name: "\(entry.name) 2", bars: entry.bars - half, existing: nil, role: entry.role)]
            case .build where entry.bars > GrooveVariation.longestBars:
                return [Shape(name: entry.name, bars: entry.bars - 8, existing: entry.existing, role: .build),
                        Shape(name: "Rise", bars: 8, existing: nil, role: .build)]
            default:
                return [entry]
            }
        }
    }

    /// What a new section plays: of each kind, the part the song plays most, and the parts of that
    /// kind that play beside it somewhere. A second groove written for the bridge stays the
    /// bridge's; a counter-melody that plays with the tune goes where the tune goes.
    static func usualParts(of song: Song, loop: [PartVersion]) -> [PartID] {
        var bars: [PartID: Int] = [:]
        for section in song.sections {
            for root in Set(section.stitch.map { song.strip(of: $0.part) }) { bars[root, default: 0] += max(1, section.lengthInBars) }
        }
        var out: [PartID] = []
        for type in StructureModel.playableTypes {
            let kind = loop.filter { $0.type == type }
            guard let principal = kind.enumerated().max(by: { a, b in
                let ba = bars[a.element.partID] ?? 0, bb = bars[b.element.partID] ?? 0
                return ba != bb ? ba < bb : a.offset < b.offset
            })?.element else { continue }
            out.append(principal.partID)
            for other in kind where other.partID != principal.partID {
                let together = song.sections.contains { section in
                    let roots = Set(section.stitch.map { song.strip(of: $0.part) })
                    return roots.contains(principal.partID) && roots.contains(other.partID)
                }
                if together { out.append(other.partID) }
            }
        }
        return out
    }

    /// The parts written for the sections they are in, which developing leaves where they are and
    /// as they are: a part that plays in fewer than two sections in three, and has never been
    /// varied. A part you make joins every section, so the loop is in all of them; what is in one
    /// or two was put there — the bridge's own beat, the figure written for the main section —
    /// and thinning it, or saving it for the hook, would undo the reason it was written.
    ///
    /// Counted against the sections its kind plays in. In a song already developed the tune is
    /// out of the intro, the bridge and the outro by arrangement, and a tune written since is in
    /// every section a tune belongs in: that is the loop's, not a part with a place of its own.
    static func placedParts(of song: Song, loop: [PartVersion]) -> Set<PartID> {
        let sections = song.sections.filter { !$0.stitch.isEmpty }
        guard sections.count >= 3 else { return [] }
        return Set(loop.filter { version in
            let part = version.partID
            guard song.variations(of: part).isEmpty else { return false }
            let plays = sections.filter { $0.stitch.contains { song.strip(of: $0.part) == part } }
            // By the section's name, developed or not: what a part is must not change because
            // the song around it was developed.
            let could = sections.filter { section in
                plays.contains { $0.id == section.id } || belongs(version.type, in: section, of: song)
            }
            return !plays.isEmpty && plays.count * 3 < could.count * 2
        }.map(\.partID))
    }

    static func word(for type: PartType) -> String {
        switch type {
        case .groove: return "drums"
        case .bassline: return "bass"
        case .progression: return "chords"
        case .melody: return "tune"
        case .sample: return "chop"
        default: return type.rawValue
        }
    }

    /// No words with a syllable in them, and nothing sung.
    static func isInstrumental(_ song: Song) -> Bool {
        let words = song.versions.last { $0.type == .lyric }.flatMap { version -> Lyric? in
            if case .lyric(let lyric) = version.kind { return lyric }
            return nil
        }
        let hasWords = words?.lines.contains { !$0.syllables.isEmpty } ?? false
        return !hasWords && Guidance.takes(in: song).isEmpty && Guidance.comps(in: song).isEmpty
    }

    /// The strip a lane's part plays through, for a part the song holds or one about to be written.
    static func strip(of part: PartID, in song: Song, written: [PartVersion]) -> PartID {
        if let variation = written.first(where: { $0.partID == part })?.variation { return song.strip(of: variation.of) }
        return song.strip(of: part)
    }

    // MARK: - What each kind of section asks of each part

    enum Choice<Treatment> {
        /// As written.
        case plain
        case vary(Treatment)
    }

    static func grooveTreatment(for role: SectionRole, electronic: Bool) -> GrooveTreatment? {
        switch role {
        case .intro, .outro: return .thin
        case .breakdown: return .noKick
        case .build: return electronic ? .build : .push
        case .pre: return .push
        case .hook, .drop: return .lift
        case .bridge: return .ride
        case .verse, .groove, .solo: return nil
        }
    }

    /// Nil sits the bass out. An intro is the drums and the chords; with nothing but drums to
    /// stand on, the bass comes in lightly instead.
    static func bassTreatment(for role: SectionRole, othersSound: Bool) -> Choice<BassTreatment>? {
        switch role {
        case .intro: return othersSound ? nil : .vary(.light)
        case .outro, .bridge: return .vary(.light)
        case .breakdown: return .vary(.held)
        case .build: return .vary(.pulse)
        case .verse, .groove, .pre, .hook, .drop, .solo: return .plain
        }
    }

    /// Nil sits the tune out. It is saved for where the song arrives; a song with nowhere to
    /// arrive plays it in its verses; and with nobody singing, the verses get its first phrase.
    static func tuneTreatment(for role: SectionRole, hasPeak: Bool, isLastPeak: Bool, nobodySings: Bool) -> Choice<TuneTreatment>? {
        switch role {
        case .hook, .drop: return isLastPeak ? .vary(.lift) : .plain
        case .solo: return .plain
        case .breakdown: return .vary(.sparse)
        case .verse, .groove:
            guard hasPeak else { return .plain }
            return nobodySings ? .vary(.sparse) : nil
        case .intro, .outro, .pre, .build, .bridge: return nil
        }
    }

    /// A section's level against the part's own, in dB. Small: the arrangement makes a section
    /// bigger by what plays in it, and the level only agrees.
    static func level(of type: PartType, in role: SectionRole) -> Double {
        switch (type, role) {
        case (.groove, .intro), (.groove, .outro): return -2
        case (.groove, .breakdown): return -1.5
        case (.groove, .bridge): return -1
        case (.groove, .hook): return 0.5
        case (.groove, .drop): return 1
        case (.bassline, .drop): return 0.5
        case (.melody, .hook): return 1
        case (.melody, .drop): return 1.5
        case (.progression, .breakdown): return 1
        default: return 0
        }
    }

    /// The loudness a genre's records are delivered at, held to what the Engineer will master to.
    static func loudness(for genre: GenreProfile?) -> Double? {
        guard let range = genre?.range(.integratedLUFS) ?? genre?.range(.masterTargetLUFS) else { return nil }
        let typical = range.typical ?? (range.low + range.high) / 2
        return max(-20, min(-8, (typical * 2).rounded() / 2))
    }

    // MARK: - The chords

    /// How the chords are played in a section, when it is not how they are written. Chords with a
    /// rhythm are held where the song stands still; chords that are held are given the genre's
    /// rhythm where the song arrives, on an instrument that can play one. Nil plays them as written.
    static func chordsTreatment(for role: SectionRole, playing: ChordPlaying?, lifted: KeysPattern?, family: String) -> ChordPlaying? {
        let written = playing ?? ChordPlaying()
        switch role {
        case .intro, .breakdown, .outro:
            guard written.keysPattern != .held else { return nil }
            return ChordPlaying(.held, written.keysVoicing)
        case .hook, .drop:
            guard written.keysPattern == .held, let lifted, lifted.suits(family: family) else { return nil }
            return ChordPlaying(lifted, written.keysVoicing, seed: 0x4B45_5953)
        default:
            return nil
        }
    }

    /// Chords for a bridge: as long as the song's own and played the same way, starting away from
    /// home and ending on the chord that leads back. In a major key IV, V, vi, V; in a minor one
    /// VI, VII, iv, V — and from somewhere else again when the song's own chords start there.
    /// Sevenths when the song's chords have them. Nil in a key with no seven-note scale to build on.
    ///
    /// Given the bars of the section they are for, they fit it: sixteen bars of chords in a bridge
    /// of eight never reached the chord that leads back. They are the longest of sixteen, eight
    /// and four bars that is no longer than the song's own and goes into the section; in a section
    /// that is not a multiple of four, a chord a bar, the last of them the one that leads back.
    ///
    /// - Parameter variant: which of the mode's bridges, when the song is being varied; nil is the
    ///   one bridge developing always wrote.
    static func bridge(from main: Progression, bars section: Int? = nil, variant: Int? = nil) -> Progression? {
        let key = main.key, scale = key.scale, tonic = key.tonic.pitchClass
        guard scale.isHeptatonic, !main.bars.isEmpty,
              let home = scale.diatonicChord(degree: 1, root: tonic, size: 3) else { return nil }
        let minor = home.quality.hasMinorThird
        let size = main.chords.contains { !$0.quality.isTriad && $0.quality != .power } ? 4 : 3
        var degrees = minor ? [6, 7, 4, 5] : [4, 5, 6, 5]
        let opens = main.chords.first.flatMap { key.romanNumeral(for: $0)?.degree }
        if opens == degrees[0] { degrees = minor ? [4, 7, 6, 5] : [6, 4, 2, 5] }
        if let variant {
            // Somewhere else, and not the same somewhere as the last song: each ends on the five,
            // none opens where the loop does.
            let pool = (minor ? minorBridges : majorBridges).filter { $0[0] != opens }
            if !pool.isEmpty { degrees = pool[((variant % pool.count) + pool.count) % pool.count] }
        }
        let beats = main.bars[0].beats
        let own = max(4, main.bars.count)
        var count = own
        var aBar = false
        if let section, section >= 2 {
            if section % 4 == 0 {
                count = [16, 8, 4].first { $0 <= own && section % $0 == 0 } ?? 4
            } else {
                count = section
                aBar = true
            }
        }
        var bars: [ProgressionBar] = []
        for bar in 0..<count {
            let degree = aBar
                ? (bar == count - 1 ? degrees[degrees.count - 1] : degrees[bar % degrees.count])
                : degrees[min(degrees.count - 1, bar * degrees.count / count)]
            guard var chord = scale.diatonicChord(degree: degree, root: tonic, size: size) else { return nil }
            // The fifth degree leads home: major, whatever the scale makes of it.
            if degree == 5, chord.quality.hasMinorThird { chord = Chord(root: chord.root, quality: size == 4 ? .dominantSeventh : .major) }
            bars.append(ProgressionBar(chord, beats: beats))
        }
        let bridge = Progression(key: key, bars: bars, playing: main.playing)
        return bridge.chords == main.chords ? nil : bridge
    }

    /// The ways a bridge goes somewhere else in a minor key, by degree: the flat six and seven
    /// climbing; the four through the circle of fifths; down from the relative major; the six
    /// and the three; the four and the seven.
    static let minorBridges = [[6, 7, 4, 5], [4, 7, 3, 5], [3, 7, 6, 5], [6, 3, 4, 5], [4, 7, 6, 5]]
    /// And in a major one: the four and five; the six falling by thirds; three–six–two–five round
    /// the circle; the six and the three.
    static let majorBridges = [[4, 5, 6, 5], [6, 4, 2, 5], [3, 6, 2, 5], [6, 3, 4, 5]]

    /// How far under its strip the line answering the tune sits, dB.
    static let answeringLevel = -5.0

    /// What the line that answers a tune is called. It is a part of its own — its own strip, its
    /// own level — and not a variation, so its note is what says it is not the song's tune.
    static func answerNote(to tune: PartVersion) -> String {
        "\(answerPrefix)\(PartLabel.title(of: tune)): its phrase endings again in the rests, an octave away"
    }
    static let answerPrefix = "Answers to "

    /// Whether a version is the line that answers a tune: asked wherever "the song's tune" is
    /// looked up, because that line is newer than the tune it answers.
    public static func isAnswer(_ version: PartVersion) -> Bool {
        version.type == .melody && (version.note ?? "").hasPrefix(answerPrefix)
    }

    /// The moves tried on the last arrival's chords, in the order a seed starts from.
    static let lastArrivalMoves: [Reharmonization] = [.bassLine, .passing, .secondaryDominant, .borrowed, .turnaround, .tritone, .uneven]

    /// The last arrival's chords said another way: the first move, from where the seed starts,
    /// that the sheet has room for, that fits the section, and that leaves the tune on its chords.
    static func lastArrival(of sheet: Progression, bars: Int, beatsPerBar: Int, under tunes: [Melody], key: Key,
                            seed: UInt64) -> Reharmonized? {
        let moves = lastArrivalMoves
        let start = Int((seed / 97) % UInt64(moves.count))
        let section = Double(bars * max(1, beatsPerBar))
        for offset in moves.indices {
            let move = moves[(start + offset) % moves.count]
            guard let made = Reharmonize.apply(move, to: sheet, variant: Int(seed % 7)) else { continue }
            let length = made.progression.bars.reduce(0) { $0 + $1.beats }
            guard length <= section + 1e-9, section.truncatingRemainder(dividingBy: length) < 1e-9 else { continue }
            let sits = tunes.allSatisfy { tune in
                let was = MelodyObservation.of(tune, label: "", key: key, progression: sheet, beatsPerBar: beatsPerBar).chordToneRatio
                let now = MelodyObservation.of(tune, label: "", key: key, progression: made.progression, beatsPerBar: beatsPerBar).chordToneRatio
                return now >= min(was, Melodist.chordToneFloor) - 0.05
            }
            if sits { return made }
        }
        return nil
    }

    /// A bass line made to follow other chords without being written again: its rhythm and its
    /// shape kept, each note that was on the old chord's bass moved to the new chord's, and each
    /// that the new chord does not hold moved to the nearest note it does. Nil when nothing moves.
    static func refit(_ line: Bassline, from old: Progression, to new: Progression, beatsPerBar: Int) -> Bassline? {
        func chord(in sheet: Progression, at beat: Double) -> Chord? {
            let total = sheet.bars.reduce(0) { $0 + $1.beats }
            guard total > 0 else { return nil }
            var at = beat.truncatingRemainder(dividingBy: total)
            for span in sheet.spans {
                if at < span.beats - 1e-9 { return span.chord }
                at -= span.beats
            }
            return sheet.spans.last?.chord
        }
        let own = Double(line.loopBars(beatsPerBar: beatsPerBar) * max(1, beatsPerBar))
        let total = new.bars.reduce(0) { $0 + $1.beats }
        guard own > 0, total > 0 else { return nil }
        let passes = max(1, Int((total / own).rounded(.up)))
        var notes: [NoteEvent] = []
        var moved = false
        // Inside the register the line already plays in: a root moved to the fifth below it is a
        // note under the instrument.
        let lowest = line.notes.map(\.pitch.midi).min() ?? 0, highest = line.notes.map(\.pitch.midi).max() ?? 127
        for pass in 0..<passes {
            for note in line.notes {
                let start = note.start + Double(pass) * own
                guard start < total - 1e-9 else { continue }
                var midi = note.pitch.midi
                if let was = chord(in: old, at: start), let now = chord(in: new, at: start), was != now {
                    let pitchClass = note.pitch.pitchClass
                    var target: PitchClass?
                    if pitchClass == was.bass { target = now.bass }
                    else if !now.pitchClasses.contains(pitchClass) {
                        target = now.pitchClasses.min { a, b in
                            min(pitchClass.distance(to: a), 12 - pitchClass.distance(to: a)) < min(pitchClass.distance(to: b), 12 - pitchClass.distance(to: b))
                        }
                    }
                    if let target, target != pitchClass {
                        let up = pitchClass.distance(to: target)
                        midi += up <= 6 ? up : up - 12
                        if midi < lowest { midi += 12 } else if midi > highest, midi - 12 >= lowest { midi -= 12 }
                        moved = true
                    }
                }
                notes.append(NoteEvent(pitch: Pitch(midi: midi), start: start, duration: min(note.duration, total - start),
                                       velocity: note.velocity))
            }
        }
        guard moved else { return nil }
        var followed = line
        followed.notes = notes
        followed.lengthInBars = Int((total / Double(max(1, beatsPerBar))).rounded(.up))
        return followed
    }

    /// The bass line over other chords: written again in the same hands, lighter, under the same
    /// drums, when the line says whose hands wrote it; else its roots, held.
    static func bass(_ line: Bassline, over chords: Progression, under groove: PartVersion?, tempo: Double,
                     timeSignature: TimeSignature) -> Bassline? {
        let spans = chords.spans
        if let hands = line.hands.flatMap(BassLineage.init(rawValue:)), let groove, case .groove(let drums) = groove.kind {
            var written = BassWriter.write(BassRequest(key: chords.key, chords: spans, groove: drums, tempo: tempo,
                                                        timeSignature: timeSignature, lineage: hands, density: 0.4,
                                                        sound: line.sound, seed: 0x4252_4944_4745, bars: chords.bars.count))
            written.hands = line.hands
            if !written.notes.isEmpty { return written }
        }
        return BassVariation.vary(line, as: .held, chords: spans, bars: chords.bars.count, beatsPerBar: timeSignature.beatsPerBar)
    }

    // MARK: - Names and notes

    static func grooveName(_ treatment: GrooveTreatment, layers: Int) -> String {
        switch treatment {
        case .thin: return "Thinned drums"
        case .noKick: return "Drums, no kick"
        case .build: return "Build"
        case .push: return "Push"
        case .lift: return layers > 1 ? "Drop drums" : "Lifted drums"
        case .ride: return "Drums on the ride"
        }
    }

    static func grooveNote(_ treatment: GrooveTreatment, bars: Int) -> String {
        switch treatment {
        case .thin: return "the kick and what keeps time, for the way in and the way out"
        case .noKick: return "the kick out and everything else a step quieter, for a breakdown"
        case .build: return "\(bars) bars with no kick, the snare from quarters to eighths to sixteenths"
        case .push: return "\(bars) bars of the loop, the snare on every beat of the last of them"
        case .lift: return "the loop with a layer on top, for where the song arrives"
        case .ride: return "the hats moved to the ride, for a bridge"
        }
    }

    static func bassName(_ treatment: BassTreatment) -> String {
        switch treatment {
        case .light: return "Lighter bass"
        case .held: return "Held bass"
        case .pulse: return "Bass pulse"
        }
    }

    static func bassNote(_ treatment: BassTreatment) -> String {
        switch treatment {
        case .light: return "half the notes, the ones on the bar and the middle of it"
        case .held: return "the root of each chord, held under a breakdown"
        case .pulse: return "eighths on the root, louder as they go, under a build"
        }
    }

    static func tuneName(_ treatment: TuneTreatment, twice: Bool) -> String {
        switch treatment {
        case .lift: return twice ? "then an octave up" : "an octave up"
        case .sparse: return "first phrase only"
        case .answered, .pushed, .sequenced: return treatment.word
        }
    }

    /// What a variation of a tune is called, before the tune's own name: the ledger cuts a name
    /// at forty-four letters, and what tells a variation from its tune has to be inside them.
    static func tuneTitle(_ treatment: TuneTreatment, twice: Bool) -> String {
        switch treatment {
        case .lift: return twice ? "Lift" : "Octave up"
        case .sparse: return "First phrase"
        case .answered: return "Second ending"
        case .pushed: return "Push"
        case .sequenced: return "Sequence"
        }
    }
}
