import AudioEngine
import Foundation
import Instrument
import SongGraph

// Inputs I5/I6: the controller on the kit, the bass or the keys, played now, and captured while the
// Booth records.

/// The controller in the app: which instrument it plays, the sources here, and the notes it put
/// down while a take ran.
@MainActor
@Observable
public final class MIDIControl {

    public enum Mode: String, CaseIterable, Sendable {
        /// Keys plays the song's pitched instrument — the Rhodes until one is chosen — and a take
        /// played on it lands as a melody. Before it, a controller could put down a beat and a
        /// bass line but not the tune, which had to be drawn a note at a time.
        case off, kit, bass, keys

        public var title: String {
            switch self {
            case .off: return "Off"
            case .kit: return "Kit"
            case .bass: return "Bass"
            case .keys: return "Keys"
            }
        }
    }

    public var mode: Mode = .off {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            if mode != oldValue { connectIfNeeded(); Task { await prepare() } }
        }
    }
    /// The sources with a port on them, by name.
    public private(set) var sources: [String] = []
    /// The source the last event came from.
    public private(set) var lastSource: String?
    /// The last thing played through, for the footer and a test.
    public private(set) var lastHit: VoiceSampler.Hit?
    public private(set) var lastError: String?
    /// Whether a take is being captured.
    public private(set) var isCapturing = false

    // Gate C: the knobs on the faders.

    /// Which control change moves which fader; remembered.
    public private(set) var map: ControllerMap
    /// The fader waiting for the next control change moved, when Learn is on.
    public private(set) var learning: ControlTarget?
    /// The last fader moved from the controller, for the footer and a test.
    public private(set) var lastControl: (target: ControlTarget, gainDB: Double)?
    /// How long the knob has to be still before the moves become one version.
    public var stillness: Duration = .milliseconds(300)
    /// The Mixer the knobs move: the open Mixer's model, or one of the control's own.
    public var mixer: (() -> MixerModel)?
    private var pendingCommit: Task<Void, Never>?

    private let app: AppState
    private let service: AuditionService
    private let defaults: UserDefaults
    private var input: MIDIInput?
    private var held: [Int: [VoiceSampler.VoiceHandle]] = [:]
    private var captured: [MIDIEvent] = []
    private var captureClock: TransportClock?
    private var captureSection: SectionID?
    private var captureStartedAt: Double?
    static let modeKey = "midi.mode"

    public init(app: AppState, service: AuditionService, defaults: UserDefaults = .standard) {
        self.app = app
        self.service = service
        self.defaults = defaults
        self.map = ControllerMapSettings(defaults: defaults).map
        if let stored = defaults.string(forKey: Self.modeKey), let mode = Mode(rawValue: stored) { self.mode = mode }
        // A controller already plugged in is listed from launch when the footer was left on it.
        if self.mode != .off { connectIfNeeded() }
    }

    /// Opens the CoreMIDI client. Called when the footer's mode is set, and once on launch, so a
    /// controller that is already plugged in is listed.
    public func connectIfNeeded() {
        guard input == nil else { return }
        do {
            let input = try MIDIInput(handler: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }, sourcesChanged: { [weak self] sources in
                Task { @MainActor in self?.sources = sources.map(\.name) }
            })
            self.input = input
            sources = input.sources.map(\.name)
        } catch {
            lastError = "\(error)"
        }
    }

    /// One event: through to the instrument the mode names, and into the capture while one runs.
    public func handle(_ event: MIDIEvent) {
        lastSource = event.source
        if case .controlChange(let controller, let value) = event.kind {
            control(controller, value: value)
            return
        }
        if isCapturing { captured.append(event) }
        // The sound is read at every note, not once when the mode was picked: the song can have
        // changed, or its instrument, or a chop's pads can have taken the shared drum sampler.
        // Loading what is already loaded is a lookup, so a note costs nothing extra.
        let sound = self.sound()
        switch (mode, event.kind) {
        case (.kit, .noteOn(let note, let velocity)):
            let hit = VoiceSampler.Hit(DrumMap.voice(for: note), velocity: velocity, at: 0)
            lastHit = hit
            Task {
                await load(sound)
                await service.play([hit])
            }
        case (.bass, .noteOn(let note, let velocity)):
            let hit = VoiceSampler.Hit(note: note, velocity: velocity, at: 0)
            lastHit = hit
            Task {
                await load(sound)
                let handles = await service.playBass([hit])
                held[note, default: []].append(contentsOf: handles)
            }
        case (.bass, .noteOff(let note)):
            if let handles = held.removeValue(forKey: note) { Task { await service.stopBass(handles) } }
        case (.keys, .noteOn(let note, let velocity)):
            let hit = VoiceSampler.Hit(note: note, velocity: velocity, at: 0)
            lastHit = hit
            Task {
                await load(sound)
                let handles = await service.playInstrument([hit])
                held[note, default: []].append(contentsOf: handles)
            }
        case (.keys, .noteOff(let note)):
            if let handles = held.removeValue(forKey: note) { Task { await service.stopInstrument(handles) } }
        default:
            break
        }
    }

    /// What the mode plays, for the song as it stands. With no song open, the app's defaults — a
    /// controller plugged in before a song exists still makes a sound.
    enum Voice: Equatable {
        case kit(String), bass(String), keys(String)
    }

    func sound() -> Voice? {
        switch mode {
        case .off:
            return nil
        case .kit:
            return .kit(app.song.map { SongPlayback.machineID(in: $0) } ?? SynthMachine.tr808.id)
        case .bass:
            let sound = app.song.flatMap { Guidance.basslines(in: $0).last }.flatMap { version -> String? in
                if case .bassline(let line) = version.kind { return line.sound }
                return nil
            }
            return .bass(BassVoiceSpec.all.first { $0.id == sound }?.id ?? BassVoiceSpec.finger.id)
        case .keys:
            return .keys(app.song.map { SongPlayback.instrumentID(in: $0) } ?? InstrumentVoiceSpec.rhodes.id)
        }
    }

    /// Loads the sound, when it is not what is loaded already.
    private func load(_ voice: Voice?) async {
        do {
            switch voice {
            case .kit(let id):
                if let machine = SynthMachine.preset(id: id) { try await service.prepare(machine: machine) }
            case .bass(let id):
                if let spec = BassVoiceSpec.all.first(where: { $0.id == id }) { try await service.prepare(bass: spec) }
            case .keys(let id):
                if let spec = InstrumentVoiceSpec.preset(id: id) { try await service.prepare(instrument: spec) }
            case nil:
                break
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// The instrument for the mode, loaded so the first pad is not late.
    private func prepare() async { await load(sound()) }

    // MARK: Capture, with the Booth

    /// Starts keeping events against this clock (the running transport's, with its start host time).
    public func beginCapture(section: SectionID?, clock: TransportClock, startedAt: Double) {
        guard mode != .off, clock.startHostTime != nil else { return }
        captured = []
        captureClock = clock
        captureSection = section
        captureStartedAt = startedAt
        isCapturing = true
    }

    /// Stops, and what was played becomes a version: a groove in Kit, a bass line in Bass, a melody
    /// in Keys. Nil when nothing was played.
    @discardableResult
    public func endCapture(endedAt: Double? = nil) -> PartVersion? {
        guard isCapturing, let clock = captureClock else { return nil }
        isCapturing = false
        let events = captured
        captured = []
        guard let song = app.song, !events.isEmpty else { return nil }
        let timed = events.compactMap { event -> (kind: MIDIEvent.Kind, seconds: Double)? in
            clock.seconds(forHostTime: event.hostTime).map { (event.kind, $0) }
        }
        let notes = MIDICapture.notes(from: timed)
        let source = events.first?.source ?? "the controller"
        let section = captureSection.flatMap { id in song.sections.first { $0.id == id } }
        let sectionStart = section.map { clock.seconds(forBar: Self.startBar(of: $0.id, in: song)) } ?? 0
        let kind: PartKind
        let what: String
        switch mode {
        case .kit:
            guard let groove = MIDICapture.groove(notes, clock: clock, sectionStart: sectionStart, bars: section?.lengthInBars) else { return nil }
            kind = .groove(groove)
            what = "groove"
        case .bass:
            let sound = Guidance.basslines(in: song).last.flatMap { version -> String? in
                if case .bassline(let line) = version.kind { return line.sound }
                return nil
            }
            guard let line = MIDICapture.bassline(notes, clock: clock, sectionStart: sectionStart, end: endedAt, key: song.key, sound: sound) else { return nil }
            kind = .bassline(line)
            what = "bass line"
        case .keys:
            guard let tune = MIDICapture.melody(notes, clock: clock, sectionStart: sectionStart, end: endedAt, bars: section?.lengthInBars) else { return nil }
            kind = .melody(tune)
            what = "melody"
        case .off:
            return nil
        }
        let version = PartVersion(partID: PartID(), kind: kind, author: .user, operation: Operation.played,
                                  note: "Played on \(source)\(section.map { " into \($0.name)" } ?? "") — \(notes.count) notes as a \(what)")
        guard app.record(version) else { return nil }
        return version
    }

    // MARK: The knobs (I7)

    /// The next control change moved binds to this fader. Nil cancels.
    public func learn(_ target: ControlTarget?) { learning = target }

    private func control(_ controller: Int, value: Int) {
        if let learning {
            map.learn(controller: controller, target: learning)
            ControllerMapSettings(defaults: defaults).map = map
            self.learning = nil
            app.note(.you, "Learned: control \(controller) moves the \(learning.title)")
        }
        guard let target = map.target(of: controller), let mixer = mixer?() else { return }
        switch target {
        case .strip(let index):
            guard mixer.rows.indices.contains(index) else { return }
            let gain = ControllerMap.gainDB(for: value)
            mixer.setGain(gain, for: mixer.rows[index].part)
            lastControl = (target, gain)
        case .master:
            let gain = ControllerMap.masterGainDB(for: value)
            mixer.setMaster(gainDB: gain)
            lastControl = (target, gain)
        }
        // A stream of changes is one gesture: the version lands when the knob has been still.
        pendingCommit?.cancel()
        let wait = stillness
        pendingCommit = Task { [weak mixer] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            mixer?.endGesture()
        }
    }

    static func startBar(of section: SectionID, in song: Song) -> Int {
        var start = 0
        for candidate in song.sections {
            if candidate.id == section { return start }
            start += candidate.lengthInBars
        }
        return 0
    }
}
