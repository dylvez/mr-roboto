import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// The Piano roll's entry in the catalog: surface #7, bound to a bass line.
public struct PianoRollSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .pianoRoll }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Piano roll") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

/// The Piano roll's model: a bass line over the bar, with the groove's kicks drawn under it so the
/// lag is visible and not only audible.
///
/// Two ways in. Opened on a **bass line**, it edits that line and every commit derives from it.
/// Opened on a **groove** (or on nothing, with a song that has one), it writes a new line under
/// that groove with `Performance.BassWriter` and the levers — lineage, lag, density, sound — re-run
/// the writer. Either way the Bassist reads the result back through `BassObservation` and its
/// readings sit under the roll, so what the bible says about the line is on the surface, not in
/// a rail two panels away.
///
/// Notes are edited in place: drag to move (across for time, up and down for pitch), drag the
/// right edge to lengthen, double-click to delete, click an empty cell to add. Several at once: a
/// marquee over empty space, or shift-click, picks out a set, and the set moves and goes together,
/// is laid again after itself (⌘D), and goes to the pasteboard and comes back from it (⌘C, ⌘V).
/// An edit refreshes the readings and keeps itself a moment later.
///
/// The line has a length of its own, in bars, that is not the groove's. A four-bar melody or an
/// eight-bar bass phrase over a one-bar groove is a line the roll can hold: the groove is read
/// repeated under it — the kick lane, the writer and the Bassist all see the kick in every bar —
/// and the length is kept on the part, so a last bar that is a rest stays a bar.
@MainActor
@Observable
public final class PianoRollModel {

    // MARK: Identity

    public let surfaceID: SurfaceID

    public var surface: PianoRollSurface {
        PianoRollSurface(id: surfaceID, bound: [base?.id, grooveVersion].compactMap { $0 }, title: title)
    }

    public var title: String {
        // A tune is not a bass line. The lineage names whose hands wrote the bass, and the bound
        // version names the part this roll was opened on — neither is right once the mode says
        // melody, unless the bound part is itself a melody.
        if mode == .melody {
            if let base, base.type == .melody { return PartLabel.title(of: base) }
            let name = InstrumentVoiceSpec.preset(id: instrument)?.name ?? instrument
            return "\(name) melody, \(String(format: "%.0f", tempo))"
        }
        if let base { return PartLabel.title(of: base) }
        return "\(lineage.name) line, \(String(format: "%.0f", tempo))"
    }

    // MARK: What it sits under

    public private(set) var groove: Groove?
    public private(set) var grooveVersion: VersionID?
    public private(set) var grooveOptions: GrooveRenderOptions
    public private(set) var chords: [ChordSpan]
    public private(set) var key: Key
    public private(set) var tempo: Double
    public private(set) var timeSignature: TimeSignature
    /// The kick's decay when the song's kit says: what R9 reads.
    public private(set) var kickDecaySeconds: Double

    // MARK: The line

    /// What this roll is writing. The surface is the same grid either way; what changes is which
    /// part it commits, which instrument sounds it, and whether the Bassist has anything to say.
    public enum Mode: String, CaseIterable, Sendable {
        case bass, melody
        public var title: String { self == .bass ? "Bass" : "Melody" }
    }

    public private(set) var mode: Mode = .bass
    /// The pitched instrument a melody plays through, by preset id.
    public private(set) var instrument: String = InstrumentVoiceSpec.rhodes.id
    public private(set) var notes: [NoteEvent]
    public private(set) var sound: String
    /// How many bars the line is. Its own, not the groove's: kept on the part, so the players loop
    /// it at this length and a trailing rest is part of the phrase. Undoable like any edit.
    public private(set) var lengthInBars: Int

    /// The lengths the control offers. Any length the line arrives with is honoured too.
    public static let lengthChoices = [1, 2, 4, 8, 16]
    /// The longest line the roll will make. Double stops here.
    public static let longestLine = 16

    // MARK: The writer's levers

    public private(set) var lineage: BassLineage
    public private(set) var lagMS: Double
    public private(set) var density: Double
    public private(set) var earlyAlternation: Bool
    public private(set) var seed: UInt64
    /// Which figure of the hand's vocabulary the body of the line is, when one was stepped to;
    /// nil leaves it to the seed. Dropped with the hand, whose figures these are.
    public private(set) var figure: Int?
    /// Whether the line on screen was written by the writer with the current levers, or has been
    /// touched by hand since. Re-running the writer over a hand edit is a real loss, so the levers
    /// say so before they do it.
    public private(set) var isHandEdited = false

    /// Whether the levers are held off the notes. A line edited by hand is the user's, and a lever
    /// re-running the writer over it would drop every edit in one silent stroke — so while the line
    /// is hand-edited a lever only moves itself. `writeOverHandEdits()` is the explicit step that
    /// lets the writer replace the line; nothing else does.
    public var leversAreHeld: Bool { writesFromLevers && isHandEdited && groove != nil }

    /// The notes a click, a marquee or a shift-click picked out, as indices into `notes`. Delete
    /// removes them, a drag on any of them moves them all, Escape clears them. Dropped whenever the
    /// list is replaced or re-ordered, because an index into a different list is a different note.
    public private(set) var selectedNotes: Set<Int> = []

    /// Where the lane was last clicked on empty space, in beats: where a paste lands. Nil until a
    /// click, and then a paste lands after the line.
    public private(set) var caret: Double?

    /// How close the lane is looked at, as chosen: this many bars across its width, or nil for the
    /// whole line. Kept as chosen through a line shortened under it, so a line doubled back is
    /// looked at as it was; read through `barsAcross`, which holds it to the line. Not an edit —
    /// nothing moves — so not a step of undo, and not kept with the part.
    private var zoomBars: Int?

    // MARK: Versions and readings

    public private(set) var base: PartVersion?
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    public private(set) var readings: [PersonaReading] = []
    /// The version the last keep made, for the footer to say so. Nil until one is kept, and set
    /// aside again — by `hasUnkeptChanges` turning true — once the notes move on from it.
    public private(set) var lastKept: PartVersion?

    /// Whether what is on screen differs from the last version kept, or from the one the roll was
    /// opened on. The keep control follows this, so pressing it twice cannot file the same line
    /// twice; a fresh roll with notes on it has everything to keep.
    public var hasUnkeptChanges: Bool {
        // A first tune carried over from the bass line is the bass line's notes until they change:
        // an edit undone back to them is nothing to keep.
        guard let kept = lastKeptOfThisKind else { return isTouched && !notes.isEmpty && notes != carriedInto[mode] }
        switch kept.kind {
        case .bassline(let line):
            if line.notes != sounding { return true }
            if let keptSound = line.sound, keptSound != sound { return true }
            return (line.lengthInBars ?? openedLength) != lengthInBars
        case .melody(let tune):
            return tune.notes != sounding || (tune.lengthInBars ?? openedLength) != lengthInBars
        default:
            return true
        }
    }

    /// The newest version this roll kept or was opened on that is the same kind of part as the
    /// mode says it is writing. A roll opened on a bass line and switched to melody is writing a
    /// new part, not a new version of the bass line — a part does not change what it is.
    private var lastKeptOfThisKind: PartVersion? { lastKept(as: mode) }

    private func lastKept(as mode: Mode) -> PartVersion? {
        let type: PartType = mode == .melody ? .melody : .bassline
        return versions.last { $0.type == type } ?? [base, other].compactMap { $0 }.first { $0.type == type }
    }

    /// The part of the other kind the roll was opened with: the bass line under a tune it opened
    /// on, or the tune over the bass line. Its own line when the mode comes back to it.
    private var other: PartVersion?

    /// Each mode's line while the other is on screen. The bass line and the tune are two parts, and
    /// one list of notes used to serve both: switching back to Bass showed the tune, and kept it
    /// over the bass line a moment later.
    private var parked: [Mode: (notes: [NoteEvent], lengthInBars: Int)] = [:]
    /// The notes a mode with no line of its own started from: the other mode's.
    private var carriedInto: [Mode: [NoteEvent]] = [:]

    /// An instrument picked for a tune before it is kept: the tune's, once it is. It used to be set
    /// on the song, and the chords moved to the lead with it.
    private var instrumentForTheTune: String?

    /// The length the roll gave a bound line that did not state one. That line is "as long as its
    /// notes", and opening it is not an edit: only a length the person sets differs from it.
    private var openedLength: Int = 1

    /// Whether the person has done anything to the line. The line the writer drafts when the roll
    /// opens under a groove is a proposal until then — played, not kept — so opening the Piano
    /// roll to look is not writing a part into the song. `useThisLine()` accepts it untouched.
    ///
    /// Asked of the mode the roll is in. Switching a bass line to melody mode is not writing a
    /// tune: the notes are the bass line's until something is done to them there. It used to count,
    /// and a moment in melody mode kept a copy of the bass line as a tune in every section.
    public var isTouched: Bool { touchedModes.contains(mode) }
    private var touchedModes: Set<Mode> = []

    // MARK: Keeping as it goes

    /// What ⌘Z steps back through: the notes and the levers that wrote them.
    struct RollState: Equatable, Sendable {
        var notes: [NoteEvent]
        var lengthInBars: Int
        var sound: String
        var mode: Mode
        var lineage: BassLineage
        var lagMS: Double
        var density: Double
        var earlyAlternation: Bool
        var seed: UInt64
        var figure: Int?
        var isHandEdited: Bool
    }

    private var history = EditHistory<RollState>()
    /// The edit in progress, so a drag or a slider is one step of undo, not one per frame.
    private var lastEdit: (kind: String, at: Date)?
    /// Keeps the line a moment after the last edit. A test sets its delay to nil and keeps by hand.
    public let autoKeep = AutoKeep()

    private var state: RollState {
        get {
            RollState(notes: notes, lengthInBars: lengthInBars, sound: sound, mode: mode, lineage: lineage, lagMS: lagMS, density: density,
                      earlyAlternation: earlyAlternation, seed: seed, figure: figure, isHandEdited: isHandEdited)
        }
        set {
            notes = newValue.notes
            lengthInBars = newValue.lengthInBars
            sound = newValue.sound
            mode = newValue.mode
            lineage = newValue.lineage
            lagMS = newValue.lagMS
            density = newValue.density
            earlyAlternation = newValue.earlyAlternation
            seed = newValue.seed
            figure = newValue.figure
            isHandEdited = newValue.isHandEdited
            selectedNotes = []
            refreshReadings()
        }
    }

    /// Before an edit. Repeats of the same kind of edit in quick succession — a drag, a slider —
    /// are folded into the first, so ⌘Z takes back the gesture rather than its last frame.
    private func willEdit(_ kind: String) {
        let now = Date()
        defer { lastEdit = (kind, now) }
        if let last = lastEdit, last.kind == kind, now.timeIntervalSince(last.at) < 0.75 { return }
        history.record(state)
    }

    /// After an edit: the line is the person's now, and it keeps itself once they stop.
    private func didEdit() {
        touchedModes.insert(mode)
        settle()
    }

    /// Keeps a moment from now when there is something to keep, and not otherwise.
    private func settle() {
        guard hasUnkeptChanges else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    /// A new tune from nothing: melody mode on an empty grid. For a roll opened on no part — the
    /// surface's "New melody" — where switching modes would carry the drafted bass line up an
    /// octave as the tune's first notes. The draft is parked for Bass mode, and nothing is kept
    /// until a note is drawn.
    public func startFreshTune() {
        guard !isTaking, base == nil, versions.isEmpty, mode == .bass else { return }
        parked[.bass] = (notes, lengthInBars)
        mode = .melody
        notes = []
        selectedNotes = []
        refreshReadings()
    }

    /// Accepts the line the writer drafted, untouched, as a part of the song.
    public func useThisLine() {
        touchedModes.insert(mode)
        keepNow()
    }

    /// The pitch range the roll draws: the lineage's register, widened to hold the notes.
    /// Whether the writer's levers apply. A tune is drawn by hand: nothing in the app writes one,
    /// and a lever that silently did would be the Bassist writing melodies.
    public var writesFromLevers: Bool { mode == .bass }

    public var melody: Melody { Melody(notes: sounding, lengthInBars: lengthInBars) }

    /// The notes in the order they sound. A drag leaves a moved note where it was in the list —
    /// its index is what the drag holds — so the order is put right when the line is kept.
    private var sounding: [NoteEvent] {
        notes.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// Who reads what this roll is writing.
    public var readingPersona: String { mode == .bass ? "Bassist" : "Melodist" }

    public func setMode(_ value: Mode) {
        // A take is written into the line on screen; it cannot change line halfway.
        guard value != mode, !isTaking else { return }
        // What this mode has not kept yet is kept before it goes off screen.
        if isTouched, hasUnkeptChanges { _ = keepNow() }
        willEdit("mode")
        parked[mode] = (notes, lengthInBars)
        mode = value
        selectedNotes = []
        defer { settle() }
        if let back = parked[value] {
            notes = back.notes
            lengthInBars = back.lengthInBars
        } else if let kept = lastKept(as: value) {
            switch kept.kind {
            case .bassline(let line):
                notes = line.notes
                lengthInBars = line.lengthInBars ?? lengthInBars
            case .melody(let tune):
                notes = tune.notes
                lengthInBars = tune.lengthInBars ?? lengthInBars
            default: break
            }
        }
        else {
            // A first tune starts from the bass line's notes: they sound an octave up on a
            // different instrument, which is usually what you wanted when you switched.
            carriedInto[value] = notes
        }
        refreshReadings()
    }

    public func setInstrument(_ id: String) {
        guard InstrumentVoiceSpec.preset(id: id) != nil else { return }
        instrument = id
        // For *this* part, so a tune can be a lead over chords on a pad. A tune not kept yet has
        // no part to name: the pick waits for its first keep rather than moving the song's.
        if mode == .melody, part == nil {
            instrumentForTheTune = id
        } else {
            host.setInstrument(id, for: part)
        }
        if let first = notes.first { audition(first) }
    }

    /// The part this roll is working on, once it has one: the bass line in bass mode, the tune in
    /// melody mode. A roll switched from a kept bass line to melody has no tune yet, so an
    /// instrument picked there is the song's rather than the bass line's.
    public var part: PartID? { lastKeptOfThisKind?.partID }

    // MARK: The song's tune

    /// Whether the tune on screen is the song's tune: the part the band reads as the tune — the
    /// Melodist, Another way, the line that answers it, the words set to it — marked as it, or a
    /// variation of the part that is. A tune not kept yet is, when it is to be marked at its first
    /// keep.
    public var isTheSongsTune: Bool {
        guard mode == .melody else { return false }
        guard let part else { return marksTuneWhenKept }
        return host.isTune(part)
    }

    /// Marks the tune on screen as the song's tune, or takes the mark off. A variation marks the
    /// part it varies. Not an edit of the line, so not a step of ⌘Z: like the instrument, it is a
    /// choice about the part, said at once.
    public func markAsTheSongsTune(_ on: Bool) {
        guard mode == .melody, !isTaking else { return }
        // A tune not kept yet has no part to name: the mark waits for its first keep.
        guard let part else { marksTuneWhenKept = on; return }
        guard on != host.isTune(part) else { return }
        host.markTune(on ? part : nil)
    }

    /// The song's tune, asked for before the tune on screen was kept.
    private var marksTuneWhenKept = false

    public var register: ClosedRange<Int> {
        // A tune is drawn where a tune sits — C4 to C6 — not in the bass player's two octaves, where
        // every note drawn used to land two octaves low.
        let drawn = mode == .melody ? 60...84 : lineage.register
        var low = drawn.lowerBound, high = drawn.upperBound
        for note in notes { low = min(low, note.pitch.midi); high = max(high, note.pitch.midi) }
        return low...high
    }

    private let host: any PianoRollHosting
    private let bassist = Bassist()

    /// The song's genre, asked each time the readings are made: a reading is re-judged in it
    /// (`GenreLens`). Nil — the default, and a song nobody has placed — leaves the persona's own.
    public var genre: @MainActor () -> GenreLens? = { nil }

    /// Reads again, for a genre that changed under an open roll.
    public func genreChanged() { refreshReadings() }

    /// What the library's other songs did, for the Melodist's reading against them, and the
    /// house's calls, which can turn that reading off. Asked each time, like the genre.
    public var before: @MainActor () -> SongsBefore? = { nil }
    public var house: @MainActor () -> HouseBook? = { nil }

    // MARK: Init

    public init(host: any PianoRollHosting,
                groove: Groove?, grooveVersion: VersionID? = nil,
                grooveOptions: GrooveRenderOptions = GrooveRenderOptions(),
                chords: [ChordSpan] = [], key: Key,
                tempo: Double, timeSignature: TimeSignature = .fourFour,
                kickDecaySeconds: Double = 0,
                bassline: PartVersion? = nil,
                melody: PartVersion? = nil,
                opensOnMelody: Bool = false,
                instrument: String? = nil,
                lineage: BassLineage = .palladino, seed: UInt64 = 0xBA55_0001,
                surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.groove = groove
        self.grooveVersion = grooveVersion
        self.grooveOptions = grooveOptions
        self.chords = chords
        self.key = key
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.kickDecaySeconds = kickDecaySeconds
        self.lineage = lineage
        self.lagMS = lineage.defaultLagMS
        self.density = 0.5
        self.earlyAlternation = false
        self.seed = seed
        self.notes = []
        self.sound = lineage.defaultSound
        // A fresh line is as long as the groove it is written under; a bound one is reset below.
        self.lengthInBars = max(1, groove?.bars ?? 1)
        if let instrument, InstrumentVoiceSpec.preset(id: instrument) != nil { self.instrument = instrument }
        let beatsPerBar = max(1, timeSignature.beatsPerBar)
        // Bound to both, the roll opens on the one it was writing last (`opensOnMelody`) and
        // remembers the other for when the mode comes back to it.
        if let bassline, case .bassline(let line) = bassline.kind, !(opensOnMelody && melody != nil) {
            base = bassline
            other = melody
            notes = line.notes
            sound = line.sound ?? lineage.defaultSound
            lengthInBars = Self.openingLength(stated: line.lengthInBars, notes: line.notes, groove: groove,
                                              beatsPerBar: beatsPerBar)
            openedLength = lengthInBars
            isHandEdited = true
            refreshReadings()
        } else if let melody, case .melody(let tune) = melody.kind {
            // Opened on a tune: melody mode, its notes, its instrument, and every commit derives
            // from it. The bass writer never runs on a tune: one comes from the hand, a controller
            // in Keys, or the Director writing for the Melodist.
            base = melody
            other = bassline
            mode = .melody
            notes = tune.notes
            lengthInBars = Self.openingLength(stated: tune.lengthInBars, notes: tune.notes, groove: groove,
                                              beatsPerBar: beatsPerBar)
            openedLength = lengthInBars
            isHandEdited = true
            refreshReadings()
        } else {
            write()
        }
    }

    /// The song around the roll moved on: new chords, a groove kept in the Grid, another tempo or
    /// key. The line on screen is left alone, because a line is the user's until they ask. But the
    /// readings, the kick lane and the next Rewrite read the song as it is now. A draft nobody has
    /// touched or kept is written again against it, since nothing of the user's is in it.
    public func follow(groove: Groove?, grooveVersion: VersionID?, chords: [ChordSpan], key: Key,
                       tempo: Double, timeSignature: TimeSignature, kickDecaySeconds: Double) {
        guard groove != self.groove || grooveVersion != self.grooveVersion || chords != self.chords
                || key != self.key || tempo != self.tempo || timeSignature != self.timeSignature
                || kickDecaySeconds != self.kickDecaySeconds else { return }
        self.groove = groove
        self.grooveVersion = grooveVersion
        self.chords = chords
        self.key = key
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.kickDecaySeconds = kickDecaySeconds
        if mode == .bass, base == nil, versions.isEmpty, !isTouched, !isHandEdited {
            write()
        } else {
            refreshReadings()
        }
    }

    /// A bound line's length: the one it states, else the bars its notes reach — the length the
    /// song loops it at (`loopBars`). It used to open no shorter than the groove, so a one-bar line
    /// under a two-bar groove opened as two, and the first nudge kept a silent second bar.
    static func openingLength(stated: Int?, notes: [NoteEvent], groove: Groove?, beatsPerBar: Int) -> Int {
        if let stated { return max(1, stated) }
        return max(1, Int(((notes.map(\.end).max() ?? 0) / Double(max(1, beatsPerBar))).rounded(.up)))
    }

    // MARK: Reading

    public var bassline: Bassline { Bassline(notes: sounding, sound: sound, key: key, lengthInBars: lengthInBars) }

    public var beatsPerBar: Int { max(1, timeSignature.beatsPerBar) }
    /// The line's bars: its own length, which may be longer (or shorter) than the groove's.
    public var bars: Int { lengthInBars }
    public var totalBeats: Double { Double(bars * beatsPerBar) }

    /// The groove as this line hears it: repeated to the line's length, or cut to it. What the kick
    /// lane draws, what the writer writes against and what the Bassist reads against — so bar
    /// eight of a phrase over a one-bar groove has a kick under it, as it does when it plays.
    public var lineGroove: Groove? { groove?.tiled(toBars: lengthInBars) }

    /// The groove's kick onsets in beats, swung as it swings them, for the lane under the notes —
    /// across the whole line, not only the groove's own bars.
    public var kickBeats: [Double] {
        guard let lineGroove else { return [] }
        return BassWriter.kickOnsets(in: lineGroove, beatsPerBar: Double(beatsPerBar))
    }

    public var observation: BassObservation? {
        guard let lineGroove else { return nil }
        return BassObservation(label: title, bassline: bassline, groove: lineGroove, chords: chords,
                               tempo: tempo, timeSignature: timeSignature, options: grooveOptions,
                               kickDecaySeconds: kickDecaySeconds)
    }

    /// Whether the line was written to the key's default harmony rather than stated chords.
    public var usesDefaultChords: Bool { chords.isEmpty }

    /// A chord's name on the band across the top: its root spelled as the song's key spells it, so
    /// the sixth of E♭ minor is C♭maj7 there as it is on the Chords sheet, and not Bmaj7.
    public func symbol(of chord: Chord) -> String { chord.symbol(in: key) }

    // MARK: The writer

    private var request: BassRequest? {
        guard let groove else { return nil }
        return BassRequest(key: key, chords: chords, groove: groove, tempo: tempo, timeSignature: timeSignature,
                           lineage: lineage, lagMS: lagMS, density: density, earlyAlternation: earlyAlternation,
                           sound: sound, seed: seed, bars: lengthInBars, figure: figure)
    }

    /// Writes the line from the levers. Replaces whatever is on screen, hand edits included: the
    /// lever setters go through `writeUnlessHeld()` so they cannot reach this over a hand edit, and
    /// `writeOverHandEdits()` is the one caller that means to.
    public func write() {
        guard let request else { return }
        let line = BassWriter.write(request)
        notes = line.notes
        sound = line.sound ?? sound
        lengthInBars = line.lengthInBars ?? lengthInBars
        isHandEdited = false
        selectedNotes = []
        refreshReadings()
    }

    /// The explicit step: the writer replaces a hand-edited line with one from the levers as they
    /// stand now. Pressed, not slid into.
    public func writeOverHandEdits() {
        guard !isTaking else { return }
        willEdit("rewrite-over")
        write()
        didEdit()
    }

    /// A lever moved. Runs the writer unless the line is edited by hand, in which case the lever
    /// has moved and the notes have not — the readings refresh because the sound may have.
    private func writeUnlessHeld() {
        // Held while a take comes in, too: the writer would replace the notes being played.
        guard !leversAreHeld, !isTaking else { refreshReadings(); return }
        write()
    }

    /// A different line from the same levers.
    public func rewrite() {
        willEdit("rewrite")
        seed &+= 0x9E37_79B9
        writeUnlessHeld()
        didEdit()
    }

    /// The phrase the levers write: the figure and the turnaround, named. Nil for the players
    /// that write from the kick, which have no figures to step through.
    public var phrase: BassPhrase? { request.flatMap(BassWriter.phrase(for:)) }

    /// Whether the hand has figures to step through.
    public var hasFigures: Bool { lineage.writesFigures }

    /// The next figure of the same hand, the seed and the turnaround as they are: a step through
    /// the hand's vocabulary rather than a new roll of everything.
    public func nextFigure() {
        guard let phrase, !lineage.figures.isEmpty else { return }
        willEdit("figure")
        figure = (phrase.figureIndex + 1) % lineage.figures.count
        writeUnlessHeld()
        didEdit()
    }

    public func setLineage(_ value: BassLineage) {
        willEdit("lineage")
        lineage = value
        figure = nil
        lagMS = value.defaultLagMS
        sound = value.defaultSound
        writeUnlessHeld()
        didEdit()
    }

    public func setLag(_ milliseconds: Double) {
        willEdit("lag")
        lagMS = min(Bassist.lagCeilingMS, max(-25, milliseconds))
        writeUnlessHeld()
        didEdit()
    }

    public func setDensity(_ value: Double) {
        willEdit("density")
        density = min(1, max(0, value))
        writeUnlessHeld()
        didEdit()
    }

    public func setEarlyAlternation(_ on: Bool) {
        willEdit("early")
        earlyAlternation = on
        writeUnlessHeld()
        didEdit()
    }

    /// The imported instruments a bass line can play on: the one it plays on now, and the ones
    /// that are basses — called one, or a tuba — and reach down to the E a bass guitar's lowest
    /// string is tuned to. A piano reaches as low and is not a bass.
    public var importedSounds: [BassVoiceSpec] {
        ImportedInstruments.all.filter { $0.id == sound || Self.isABass($0) }.map(BassVoiceSpec.init(imported:))
    }

    /// The imported instruments that are basses, whatever a line plays on now: what the Director's
    /// write_bassline is offered beside the presets.
    public nonisolated static var importedBasses: [BassVoiceSpec] {
        ImportedInstruments.all.filter(isABass).map(BassVoiceSpec.init(imported:))
    }

    /// Called a bass, and reaching down to a bass guitar's low E.
    nonisolated static func isABass(_ spec: InstrumentVoiceSpec) -> Bool {
        isCalledABass(spec) && ImportedInstruments.lowestNote(of: spec).map { $0 <= 40 } == true
    }

    /// Whether an imported instrument is one a bass line would reach for: placed among the
    /// basses, or called a bass, a contrabass or a tuba. By the word, not the letters: a bassoon
    /// is not a bass.
    public nonisolated static func isCalledABass(_ spec: InstrumentVoiceSpec) -> Bool {
        if spec.family == "bass" { return true }
        let words = Set(spec.name.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["bass", "contrabass", "tuba"])
    }

    /// The bass sound. Does not rewrite: the same notes through another voice.
    public func setSound(_ id: String) {
        guard BassVoiceSpec.resolve(id: id) != nil, id != sound else { return }
        willEdit("sound")
        sound = id
        refreshReadings()
        if let first = notes.first { audition(first) }
        didEdit()
    }

    /// The levers the Director hung on the surface, as the sliders' starting positions.
    ///
    /// On a line written under a groove they re-run the writer, which is what a lever means there.
    /// On a bound line they only move the sliders: the line was written with them already, and a
    /// lever on an existing version is a description of it, not an instruction to replace it.
    public func adoptLevers(lag: Double?, density: Double?) {
        if base != nil {
            if let lag { lagMS = min(Bassist.lagCeilingMS, max(-25, lag)) }
            if let density { self.density = min(1, max(0, density)) }
            return
        }
        if let lag { lagMS = min(Bassist.lagCeilingMS, max(-25, lag)) }
        if let density { self.density = min(1, max(0, density)) }
        if lag != nil || density != nil { write() }
    }

    // MARK: The line's length

    /// The line becomes `bars` long. Longer, and the new bars are empty — unless the line is still
    /// the writer's, in which case the writer writes the whole length, since a lever is what the
    /// writer's line answers to. Shorter, and every note past the new end goes, and a note that
    /// would ring over it is cut at it. Both are one step of ⌘Z.
    public func setLength(_ bars: Int) {
        let target = min(Self.longestLine, max(1, bars))
        guard target != lengthInBars, !isTaking else { return }
        willEdit("length")
        defer { didEdit() }
        lengthInBars = target
        if writesFromLevers, !isHandEdited, groove != nil {
            write()
            return
        }
        trimToLength()
        selectedNotes = []
        refreshReadings()
    }

    /// Whether Double has room: the line twice over is no longer than the roll will make.
    public var canDouble: Bool { lengthInBars * 2 <= Self.longestLine }

    /// The line twice: every note copied into the bars after it, and the length doubled. The usual
    /// way a one-bar idea becomes a phrase — the copy is there to be changed, and changing it is
    /// the point, so the line is the person's from here and the levers hold off it.
    public func double() {
        guard canDouble, !isTaking else { return }
        willEdit("double")
        defer { didEdit() }
        let offset = totalBeats
        let copies = notes.filter { $0.start < offset }.map { note in
            NoteEvent(pitch: note.pitch, start: note.start + offset, duration: note.duration, velocity: note.velocity)
        }
        lengthInBars *= 2
        notes += copies
        notes.sort { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
        if !copies.isEmpty { isHandEdited = true }
        selectedNotes = []
        refreshReadings()
    }

    // MARK: Another way

    /// The treatments offered on a tune, the ones that change what it says first.
    static let tuneWaysOffered: [TuneTreatment] = [.pushed, .sequenced, .answered, .lift, .sparse]

    /// The treatments the tune on the roll has room for: pushed over its bar lines, its opening
    /// again on another degree, twice with a second ending. Empty on a bass line.
    public var tuneWays: [TuneTreatment] {
        guard mode == .melody, notes.count >= 2 else { return [] }
        return Self.tuneWaysOffered.filter { treated($0) != nil }
    }

    private func treated(_ treatment: TuneTreatment) -> Melody? {
        let tune = Melody(notes: sounding, lengthInBars: lengthInBars)
        guard let varied = TuneVariation.vary(tune, as: treatment, bars: lengthInBars * 2, beatsPerBar: beatsPerBar,
                                              key: key, chords: chords),
              varied.loopBars(beatsPerBar: beatsPerBar) <= Self.longestLine, varied.notes != tune.notes else { return nil }
        return varied
    }

    /// The tune on the roll played another way, as one edit: ⌘Z puts it back.
    public func play(as treatment: TuneTreatment) {
        guard mode == .melody, !isTaking, let varied = treated(treatment) else { return }
        willEdit("way-\(treatment.rawValue)-\(notes.count)")
        defer { didEdit() }
        notes = varied.notes.sorted { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
        lengthInBars = varied.loopBars(beatsPerBar: beatsPerBar)
        isHandEdited = true
        selectedNotes = []
        refreshReadings()
    }

    /// Whether Tighten would move anything. Never on the writer's own line: the writer put each
    /// note where the levers say, and moving them would be arguing with the levers.
    public var canTighten: Bool {
        guard !(writesFromLevers && !isHandEdited) else { return false }
        let target = tightened
        return target.count != notes.count || zip(target, notes).contains { a, b in
            a.pitch != b.pitch || abs(a.start - b.start) > 1e-6 || abs(a.duration - b.duration) > 1e-6
        }
    }

    /// How far behind the grid Tighten leaves a bass note: the Behind-the-kick lever, in beats. A
    /// tune has no lag to keep.
    var tightenLagBeats: Double { mode == .bass ? lagMS / 1000 * tempo / 60 : 0 }

    /// Every note onto the nearest sixteenth, start and end, at least a sixteenth long — and a bass
    /// note the lever's lag behind its sixteenth, since a bass line dead on the kick is not the
    /// idiom. A line played in on a controller lands as the hands played it, which is what a feel
    /// is and not always what was meant; this is the one press that makes it read as written.
    /// Two notes that land on the same step and pitch become the louder one. One step of ⌘Z puts
    /// the feel back.
    public func tighten() {
        guard canTighten, !isTaking else { return }
        willEdit("tighten")
        defer { didEdit() }
        notes = tightened
        isHandEdited = true
        selectedNotes = []
        refreshReadings()
    }

    /// The notes as Tighten would leave them.
    private var tightened: [NoteEvent] {
        let end = totalBeats
        let lag = tightenLagBeats
        var out: [NoteEvent] = []
        for note in notes {
            let onGrid = max(0, min(end - 0.25, Self.snap(note.start - lag)))
            let start = min(end - 0.125, onGrid + lag)
            let stop = min(end, max(onGrid + 0.25, Self.snap(note.end)))
            let snapped = NoteEvent(pitch: note.pitch, start: start, duration: max(0.125, stop - start), velocity: note.velocity)
            if let twin = out.firstIndex(where: { $0.pitch == snapped.pitch && abs($0.start - start) < 1e-9 }) {
                if snapped.velocity > out[twin].velocity { out[twin] = snapped }
            } else {
                out.append(snapped)
            }
        }
        return out.sorted { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
    }

    /// Drops the notes that start at or past the end, and cuts the ones that ring over it.
    private func trimToLength() {
        let end = totalBeats
        notes = notes.compactMap { note in
            guard note.start < end - 1e-9 else { return nil }
            var kept = note
            kept.duration = min(note.duration, end - note.start)
            return kept
        }
    }

    // MARK: Editing notes

    public func addNote(pitch: Int, at beat: Double, duration: Double = 0.5) {
        // The notes of a take are held by their place in the list: nothing moves it under them.
        guard !isTaking else { return }
        willEdit("add")
        defer { didEdit() }
        // On the grid, inside the loop: a click in the last sixteenth snaps to that sixteenth, not a
        // thirty-second before the loop point, and the note is cut to end there.
        let start = max(0, min(totalBeats - 0.25, Self.snap(beat)))
        let note = NoteEvent(pitch: Pitch(midi: pitch), start: start,
                             duration: max(0.125, min(duration, totalBeats - start)), velocity: 100)
        isHandEdited = true
        // The new note is the selection, so a stray click is one Delete from undone; and the click
        // is where a paste lands next.
        selectedNotes = place([note])
        caret = start
        refreshReadings()
        audition(note)
    }

    /// `added` into the list, in the order the line sounds, and where they landed: the indices a
    /// selection of them is. Two notes alike are told apart by their place in the list, so a copy
    /// laid over its original is found and not its original.
    private func place(_ added: [NoteEvent]) -> Set<Int> {
        let all = notes.enumerated().map { (note: $0.element, added: false, order: $0.offset) }
            + added.enumerated().map { (note: $0.element, added: true, order: notes.count + $0.offset) }
        let sorted = all.sorted { ($0.note.start, $0.note.pitch.midi, $0.order) < ($1.note.start, $1.note.pitch.midi, $1.order) }
        notes = sorted.map(\.note)
        return Set(sorted.indices.filter { sorted[$0].added })
    }

    public func moveNote(at index: Int, toStart start: Double, pitch: Int) {
        guard notes.indices.contains(index), !isTaking else { return }
        willEdit("move \(index)")
        defer { didEdit() }
        var note = notes[index]
        note.start = max(0, min(totalBeats - note.duration, Self.snap(start)))
        note.pitch = Pitch(midi: max(0, min(127, pitch)))
        let pitchChanged = notes[index].pitch != note.pitch
        notes[index] = note
        isHandEdited = true
        refreshReadings()
        if pitchChanged { audition(note) }
    }

    public func resizeNote(at index: Int, toDuration duration: Double) {
        guard notes.indices.contains(index), !isTaking else { return }
        willEdit("resize \(index)")
        defer { didEdit() }
        notes[index].duration = max(0.125, min(totalBeats - notes[index].start, Self.snap(duration)))
        isHandEdited = true
        refreshReadings()
    }

    public func deleteNote(at index: Int) {
        guard notes.indices.contains(index), !isTaking else { return }
        willEdit("delete")
        defer { didEdit() }
        notes.remove(at: index)
        isHandEdited = true
        // The rest of the selection stays selected, a place further up the list past the gap.
        selectedNotes = Set(selectedNotes.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
        refreshReadings()
    }

    // MARK: Played in from the controller

    /// Whether the controller is recording into the roll now. Each note is drawn as it is played
    /// and grows while its key is held; the take is one step of ⌘Z, and is kept once it ends.
    public private(set) var isTaking = false
    /// The keys down in the take, by pitch: the index of the note each one began.
    private var takeHeld: [Int: Int] = [:]
    /// Beats from the section's first bar the take may write to: the section, when it is played
    /// over one, and never past the longest line.
    private var takeLimit: Double = 0
    /// Whether the take writes over what is on the roll rather than into it. See `takeReplaces`.
    private var takeClears = false
    private var takeLanded = 0

    /// Whether a take played now writes over the line rather than into it. The writer's draft and a
    /// first tune carried up from the bass line are proposals nobody has touched, and what is
    /// played is the line; a line that is the person's — kept, drawn, played in before — is played
    /// into, as a take overdubs.
    public var takeReplaces: Bool {
        guard !isTouched else { return false }
        if mode == .bass { return !isHandEdited }
        return notes == (carriedInto[.melody] ?? [])
    }

    /// The take begins. Nothing changes until a note lands.
    public func beginTake(bars: Int?) {
        guard !isTaking else { return }
        // An edit waiting to keep itself is kept on its own, and nothing keeps half a take.
        if isTouched, hasUnkeptChanges { _ = keepNow() }
        autoKeep.cancel()
        takeClears = takeReplaces
        takeLimit = Double(min(Self.longestLine, bars ?? Self.longestLine) * beatsPerBar)
        takeHeld = [:]
        takeLanded = 0
        selectedNotes = []
        isTaking = true
    }

    /// A key put down `beat` beats from the section's first bar, at the pitch and velocity played:
    /// not quantised — Tighten is the press that does that, where it can be heard and undone. A
    /// note a little early off the first downbeat is on it. The line grows by whole bars to hold a
    /// note past its end.
    public func takeNoteOn(pitch: Int, velocity: Int, beat: Double) {
        guard isTaking, beat > -0.25 else { return }
        let start = max(0, beat)
        guard start < takeLimit else { return }
        if takeLanded == 0 {
            // The take is one step of ⌘Z, taken back to the line as it stood before its first note.
            lastEdit = nil
            willEdit("take")
            lastEdit = nil
            if takeClears { notes = [] }
        }
        if let open = takeHeld[pitch] { hold(open, until: start) }
        grow(toHold: start + 1.0 / 16)
        let note = NoteEvent(pitch: Pitch(midi: max(0, min(127, pitch))), start: start,
                             duration: min(0.25, totalBeats - start), velocity: max(1, min(127, velocity)))
        notes.append(note)
        takeHeld[pitch] = notes.count - 1
        takeLanded += 1
        isHandEdited = true
    }

    /// The key let go: the note is as long as it was held.
    public func takeNoteOff(pitch: Int, beat: Double) {
        guard isTaking, let index = takeHeld.removeValue(forKey: pitch) else { return }
        hold(index, until: beat)
    }

    /// The take is over: a key still down is let go at `beat`, the notes go into the order they
    /// sound, and the line is read and kept like any edit.
    public func endTake(at beat: Double?) {
        guard isTaking else { return }
        for index in takeHeld.values {
            hold(index, until: beat ?? notes[index].end)
        }
        takeHeld = [:]
        isTaking = false
        guard takeLanded > 0 else { return }
        notes.sort { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
        lastEdit = nil
        refreshReadings()
        didEdit()
    }

    /// A note of the take held to `beat`: at least a sixty-fourth, and no further than the take
    /// may write. The line grows to hold it.
    private func hold(_ index: Int, until beat: Double) {
        guard notes.indices.contains(index) else { return }
        let end = min(takeLimit, max(beat, notes[index].start + 1.0 / 16))
        grow(toHold: end)
        notes[index].duration = max(1.0 / 16, min(end, totalBeats) - notes[index].start)
    }

    /// Lengthens the line by whole bars until it reaches `beat`, up to the longest line.
    private func grow(toHold beat: Double) {
        let needed = Int((beat / Double(beatsPerBar)).rounded(.up))
        if needed > lengthInBars { lengthInBars = min(Self.longestLine, needed) }
    }

    // MARK: Looking closer

    /// The levels the lane is looked at closer: this many bars across its width. From the whole
    /// line, ⌘= steps down them and ⌘− back up. A level no narrower than the line is the whole line.
    public static let zoomLevels = [8, 4, 2, 1]

    /// How many bars the lane shows across its width, or nil for the whole line.
    public var barsAcross: Int? { zoomBars.flatMap { $0 < lengthInBars ? $0 : nil } }

    /// The same in beats, as the lane lays itself out.
    public var beatsAcross: Double? { barsAcross.map { Double($0 * beatsPerBar) } }

    /// The levels narrower than the line: the ones that show less of it than the whole.
    private var zoomLevelsForLine: [Int] { Self.zoomLevels.filter { $0 < lengthInBars } }

    public var canZoomIn: Bool { zoomLevelsForLine.contains { $0 < (barsAcross ?? Int.max) } }
    public var canZoomOut: Bool { barsAcross != nil }

    /// One level closer: fewer bars across, every beat wider. Nothing closer than one bar.
    public func zoomIn() {
        guard let next = zoomLevelsForLine.first(where: { $0 < (barsAcross ?? Int.max) }) else { return }
        zoomBars = next
    }

    /// One level wider, up to the whole line.
    public func zoomOut() {
        guard let current = barsAcross else { return }
        zoomBars = zoomLevelsForLine.last(where: { $0 > current })
    }

    /// The whole line across, as the lane opens.
    public func zoomToFit() { zoomBars = nil }

    // MARK: Selection

    /// The selected note when there is exactly one: what the caption names. Nil with none, and
    /// nil with several.
    public var selectedNote: Int? { selectedNotes.count == 1 ? selectedNotes.first : nil }

    /// The selected notes themselves, in the order they sound.
    public var selection: [NoteEvent] {
        selectedNotes.sorted().compactMap { notes.indices.contains($0) ? notes[$0] : nil }
            .sorted { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
    }

    /// The beats the selection covers, from the earliest start to the latest end. Nil with nothing
    /// selected. A zoom keeps the middle of it in view.
    public var selectionSpan: ClosedRange<Double>? {
        let picked = selection
        guard let first = picked.map(\.start).min(), let last = picked.map(\.end).max() else { return nil }
        return first...max(first, last)
    }

    /// A click on a note: that note, alone. An index the list does not have clears the selection
    /// rather than pointing at nothing.
    public func select(_ index: Int?) {
        selectedNotes = index.flatMap { notes.indices.contains($0) ? [$0] : nil } ?? []
    }

    /// A shift-click: the note joins the selection, or leaves it if it was in.
    public func toggle(_ index: Int) {
        guard notes.indices.contains(index) else { return }
        if selectedNotes.contains(index) { selectedNotes.remove(index) } else { selectedNotes.insert(index) }
    }

    /// The marquee: every note that sounds within `beats` — any part of it, so a note that starts
    /// before the box and rings into it is covered — on a pitch within `pitches`. Called on every
    /// frame of the drag, so the box can shrink; `base` is what was selected when it began, which
    /// shift keeps and a plain drag does not.
    public func select(beats: ClosedRange<Double>, pitches: ClosedRange<Int>, over base: Set<Int> = []) {
        let covered = notes.indices.filter { index in
            let note = notes[index]
            return note.start < beats.upperBound && note.end > beats.lowerBound && pitches.contains(note.pitch.midi)
        }
        selectedNotes = Set(covered).union(base.filter { notes.indices.contains($0) })
    }

    /// Every note: the Edit menu's Select All.
    public func selectAll() { selectedNotes = Set(notes.indices) }

    public func clearSelection() { selectedNotes = [] }

    /// Whether Delete has anything to remove: a selection, and no take coming in.
    public var canDelete: Bool { !isTaking && selectedNotes.contains { notes.indices.contains($0) } }

    /// The Delete key: the selection goes, one step of ⌘Z however many it was. Nothing selected,
    /// nothing removed.
    public func deleteSelection() {
        let going = selectedNotes.filter { notes.indices.contains($0) }
        guard !going.isEmpty, !isTaking else { return }
        willEdit("delete")
        defer { didEdit() }
        notes = notes.indices.filter { !going.contains($0) }.map { notes[$0] }
        isHandEdited = true
        selectedNotes = []
        refreshReadings()
    }

    /// The same, by the name the key had when it removed one note.
    public func deleteSelectedNote() { deleteSelection() }

    // MARK: Moving the selection

    /// Where the selection stood when a drag of it began, and the line as it was, for ⌘Z. Each
    /// frame of the drag is the whole translation from there and not a step from the last frame,
    /// so a drag that comes back lands where it started; and the step of ⌘Z is recorded on the
    /// first frame that moves something, so a drag that moves nothing leaves nothing to undo.
    private var moveOrigin: (notes: [NoteEvent], state: RollState, recorded: Bool, semitones: Int)?

    /// A drag of the selection begins. `moveSelection` begins one on its own when none has.
    public func beginMove() {
        guard !isTaking else { return }
        moveOrigin = (notes, state, false, 0)
    }

    /// The selection moved as one: every selected note `beats` later and `semitones` up from where
    /// it stood when the drag began. The beats are snapped to the sixteenth, as a note dragged alone
    /// is, and the same for all of them — so the lag a line carries, and the rhythm the notes make
    /// between them, keep. Held inside the line and the keyboard as a group: the set stops at the
    /// last sixteenth that keeps its earliest note at or after the start and its latest at or before
    /// the end — a line behind the kick stays behind it at the start of the line too — and at the
    /// lowest and highest pitches likewise.
    public func moveSelection(by beats: Double, semitones: Int) {
        guard !isTaking else { return }
        if moveOrigin == nil { beginMove() }
        guard var origin = moveOrigin else { return }
        let picked = selectedNotes.filter { origin.notes.indices.contains($0) && notes.indices.contains($0) }.sorted()
        guard let firstStart = picked.map({ origin.notes[$0].start }).min(),
              let lastEnd = picked.map({ origin.notes[$0].end }).max(),
              let lowest = picked.map({ origin.notes[$0].pitch.midi }).min(),
              let highest = picked.map({ origin.notes[$0].pitch.midi }).max() else { return }
        let grid = 0.25
        var shift = Self.snap(beats, to: grid)
        let earliest = -firstStart, latest = max(0, totalBeats - lastEnd)
        if shift < earliest { shift = (earliest / grid).rounded(.up) * grid }
        if shift > latest { shift = (latest / grid).rounded(.down) * grid }
        let rise = min(127 - highest, max(-lowest, semitones))
        var moved = notes
        for index in picked {
            var note = origin.notes[index]
            note.start += shift
            note.pitch = Pitch(midi: note.pitch.midi + rise)
            moved[index] = note
        }
        guard moved != notes else { return }
        if !origin.recorded {
            history.record(origin.state)
            lastEdit = nil
            origin.recorded = true
        }
        notes = moved
        isHandEdited = true
        refreshReadings()
        // Heard as the pitch changes, on the earliest of them: the note itself, dragged alone.
        if rise != origin.semitones, let first = picked.first { audition(moved[first]) }
        origin.semitones = rise
        moveOrigin = origin
    }

    /// The drag ends: the line keeps itself, if anything moved.
    public func endMove() {
        guard let origin = moveOrigin else { return }
        moveOrigin = nil
        if origin.recorded { didEdit() }
    }

    // MARK: Duplicating, and the pasteboard

    /// How far past a beat a note may ring and still count as ending on it: a thirty-second. A line
    /// behind the kick ends its last note a hair over the bar, and a duplicate of it that waited
    /// for the next whole beat would leave a beat's gap in every copy.
    nonisolated static let ringOver = 0.125

    /// How far on the copies ⌘D lays go: a whole number of beats, the fewest that put the first copy
    /// after the last selected note's end. Whole beats, so each copy keeps its place in its beat and
    /// a line behind the kick stays behind it. Nil with nothing selected.
    private var duplicateOffset: Double? {
        guard let span = selectionSpan else { return nil }
        return max(1, (span.upperBound - span.lowerBound - Self.ringOver).rounded(.up))
    }

    /// Whether ⌘D has room: something is selected, and its copies would start inside the longest line.
    public var canDuplicate: Bool {
        guard !isTaking, let span = selectionSpan, let offset = duplicateOffset else { return false }
        return span.lowerBound + offset < Double(Self.longestLine * beatsPerBar) - 1e-9
    }

    /// ⌘D: the selection again, right after itself, and the copies are the selection — so ⌘D again
    /// lays a third. The line grows by whole bars to hold them, up to the longest line; a copy past
    /// that is not made, and one that rings over it is cut there.
    public func duplicateSelection() {
        guard canDuplicate, let offset = duplicateOffset else { return }
        let copies = selection.map { note in
            NoteEvent(pitch: note.pitch, start: note.start + offset, duration: note.duration, velocity: note.velocity)
        }
        lay(copies, as: "duplicate-\(notes.count)")
    }

    /// The selection as a clip for the pasteboard: the notes in beats from the beat the first of
    /// them sits in, so the lag a line carries is kept through a paste. Nil with nothing selected.
    public var clipOfSelection: NoteClip? {
        let picked = selection
        guard !picked.isEmpty else { return nil }
        return NoteClip(lifting: picked, beatsPerBar: beatsPerBar)
    }

    /// A click on empty space, at `beat`: where the next paste lands.
    public func placeCaret(at beat: Double) {
        caret = max(0, min(totalBeats, beat))
    }

    /// Where a paste lands: the beat the lane was last clicked on, else right after the line's last
    /// note, on the beat, as a duplicate lands. The first beat of an empty line.
    public var pasteLanding: Double {
        if let caret { return max(0, Self.snap(caret, to: 1)) }
        guard let last = notes.map(\.end).max() else { return 0 }
        return max(0, (last - Self.ringOver).rounded(.up))
    }

    /// Whether a paste would land inside the longest line.
    public var canPaste: Bool { !isTaking && pasteLanding < Double(Self.longestLine * beatsPerBar) - 1e-9 }

    /// ⌘V: the clip laid with its first beat on `pasteLanding`, the pasted notes the selection, and
    /// the caret moved past them, so ⌘V again lays the clip after the first paste as ⌘D would.
    /// Cut to the longest line as a duplicate is, and the line grown to hold it.
    public func paste(_ clip: NoteClip) {
        guard canPaste, !clip.notes.isEmpty else { return }
        let landing = pasteLanding
        let placed = clip.notes.map { note in
            NoteEvent(pitch: note.pitch, start: note.start + landing, duration: note.duration, velocity: note.velocity)
        }
        let count = notes.count
        lay(placed, as: "paste-\(count)")
        if notes.count != count { caret = landing + clip.lengthInBeats }
    }

    /// `added` laid into the line as one edit: cut to the longest line, the line grown by whole
    /// bars to hold them, and the selection moved onto them. Nothing lands, nothing changes.
    private func lay(_ added: [NoteEvent], as kind: String) {
        let limit = Double(Self.longestLine * beatsPerBar)
        let fitted = added.compactMap { note -> NoteEvent? in
            guard note.start < limit - 1e-9 else { return nil }
            return NoteEvent(pitch: note.pitch, start: note.start,
                             duration: max(0.125, min(note.duration, limit - note.start)), velocity: note.velocity)
        }
        guard !fitted.isEmpty, !isTaking else { return }
        willEdit(kind)
        defer { didEdit() }
        grow(toHold: (fitted.map(\.end).max() ?? 0) - Self.ringOver)
        selectedNotes = place(fitted)
        isHandEdited = true
        refreshReadings()
    }

    /// Sixteenths, with the lag kept: snapping moves the grid part of a start and leaves the
    /// fractional lag the writer put on it alone when the note already carries one.
    static func snap(_ beat: Double, to grid: Double = 0.25) -> Double {
        (beat / grid).rounded() * grid
    }

    // MARK: Playing

    public func audition(_ note: NoteEvent) {
        let seconds = note.duration * 60 / max(1, tempo)
        let sound = self.sound, instrument = self.instrument, mode = self.mode
        Task { [host] in
            if mode == .melody {
                await host.auditionMelody(note: note.pitch.midi, velocity: note.velocity, duration: seconds, instrument: instrument)
            } else {
                await host.audition(note: note.pitch.midi, velocity: note.velocity, duration: seconds, sound: sound)
            }
        }
    }

    public func stop() {
        Task { [host] in await host.stop() }
    }

    // MARK: Readings

    private func refreshReadings() {
        guard mode == .bass else {
            var melodyObservation = MelodyObservation(label: title, key: key, beatsPerBar: beatsPerBar,
                                                      notes: notes, chords: chords.enumerated().map { index, span in
                                                          (span.chord, chords.prefix(index).reduce(0) { $0 + $1.beats })
                                                      }, chordsLength: chords.isEmpty ? nil : chords.reduce(0) { $0 + $1.beats })
            guard notes.count >= 2 else { readings = []; return }
            melodyObservation.alternatives = MelodyObservation.alternatives(to: Melody(notes: notes), key: key,
                                                                            beatsPerBar: beatsPerBar, chords: chords)
            melodyObservation.before = before()
            let judged = GenreLens.judge(Melodist().read(melodyObservation), by: Melodist.bible, in: genre())
            readings = house()?.settle(judged, by: Melodist.bible) ?? judged
            return
        }
        guard let observation else { readings = []; return }
        readings = GenreLens.judge(bassist.read(observation), by: Bassist.bible, in: genre())
    }

    /// The readings that did not hold: what the Bassist would say first.
    public var flags: [PersonaReading] { readings.filter { !$0.holds } }

    // MARK: Versions

    /// A new version of the line. Derives from the one it was opened against (or the last one it
    /// made); starts a part otherwise. The note says whose hands, how far behind the kick, and
    /// whether it was written or edited.
    @discardableResult
    public func commit(note: String? = nil) -> PartVersion {
        let payload: PartKind = mode == .melody ? .melody(melody) : .bassline(bassline)
        let text = note ?? defaultNote
        let version: PartVersion
        if let kept = lastKeptOfThisKind {
            let previous = host.newest(of: kept.partID) ?? kept
            version = previous.deriving(payload, by: .user, operation: isHandEdited ? Operation.edit : Operation.written,
                                        note: text)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user,
                                  parents: grooveVersion.map { [$0] } ?? [],
                                  operation: Operation.written, note: text)
        }
        autoKeep.cancel()
        // Synchronous, so a keep the frame asks for before it plays is in the song when it reads.
        guard host.commit(version) else {
            lastError = "The song would not take that line."
            return version
        }
        versions.append(version)
        lastKept = version
        lastError = nil
        if version.type == .melody, let picked = instrumentForTheTune {
            instrumentForTheTune = nil
            host.setInstrument(picked, for: version.partID)
        }
        if version.type == .melody, marksTuneWhenKept {
            marksTuneWhenKept = false
            host.markTune(version.partID)
        }
        return version
    }

    private var defaultNote: String {
        if mode == .melody {
            let name = InstrumentVoiceSpec.preset(id: instrument)?.name ?? instrument
            return "Melody, \(notes.count) note\(notes.count == 1 ? "" : "s") on the \(name), \(lengthInBars) bar\(lengthInBars == 1 ? "" : "s")"
        }
        var parts = [isHandEdited ? "Bass line, edited" : "\(lineage.name) line"]
        if let groove, lengthInBars != groove.bars { parts.append("\(lengthInBars) bars") }
        if lagMS != 0 { parts.append(String(format: "%+.0f ms behind the kick", lagMS)) }
        parts.append(String(format: "%.0f bpm", tempo))
        parts.append(BassVoiceSpec.resolve(id: sound)?.name ?? sound)
        if usesDefaultChords { parts.append("to the key's I–IV–V–I") }
        return parts.joined(separator: ", ")
    }
}

extension PianoRollModel: KeepsAsItGoes {
    @discardableResult
    public func keepNow() -> Bool {
        // Half a take is not a version: the take keeps itself when it ends.
        guard !isTaking else { return true }
        guard hasUnkeptChanges else { autoKeep.cancel(); return true }
        let version = commit()
        return versions.last?.id == version.id
    }

    public var canUndo: Bool { history.canUndo && !isTaking }
    public var canRedo: Bool { history.canRedo && !isTaking }

    public func undo() {
        guard !isTaking, let previous = history.undo(from: state) else { return }
        lastEdit = nil
        state = previous
        didEdit()
    }

    public func redo() {
        guard !isTaking, let next = history.redo(from: state) else { return }
        lastEdit = nil
        state = next
        didEdit()
    }

    public var keepLine: KeepLine {
        if let lastError { return .refused(lastError) }
        if hasUnkeptChanges { return .pending }
        if let kept = lastKeptOfThisKind { return .kept(title: PartLabel.title(of: kept)) }
        return .untouched
    }
}

extension PianoRollModel: TakesFromController {
    public var takeName: String { "the Piano roll" }
    /// The line's own voice: its bass sound, or in melody mode the tune's instrument.
    public var controllerVoice: MIDIControl.Voice { mode == .melody ? .keys(instrument) : .bass(sound) }
    public var takesInTime: Bool { true }

    public func takeNoteOn(_ note: Int, velocity: Int, beat: Double?) {
        guard let beat else { return }
        takeNoteOn(pitch: note, velocity: velocity, beat: beat)
    }

    public func takeNoteOff(_ note: Int, beat: Double?) {
        guard let beat else { return }
        takeNoteOff(pitch: note, beat: beat)
    }
}

extension PianoRollModel: ZoomsItsWork {}

extension PianoRollModel: DuplicatesItsSelection {}

extension PianoRollModel: DeletesItsSelection {}
