import Foundation
import Instrument
import MusicTheory
import Performance
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
            willEdit(ChordsState(text: oldValue, key: key, playing: playing, lifts: lifts), kind: "text")
            didEdit()
        }
    }

    /// How the chords are played: how they are voiced, and the rhythm they are struck in. Held
    /// and close until somebody says otherwise, which is how every progression used to play.
    public private(set) var playing = ChordPlaying()

    public var pattern: KeysPattern { playing.keysPattern }
    public var voicing: KeysVoicing { playing.keysVoicing }

    /// The rhythm the chords are struck in. Heard at once, as the song will play it.
    public func setPattern(_ pattern: KeysPattern) {
        guard pattern != self.pattern else { return }
        willEdit(state, kind: "pattern")
        playing.pattern = pattern.rawValue
        // A hand of its own the first time it has a rhythm to play.
        if pattern != .held, playing.seed == 0 { playing.seed = GrooveFeel.freshSeed() }
        parse()
        didEdit()
        hear()
    }

    /// Where the notes of each chord sit.
    public func setVoicing(_ voicing: KeysVoicing) {
        guard voicing != self.voicing else { return }
        willEdit(state, kind: "voicing")
        playing.voicing = voicing.rawValue
        parse()
        didEdit()
        hear()
    }

    // MARK: Sounds, saved

    /// Where sounds are kept between songs. A test hands it a suite of its own.
    public var shelf = ChordSoundShelf()
    /// Bumped when the shelf changes, so a view listing it reads it again.
    public private(set) var shelfChanges = 0

    /// The sounds to choose from: the starters, then the saved.
    public var sounds: [ChordSound] { _ = shelfChanges; return shelf.sounds }

    /// The sheet's sound as it stands, by `name`: its instrument, the way it is played, its strip.
    public func currentSound(named name: String) -> ChordSound {
        ChordSound(name: name, instrument: instrument, playing: playing, strip: host.stripSound(for: part))
    }

    /// The kept sound the sheet is playing now, when it is one: the instrument, the playing and the
    /// strip all as that sound has them.
    public var soundInUse: ChordSound? {
        let now = currentSound(named: "")
        return sounds.first { $0.instrument == now.instrument && $0.playing == now.playing && $0.strip == now.strip }
    }

    /// A kept sound put on these chords: the way it is played as one step of ⌘Z on the sheet, and
    /// the instrument and the strip on the chords' part, as picking either is. Chords that are not
    /// a part yet are kept first, so the sound has a part to be on.
    public func use(_ sound: ChordSound) {
        guard progression != nil, problem == nil else { return }
        willEdit(state, kind: "sound")
        let seed = playing.seed
        playing = sound.playing
        playing.seed = seed
        if (playing.keysPattern != .held || playing.isSloppy), playing.seed == 0 { playing.seed = GrooveFeel.freshSeed() }
        parse()
        didEdit()
        if part == nil { _ = commit() } else { keepNow() }
        host.setInstrument(sound.instrument, for: part)
        _ = host.setStripSound(sound.strip, for: part)
        lastError = nil
        hear()
    }

    /// Keeps the sheet's sound under `name`, in place of one kept under it before.
    public func saveSound(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        shelf.save(currentSound(named: trimmed))
        shelfChanges += 1
    }

    /// Forgets a saved sound.
    public func forgetSound(named name: String) {
        shelf.remove(named: name)
        shelfChanges += 1
    }

    /// A name for the sheet's sound as it stands: its instrument and how it is played.
    public var suggestedSoundName: String {
        let name = InstrumentVoiceSpec.preset(id: instrument)?.name ?? instrument
        return "\(name), \(playing.keysPattern.name.lowercased())"
    }

    // MARK: How a strike leaves the hand

    public var roll: KeysRoll { playing.keysRoll }
    public var isSloppy: Bool { playing.isSloppy }

    /// How each strike's notes leave the hand: together, strummed, or run as a harp.
    public func setRoll(_ roll: KeysRoll) {
        guard roll != self.roll else { return }
        willEdit(state, kind: "roll")
        playing.roll = roll == .together ? nil : roll.rawValue
        parse()
        didEdit()
        hear()
    }

    /// Whether each strike lands a little off the grid, as a loose hand does: the Orchid's Slop.
    public func setSlop(_ on: Bool) {
        guard on != isSloppy else { return }
        willEdit(state, kind: "slop")
        playing.slop = on ? true : nil
        // A hand of its own the first time it is loose: the slop is the seed's.
        if on, playing.seed == 0 { playing.seed = GrooveFeel.freshSeed() }
        parse()
        didEdit()
        hear()
    }

    /// Plays the chords as they stand, voiced and struck.
    public func hear() {
        guard let progression, problem == nil else { return }
        let part = self.part
        Task { [host] in await host.audition(progression, for: part) }
    }

    /// The top note of each chord as it is voiced, spelled in the key: the line the chords are
    /// heard as. "E4 · D4 · E4 · E4".
    public var topLine: String {
        guard let progression else { return "" }
        return Voicing.topLine(of: progression, as: voicing).map { key.name(of: Pitch(midi: $0)) }.joined(separator: " · ")
    }

    /// How far the voices travel from chord to chord as they are voiced, in semitones a voice.
    public var movement: Double {
        progression.map { Voicing.movement(of: $0, as: voicing) } ?? 0
    }

    /// Why the pattern chosen will not be heard well on the instrument chosen, when it will not.
    public var patternCaution: String? {
        let family = host.instrumentFamily(for: part)
        guard !pattern.suits(family: family) else { return nil }
        // A section, or an instrument with its short notes recorded, plays them whatever its family.
        if InstrumentVoiceSpec.preset(id: host.instrument(for: part))?.playsShortNotes == true { return nil }
        return "\(pattern.name) is short notes, and this instrument swells into a note: try it on a piano, an organ or a guitar, or hold the chords."
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
        var playing = ChordPlaying()
        var lifts: [Int] = []
    }

    private var history = EditHistory<ChordsState>()
    private var lastEdit: (kind: String, at: Date)?
    private var isApplyingState = false
    /// Keeps the chords a moment after the last edit. A test sets its delay to nil.
    public let autoKeep = AutoKeep()

    private var state: ChordsState {
        get { ChordsState(text: text, key: key, playing: playing, lifts: lifts) }
        set {
            isApplyingState = true
            key = newValue.key
            playing = newValue.playing
            lifts = newValue.lifts
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
            playing = stored.playing ?? ChordPlaying()
            lifts = stored.spans.map { $0.lift ?? 0 }
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
        defer {
            // Each chord turned as the sheet turned it, by its place on the line.
            progression = progression.map(turned)
            // Played the way the sheet says, whatever the line. Held and close is said as nothing,
            // so chords nobody has chosen a playing for are the chords they were.
            progression?.playing = playing.isPlain ? nil : playing
            refreshReadings()
        }
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

    /// What the library's other songs did, for the readings that are made against them, and the
    /// house's calls, which can turn those readings off. Asked each time, like the genre.
    public var before: @MainActor () -> SongsBefore? = { nil }
    public var house: @MainActor () -> HouseBook? = { nil }

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

    /// The other ways the sheet on screen can be said, each one named move: a borrowed chord, a
    /// bass line of inversions, a chord's own dominant before it. The ones a listener hears as a
    /// new chord first. Empty on a typo and on a sheet with nowhere to go.
    public var anotherWays: [Reharmonized] {
        guard problem == nil, let progression else { return [] }
        return ReharmonizeTool.offered.compactMap { Reharmonize.apply($0, to: progression) }
    }

    /// Types one of them into the field, as one edit: ⌘Z puts the sheet back.
    public func use(way: Reharmonized) {
        // A step of its own, whatever was typed a moment before or is typed a moment after.
        lastEdit = nil
        text = way.progression.symbols()
        lastEdit = nil
    }

    /// The Harmonist's reading of the bars on screen. On a typo those are the last bars that read,
    /// and so are the readings; the view dims both together.
    private func refreshReadings() {
        guard let progression else { readings = []; return }
        var observation = HarmonyObservation.of(progression, label: title, bassline: host.bassline,
                                                beatsPerBar: beatsPerBar)
        observation.before = before()
        let judged = GenreLens.judge(Harmonist().read(observation), by: Harmonist.bible, in: genre())
        readings = house()?.settle(judged, by: Harmonist.bible) ?? judged
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

    /// A chord's symbol as its bar shows it: its root spelled as the key spells it, so the sixth of
    /// E♭ minor is C♭maj7 on the card as it is in the line kept, and not Bmaj7.
    public func symbol(of chord: Chord) -> String { chord.symbol(in: key) }

    /// The Roman numeral of a chord in the key, or its symbol when it is not diatonic.
    public func numeral(of chord: Chord) -> String {
        key.romanNumeral(for: chord).map { "\($0)" } ?? symbol(of: chord)
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

    // MARK: The dial, and the bass under a chord

    /// How far each chord on the line is turned from where its voicing puts it, by its place on the
    /// line: the Orchid's voicing dial, a chord at a time. Kept beside the line rather than in it,
    /// since a lead sheet has no way to write a turn; a place with none, or past the end, is none.
    public private(set) var lifts: [Int] = []

    /// How far the chord at `index` is turned.
    public func lift(ofChordAt index: Int) -> Int { index < lifts.count ? lifts[index] : 0 }

    /// The chord a click on its card chose, by its place on the line, for the dial and the bass
    /// under the bars to act on. Nil, or a place the line no longer has, is none.
    public private(set) var selectedChord: Int?

    /// The chord at `index` chosen, and heard as it is voiced and turned.
    public func select(chordAt index: Int) {
        selectedChord = index
        hear(chordAt: index)
    }

    /// The chosen chord and its place, while the line still has it.
    public var selected: (index: Int, span: ChordSpan)? {
        guard let index = selectedChord, let spans = progression?.spans, index < spans.count else { return nil }
        return (index, spans[index])
    }

    /// The progression with each chord carrying its turn.
    private func turned(_ progression: Progression) -> Progression {
        var out = progression
        var index = 0
        for bar in out.bars.indices {
            for chord in out.bars[bar].chords.indices {
                let lift = lift(ofChordAt: index)
                out.bars[bar].chords[chord].lift = lift == 0 ? nil : lift
                index += 1
            }
        }
        return out
    }

    /// The chord at `index` turned `steps` further, heard at once as it is voiced now: up, its
    /// lowest note goes an octave up; down, its highest an octave down. One step of ⌘Z a pause,
    /// as typing is.
    public func turn(chordAt index: Int, by steps: Int) {
        guard let progression, problem == nil, index >= 0, index < progression.chords.count else { return }
        willEdit(state, kind: "lift-\(index)")
        setLift(lift(ofChordAt: index) + steps, at: index)
        parse()
        didEdit()
        hear(chordAt: index)
    }

    private func setLift(_ value: Int, at index: Int) {
        if lifts.count <= index { lifts += Array(repeating: 0, count: index + 1 - lifts.count) }
        lifts[index] = min(ChordKeyboard.lifts.upperBound, max(ChordKeyboard.lifts.lowerBound, value))
        while lifts.last == 0 { lifts.removeLast() }
    }

    /// The notes the chord at `index` is played on, as the sheet voices it now.
    public func voiced(chordAt index: Int) -> [Int] {
        guard let progression else { return [] }
        let voiced = Voicing.voicings(of: progression.spans, as: voicing)
        return index < voiced.count ? voiced[index] : []
    }

    /// Sounds the chord at `index` as it is voiced and turned.
    public func hear(chordAt index: Int) {
        let pitches = voiced(chordAt: index)
        guard !pitches.isEmpty else { return }
        let part = self.part
        Task { [host] in await host.audition(pitches: pitches, duration: 0.9, for: part) }
    }

    /// The bass under the chord at `index`: one of its own notes, written into the line as the
    /// chord over it — C/E — which is what the bass player reads. Its root is the chord as it was.
    public func setBass(_ bass: PitchClass, forChordAt index: Int) {
        guard let progression, problem == nil, index >= 0, index < progression.chords.count else { return }
        let chord = progression.chords[index]
        guard let inversion = chord.pitchClasses.firstIndex(of: bass), inversion != chord.inversion else { return }
        // The line as it is typed, or the suggestion as a line when nothing is: either way one
        // symbol a chord and one bar a stretch between bars, so the chord's place is its symbol's.
        var bars = (isDefault ? progression.symbols() : text)
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }
            .filter { !$0.isEmpty }
        var place = index
        for bar in bars.indices {
            guard place >= bars[bar].count else {
                bars[bar][place] = symbol(of: chord.inverted(inversion))
                break
            }
            place -= bars[bar].count
        }
        lastEdit = nil
        text = bars.map { $0.joined(separator: " ") }.joined(separator: " | ")
        lastEdit = nil
        hear(chordAt: index)
    }

    // MARK: Played in from the controller

    /// Whether Record is on: each chord played on the controller is written into the line as the
    /// next bar, as the hand comes off the keys.
    public private(set) var isTaking = false
    /// The keys down now, and every key put down since the hand was last off them all — the chord
    /// being played, its lowest key its bass.
    private var takeHeld: Set<Int> = []
    private var takeChord: [Int] = []
    /// What the last chord played was written as, or why it was not: for the line under the field.
    public private(set) var takeLine: String?

    public func beginTake(bars: Int?) {
        isTaking = true
        takeHeld = []
        takeChord = []
        takeLine = nil
    }

    public func takeNoteOn(_ note: Int, velocity: Int, beat: Double?) {
        guard isTaking else { return }
        takeHeld.insert(note)
        if !takeChord.contains(note) { takeChord.append(note) }
    }

    public func takeNoteOff(_ note: Int, beat: Double?) {
        guard isTaking, takeHeld.remove(note) != nil, takeHeld.isEmpty else { return }
        let played = takeChord
        takeChord = []
        write(played: played)
    }

    /// Record off. A chord still held is written: Record pressed with the other hand is the end of
    /// a chord, not the loss of it.
    public func endTake(at beat: Double?) {
        guard isTaking else { return }
        isTaking = false
        if !takeChord.isEmpty { write(played: takeChord) }
        takeHeld = []
        takeChord = []
    }

    /// Keys played together, written into the line as the next bar — the chord they are, spelled as
    /// the key spells it — each one a step of ⌘Z of its own. Typed after a sheet showing the key's
    /// I–IV–V–I they are the first bar: that sheet was a suggestion.
    func write(played keys: [Int]) {
        let names = keys.sorted().map { key.name(of: Pitch(midi: $0)) }.joined(separator: " ")
        guard keys.count >= 2 else {
            takeLine = "One note is not a chord — play two or more together."
            return
        }
        guard let chord = Chord.recognise(playedNotes: keys) else {
            takeLine = "\(names) is not a chord I can name."
            return
        }
        append(chord)
        takeLine = "\(names) → \(symbol(of: chord))"
    }

    /// A chord written into the line as the next bar, as its own step of ⌘Z.
    private func append(_ chord: Chord) {
        let line = text.trimmingCharacters(in: .whitespaces)
        lastEdit = nil
        text = line.isEmpty ? symbol(of: chord) : line + " | " + symbol(of: chord)
        lastEdit = nil
    }

    // MARK: Versions

    @discardableResult
    public func commit(note: String? = nil) -> PartVersion? {
        guard let progression, problem == nil else { return nil }
        let payload = PartKind.progression(progression)
        let text = note ?? "\(progression.symbols()) in \(progression.key)"
            + (progression.playing.map { ": \($0.sentence.lowercased())" } ?? "")
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

extension ChordsModel: TakesChords {
    /// A chord key on the sheet plays in the sheet's key, voiced as its chords are, on their
    /// instrument: a chord struck is heard as the sheet will play it.
    public var chordContext: ChordContext {
        ChordContext(key: key, voicing: voicing, instrument: instrument, roll: playing.keysRoll)
    }

    /// A chord struck on a chord key while Record is on: the next bar, as a chord played whole is,
    /// turned as the dial turned it. Buttons held that the chord could not take are said, so a
    /// hand holding maj7 on a diminished chord knows why it was not heard.
    public func takeChord(_ played: ChordKeys.Played, lift: Int) {
        guard isTaking else { return }
        let before = isDefault ? 0 : progression?.chords.count ?? 0
        append(played.chord)
        // The turn goes on after the line, so ⌘Z takes the chord and its turn back together.
        lifts = Array(lifts.prefix(before))
        if lift != 0 { setLift(lift, at: before) }
        parse()
        let unused = played.unused.map(\.name).joined(separator: ", ")
        takeLine = symbol(of: played.chord) + (lift == 0 ? "" : ", turned \(lift > 0 ? "up" : "down") \(abs(lift))")
            + (unused.isEmpty ? "" : " — \(unused) did not go on it")
    }
}

extension ChordsModel: TakesFromController {
    public var takeName: String { "the Chords sheet" }
    /// The instrument the chords are voiced on, so a chord played is heard as the sheet will play it.
    public var controllerVoice: MIDIControl.Voice { .keys(instrument) }
    /// A chord at a time, as it is played: nothing needs to run under a lead sheet.
    public var takesInTime: Bool { false }
}
