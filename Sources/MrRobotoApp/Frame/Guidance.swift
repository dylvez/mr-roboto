import Foundation
import Instrument
import SongGraph

// MARK: - What a proposal asks the frame to do

/// One thing the frame can be asked to open, as a plain value.
///
/// This is the Gate B shape drawn early. When the Director arrives it will answer by *naming a
/// surface and binding it to part versions* — it never invents a layout — which is exactly what this
/// is. Gate A derives the same values from the song graph instead of from a model, so the rail, the
/// parts ledger, the bench dock and the empty surfaces all speak one vocabulary, and the Director
/// slots in above it rather than replacing it.
///
/// Being a value is the point: an action can be compared, logged, tested, and (later) decoded from
/// a persona's reply without the frame growing a second way to open a surface.
public struct SurfaceAction: Sendable, Equatable, Hashable {

    /// Work that has to happen before the surface has anything to bind to.
    ///
    /// Kept in the action rather than in the caller so a proposal stays one clickable value: "chop a
    /// bar of the drums and open the lane on it" is one thing you asked for, not two.
    public enum Preparation: Sendable, Equatable, Hashable {
        /// Everything the surface binds to already exists.
        case none
        /// Cut one bar out of an audio version first; the `.sample` that lands is what the surface
        /// binds to. Resolved by `AppState.perform(_:)` before the surface opens, and idempotent —
        /// a stem that has already been chopped reopens its chop rather than cutting another.
        case chopBar(of: VersionID)
        /// Split the song's take into stems. The surface opens first and reports the run itself, so
        /// this is filed as a request the wiring hands to the model, not done here.
        case separateStems(of: VersionID)
    }

    /// Which surface in the catalog.
    public var surface: SurfaceKind
    /// The bench item's title: "Arrival", "Bar 12 of Arrival".
    public var title: String
    /// The part versions the surface opens against.
    public var bound: [VersionID]
    public var prepare: Preparation
    /// Controls to hang on the surface once it is open, at most two.
    ///
    /// Empty for everything Gate A derives, and that is right: a surface you opened yourself needs
    /// no lever, because you already know what you came to move. They live on the action rather
    /// than beside it so that a *proposal* keeps them — a Director's suggestion that loses its two
    /// knobs between the rail and the bench is a suggestion the user cannot act on the way it was
    /// meant. `DirectorSurfaceChoice` is what validates them; nothing else may invent one.
    public var levers: [SurfaceLever]

    public init(surface: SurfaceKind, title: String, bound: [VersionID] = [],
                prepare: Preparation = .none, levers: [SurfaceLever] = []) {
        self.surface = surface
        self.title = title
        self.bound = bound
        self.prepare = prepare
        self.levers = levers
    }

    /// Stable across recomputes, so a list of proposals does not reshuffle between renders.
    var identity: String {
        let ids = bound.map(\.description).joined(separator: ",")
        return "\(surface.rawValue)|\(ids)|\(prepare)"
    }
}

// MARK: - A proposal

/// Something worth doing next, with the reason it is worth doing.
///
/// In Gate A every proposal is derived from the song by `Guidance`; the source says so. In Gate B a
/// persona's reply carries the same three fields and lands in the same list, which is why the rail
/// renders `Proposal` rather than rendering a hard-coded Gate A list.
public struct Proposal: Identifiable, Sendable, Equatable {

    /// Who is proposing. The rail labels the block with this, exactly as it labels a log line.
    public enum Source: Sendable, Equatable, Hashable {
        /// Derived from the state of the song. No model wrote it.
        case session
        /// The Director, answering something you typed.
        case director
        /// An AI band member, by name, on its own initiative.
        case persona(String)

        public var label: String {
            switch self {
            case .session: return "What next"
            case .director: return "The Director"
            case .persona(let name): return name
            }
        }
    }

    /// The verb, as it appears on the control: "Chop a bar of the drums".
    public let title: String
    /// One quiet line saying why, in the song's own numbers. Never a slogan.
    public let rationale: String
    public let action: SurfaceAction
    public let source: Source

    public init(title: String, rationale: String, action: SurfaceAction, source: Source = .session) {
        self.title = title
        self.rationale = rationale
        self.action = action
        self.source = source
    }

    public var id: String { "\(source.label)|\(action.identity)" }
}

// MARK: - Naming a part

/// What a part version is called where a person reads it: the ledger row, a bench title, a rail line.
///
/// `PartType.rawValue` is the graph's word and it is not enough — a song with five `audio` rows in
/// the ledger says nothing, and "audio" is not what you call the drums.
enum PartLabel {

    /// "Drums stem", "The record", "Bar 12", "Groove", "Analysis".
    static func title(of version: PartVersion) -> String {
        switch version.kind {
        case .analysis:
            return "Analysis"
        case .audio(let audio):
            switch audio.role {
            case .take:
                if audio.comp != nil { return "Comp" }
                if let take = audio.take { return "Take \(take.pass)" }
                return "Record"
            case .stem: return "\((audio.stem ?? "unnamed").capitalized) stem"
            }
        case .sample:
            return note(of: version) ?? "Chop"
        case .groove:
            return note(of: version) ?? "Groove"
        case .sound(let sound):
            // A groove on a chop names the chop by part, which is not a name anybody reads.
            if ChopSound.part(of: sound.instrument) != nil { return note(of: version) ?? "Chop kit" }
            // "drum.tr808.kick" is the Sound surface's key, not a name: the machine's name and the
            // voice, and the dust only when there is some.
            let pieces = sound.instrument.split(separator: ".").map(String.init)
            if pieces.count == 3, pieces[0] == "drum" {
                let machine = SynthMachine.preset(id: pieces[1])?.name ?? pieces[1].uppercased()
                let voice = pieces[2].replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
                let dust = sound.preset.flatMap { $0 == "clean" ? nil : $0 }
                return "\(machine) \(voice)" + (dust.map { ", \($0)" } ?? "")
            }
            // An instrument by its name: "felt-piano" and "sfz-salamander-upright" are keys.
            let named = InstrumentVoiceSpec.preset(id: sound.instrument)?.name ?? sound.instrument
            return sound.preset.map { "\(named) · \($0)" } ?? named
        case .bassline:
            return note(of: version) ?? "Bass line"
        case .progression(let progression):
            // Spelled against the progression's own key. `symbol()` defaults to sharps, so the
            // second degree of D minor came out "A♯maj7" — a spelling that key does not contain —
            // in the ledger, on a Structure chip and anywhere else a part is named. Every other
            // place chords are drawn already asks the key; this one did not.
            return note(of: version) ?? progression.chords.prefix(4)
                .map { $0.symbol(preferring: progression.key.spellingPreference) }
                .joined(separator: " ")
        case .melody, .lyric:
            // Its own note, like every other kind. A melody called "Melody" on a chip beside a
            // groove called "Swung brushes, kick pushing the and-of-3" is the one part in the song
            // that will not say what it is.
            return note(of: version) ?? version.type.rawValue.capitalized
        case .mix:
            return note(of: version) ?? "Mix"
        }
    }

    /// The part's own note, cut to something that fits a 230-point column.
    private static func note(of version: PartVersion) -> String? {
        guard let note = version.note, !note.isEmpty else { return nil }
        return name(from: note)
    }

    /// The longest a name runs before it is cut at a word.
    static let longestName = 44

    /// A note as a name. Notes read "Bar 12 of Arrival — Vessel – Arrival (1974)": the citation is
    /// provenance, not a name, and the ledger shows provenance on its second line. And notes the
    /// band writes are descriptions — "Brushes under the C loop: kick on 1, brushed accent on 3,
    /// ghost snare sweeping between…" — whose name is what comes before the colon or the first full
    /// stop. The whole sentence used to be the name, in a rail suggestion, a header, a chip.
    static func name(from note: String) -> String {
        var head = note.split(separator: "—", maxSplits: 1).first.map(String.init) ?? note
        for mark in [": ", ". "] {
            if let range = head.range(of: mark), head.distance(from: head.startIndex, to: range.lowerBound) >= 3 {
                head = String(head[..<range.lowerBound])
            }
        }
        head = head.trimmingCharacters(in: .whitespaces)
        if head.hasSuffix("."), !head.hasSuffix("..") { head.removeLast() }
        guard head.count > longestName else { return head }
        let cut = head.prefix(longestName)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// The instrument class a stem belongs to, when its name is one the analysis reports activity for.
    static func instrument(of audio: Audio) -> InstrumentKind? {
        guard audio.role == .stem, let stem = audio.stem else { return nil }
        return InstrumentKind(rawValue: stem)
    }
}

// MARK: - Deriving what to do next

/// Gate A's stand-in for the Director.
///
/// Everything here is a pure function of the song graph, which is what makes it honest: a suggestion
/// exists because the song actually holds the thing it names, and `AppState.canPerform(_:)` is the
/// second gate that keeps a suggestion off the screen when the frame could not carry it out.
///
/// The order is the workflow the Gate A milestone builds — record, stems, chop, groove — with the
/// next undone step first. A song with nothing in it proposes nothing; inventing work for an empty
/// song is the failure this whole file exists to avoid.
public enum Guidance {

    /// How many proposals the rail will show. Past four it is a menu, not advice.
    public static let maximumProposals = 4

    /// What you can do next, given the song. Empty for no song and for an empty song.
    public static func proposals(for song: Song?) -> [Proposal] {
        Array(allProposals(for: song).prefix(maximumProposals))
    }

    /// Every proposal the song supports, in the path's order, before the rail's cut to four: the
    /// band's question ranks these against what you tend to choose (`NextAdvisor`).
    public static func allProposals(for song: Song?) -> [Proposal] {
        guard let song, !song.versions.isEmpty else { return [] }
        var out: [Proposal] = []

        let analysis = self.analysis(in: song)
        let take = self.take(in: song)
        let stems = self.stems(in: song)

        // 1. One stereo file and nothing else: the drums are inside it and have to come out first.
        if let take, stems.isEmpty {
            out.append(Proposal(
                title: "Separate the stems",
                rationale: "\(song.title) is one \(duration(of: take)) file. Separation splits it into "
                    + "drums, bass, vocals and other — the drums are what a chop is cut from.",
                action: SurfaceAction(surface: .importRecord, title: song.title,
                                      bound: boundRecord(in: song),
                                      prepare: .separateStems(of: take.id))))
        }

        // 1b. No stems — separation not run, or not possible here — and nothing chopped: a bar of the
        //     record itself. Without it the only way on was a drag and a Promote nobody suggested.
        if let take, stems.isEmpty, samples(in: song).isEmpty, let bar = barToChop(of: take, in: song) {
            out.append(Proposal(
                title: "Chop a bar of the record",
                rationale: "Bar \(bar.number), straight from the record without separating it. The lane slices it "
                    + "on its transients; stems can come later.",
                action: SurfaceAction(surface: .chopLane, title: "Bar \(bar.number) of \(song.title)",
                                      prepare: .chopBar(of: take.id))))
        }

        // 2. Drums, uncut. The one action the whole milestone is built around.
        if let drums = stems.first(where: { audio(of: $0).flatMap(PartLabel.instrument(of:)) == .drums }),
           chop(of: drums.id, in: song) == nil,
           let bar = barToChop(of: drums, in: song) {
            out.append(Proposal(
                title: "Chop a bar of the drums",
                rationale: "Bar \(bar.number) of the drums stem, \(seconds(bar.range.duration)) at "
                    + "\(tempoText(song, analysis)). The lane slices it on its downbeats.",
                action: SurfaceAction(surface: .chopLane,
                                      title: "Bar \(bar.number) of \(song.title)",
                                      prepare: .chopBar(of: drums.id))))
        }

        // 3. A chop with no groove off it yet: re-grooving is what the lane is for.
        // By part: a chop whose any version has made a groove has been re-grooved. By version, every
        // keep of the chop and every dusty version brought the suggestion back.
        let regrooved = Set(song.versions.filter { $0.type == .groove }.flatMap(\.parents)
            .compactMap { song.version($0)?.partID })
        if let sample = samples(in: song).last(where: { !regrooved.contains($0.partID) }) {
            out.append(Proposal(
                title: "Re-groove \(PartLabel.title(of: sample))",
                rationale: "The lane re-slices this bar on its transients; its re-groove lever puts the "
                    + "slices on a feel and hands the groove to the Grid.",
                action: SurfaceAction(surface: .chopLane,
                                      title: PartLabel.title(of: sample),
                                      bound: [sample.id])))
        }

        // 4. A groove exists and nothing is built on it yet: the Grid is where it is edited and
        //    played. Once there is a bass line or a form the song has moved on, and a standing
        //    "open the groove" put itself ahead of every later step on the dock.
        if let groove = grooves(in: song).last, basslines(in: song).isEmpty,
           !song.sections.contains(where: { !$0.stitch.isEmpty }) {
            out.append(Proposal(
                title: "Open \(PartLabel.title(of: groove)) in the Grid",
                rationale: "Paint steps, set the swing, commit a new version. \(tempoText(song, analysis)).",
                action: SurfaceAction(surface: .grid, title: PartLabel.title(of: groove),
                                      bound: [groove.id])))
        }

        // 5. A groove with no bass under it yet: the band's first written part.
        if let groove = grooves(in: song).last, basslines(in: song).isEmpty {
            out.append(Proposal(
                title: "Write a bass line under \(PartLabel.title(of: groove))",
                rationale: "The Piano roll writes one in a named player's hands — 40 ms behind the kick by "
                    + "default — and the Bassist reads it back. \(tempoText(song, analysis)).",
                action: SurfaceAction(surface: .pianoRoll, title: "Bass under \(PartLabel.title(of: groove))",
                                      bound: [groove.id])))
        }

        // 6. Parts that play and no form yet: the song gets arranged.
        if !song.sections.contains(where: { !$0.stitch.isEmpty }), !grooves(in: song).isEmpty || !samples(in: song).isEmpty {
            out.append(Proposal(
                title: "Arrange \(song.title) into sections",
                rationale: "Structure lays the groove, the bass line and the chop out as intro, verse and hook, "
                    + "and the transport plays them in order.",
                action: SurfaceAction(surface: .structure, title: song.title)))
        }

        // 7. Arranged, and nothing sung over it yet: the Booth. Then the takes, uncomped; then the
        //    mix; then the master. The path strip has drawn these steps since M5 and M6, but the
        //    list of what to do next stopped at the arrangement, so a finished beat was told
        //    "nothing obvious left" with the singing, the mix and the master still to do.
        if song.sections.contains(where: { !$0.stitch.isEmpty }),
           song.versions.contains(where: StructureModel.plays) {
            let takes = self.takes(in: song)
            // The words before the microphone, as the path has them: a take needs something to
            // sing, and the Booth shows the stanza labelled for the section it records.
            let words: Lyric? = song.versions.last { $0.type == .lyric }.flatMap { version in
                if case .lyric(let lyric) = version.kind { return lyric }
                return nil
            }
            if takes.isEmpty, words?.lines.contains(where: { !$0.syllables.isEmpty }) != true {
                out.append(Proposal(
                    title: "Write the words",
                    rationale: "A stanza for each section, labelled [Verse] or [Hook] so the Booth shows the one you "
                        + "are singing. The Lyricist reads them as you type.",
                    action: dockAction(for: .lyrics, in: song)))
            } else if let words, words.alignedTo == nil, let tune = melodies(in: song).last {
                out.append(Proposal(
                    title: "Set the words to \(PartLabel.title(of: tune))",
                    rationale: "One syllable a note, from Set to melody on the Lyrics surface; the Lyricist then says "
                        + "where a stressed syllable lands off the beat.",
                    action: dockAction(for: .lyrics, in: song)))
            }
            if takes.isEmpty {
                out.append(Proposal(
                    title: "Sing over \(song.title)",
                    rationale: "The Booth plays the song under you and lands the take on the bar you sang it on; "
                        + "every take stays, and the band reads them in Takes.",
                    action: SurfaceAction(surface: .booth, title: song.title)))
            } else if comps(in: song).isEmpty, let newest = takes.last {
                let part = takes.filter { $0.partID == newest.partID }
                out.append(Proposal(
                    title: "Comp the \(count(part.count, "take"))",
                    rationale: "Choose which take each bar comes from and keep one version, seams crossfaded.",
                    action: SurfaceAction(surface: .takes, title: takesTitle(of: part, in: song), bound: part.map(\.id))))
            }
            if mixes(in: song).isEmpty {
                out.append(Proposal(
                    title: "Mix \(song.title)",
                    rationale: "A strip per part: level, pan, EQ and a compressor, with meters while it plays. "
                        + "Every move you let go of is a mix version.",
                    action: SurfaceAction(surface: .mixer, title: song.title)))
            } else if let mix = mixes(in: song).last {
                out.append(Proposal(
                    title: "Read the master",
                    rationale: "Loudness, true peak and crest against the target; the Engineer says what to change first. "
                        + "Then File ▸ Export.",
                    action: SurfaceAction(surface: .master, title: song.title, bound: [mix.id])))
            }
        }

        // 8. A sound to shape.
        if let sound = shapeableSounds(in: song).last {
            out.append(Proposal(
                title: "Shape \(PartLabel.title(of: sound)) in Sound",
                rationale: "The synthesis and the degradation chain, auditioned on every knob.",
                action: SurfaceAction(surface: .sound, title: PartLabel.title(of: sound),
                                      bound: [sound.id])))
        }

        // 7. The record itself, last: it is what opening the song already put on the bench, so it is
        //    here for getting back to rather than for getting started.
        if canShowRecord(in: song) {
            out.append(Proposal(
                title: "Show the record",
                rationale: readingsLine(song: song, analysis: analysis),
                action: SurfaceAction(surface: .importRecord, title: song.title,
                                      bound: boundRecord(in: song))))
        }

        return out
    }

    /// The one thing opening a song should put on the bench, or nothing when the song holds nothing
    /// worth showing. Deliberately not `proposals(for:).first`: the first proposal is the next thing
    /// *to do*, and what a song should open on is what it *is*.
    public static func opening(_ song: Song) -> SurfaceAction? {
        if canShowRecord(in: song) {
            return SurfaceAction(surface: .importRecord, title: song.title, bound: boundRecord(in: song))
        }
        if let groove = grooves(in: song).last {
            return SurfaceAction(surface: .grid, title: PartLabel.title(of: groove), bound: [groove.id])
        }
        if let sample = samples(in: song).last {
            return SurfaceAction(surface: .chopLane, title: PartLabel.title(of: sample), bound: [sample.id])
        }
        if let sound = shapeableSounds(in: song).last {
            return SurfaceAction(surface: .sound, title: PartLabel.title(of: sound), bound: [sound.id])
        }
        return nil
    }

    /// What a surface should open on when it is picked by *name* rather than by proposal — the bench
    /// dock, ⌘1–⌘4, the Surfaces menu.
    ///
    /// The point is that picking a surface off the shelf lands you in a useful one: the Grid opens on
    /// the song's newest groove rather than on an empty bar, the Chop lane on its newest chop. Every
    /// one of these surfaces is legitimate unbound as well (the drop target, an empty grid, a new
    /// sound from the machine preset), so this never fails and never has to be checked.
    public static func dockAction(for kind: SurfaceKind, in song: Song?) -> SurfaceAction {
        let fallback = SurfaceAction(surface: kind, title: song?.title ?? "Untitled")
        guard let song else { return fallback }
        switch kind {
        case .importRecord:
            guard canShowRecord(in: song) else { return fallback }
            return SurfaceAction(surface: kind, title: song.title, bound: boundRecord(in: song))
        case .chopLane:
            guard let sample = samples(in: song).last else { return fallback }
            return SurfaceAction(surface: kind, title: PartLabel.title(of: sample), bound: [sample.id])
        case .grid:
            guard let groove = grooves(in: song).last else { return fallback }
            return SurfaceAction(surface: kind, title: PartLabel.title(of: groove), bound: [groove.id])
        case .sound:
            guard let sound = shapeableSounds(in: song).last else { return fallback }
            return SurfaceAction(surface: kind, title: PartLabel.title(of: sound), bound: [sound.id])
        case .chords:
            guard let progression = progressions(in: song).last else { return fallback }
            return SurfaceAction(surface: kind, title: PartLabel.title(of: progression), bound: [progression.id])
        case .pianoRoll:
            if let line = basslines(in: song).last {
                return SurfaceAction(surface: kind, title: PartLabel.title(of: line), bound: [line.id])
            }
            guard let groove = grooves(in: song).last else { return fallback }
            return SurfaceAction(surface: kind, title: "Bass under \(PartLabel.title(of: groove))", bound: [groove.id])
        case .structure:
            // Bound to nothing: it draws the song's sections, and the song is what is open.
            return SurfaceAction(surface: kind, title: song.title)
        case .lyrics:
            if let lyric = song.versions.last(where: { $0.type == .lyric }) {
                return SurfaceAction(surface: kind, title: PartLabel.title(of: lyric), bound: [lyric.id])
            }
            return SurfaceAction(surface: kind, title: "Lyrics")
        case .booth:
            // Bound to nothing: it records against the song as it plays, on the active section.
            return SurfaceAction(surface: kind, title: song.title)
        case .mashup:
            return SurfaceAction(surface: kind, title: "Mashup")
        case .mixer, .master:
            // Bound to the newest mix version when there is one; a song at unity opens on nothing
            // and the first move makes the mix.
            if let mix = Guidance.mixes(in: song).last {
                return SurfaceAction(surface: kind, title: song.title, bound: [mix.id])
            }
            return SurfaceAction(surface: kind, title: song.title)
        case .takes:
            let takes = Guidance.takes(in: song)
            guard let newest = takes.last else { return SurfaceAction(surface: kind, title: "Takes") }
            let part = takes.filter { $0.partID == newest.partID }
            return SurfaceAction(surface: kind, title: Guidance.takesTitle(of: part, in: song), bound: part.map(\.id))
        case .album, .merge, .cast:
            // Opened from a library row, a ledger row or the menu, never from the dock: an album
            // is not something the open song has, a merge needs two named versions, and the cast
            // is the song's setting.
            return fallback
        case .compare, .check:
            // Nothing reaches here: the dock, ⌘1–⌘4 and the Surfaces menu all iterate
            // `SurfaceKind.gateA`, and an answer surface is not something you pick off a shelf —
            // a Compare with nothing to compare is not a surface, it is an empty promise. The
            // unbound action this returns is refused by `canPerform` for exactly that reason.
            return fallback
        }
    }

    // MARK: The dock

    /// The surfaces the dock carries: every one you work in, from the start, none waiting for the
    /// song to reach it; and Takes once there are takes to comp.
    public static func dockSurfaces(for song: Song?) -> [SurfaceKind] {
        var kinds = SurfaceKind.gateA + [.lyrics, .booth]
        if let song, !takes(in: song).isEmpty { kinds.append(.takes) }
        kinds.append(.mixer)
        return kinds
    }

    /// What the dock's chip says after the name: the key that opens it.
    public static func dockShortcut(for kind: SurfaceKind) -> String {
        if let index = SurfaceKind.gateA.firstIndex(of: kind) { return "⌘\(index + 1)" }
        switch kind {
        case .lyrics: return "⌘9"
        case .booth: return "⌘0"
        case .mixer: return "⇧⌘M"
        case .takes: return "⇧⌘T"
        case .master: return "⌥⌘M"
        default: return ""
        }
    }

    // MARK: Reading the song

    /// The newest whole-track analysis in the song.
    public static func analysis(in song: Song?) -> MusicAnalysis? {
        song?.versions.reversed().compactMap { version -> MusicAnalysis? in
            if case .analysis(let analysis) = version.kind { return analysis }
            return nil
        }.first
    }

    /// The version carrying the analysis, as opposed to the analysis itself.
    public static func analysisVersion(in song: Song) -> PartVersion? {
        song.versions.last { $0.type == .analysis }
    }

    /// The analysis that describes *this* audio, when the song holds more than one record.
    ///
    /// Import stamps the take and its analysis with the same seed (`origin`), and a stem's parent is
    /// its take; so the analysis for an audio version is the one that shares its seed. A song from
    /// before seeds were stamped, or one with a single record, falls back to the newest analysis —
    /// which is what every caller read before a second record could be adopted into a song.
    public static func analysis(for audio: PartVersion, in song: Song) -> MusicAnalysis? {
        let seed = audio.origin ?? audio.parents.compactMap { song.version($0)?.origin }.first
        // The analysis stamped with the audio's seed; for audio with no seed, the newest analysis
        // that has none either — the song's own, from before a second record could be adopted.
        if let version = song.versions.last(where: { $0.type == .analysis && $0.origin == seed }),
           case .analysis(let analysis) = version.kind {
            return analysis
        }
        return analysis(in: song)
    }

    /// The library record an audio version was imported from, by way of the seed it carries.
    public static func sourceRecord(of audio: PartVersion, in song: Song) -> RecordID? {
        let seed = audio.origin ?? audio.parents.compactMap { song.version($0)?.origin }.first
        guard let seed, let found = song.seed(seed), case .importedRecord(let id) = found.kind else { return nil }
        return id
    }

    /// Whether there is a record to show at all.
    ///
    /// Both halves are needed, and this is the gate that keeps the honesty promise for the one
    /// surface that could otherwise open onto its own failure: the Import surface reconstitutes a
    /// draft out of an analysis *and* a take, and a song holding one without the other would open a
    /// panel whose only content is the reason it is empty.
    public static func canShowRecord(in song: Song) -> Bool {
        take(in: song) != nil && analysisVersion(in: song) != nil
    }

    /// The record as imported: the one `.audio` version whose role is `.take` and that was never
    /// sung here. A take corrected from a Check keeps no `Take` of its own, so it is not counted as
    /// another pass, and it used to pass for the record: played at the second it was sung from,
    /// in place of the record it pushed out.
    public static func take(in song: Song) -> PartVersion? {
        song.versions.last { version in
            guard let audio = audio(of: version), audio.role == .take, audio.take == nil, audio.comp == nil else { return false }
            return TakePlacement.audio(of: version, in: song) == nil
        }
    }

    /// Takes recorded here (M5): audio versions that carry a `Take`, in graph order. Comps are not
    /// takes; they are what takes become.
    public static func takes(in song: Song) -> [PartVersion] {
        song.versions.filter { audio(of: $0)?.take != nil }
    }

    /// Comps (M5), in graph order.
    public static func comps(in song: Song) -> [PartVersion] {
        song.versions.filter { audio(of: $0)?.comp != nil }
    }

    /// "Verse takes", or "Takes" when the part was sung to no section.
    public static func takesTitle(of takes: [PartVersion], in song: Song) -> String {
        if let section = takes.compactMap({ audio(of: $0)?.take?.section }).first,
           let name = song.sections.first(where: { $0.id == section })?.name {
            return "\(name) takes"
        }
        return "Takes"
    }

    /// Separated stems, in the order the graph holds them.
    public static func stems(in song: Song) -> [PartVersion] {
        song.versions.filter { audio(of: $0)?.role == .stem }
    }

    public static func samples(in song: Song) -> [PartVersion] {
        song.versions.filter { $0.type == .sample }
    }

    /// Versions of one kind with the variations first, each group in the order the graph holds it.
    ///
    /// Nearly every caller of these lists takes the last: the newest groove is what a bass line is
    /// written under, what the Grid opens on, what a new section plays. A variation — the intro's
    /// thinned drums — is written after the loop it came from, and would be that newest; and the
    /// loop is what all of those mean. So the variations go first, and "the newest" is the newest
    /// part of its own.
    static func mainsLast(_ versions: [PartVersion], in song: Song) -> [PartVersion] {
        // A line that answers the tune goes with them: it is newer than the tune, and is not it.
        let varied = Set(song.versions.lazy.filter { $0.variation != nil || Develop.isAnswer($0) }.map(\.partID))
        guard !varied.isEmpty else { return versions }
        return versions.filter { varied.contains($0.partID) } + versions.filter { !varied.contains($0.partID) }
    }

    public static func grooves(in song: Song) -> [PartVersion] {
        mainsLast(song.versions.filter { $0.type == .groove }, in: song)
    }

    public static func sounds(in song: Song) -> [PartVersion] {
        song.versions.filter { $0.type == .sound }
    }

    /// The sounds the Sound surface can shape: every pick but a groove's chop kit, which is the
    /// chop's slices and is shaped in the Chop lane.
    public static func shapeableSounds(in song: Song) -> [PartVersion] {
        sounds(in: song).filter { version in
            guard case .sound(let sound) = version.kind else { return false }
            return ChopSound.part(of: sound.instrument) == nil
        }
    }

    /// Mix versions, in graph order. The newest is the one the transport plays.
    public static func mixes(in song: Song) -> [PartVersion] {
        song.versions.filter { $0.type == .mix }
    }

    /// The newest mix, or nil for unity.
    public static func mix(in song: Song) -> Mix? {
        guard let version = mixes(in: song).last, case .mix(let mix) = version.kind else { return nil }
        return mix
    }

    public static func basslines(in song: Song) -> [PartVersion] {
        mainsLast(song.versions.filter { $0.type == .bassline }, in: song)
    }

    public static func progressions(in song: Song) -> [PartVersion] {
        mainsLast(song.versions.filter { $0.type == .progression }, in: song)
    }

    public static func melodies(in song: Song) -> [PartVersion] {
        mainsLast(song.versions.filter { $0.type == .melody }, in: song)
    }

    /// A chop already cut from this audio version, if there is one.
    public static func chop(of audioID: VersionID, in song: Song) -> PartVersion? {
        song.versions.last { $0.type == .sample && $0.parents.contains(audioID) }
    }

    /// A groove already re-grooved from this sample, if there is one.
    public static func groove(from sampleID: VersionID, in song: Song) -> PartVersion? {
        song.versions.last { $0.type == .groove && $0.parents.contains(sampleID) }
    }

    static func audio(of version: PartVersion) -> Audio? {
        if case .audio(let audio) = version.kind { return audio }
        return nil
    }

    // MARK: Which bar to chop

    /// A bar of the record, and the number a person would call it.
    public struct Bar: Sendable, Equatable {
        /// 1-based, as the ledger and the lane title say it.
        public var number: Int
        public var range: SongGraph.TimeRange
        /// The downbeats inside it, which become the chop's slice markers.
        public var downbeats: [Double]
    }

    /// The bar "chop a bar of this" means.
    ///
    /// Not bar one: the first bar of a record is usually an intro the stem is silent through, and a
    /// chop lane that opens on two seconds of nothing is the Komma failure again. So the analysis's
    /// own instrument-activity ranges pick the first bar where this stem's instrument is actually
    /// playing; with no activity reported, the first bar the analysis found.
    ///
    /// Returns nil when the song has no analysed bars, which is the honest reason a "chop a bar"
    /// suggestion must not appear.
    public static func barToChop(of version: PartVersion, in song: Song) -> Bar? {
        guard let audio = audio(of: version), let analysis = analysis(for: version, in: song) else { return nil }
        let bars = analysis.bars
        guard !bars.isEmpty else { return nil }

        var index = 0
        if let instrument = PartLabel.instrument(of: audio),
           let activity = analysis.instruments.first(where: { $0.instrument == instrument }),
           let entry = activity.ranges.map(\.start).min() {
            // The first bar the instrument plays *all* of, not the one it happens to come in during:
            // half a bar of silence and half a bar of drums is not a loop. The eighth-of-a-bar
            // tolerance is for the usual case where the activity range and the downbeat disagree by a
            // few tens of milliseconds and the bar really is the right one.
            let slack = (bars[0].duration) / 8
            index = bars.firstIndex { $0.start >= entry - slack } ?? 0
        }
        let range = bars[index]
        let downbeats = analysis.downbeats.filter { $0 >= range.start && $0 < range.end }
        return Bar(number: index + 1, range: range,
                   downbeats: downbeats.isEmpty ? [range.start] : downbeats)
    }

    // MARK: Lines a person reads

    /// Everything the Import surface's readings row shows, as one sentence for the rail.
    static func readingsLine(song: Song, analysis: MusicAnalysis?) -> String {
        var pieces: [String] = []
        if let key = analysis?.dominantKey ?? song.key { pieces.append(key.name) }
        pieces.append(tempoText(song, analysis))
        if let bars = analysis?.bars.count, bars > 0 { pieces.append("\(bars) bars") }
        if let sections = analysis?.sections.count, sections > 0 { pieces.append("\(sections) sections") }
        let stems = self.stems(in: song).count
        if stems > 0 { pieces.append("\(stems) stems") }
        return pieces.joined(separator: " · ")
    }

    static func tempoText(_ song: Song, _ analysis: MusicAnalysis?) -> String {
        String(format: "%.0f bpm", analysis?.dominantTempo ?? song.tempo)
    }

    static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    /// "1 marker", "11 markers". A rationale quotes the song's own numbers, so it has to count.
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    static func duration(of take: PartVersion) -> String {
        guard let audio = audio(of: take) else { return "" }
        let minutes = Int(audio.duration) / 60
        let rest = Int(audio.duration) % 60
        return minutes > 0 ? "\(minutes):\(String(format: "%02d", rest))" : "\(rest) s"
    }

    /// What a Record surface opens against: the analysis and the take, which is exactly what the
    /// Import surface's own `boundVersions` reports after an import.
    static func boundRecord(in song: Song) -> [VersionID] {
        // The take first, so the row the ledger accents when the record opens is the record itself
        // rather than its analysis. (`ImportModel.boundVersions` reports the other order; that is the
        // surface describing itself, and the frame's binding is the frame's.)
        [take(in: song)?.id, analysisVersion(in: song)?.id].compactMap { $0 }
    }
}

extension PartVersion {
    /// How many slices a `.sample` carries, for a rationale that quotes the song rather than a mood.
    var kindSliceCount: Int {
        if case .sample(let sample) = kind { return sample.slices.count }
        return 0
    }
}

// MARK: - The obvious thing to do with a part

/// What a row in the parts ledger offers.
///
/// One entry per kind that Gate A has a surface for, and deliberately nothing for the four that it
/// does not (progression, melody, lyric, bassline): a row that offers an action which opens nothing
/// is the dead suggestion this design forbids. Those rows still select; they simply do not pretend.
public enum PartActions {

    /// The record surface, when there is a record to show.
    private static func showTheRecord(in song: Song) -> Proposal? {
        guard Guidance.canShowRecord(in: song) else { return nil }
        return Proposal(title: "Show the record",
                        rationale: Guidance.readingsLine(song: song, analysis: Guidance.analysis(in: song)),
                        action: SurfaceAction(surface: .importRecord, title: song.title,
                                              bound: Guidance.boundRecord(in: song)))
    }

    /// The action a ledger row performs when it is clicked, or nil when Gate A has no surface for
    /// this kind of part.
    public static func primary(for version: PartVersion, in song: Song) -> Proposal? {
        switch version.kind {

        case .analysis:
            return showTheRecord(in: song)

        case .audio(let audio) where audio.take != nil || audio.comp != nil:
            // A sung take, or the comp of several: the Takes surface, on every take of its part.
            // These rows used to open the Record surface — or nothing, in a song with no record.
            let takes = Guidance.takes(in: song).filter { $0.partID == version.partID }
            let bound = takes.isEmpty ? [version.id] : takes.map(\.id)
            return Proposal(title: "Open in Takes",
                            rationale: "\(Guidance.count(takes.count, "take")) of this part, lane by lane against the bars; choose a comp.",
                            action: SurfaceAction(surface: .takes, title: Guidance.takesTitle(of: takes, in: song), bound: bound))

        case .audio(let audio) where audio.role == .take:
            return showTheRecord(in: song)

        case .audio:
            // A stem. Chopping a bar of it is the thing you came for; the second click on the same
            // row is the same gesture and reopens the chop it already cut.
            if let cut = Guidance.chop(of: version.id, in: song) {
                return Proposal(title: "Open the chop lane",
                                rationale: "The bar already cut from this stem: \(PartLabel.title(of: cut)).",
                                action: SurfaceAction(surface: .chopLane, title: PartLabel.title(of: cut),
                                                      bound: [cut.id]))
            }
            guard let bar = Guidance.barToChop(of: version, in: song) else { return nil }
            return Proposal(title: "Chop a bar",
                            rationale: "Bar \(bar.number) of \(PartLabel.title(of: version).lowercased()), "
                                + "\(Guidance.seconds(bar.range.duration)), sliced on its downbeats.",
                            action: SurfaceAction(surface: .chopLane,
                                                  title: "Bar \(bar.number) of \(song.title)",
                                                  prepare: .chopBar(of: version.id)))

        case .sample:
            return Proposal(title: "Open the chop lane",
                            rationale: "\(Guidance.count(version.kindSliceCount, "marker")) off the record. The lane "
                                + "slices it, plays it on the pads, and re-grooves it.",
                            action: SurfaceAction(surface: .chopLane, title: PartLabel.title(of: version),
                                                  bound: [version.id]))

        case .groove:
            return Proposal(title: "Open in the Grid",
                            rationale: "Steps, swing and ghosts, played as you paint.",
                            action: SurfaceAction(surface: .grid, title: PartLabel.title(of: version),
                                                  bound: [version.id]))

        case .sound(let sound):
            // A groove's chop kit is shaped where the chop is cut.
            if let chop = ChopSound.part(of: sound.instrument),
               let cut = song.versions.last(where: { $0.partID == chop }) {
                return Proposal(title: "Open the chop",
                                rationale: "The groove plays these slices. Re-cut them and the groove follows.",
                                action: SurfaceAction(surface: .chopLane, title: PartLabel.title(of: cut),
                                                      bound: [cut.id]))
            }
            return Proposal(title: "Open in Sound",
                            rationale: "Synthesis and the degradation chain, auditioned on every knob.",
                            action: SurfaceAction(surface: .sound, title: PartLabel.title(of: version),
                                                  bound: [version.id]))

        case .bassline:
            return Proposal(title: "Open in the Piano roll",
                            rationale: "The notes over the bar with the kicks under them; the Bassist's readings below.",
                            action: SurfaceAction(surface: .pianoRoll, title: PartLabel.title(of: version),
                                                  bound: [version.id]))

        case .progression:
            return Proposal(title: "Open in Chords",
                            rationale: "The lead sheet, playable bar by bar.",
                            action: SurfaceAction(surface: .chords, title: PartLabel.title(of: version),
                                                  bound: [version.id]))

        case .lyric:
            return Proposal(title: "Open in Lyrics",
                            rationale: "The lines with their stresses and scheme; the Lyricist's readings below.",
                            action: SurfaceAction(surface: .lyrics, title: PartLabel.title(of: version), bound: [version.id]))

        case .melody:
            // The Piano roll in melody mode: the same grid the bass is drawn on, on the tune's own
            // instrument, read by the Melodist. A tune you drew used to be the one part in the
            // ledger that could not be opened again.
            return Proposal(title: "Open in the Piano roll",
                            rationale: "The tune over the bar, on its instrument; the Melodist's readings below.",
                            action: SurfaceAction(surface: .pianoRoll, title: PartLabel.title(of: version),
                                                  bound: [version.id]))

        case .mix:
            return Proposal(title: "Open in the Mixer",
                            rationale: "The strips as this version set them; the Master reads the bounce.",
                            action: SurfaceAction(surface: .mixer, title: song.title, bound: [version.id]))
        }
    }
}

// MARK: - Carrying an action out

extension AppState {

    /// What the rail offers right now.
    ///
    /// Two filters, both load-bearing. `director` first, because in Gate B a persona's proposals
    /// replace the derived ones rather than sitting under them. `canPerform` second, because the one
    /// promise this list makes is that everything on it works when clicked.
    public var proposals: [Proposal] {
        let derived = director.isEmpty ? Guidance.proposals(for: song) : director
        return derived.filter { canPerform($0.action) }
    }

    /// The next step, when the rail it normally lives in is folded away.
    ///
    /// Collapsing a region must not lose anything, and the rail is the one region where that is a
    /// real risk: "What next" is the only part of Gate A that tells you what to do. So when the rail
    /// is collapsed the leading proposal moves into the bench dock, above the surface you are working
    /// in — which is arguably where it belonged all along, since it is an instruction about the work
    /// rather than a line of conversation. The rest stay one keystroke away (⌥⌘2), and the collapsed
    /// strip carries their count in the accent so you can see there are more.
    ///
    /// Nil when the rail is open (the rail is showing them) or when there is nothing to propose.
    public var dockProposal: Proposal? {
        guard regions.isCollapsed(.rail) else { return nil }
        // Not what is already on the bench: "Re-groove Bar 5" over the lane open on Bar 5 is where
        // you are, not where to go.
        return proposals.first { !isShowing($0.action) }
    }

    /// Whether an open surface already shows what an action would open: its kind, on everything the
    /// action binds.
    func isShowing(_ action: SurfaceAction) -> Bool {
        guard action.prepare == .none else { return false }
        return bench.items.contains { item in
            item.kind == action.surface && Set(bound(for: item.id)).isSuperset(of: action.bound)
        }
    }

    /// Whether the frame could actually carry this out, right now, with this song and this library.
    ///
    /// The rail filters on this rather than trusting the derivation, so a proposal that arrives from
    /// somewhere else — a persona, a restored session — is held to the same standard.
    public func canPerform(_ action: SurfaceAction) -> Bool {
        for id in action.bound where version(id) == nil { return false }
        // An answer surface with nothing in it is not an answer. Every other surface in the catalog
        // is legitimate empty — the drop target, an empty grid, a new sound from the machine preset
        // — but a Compare with nothing to compare and a Check with nothing to check are panels whose
        // only content is the reason they are blank, which is the one thing this frame will not draw.
        if action.surface.isAnswer && action.bound.isEmpty { return false }
        switch action.prepare {
        case .none:
            // An unbound surface is legitimate (the drop target, an empty grid), so an action with
            // nothing bound and nothing to prepare is still performable.
            return true
        case .chopBar(let source):
            guard let song, let version = song.version(source), Guidance.audio(of: version) != nil else { return false }
            return Guidance.chop(of: source, in: song) != nil || Guidance.barToChop(of: version, in: song) != nil
        case .separateStems(let source):
            guard let song, let version = song.version(source),
                  Guidance.audio(of: version)?.role == .take else { return false }
            // Separation writes stems into the song's package, so a session with nowhere to write
            // must not offer it.
            return store != nil
        }
    }

    /// The surfaces whose work is a part of the song, so they need one open to keep it in.
    static let makesParts: Set<SurfaceKind> = [.grid, .chords, .pianoRoll, .sound, .structure, .lyrics, .booth, .mixer]

    /// Opens what a proposal asks for, doing any preparation first, and returns the surface.
    ///
    /// A surface of the kind already open is reused: brought forward if it is on the same versions,
    /// turned to them otherwise (`openSurface`). There is one of each kind.
    @discardableResult
    public func perform(_ action: SurfaceAction) -> SurfaceID? {
        // The master lives on the Mixer's own tab now: one surface and one working mix, rather than
        // two surfaces each saving moves off the same parent. Whoever asks for the Master — the
        // path, a proposal, the Director — gets the Mixer, on that tab.
        if action.surface == .master {
            var mixer = action
            mixer.surface = .mixer
            let id = perform(mixer)
            if let id { showMasterTab(id) }
            return id
        }
        // A surface that makes parts, opened with no song, writes into a new one. A beat painted
        // on first launch used to be kept nowhere — its version had no song to go in, and the one
        // line saying so went to the folded band column — and the next New Song closed it unasked.
        if song == nil, Self.makesParts.contains(action.surface) {
            open(Song.new(title: MrRobotoApp.untitledName()))
            note(.session, "Started \(song?.title ?? "a song") to keep what you make",
                 detail: "Name it and set its tempo in Song Settings (⇧⌘,).")
        }
        guard canPerform(action) else {
            note(.session, "That is not something this song can do right now", detail: action.title)
            return nil
        }

        var versions = action.bound
        if case .chopBar(let source) = action.prepare {
            guard let cut = chopBar(of: source) else {
                note(.session, "Could not cut a bar out of that", detail: action.title)
                return nil
            }
            versions = [cut] + action.bound
        }

        if let first = versions.first, version(first) != nil { select(first) }

        let id: SurfaceID
        if let existing = bench.items.first(where: { $0.kind == action.surface && bound(for: $0.id) == versions }) {
            retitleSurface(existing.id, to: action.title)
            id = existing.id
        } else {
            id = openSurface(action.surface, title: action.title, bound: versions)
        }
        setLevers(action.levers, for: id)
        // Filed after the reuse branch, not inside the else: "separate the stems" names the surface
        // the open song's record is already on, so reuse is the *normal* path for it, not the corner.
        if case .separateStems = action.prepare { file(action.prepare, for: id) }
        return id
    }

    /// Cuts one bar out of an audio version and records it, or returns the chop already cut from it.
    ///
    /// This is the Import surface's `promote` seen from the ledger: the same `.sample` payload, cut
    /// on the same downbeats, with the same parent — so the Chop lane resolves it by exactly the
    /// path a promoted region takes, and nothing new had to be plumbed to get there.
    @discardableResult
    public func chopBar(of audioID: VersionID) -> VersionID? {
        guard let song, let version = song.version(audioID), let audio = Guidance.audio(of: version) else { return nil }
        if let existing = Guidance.chop(of: audioID, in: song) { return existing.id }
        guard let bar = Guidance.barToChop(of: version, in: song) else { return nil }

        let analysis = Guidance.analysis(for: version, in: song)
        // The record the bar came from, for an album's clearances: the library record with this
        // media, or the one the song was seeded from.
        let sourceRecord = library.record(forMedia: audio.media)?.id ?? Guidance.sourceRecord(of: version, in: song)
        let sample = Sample(media: audio.media,
                            slices: bar.downbeats.map { SliceMarker(position: $0) },
                            rootPitch: nil,
                            detectedTempo: analysis?.dominantTempo ?? song.tempo,
                            sourceRecord: sourceRecord,
                            key: analysis?.key(at: bar.range.start))
        let cut = version.spawning(.sample(sample), by: .user, operation: Operation.chop,
                                   note: "Bar \(bar.number) of \(PartLabel.title(of: version).lowercased())")
        return record(cut) ? cut.id : nil
    }
}
