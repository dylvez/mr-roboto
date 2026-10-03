import SongGraph
import SwiftUI

// MARK: - The path

/// Where you are in the work, as a row of steps: what is done, which one you are in, what is next.
///
/// The frame already said *what to do* — "What next" in the rail, the Next chip in the dock, a verb on
/// every ledger row — but never *where you are*. Without that, the idioms were a vocabulary with no
/// grammar: a record, stems, a chop, a groove, dust, each opened from a different place, with nothing
/// saying they are one chain and that each is made out of the one before it. The path is that
/// sentence, drawn.
///
/// Which path is worked out from the song, never asked for. A song that grew from a record is a
/// **flip** (record → stems → chop → groove → dust → arrange); anything else is a **beat** made from
/// scratch (groove → kit → dust → arrange). Like `Guidance`, every step is a pure function of the
/// song graph, and a step only offers an action the frame could actually carry out.
public enum WorkPath: String, Sendable, Equatable {
    case flip
    case beat
    /// A song made of other records: their stems and bars pulled in through Sources, with drums,
    /// chords, a bass line and a tune written to them.
    case assembled

    /// What the strip calls it, before the steps.
    public var title: String {
        switch self {
        case .flip: return "Flip"
        case .beat: return "Beat"
        case .assembled: return "Assembled"
        }
    }

    /// One line on what this path makes, for the strip's tooltip.
    public var summary: String {
        switch self {
        case .flip:
            return "A record becomes a beat: its stems are separated, a bar of one is chopped, the chop is "
                + "re-grooved onto a feel, the groove gets dust, and the parts are arranged into sections."
        case .beat:
            return "A beat from scratch: a groove painted on a feel, a kit to play it, dust, and then the "
                + "parts arranged into sections."
        case .assembled:
            return "Records brought together: stems and bars of them pulled in through Sources, then drums, "
                + "chords, a bass line and a tune written to them, arranged and mixed."
        }
    }

    public var steps: [PathStep.Kind] {
        switch self {
        // Words before Sing: a take needs something to sing, and the Booth shows the stanza
        // labelled for the section it records. Before this step the path went from arranging
        // straight to the microphone, and the Lyrics surface was only in the dock.
        case .flip: return [.record, .stems, .chop, .groove, .chords, .bass, .dust, .arrange, .words, .sing, .mix]
        case .beat: return [.groove, .chords, .bass, .kit, .dust, .arrange, .words, .sing, .mix]
        case .assembled: return [.sources, .groove, .chords, .bass, .tune, .arrange, .mix]
        }
    }

    /// A song that grew from a record, or that holds one, is a flip. One that takes from other
    /// records — a source pulled in, a mashup's stems — is assembled. Everything else is a beat.
    public static func of(_ song: Song) -> WorkPath {
        let seeded = song.seeds.contains {
            if case .importedRecord = $0.kind { return true }
            return false
        }
        if seeded || Guidance.take(in: song) != nil { return .flip }
        let mashed = Guidance.stems(in: song).contains { $0.operation == Operation.mashup }
        return !song.fittedSources.isEmpty || mashed ? .assembled : .beat
    }
}

/// One step on the path, as the strip draws it.
public struct PathStep: Identifiable, Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case record, stems, chop, groove, chords, bass, kit, dust, arrange, words, sing, mix
        /// Stems and bars of other records, pulled in.
        case sources
        /// A melody written over it.
        case tune

        /// A step the path passes through without insisting on: it is never "next". The chords are
        /// this — the bass writes to the key when none are stated — so the path does not stall on
        /// a lead sheet nobody needs yet. So are a kit and dust: they are choices about a sound, and
        /// a song that never takes them is finished, not stuck. The path used to say "Dust →"
        /// through arranging, singing and mixing.
        public var isOptional: Bool { self == .chords || self == .kit || self == .dust || self == .tune }

        /// The idiom's own word, as the ledger groups and the field guide use it.
        public var title: String {
            switch self {
            case .record: return "Record"
            case .stems: return "Stems"
            case .chop: return "Chop"
            case .groove: return "Groove"
            case .chords: return "Chords"
            case .bass: return "Bass"
            case .kit: return "Kit"
            case .dust: return "Dust"
            case .arrange: return "Arrange"
            case .words: return "Words"
            case .sing: return "Sing"
            case .mix: return "Mix"
            case .sources: return "Sources"
            case .tune: return "Tune"
            }
        }

        /// The drawn glyph, `Resources/Glyphs/glyph-<name>.svg`.
        public var glyph: String {
            switch self {
            case .record: return "record"
            case .stems: return "stems"
            case .chop: return "chop"
            case .groove: return "groove"
            case .chords: return "chords"
            case .bass: return "stem-bass"
            case .kit: return "sound"
            case .dust: return "dust"
            case .arrange: return "section"
            case .words: return "lyrics"
            case .sing: return "booth"
            case .mix: return "mixer"
            case .sources: return "sources"
            case .tune: return "stem-vocals"
            }
        }

        /// The SF Symbol drawn when the glyph file is missing.
        public var symbol: String {
            switch self {
            case .record: return "record.circle"
            case .stems: return "square.3.layers.3d"
            case .chop: return "scissors"
            case .groove: return "square.grid.4x3.fill"
            case .chords: return "music.note.list"
            case .bass: return "waveform.path"
            case .kit: return "dial.medium"
            case .dust: return "waveform.path.badge.minus"
            case .arrange: return "rectangle.split.3x1"
            case .words: return "text.quote"
            case .sing: return "mic"
            case .mix: return "slider.vertical.3"
            case .sources: return "square.stack.3d.down.right"
            case .tune: return "music.note"
            }
        }

        /// What this step makes, one line, for the tooltip.
        public var meaning: String {
            switch self {
            case .record: return "The record: its waveform, key, tempo, bars and form."
            case .stems: return "The record split into drums, bass, vocals and other."
            case .chop: return "A bar cut from a stem, sliced on its hits, playable on pads."
            case .groove: return "Steps, swing and ghosts for each drum voice, on a feel."
            case .chords: return "The progression, as a lead sheet says it. Optional: with none, the bass is written to the key."
            case .bass: return "A bass line under the groove, in a named player's hands, read by the Bassist."
            case .kit: return "The drum sounds a groove plays: synthesized 808, 909 and Linn voices."
            case .dust: return "A chop or groove played through a machine (SP-1200, MPC60, tape, vinyl, radio)."
            case .arrange: return "Parts stitched into sections, and sections into a song."
            case .words: return "The lyric, a stanza labelled for each section it is sung in, set to the tune when there is one; read by the Lyricist."
            case .sing: return "A take sung against the song as it plays, on the bar you sang it; takes comped into one."
            case .mix: return "A strip per part and a master: level, pan, EQ, compression, the limiter's ceiling and the loudness target."
            case .sources: return "A stem, or some bars, of another record, fitted to the song's key, tempo and bars."
            case .tune: return "A melody over it, in the Piano roll, read by the Melodist. Optional."
            }
        }
    }

    public let kind: Kind
    /// How many of this step's parts the song holds. Zero is "not yet".
    public let count: Int
    /// The surface you are working in is this step's.
    public let isHere: Bool
    /// The first step not yet done that the frame can carry out: where the work goes next.
    public let isNext: Bool
    /// Set when the step is part of the path but has no surface yet; says when it arrives.
    public let later: String?
    /// What pressing the step does. Nil when there is nothing to open.
    public let action: SurfaceAction?

    public var id: Kind { kind }
    public var isDone: Bool { count > 0 }

    /// The tooltip: what the step is, then what pressing it will do.
    public var help: String {
        var lines = [kind.meaning]
        if let later { lines.append(later) }
        else if let action { lines.append(isDone ? "Open \(action.title) in \(action.surface.rawValue)." : "Start here: \(action.surface.rawValue).") }
        return lines.joined(separator: " ")
    }
}

extension WorkPath {

    /// The path for a song, with `active` as the surface you are in.
    ///
    /// `canPerform` is the frame's own gate (`AppState.canPerform`), passed in so this stays a pure
    /// function a test can drive with a plain closure.
    public static func steps(for song: Song, active: (kind: SurfaceKind, bound: [VersionID])?,
                             canPerform: (SurfaceAction) -> Bool) -> (path: WorkPath, steps: [PathStep]) {
        let path = WorkPath.of(song)
        let here = active.flatMap { stepKind(for: $0.kind, bound: $0.bound, in: song, path: path) }

        var steps: [PathStep] = []
        var nextTaken = false
        for kind in path.steps {
            let count = self.count(kind, in: song)
            let action = self.action(kind, in: song).flatMap { canPerform($0) ? $0 : nil }
            let isNext = !nextTaken && count == 0 && action != nil && !kind.isOptional
            if isNext { nextTaken = true }
            // No step is "later" today: arranging arrived with M2's Gate C. The field stays for
            // the next milestone's steps, which is what it was drawn for.
            steps.append(PathStep(kind: kind, count: count, isHere: kind == here, isNext: isNext,
                                  later: nil, action: action))
        }
        return (path, steps)
    }

    /// Which step a surface belongs to. The Sound surface is two steps: bound to a chop or a groove
    /// it is putting dust on it; bound to a sound, or to nothing, it is shaping the kit.
    static func stepKind(for surface: SurfaceKind, bound: [VersionID], in song: Song,
                         path: WorkPath) -> PathStep.Kind? {
        switch surface {
        case .importRecord: return .record
        case .chopLane: return .chop
        case .grid: return .groove
        case .chords: return .chords
        case .pianoRoll:
            let melody = bound.compactMap { song.version($0) }.contains { $0.type == .melody }
            return melody && path.steps.contains(.tune) ? .tune : .bass
        case .structure: return .arrange
        case .lyrics: return .words
        case .sources: return path == .assembled ? .sources : nil
        case .album, .merge, .cast, .mashup: return nil
        case .booth, .takes: return .sing
        case .mixer, .master: return .mix
        case .sound:
            let carries = bound.compactMap { song.version($0) }.contains { $0.kind.canCarryDegradation }
            if carries { return .dust }
            return path.steps.contains(.kit) ? .kit : nil
        case .compare, .check:
            return nil
        }
    }

    /// Parts, not versions: a chop and its dusty version are one chop.
    static func count(_ kind: PathStep.Kind, in song: Song) -> Int {
        // A variation is its part played another way, not another part.
        func parts(_ versions: [PartVersion]) -> Int { Set(versions.map { song.strip(of: $0.partID) }).count }
        switch kind {
        case .record: return Guidance.canShowRecord(in: song) ? 1 : 0
        case .stems: return Guidance.stems(in: song).count
        case .chop: return parts(Guidance.samples(in: song))
        case .groove: return parts(Guidance.grooves(in: song))
        case .kit: return parts(Guidance.sounds(in: song))
        case .chords: return parts(Guidance.progressions(in: song))
        case .bass: return parts(Guidance.basslines(in: song))
        // Parts whose newest version is dusty: what plays, not what ever was. A part made dusty and
        // then kept clean again is not dust.
        case .dust: return newestVersions(in: song).filter { !$0.kind.degradation.isEmpty }.count
        // Sections that play something: a new song's empty Intro, Verse and Hook are a shape
        // waiting for parts, not an arrangement.
        case .arrange: return song.sections.filter { !$0.stitch.isEmpty }.count
        case .words:
            // A lyric of blank lines is not words yet — the Booth says "No words yet" over one —
            // so the step counts a lyric only when its newest version has a syllable to sing.
            let lyrics = song.versions.filter { $0.type == .lyric }
            return Set(lyrics.map(\.partID)).filter { part in
                guard let newest = lyrics.last(where: { $0.partID == part }), case .lyric(let words) = newest.kind else { return false }
                return words.lines.contains { !$0.syllables.isEmpty }
            }.count
        case .sing: return Guidance.takes(in: song).count
        case .mix: return Guidance.mixes(in: song).count
        case .sources:
            let mashed = Guidance.stems(in: song).filter { $0.operation == Operation.mashup }
            return song.fittedSources.count + Set(mashed.map(\.partID)).count
        case .tune: return parts(Guidance.melodies(in: song))
        }
    }

    /// Each part's newest version, in the order the parts were started.
    static func newestVersions(in song: Song) -> [PartVersion] {
        var newest: [PartID: PartVersion] = [:]
        var order: [PartID] = []
        for version in song.versions {
            if newest[version.partID] == nil { order.append(version.partID) }
            newest[version.partID] = version
        }
        return order.compactMap { newest[$0] }
    }

    /// What pressing a step opens: its newest part if it has one, otherwise the way to make one.
    static func action(_ kind: PathStep.Kind, in song: Song) -> SurfaceAction? {
        switch kind {
        case .sources:
            return SurfaceAction(surface: .sources, title: "Sources")
        case .tune:
            // An existing tune opens; a new one is started from the Piano roll's own menu.
            guard let melody = Guidance.melodies(in: song).last else { return nil }
            return SurfaceAction(surface: .pianoRoll, title: PartLabel.title(of: melody), bound: [melody.id])
        case .mix:
            // The Master once the song is arranged and mixed; the Mixer until then.
            if !song.sections.isEmpty, !Guidance.mixes(in: song).isEmpty { return Guidance.dockAction(for: .master, in: song) }
            return Guidance.dockAction(for: .mixer, in: song)
        case .words:
            return Guidance.dockAction(for: .lyrics, in: song)
        case .sing:
            // The takes, when there are any; otherwise the Booth, which opens on nothing.
            if !Guidance.takes(in: song).isEmpty { return Guidance.dockAction(for: .takes, in: song) }
            return SurfaceAction(surface: .booth, title: song.title)
        case .record:
            if Guidance.canShowRecord(in: song) {
                return SurfaceAction(surface: .importRecord, title: song.title, bound: Guidance.boundRecord(in: song))
            }
            return SurfaceAction(surface: .importRecord, title: song.title)

        case .stems:
            guard let take = Guidance.take(in: song) else { return nil }
            if Guidance.stems(in: song).isEmpty {
                return SurfaceAction(surface: .importRecord, title: song.title,
                                     bound: Guidance.boundRecord(in: song), prepare: .separateStems(of: take.id))
            }
            return SurfaceAction(surface: .importRecord, title: song.title, bound: Guidance.boundRecord(in: song))

        case .chop:
            if let chop = Guidance.samples(in: song).last {
                return SurfaceAction(surface: .chopLane, title: PartLabel.title(of: chop), bound: [chop.id])
            }
            // The drums first: they are what a chop is usually cut from. Then any stem with a bar.
            let stems = Guidance.stems(in: song)
            let ordered = stems.filter { Guidance.audio(of: $0).flatMap(PartLabel.instrument(of:)) == .drums }
                + stems.filter { Guidance.audio(of: $0).flatMap(PartLabel.instrument(of:)) != .drums }
            for stem in ordered {
                if let bar = Guidance.barToChop(of: stem, in: song) {
                    return SurfaceAction(surface: .chopLane, title: "Bar \(bar.number) of \(song.title)",
                                         prepare: .chopBar(of: stem.id))
                }
            }
            // No stems: a bar of the record itself.
            if stems.isEmpty, let take = Guidance.take(in: song), let bar = Guidance.barToChop(of: take, in: song) {
                return SurfaceAction(surface: .chopLane, title: "Bar \(bar.number) of \(song.title)",
                                     prepare: .chopBar(of: take.id))
            }
            return nil

        case .groove:
            if let groove = Guidance.grooves(in: song).last {
                return SurfaceAction(surface: .grid, title: PartLabel.title(of: groove), bound: [groove.id])
            }
            // A chop re-grooves in the lane; with no chop, a groove is painted from scratch.
            if let chop = Guidance.samples(in: song).last {
                return SurfaceAction(surface: .chopLane, title: PartLabel.title(of: chop), bound: [chop.id])
            }
            return SurfaceAction(surface: .grid, title: "New groove")

        case .chords:
            if let progression = Guidance.progressions(in: song).last {
                return SurfaceAction(surface: .chords, title: PartLabel.title(of: progression), bound: [progression.id])
            }
            return SurfaceAction(surface: .chords, title: "Chords")

        case .bass:
            if let line = Guidance.basslines(in: song).last {
                return SurfaceAction(surface: .pianoRoll, title: PartLabel.title(of: line), bound: [line.id])
            }
            // A new line is written under a groove; with none there is nothing to sit under.
            if let groove = Guidance.grooves(in: song).last {
                return SurfaceAction(surface: .pianoRoll, title: "Bass under \(PartLabel.title(of: groove))", bound: [groove.id])
            }
            return nil

        case .kit:
            if let sound = Guidance.shapeableSounds(in: song).last {
                return SurfaceAction(surface: .sound, title: PartLabel.title(of: sound), bound: [sound.id])
            }
            return SurfaceAction(surface: .sound, title: "Kit")

        case .dust:
            // The newest dusty part if there is one, else the newest thing that could carry dust —
            // a groove before a chop, since a groove is further along.
            if let dusty = newestVersions(in: song).last(where: { !$0.kind.degradation.isEmpty }) {
                return SurfaceAction(surface: .sound, title: PartLabel.title(of: dusty), bound: [dusty.id])
            }
            if let target = Guidance.grooves(in: song).last ?? Guidance.samples(in: song).last {
                return SurfaceAction(surface: .sound, title: PartLabel.title(of: target), bound: [target.id])
            }
            return nil

        case .arrange:
            // The form is arranged from parts that play; with none there is nothing to stitch.
            guard !song.sections.isEmpty || !Guidance.grooves(in: song).isEmpty
                || !Guidance.basslines(in: song).isEmpty || !Guidance.samples(in: song).isEmpty else { return nil }
            return SurfaceAction(surface: .structure, title: song.title)
        }
    }
}
