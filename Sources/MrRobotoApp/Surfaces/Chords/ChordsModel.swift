import Foundation
import MusicTheory
import SongGraph

/// The Chords surface's entry in the catalog: the lead sheet, surface #5, bound to a progression.
public struct ChordsSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .chords }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Chords") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

/// The Chords surface's model: a line of chord symbols, read as a `Progression` in the song's key.
///
/// You type what a lead sheet says — `Dm7 G7 | Cmaj7` — and the surface shows the bars with their
/// Roman numerals, plays a bar when you touch it, and commits the progression as a version the
/// bass writer reads. Nothing is stored as text: the part is the chords, and the text is one way
/// of saying them.
///
/// The Harmonist reads the bars as they parse and its readings sit under them, the way the
/// Bassist's sit under the Piano roll: the one who owns the chords is on the surface where the
/// chords are written, not only in the rail after they are kept.
@MainActor
@Observable
public final class ChordsModel {

    public let surfaceID: SurfaceID
    public var surface: ChordsSurface {
        ChordsSurface(id: surfaceID, bound: base.map { [$0.id] } ?? [], title: title)
    }

    public var title: String {
        if let base { return PartLabel.title(of: base) }
        return progression.map { "\($0.chords.count) chords in \($0.key)" } ?? "Chords"
    }

    /// What is typed. Parsed on every change; a symbol that cannot be read is named in `problem`.
    public var text: String {
        didSet {
            parse()
            guard !isApplyingState, oldValue != text else { return }
            willEdit(ChordsState(text: oldValue, key: key), kind: "text")
            didEdit()
        }
    }
    public private(set) var key: Key
    public private(set) var progression: Progression?
    public private(set) var problem: String?
    /// What the key field last failed to read, or nil while the key is what was typed. The key
    /// itself stays put on a bad line: a field that half-read "F#m" as F major would be worse than
    /// one that says no.
    public private(set) var keyProblem: String?
    public private(set) var base: PartVersion?
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    /// What the Harmonist says about the bars on screen, refreshed on every parse. Read against the
    /// song's newest bass line when there is one, so a bass that disagrees is named here.
    public private(set) var readings: [PersonaReading] = []
    /// The version the last keep made, for the footer to say so. Nil until one is kept, and set
    /// aside again — by `hasUnkeptChanges` turning true — once the chords move on from it.
    public private(set) var lastKept: PartVersion?

    /// Whether the bars on screen are a progression the song does not have yet: something that
    /// reads, and differs from the last version kept or the one the surface was opened on. A line
    /// with a typo has nothing to keep; a fresh surface's I–IV–V–I does.
    public var hasUnkeptChanges: Bool {
        guard problem == nil, let progression else { return false }
        guard let kept = versions.last ?? base, case .progression(let keptProgression) = kept.kind else { return isTouched }
        return keptProgression != progression
    }

    /// Whether anything has been typed or chosen. The I–IV–V–I an empty sheet shows is a
    /// suggestion, not chords the song has — `useTheseChords()` takes it as it is.
    public private(set) var isTouched = false

    // MARK: Keeping as it goes

    struct ChordsState: Equatable, Sendable {
        var text: String
        var key: Key
    }

    private var history = EditHistory<ChordsState>()
    private var lastEdit: (kind: String, at: Date)?
    private var isApplyingState = false
    /// Keeps the chords a moment after the last edit. A test sets its delay to nil.
    public let autoKeep = AutoKeep()

    private var state: ChordsState {
        get { ChordsState(text: text, key: key) }
        set {
            isApplyingState = true
            key = newValue.key
            text = newValue.text
            isApplyingState = false
            keyProblem = nil
            parse()
        }
    }

    /// Typing is one step of undo per pause, not per key.
    private func willEdit(_ before: ChordsState, kind: String) {
        let now = Date()
        defer { lastEdit = (kind, now) }
        if let last = lastEdit, last.kind == kind, now.timeIntervalSince(last.at) < 1.5 { return }
        history.record(before)
    }

    private func didEdit() {
        isTouched = true
        guard hasUnkeptChanges else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    /// Takes the suggested I–IV–V–I as the song's chords.
    public func useTheseChords() {
        isTouched = true
        keepNow()
    }

    /// True while the line has a typo: the bars still show the last line that read, and the view
    /// says so rather than letting them pass for what is typed.
    public var barsAreStale: Bool { problem != nil }
    /// The instrument these chords are voiced on, by preset id: their part's pick once they are a
    /// part, else the song's.
    public var instrument: String { host.instrument(for: part) }

    public func setInstrument(_ id: String) {
        host.setInstrument(id, for: part)
        if let progression, let first = progression.chords.first { audition(first) }
    }

    /// The part these chords belong to, once they have been kept.
    public var part: PartID? { (versions.last ?? base)?.partID }
    public private(set) var beatsPerBar: Int

    /// The song's meter now. A sheet left open across a meter change kept writing bars of the old
    /// one, across the new bar lines. What is kept is not re-barred; the next edit is in the new.
    public func follow(beatsPerBar value: Int) {
        guard value > 0, value != beatsPerBar else { return }
        beatsPerBar = value
    }

    private let host: any ChordsHosting

    public init(host: any ChordsHosting, key: Key, beatsPerBar: Int = 4, progression: PartVersion? = nil,
                surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.key = key
        self.beatsPerBar = beatsPerBar
        if let progression, case .progression(let stored) = progression.kind {
            base = progression
            self.key = stored.key
            text = stored.symbols()
            opened = (text, stored)
        } else {
            text = ""
        }
        parse()
    }

    /// The chords the surface opened on, and the line they were written out as. The line reads
    /// back as bars split evenly, so chords that split a bar unevenly — three beats and one, as a
    /// MIDI import writes them — would be rewritten just by opening them. While the line is the one
    /// they were written as, it means them exactly.
    private var opened: (text: String, progression: Progression)?

    /// Reads `text` as the key's I–IV–V–I when it is empty, so an open surface is never blank.
    private func parse() {
        defer { refreshReadings() }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            progression = Progression(key: key, bars: Self.defaultBars(in: key, beatsPerBar: beatsPerBar))
            problem = nil
            return
        }
        if let opened, trimmed == opened.text.trimmingCharacters(in: .whitespaces), key == opened.progression.key {
            progression = opened.progression
            problem = nil
            return
        }
        switch Progression.parse(trimmed, key: key, beatsPerBar: beatsPerBar) {
        case .success(let parsed):
            progression = parsed
            problem = nil
        case .failure(let error):
            problem = error.description
        }
    }

    // MARK: The Harmonist

    /// The song's genre, asked each time the readings are made: a reading is re-judged in it
    /// (`GenreLens`). Nil — the default, and a song nobody has placed — leaves the persona's own.
    public var genre: @MainActor () -> GenreLens? = { nil }

    /// Reads again, for a genre that changed under an open sheet.
    public func genreChanged() { refreshReadings() }

    /// The genre's own progressions, in this sheet's key: the ones written for a key of its kind,
    /// major or minor, each as the line it would type. What the sheet offers under the field.
    public var genreProgressions: [(genre: String, roman: String, text: String, about: String)] {
        guard let profile = genre()?.profile else { return [] }
        return profile.progressions.compactMap { progression in
            guard GenreNumerals.fits(mode: progression.mode, key),
                  let line = GenreNumerals.symbols(progression.roman, in: key, mode: progression.mode) else { return nil }
            return (profile.name, progression.roman, line, progression.text)
        }
    }

    /// Types a genre progression into the field, as one edit.
    public func use(progression line: String) { text = line }

    /// The Harmonist's reading of the bars on screen. On a typo those are the last bars that read,
    /// and so are the readings; the view dims both together.
    private func refreshReadings() {
        guard let progression else { readings = []; return }
        let observation = HarmonyObservation.of(progression, label: title, bassline: host.bassline,
                                                beatsPerBar: beatsPerBar)
        readings = GenreLens.judge(Harmonist().read(observation), by: Harmonist.bible, in: genre())
    }

    /// The readings that did not hold: what the Harmonist would say first.
    public var flags: [PersonaReading] { readings.filter { !$0.holds } }

    /// Flags first, then what holds — the order the panel shows them in.
    public var orderedReadings: [PersonaReading] { flags + readings.filter(\.holds) }

    /// I–IV–V–I in the key, a bar each: what the bass writer uses when nothing is stated.
    static func defaultBars(in key: Key, beatsPerBar: Int) -> [ProgressionBar] {
        [1, 4, 5, 1].compactMap { degree in
            key.scale.diatonicChord(degree: degree, root: key.tonic.pitchClass, size: 4)
                .map { ProgressionBar($0, beats: Double(beatsPerBar)) }
        }
    }

    public var isDefault: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    public func setKey(_ newKey: Key) {
        guard newKey != key else { keyProblem = nil; return }
        willEdit(state, kind: "key")
        key = newKey
        keyProblem = nil
        parse()
        didEdit()
    }

    /// The key as a line you type: "D major", "F# minor", "Bb", "E dorian" — whatever `Key` reads.
    /// A line it does not read leaves the key alone and says so in `keyProblem`; true when the
    /// key changed to what was typed.
    @discardableResult
    public func setKey(parsing text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Key(parsing: trimmed) else {
            keyProblem = trimmed.isEmpty
                ? "Type a key, like D major or F# minor."
                : "Not a key I know — try D major, F# minor or E dorian."
            return false
        }
        setKey(parsed)
        return true
    }

    /// The Roman numeral of a chord in the key, or its symbol when it is not diatonic.
    public func numeral(of chord: Chord) -> String {
        key.romanNumeral(for: chord).map { "\($0)" } ?? chord.symbol(preferring: key.signature.preference)
    }

    // MARK: Playing

    /// Sounds a bar's first chord as a bass voicing — root, third, seventh — an octave above the
    /// bass register, for one beat.
    public func audition(_ chord: Chord) {
        let root = 48 + chord.root.rawValue
        let pitches = chord.pitches(root: Pitch(midi: root)).map(\.midi)
        let part = self.part
        Task { [host] in await host.audition(pitches: pitches, duration: 0.9, for: part) }
    }

    // MARK: Versions

    @discardableResult
    public func commit(note: String? = nil) -> PartVersion? {
        guard let progression, problem == nil else { return nil }
        let payload = PartKind.progression(progression)
        let text = note ?? "\(progression.symbols()) in \(progression.key)"
        let version: PartVersion
        if let kept = versions.last ?? base {
            let previous = host.newest(of: kept.partID) ?? kept
            version = previous.deriving(payload, by: .user, operation: Operation.edit, note: text)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user, operation: Operation.written, note: text)
        }
        autoKeep.cancel()
        // Synchronous, so a keep the frame asks for before it plays is in the song when it reads.
        guard host.commit(version) else {
            lastError = "The song would not take these chords."
            return nil
        }
        versions.append(version)
        lastKept = version
        lastError = nil
        return version
    }
}

extension ChordsModel: KeepsAsItGoes {
    @discardableResult
    public func keepNow() -> Bool {
        guard hasUnkeptChanges else { autoKeep.cancel(); return true }
        return commit() != nil
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
        if problem != nil { return .refused("Not kept while a chord does not read.") }
        if hasUnkeptChanges { return .pending }
        if let kept = versions.last ?? base { return .kept(title: PartLabel.title(of: kept)) }
        return .untouched
    }
}
