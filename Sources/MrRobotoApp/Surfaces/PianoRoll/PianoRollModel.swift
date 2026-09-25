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
/// right edge to lengthen, double-click to delete, click an empty cell to add. An edit refreshes
/// the readings and keeps itself a moment later.
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
    /// Whether the line on screen was written by the writer with the current levers, or has been
    /// touched by hand since. Re-running the writer over a hand edit is a real loss, so the levers
    /// say so before they do it.
    public private(set) var isHandEdited = false

    /// Whether the levers are held off the notes. A line edited by hand is the user's, and a lever
    /// re-running the writer over it would drop every edit in one silent stroke — so while the line
    /// is hand-edited a lever only moves itself. `writeOverHandEdits()` is the explicit step that
    /// lets the writer replace the line; nothing else does.
    public var leversAreHeld: Bool { writesFromLevers && isHandEdited && groove != nil }

    /// The note a click picked out, as an index into `notes`. Delete removes it, Escape clears it.
    /// Dropped whenever the list is replaced or re-ordered, because an index into a different list
    /// is a different note.
    public private(set) var selectedNote: Int?

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
        guard let kept = lastKeptOfThisKind else { return isTouched && !notes.isEmpty }
        switch kept.kind {
        case .bassline(let line):
            if line.notes != notes { return true }
            if let keptSound = line.sound, keptSound != sound { return true }
            return (line.lengthInBars ?? openedLength) != lengthInBars
        case .melody(let tune):
            return tune.notes != notes || (tune.lengthInBars ?? openedLength) != lengthInBars
        default:
            return true
        }
    }

    /// The newest version this roll kept or was opened on that is the same kind of part as the
    /// mode says it is writing. A roll opened on a bass line and switched to melody is writing a
    /// new part, not a new version of the bass line — a part does not change what it is.
    private var lastKeptOfThisKind: PartVersion? {
        let type: PartType = mode == .melody ? .melody : .bassline
        return versions.last { $0.type == type } ?? (base?.type == type ? base : nil)
    }

    /// The length the roll gave a bound line that did not state one. That line is "as long as its
    /// notes", and opening it is not an edit: only a length the person sets differs from it.
    private var openedLength: Int = 1

    /// Whether the person has done anything to the line. The line the writer drafts when the roll
    /// opens under a groove is a proposal until then — played, not kept — so opening the Piano
    /// roll to look is not writing a part into the song. `useThisLine()` accepts it untouched.
    public private(set) var isTouched = false

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
                      earlyAlternation: earlyAlternation, seed: seed, isHandEdited: isHandEdited)
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
            isHandEdited = newValue.isHandEdited
            selectedNote = nil
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
        isTouched = true
        guard hasUnkeptChanges else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    /// Accepts the line the writer drafted, untouched, as a part of the song.
    public func useThisLine() {
        isTouched = true
        keepNow()
    }

    /// The pitch range the roll draws: the lineage's register, widened to hold the notes.
    /// Whether the writer's levers apply. A tune is drawn by hand: nothing in the app writes one,
    /// and a lever that silently did would be the Bassist writing melodies.
    public var writesFromLevers: Bool { mode == .bass }

    public var melody: Melody { Melody(notes: notes, lengthInBars: lengthInBars) }

    /// Who reads what this roll is writing.
    public var readingPersona: String { mode == .bass ? "Bassist" : "Melodist" }

    public func setMode(_ value: Mode) {
        guard value != mode else { return }
        willEdit("mode")
        mode = value
        defer { didEdit() }
        // A bass line dragged into melody mode keeps its notes; they just sound an octave up on a
        // different instrument, which is usually what you wanted when you switched.
        refreshReadings()
    }

    public func setInstrument(_ id: String) {
        guard InstrumentVoiceSpec.preset(id: id) != nil else { return }
        instrument = id
        // For *this* part, so a tune can be a lead over chords on a pad. A roll opened on nothing
        // has no part to name yet and sets the song's, which is what it always did.
        host.setInstrument(id, for: part)
        if let first = notes.first { audition(first) }
    }

    /// The part this roll is working on, once it has one.
    public var part: PartID? { (versions.last ?? base)?.partID }

    public var register: ClosedRange<Int> {
        var low = lineage.register.lowerBound, high = lineage.register.upperBound
        for note in notes { low = min(low, note.pitch.midi); high = max(high, note.pitch.midi) }
        return low...high
    }

    private let host: any PianoRollHosting
    private let bassist = Bassist()

    // MARK: Init

    public init(host: any PianoRollHosting,
                groove: Groove?, grooveVersion: VersionID? = nil,
                grooveOptions: GrooveRenderOptions = GrooveRenderOptions(),
                chords: [ChordSpan] = [], key: Key,
                tempo: Double, timeSignature: TimeSignature = .fourFour,
                kickDecaySeconds: Double = 0,
                bassline: PartVersion? = nil,
                melody: PartVersion? = nil,
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
        if let bassline, case .bassline(let line) = bassline.kind {
            base = bassline
            notes = line.notes
            sound = line.sound ?? lineage.defaultSound
            lengthInBars = Self.openingLength(stated: line.lengthInBars, notes: line.notes, groove: groove,
                                              beatsPerBar: beatsPerBar)
            openedLength = lengthInBars
            isHandEdited = true
            refreshReadings()
        } else if let melody, case .melody(let tune) = melody.kind {
            // Opened on a tune: melody mode, its notes, its instrument, and every commit derives
            // from it. The writer never runs — nothing in the band writes a melody.
            base = melody
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

    /// A bound line's length: the one it states, else the larger of the groove's bars and the
    /// bars its notes reach — so a line from before lengths were kept opens no shorter than the
    /// groove it sits under, and never cuts a note off.
    static func openingLength(stated: Int?, notes: [NoteEvent], groove: Groove?, beatsPerBar: Int) -> Int {
        if let stated { return max(1, stated) }
        let reach = Int(((notes.map(\.end).max() ?? 0) / Double(max(1, beatsPerBar))).rounded(.up))
        return max(1, groove?.bars ?? 1, reach)
    }

    // MARK: Reading

    public var bassline: Bassline { Bassline(notes: notes, sound: sound, key: key, lengthInBars: lengthInBars) }

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

    // MARK: The writer

    private var request: BassRequest? {
        guard let groove else { return nil }
        return BassRequest(key: key, chords: chords, groove: groove, tempo: tempo, timeSignature: timeSignature,
                           lineage: lineage, lagMS: lagMS, density: density, earlyAlternation: earlyAlternation,
                           sound: sound, seed: seed, bars: lengthInBars)
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
        selectedNote = nil
        refreshReadings()
    }

    /// The explicit step: the writer replaces a hand-edited line with one from the levers as they
    /// stand now. Pressed, not slid into.
    public func writeOverHandEdits() {
        willEdit("rewrite-over")
        write()
        didEdit()
    }

    /// A lever moved. Runs the writer unless the line is edited by hand, in which case the lever
    /// has moved and the notes have not — the readings refresh because the sound may have.
    private func writeUnlessHeld() {
        guard !leversAreHeld else { refreshReadings(); return }
        write()
    }

    /// A different line from the same levers.
    public func rewrite() {
        willEdit("rewrite")
        seed &+= 0x9E37_79B9
        writeUnlessHeld()
        didEdit()
    }

    public func setLineage(_ value: BassLineage) {
        willEdit("lineage")
        lineage = value
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

    /// The bass sound. Does not rewrite: the same notes through another voice.
    public func setSound(_ id: String) {
        guard BassVoiceSpec.all.contains(where: { $0.id == id }), id != sound else { return }
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
        guard target != lengthInBars else { return }
        willEdit("length")
        defer { didEdit() }
        lengthInBars = target
        if writesFromLevers, !isHandEdited, groove != nil {
            write()
            return
        }
        trimToLength()
        selectedNote = nil
        refreshReadings()
    }

    /// Whether Double has room: the line twice over is no longer than the roll will make.
    public var canDouble: Bool { lengthInBars * 2 <= Self.longestLine }

    /// The line twice: every note copied into the bars after it, and the length doubled. The usual
    /// way a one-bar idea becomes a phrase — the copy is there to be changed, and changing it is
    /// the point, so the line is the person's from here and the levers hold off it.
    public func double() {
        guard canDouble else { return }
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
        selectedNote = nil
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
        guard canTighten else { return }
        willEdit("tighten")
        defer { didEdit() }
        notes = tightened
        isHandEdited = true
        selectedNote = nil
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
        willEdit("add")
        defer { didEdit() }
        let start = max(0, min(totalBeats - 0.125, Self.snap(beat)))
        let note = NoteEvent(pitch: Pitch(midi: pitch), start: start, duration: max(0.125, duration), velocity: 100)
        notes.append(note)
        notes.sort { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
        isHandEdited = true
        // The new note is the selection, so a stray click is one Delete from undone.
        selectedNote = notes.firstIndex(of: note)
        refreshReadings()
        audition(note)
    }

    public func moveNote(at index: Int, toStart start: Double, pitch: Int) {
        guard notes.indices.contains(index) else { return }
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
        guard notes.indices.contains(index) else { return }
        willEdit("resize \(index)")
        defer { didEdit() }
        notes[index].duration = max(0.125, min(totalBeats - notes[index].start, Self.snap(duration)))
        isHandEdited = true
        refreshReadings()
    }

    public func deleteNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        willEdit("delete")
        defer { didEdit() }
        notes.remove(at: index)
        isHandEdited = true
        selectedNote = nil
        refreshReadings()
    }

    // MARK: Selection

    /// A click on a note. An index the list does not have clears the selection rather than
    /// pointing at nothing.
    public func select(_ index: Int?) {
        selectedNote = index.flatMap { notes.indices.contains($0) ? $0 : nil }
    }

    public func clearSelection() { selectedNote = nil }

    /// The Delete key. Nothing selected, nothing removed.
    public func deleteSelectedNote() {
        guard let selectedNote else { return }
        deleteNote(at: selectedNote)
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

    public func playLine() {
        let line = bassline, tempo = self.tempo, signature = timeSignature
        let notes = self.notes, instrument = self.instrument, mode = self.mode
        Task { [host] in
            if mode == .melody {
                await host.playMelody(notes, tempo: tempo, timeSignature: signature, instrument: instrument)
            } else {
                await host.play(line, tempo: tempo, timeSignature: signature)
            }
        }
    }

    public func stop() {
        Task { [host] in await host.stop() }
    }

    // MARK: Readings

    private func refreshReadings() {
        guard mode == .bass else {
            let melodyObservation = MelodyObservation(label: title, key: key, beatsPerBar: beatsPerBar,
                                                      notes: notes, chords: chords.enumerated().map { index, span in
                                                          (span.chord, chords.prefix(index).reduce(0) { $0 + $1.beats })
                                                      })
            readings = notes.count >= 2 ? Melodist().read(melodyObservation) : []
            return
        }
        guard let observation else { readings = []; return }
        readings = bassist.read(observation)
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
        if let previous = lastKeptOfThisKind {
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
        parts.append(BassVoiceSpec.all.first { $0.id == sound }?.name ?? sound)
        if usesDefaultChords { parts.append("to the key's I–IV–V–I") }
        return parts.joined(separator: ", ")
    }
}

extension PianoRollModel: KeepsAsItGoes {
    @discardableResult
    public func keepNow() -> Bool {
        guard hasUnkeptChanges else { autoKeep.cancel(); return true }
        let version = commit()
        return versions.last?.id == version.id
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let previous = history.undo(from: state) else { return }
        lastEdit = nil
        state = previous
        didEdit()
    }

    public func redo() {
        guard let next = history.redo(from: state) else { return }
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
