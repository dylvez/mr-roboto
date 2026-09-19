import AudioEngine
import Foundation
import Instrument
import SongGraph

// Inputs I5/I6: the controller on the kit or the bass, played now, and captured while the Booth records.

/// The controller in the app: which instrument it plays, the sources here, and the notes it put
/// down while a take ran.
@MainActor
@Observable
public final class MIDIControl {

    public enum Mode: String, CaseIterable, Sendable {
        case off, kit, bass

        public var title: String {
            switch self {
            case .off: return "Off"
            case .kit: return "Kit"
            case .bass: return "Bass"
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
        switch (mode, event.kind) {
        case (.kit, .noteOn(let note, let velocity)):
            let hit = VoiceSampler.Hit(DrumMap.voice(for: note), velocity: velocity, at: 0)
            lastHit = hit
            Task { await service.play([hit]) }
        case (.bass, .noteOn(let note, let velocity)):
            let hit = VoiceSampler.Hit(note: note, velocity: velocity, at: 0)
            lastHit = hit
            Task {
                let handles = await service.playBass([hit])
                held[note, default: []].append(contentsOf: handles)
            }
        case (.bass, .noteOff(let note)):
            if let handles = held.removeValue(forKey: note) { Task { await service.stopBass(handles) } }
        default:
            break
        }
    }

    /// The instrument for the mode, loaded so the first pad is not late.
    private func prepare() async {
        guard let song = app.song else { return }
        do {
            switch mode {
            case .kit:
                if let machine = SynthMachine.preset(id: SongPlayback.machineID(in: song)) { try await service.prepare(machine: machine) }
            case .bass:
                let sound = Guidance.basslines(in: song).last.flatMap { version -> String? in
                    if case .bassline(let line) = version.kind { return line.sound }
                    return nil
                }
                try await service.prepare(bass: BassVoiceSpec.all.first { $0.id == sound } ?? .finger)
            case .off:
                break
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

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

    /// Stops, and what was played becomes a version: a groove in Kit, a bass line in Bass. Nil when
    /// nothing was played, and the reason in the rail.
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
