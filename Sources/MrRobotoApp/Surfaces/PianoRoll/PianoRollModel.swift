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
/// the readings; nothing is committed until you say so.
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

    // MARK: Versions and readings

    public private(set) var base: PartVersion?
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    public private(set) var readings: [PersonaReading] = []

    /// The pitch range the roll draws: the lineage's register, widened to hold the notes.
    /// Whether the writer's levers apply. A tune is drawn by hand: nothing in the app writes one,
    /// and a lever that silently did would be the Bassist writing melodies.
    public var writesFromLevers: Bool { mode == .bass }

    public var melody: Melody { Melody(notes: notes) }

    /// Who reads what this roll is writing.
    public var readingPersona: String { mode == .bass ? "Bassist" : "Melodist" }

    public func setMode(_ value: Mode) {
        guard value != mode else { return }
        mode = value
        // A bass line dragged into melody mode keeps its notes; they just sound an octave up on a
        // different instrument, which is usually what you wanted when you switched.
        refreshReadings()
    }

    public func setInstrument(_ id: String) {
        guard InstrumentVoiceSpec.preset(id: id) != nil else { return }
        instrument = id
        host.setInstrument(id)
        if let first = notes.first { audition(first) }
    }

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
        if let bassline, case .bassline(let line) = bassline.kind {
            base = bassline
            notes = line.notes
            sound = line.sound ?? lineage.defaultSound
            isHandEdited = true
            refreshReadings()
        } else {
            write()
        }
    }

    // MARK: Reading

    public var bassline: Bassline { Bassline(notes: notes, sound: sound, key: key) }

    public var beatsPerBar: Int { max(1, timeSignature.beatsPerBar) }
    public var bars: Int { max(1, groove?.bars ?? Int((bassline.lengthInBeats / Double(beatsPerBar)).rounded(.up))) }
    public var totalBeats: Double { Double(bars * beatsPerBar) }

    /// The groove's kick onsets in beats, swung as it swings them, for the lane under the notes.
    public var kickBeats: [Double] {
        guard let groove else { return [] }
        return BassWriter.kickOnsets(in: groove, beatsPerBar: Double(beatsPerBar))
    }

    public var observation: BassObservation? {
        guard let groove else { return nil }
        return BassObservation(label: title, bassline: bassline, groove: groove, chords: chords,
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
                           sound: sound, seed: seed)
    }

    /// Writes the line from the levers. Replaces whatever is on screen.
    public func write() {
        guard let request else { return }
        let line = BassWriter.write(request)
        notes = line.notes
        sound = line.sound ?? sound
        isHandEdited = false
        refreshReadings()
    }

    /// A different line from the same levers.
    public func rewrite() {
        seed &+= 0x9E37_79B9
        write()
    }

    public func setLineage(_ value: BassLineage) {
        lineage = value
        lagMS = value.defaultLagMS
        sound = value.defaultSound
        write()
    }

    public func setLag(_ milliseconds: Double) {
        lagMS = min(Bassist.lagCeilingMS, max(-25, milliseconds))
        write()
    }

    public func setDensity(_ value: Double) {
        density = min(1, max(0, value))
        write()
    }

    public func setEarlyAlternation(_ on: Bool) {
        earlyAlternation = on
        write()
    }

    /// The bass sound. Does not rewrite: the same notes through another voice.
    public func setSound(_ id: String) {
        guard BassVoiceSpec.all.contains(where: { $0.id == id }) else { return }
        sound = id
        refreshReadings()
        if let first = notes.first { audition(first) }
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

    // MARK: Editing notes

    public func addNote(pitch: Int, at beat: Double, duration: Double = 0.5) {
        let start = max(0, min(totalBeats - 0.125, Self.snap(beat)))
        let note = NoteEvent(pitch: Pitch(midi: pitch), start: start, duration: max(0.125, duration), velocity: 100)
        notes.append(note)
        notes.sort { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
        isHandEdited = true
        refreshReadings()
        audition(note)
    }

    public func moveNote(at index: Int, toStart start: Double, pitch: Int) {
        guard notes.indices.contains(index) else { return }
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
        notes[index].duration = max(0.125, min(totalBeats - notes[index].start, Self.snap(duration)))
        isHandEdited = true
        refreshReadings()
    }

    public func deleteNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
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
        if let previous = versions.last ?? base {
            version = previous.deriving(payload, by: .user, operation: isHandEdited ? Operation.edit : Operation.written,
                                        note: text)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user,
                                  parents: grooveVersion.map { [$0] } ?? [],
                                  operation: Operation.written, note: text)
        }
        versions.append(version)
        lastError = nil
        Task { @MainActor [host, weak self] in
            let kept = await host.commit(version)
            if !kept { self?.lastError = "The host refused the version." }
        }
        return version
    }

    private var defaultNote: String {
        if mode == .melody {
            let name = InstrumentVoiceSpec.preset(id: instrument)?.name ?? instrument
            return "Melody, \(notes.count) note\(notes.count == 1 ? "" : "s") on the \(name)"
        }
        var parts = [isHandEdited ? "Bass line, edited" : "\(lineage.name) line"]
        if lagMS != 0 { parts.append(String(format: "%+.0f ms behind the kick", lagMS)) }
        parts.append(String(format: "%.0f bpm", tempo))
        parts.append(BassVoiceSpec.all.first { $0.id == sound }?.name ?? sound)
        if usesDefaultChords { parts.append("to the key's I–IV–V–I") }
        return parts.joined(separator: ", ")
    }
}
