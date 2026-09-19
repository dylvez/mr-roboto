import Foundation
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
            return sound.preset.map { "\(sound.instrument) · \($0)" } ?? sound.instrument
        case .bassline:
            return note(of: version) ?? "Bass line"
        case .progression(let progression):
            return note(of: version) ?? progression.chords.prefix(4).map { $0.symbol() }.joined(separator: " ")
        case .melody, .lyric:
            return version.type.rawValue.capitalized
        case .mix:
            return note(of: version) ?? "Mix"
        }
    }

    /// The part's own note, cut to something that fits a 230-point column.
    private static func note(of version: PartVersion) -> String? {
        guard let note = version.note, !note.isEmpty else { return nil }
        // Notes read "Bar 12 of Arrival — Vessel – Arrival (1974)"; the citation is provenance, not
        // a name, and the ledger already shows provenance on its second line.
        let head = note.split(separator: "—", maxSplits: 1).first.map(String.init) ?? note
        return head.trimmingCharacters(in: .whitespaces)
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
        if let sample = samples(in: song).last(where: { groove(from: $0.id, in: song) == nil }) {
            out.append(Proposal(
                title: "Re-groove \(PartLabel.title(of: sample))",
                rationale: "The lane re-slices this bar on its transients; its re-groove lever puts the "
                    + "slices on a feel and hands the groove to the Grid.",
                action: SurfaceAction(surface: .chopLane,
                                      title: PartLabel.title(of: sample),
                                      bound: [sample.id])))
        }

        // 4. A groove exists: the Grid is where it is edited and played.
        if let groove = grooves(in: song).last {
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
        if song.sections.isEmpty, !grooves(in: song).isEmpty || !samples(in: song).isEmpty {
            out.append(Proposal(
                title: "Arrange \(song.title) into sections",
                rationale: "Structure lays the groove, the bass line and the chop out as intro, verse and hook, "
                    + "and the transport plays them in order.",
                action: SurfaceAction(surface: .structure, title: song.title)))
        }

        // 7. A sound to shape.
        if let sound = sounds(in: song).last {
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

        return Array(out.prefix(maximumProposals))
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
        if let sound = sounds(in: song).last {
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
            guard let sound = sounds(in: song).last else { return fallback }
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

    /// The record as imported: the one `.audio` version whose role is `.take`.
    public static func take(in song: Song) -> PartVersion? {
        song.versions.last { audio(of: $0)?.role == .take && audio(of: $0)?.take == nil && audio(of: $0)?.comp == nil }
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

    public static func grooves(in song: Song) -> [PartVersion] {
        song.versions.filter { $0.type == .groove }
    }

    public static func sounds(in song: Song) -> [PartVersion] {
        song.versions.filter { $0.type == .sound }
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
        song.versions.filter { $0.type == .bassline }
    }

    public static func progressions(in song: Song) -> [PartVersion] {
        song.versions.filter { $0.type == .progression }
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

        case .sound:
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
            // No surface edits a melody yet. Saying nothing is the honest answer; its surface
            // arrives with the rest of the catalog.
            return nil

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
        return proposals.first
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

    /// Opens what a proposal asks for, doing any preparation first, and returns the surface.
    ///
    /// Reuses an open surface of the same kind bound to the same versions rather than opening a
    /// second one: the bench holds three, and clicking a ledger row twice should take you back to
    /// the panel you were just in, not retire something to make room for its twin.
    @discardableResult
    public func perform(_ action: SurfaceAction) -> SurfaceID? {
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
