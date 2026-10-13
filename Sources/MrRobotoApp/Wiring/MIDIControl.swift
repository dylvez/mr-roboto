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

        /// What a take played in this mode lands as.
        public var capturedKind: String {
            switch self {
            case .off: return "nothing"
            case .kit: return "groove"
            case .bass: return "bass line"
            case .keys: return "melody"
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
    /// Whether the capture is the controller's own — Play in — rather than the Booth's.
    public private(set) var isPlayingIn = false

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
    /// Held notes on their way to sounding, by key, and the keys let go before they got there.
    private var starting: [Int: Int] = [:]
    private var letGo: Set<Int> = []
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

    /// One event: through to the instrument the mode names, and into the capture while one runs —
    /// or, while a surface has Record on, through that surface's own sound and onto the surface.
    public func handle(_ event: MIDIEvent) {
        lastSource = event.source
        if case .controlChange(let controller, let value) = event.kind {
            control(controller, value: value)
            return
        }
        if takeSurface != nil {
            take(event)
            return
        }
        if isCapturing { captured.append(event) }
        // The sound is read at every note, not once when the mode was picked: the song can have
        // changed, or its instrument, or a chop's pads can have taken the shared drum sampler.
        // Loading what is already loaded is a lookup, so a note costs nothing extra.
        play(event, on: sound())
    }

    /// Sounds a key on a voice: a drum hit now, or a bass or keys note held until it is let go.
    private func play(_ event: MIDIEvent, on sound: Voice?, hit: ((Int, Int) -> Bool)? = nil) {
        switch (sound, event.kind) {
        case (.kit, .noteOn(let note, let velocity)):
            let played = VoiceSampler.Hit(DrumMap.voice(for: note), velocity: velocity, at: 0)
            lastHit = played
            if hit?(note, velocity) == true { return }
            Task {
                await load(sound)
                await service.play([played])
            }
        case (.bass, .noteOn(let note, let velocity)), (.keys, .noteOn(let note, let velocity)):
            let played = VoiceSampler.Hit(note: note, velocity: velocity, at: 0)
            lastHit = played
            starting[note, default: 0] += 1
            Task {
                await load(sound)
                let handles: [VoiceSampler.VoiceHandle]
                if case .bass = sound {
                    handles = await service.playBass([played])
                } else {
                    handles = await service.playInstrument([played])
                }
                started(note, handles)
            }
        case (_, .noteOff(let note)):
            // Let go on whatever it was held on: Record pressed between the key going down and
            // coming up must not leave it ringing.
            if let handles = held.removeValue(forKey: note) {
                release(handles)
            } else if starting[note, default: 0] > 0 {
                letGo.insert(note)
            }
        default:
            break
        }
    }

    /// A held note has begun sounding. A key let go before it had — a quick tap, while the voice
    /// was still loading — is stopped now; it used to ring on, since its release found nothing.
    private func started(_ note: Int, _ handles: [VoiceSampler.VoiceHandle]) {
        let left = starting[note, default: 1] - 1
        starting[note] = left > 0 ? left : nil
        if letGo.remove(note) != nil {
            release(handles)
        } else {
            held[note, default: []].append(contentsOf: handles)
        }
    }

    private func release(_ handles: [VoiceSampler.VoiceHandle]) {
        guard !handles.isEmpty else { return }
        Task {
            await service.stopBass(handles)
            await service.stopInstrument(handles)
        }
    }

    /// What the mode plays, for the song as it stands. With no song open, the app's defaults — a
    /// controller plugged in before a song exists still makes a sound.
    public enum Voice: Equatable, Sendable {
        /// A drum machine, by id.
        case kit(String)
        /// A bass voice, by id.
        case bass(String)
        /// A pitched instrument, by preset id.
        case keys(String)
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
            return .bass(sound.flatMap(BassVoiceSpec.resolve(id:))?.id ?? BassVoiceSpec.finger.id)
        case .keys:
            return .keys(app.song.map { SongPlayback.instrumentID(in: $0) } ?? InstrumentVoiceSpec.rhodes.id)
        }
    }

    /// Loads the sound, when it is not what is loaded already.
    private func load(_ voice: Voice?) async {
        do {
            switch voice {
            case .kit(let id):
                if let machine = SynthMachine.preset(id: id) {
                    try await service.prepare(machine: app.song.map { SongPlayback.shaped(machine, in: $0) } ?? machine)
                }
            case .bass(let id):
                if let spec = BassVoiceSpec.resolve(id: id) { try await service.prepare(bass: spec) }
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
            guard let line = MIDICapture.bassline(notes, clock: clock, sectionStart: sectionStart, end: endedAt, key: song.key,
                                                  sound: sound, bars: section?.lengthInBars) else { return nil }
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

    // MARK: Play in, with no microphone

    /// "Play in": the song from the active section, a bar counted in, and what the controller plays
    /// kept when it stops — a groove, a bass line or a melody, as the mode says. Capture used to
    /// happen only while the Booth recorded audio, so a pad controller with no microphone behind it
    /// could play along and keep nothing.
    public func playIn() async {
        guard mode != .off, !isCapturing, takeSurface == nil, let song = app.song else { return }
        lastError = nil
        let booth = BoothAdapter(app: app, service: service)
        let section = app.activeSection ?? song.sections.first?.id
        // Played in is one pass, as a take is: over a loop the song starts again, unlooped.
        if app.isRunningALoop { await app.stopTransport() }
        let startedHere = !app.transport.isPlaying
        if startedHere {
            await booth.play(from: section, countInBars: song.sections.isEmpty ? 0 : 1, click: true)
        }
        guard app.transport.isPlaying else {
            lastError = "The song did not start, so there is nothing to play to."
            return
        }
        guard let clock = await booth.songClock() else {
            lastError = "No running engine to time the notes against."
            if startedHere { await app.stopTransport() }
            return
        }
        beginCapture(section: section, clock: clock, startedAt: app.playhead)
        isPlayingIn = isCapturing
    }

    /// Stops Play in: what was played becomes a version, and the song stops.
    @discardableResult
    public func stopPlayIn() async -> PartVersion? {
        guard isPlayingIn else { return nil }
        isPlayingIn = false
        let version = endCapture(endedAt: app.playhead)
        await app.stopTransport()
        if version == nil { app.note(.session, "Nothing was played in", detail: "Play the controller while the song runs; what you play lands when you stop.") }
        return version
    }

    /// Ends whatever the controller is doing for the song being left: a capture kept into that
    /// song when `keeping`, held notes let go. Play in carried across a switch used to record the
    /// old song's notes into the new one on Stop.
    public func finishForSongChange(keeping: Bool) {
        isPlayingIn = false
        // A surface's take is that song's surface's: ended, and kept with the rest when keeping.
        if let target = takeTarget, keeping {
            finishTake(at: takeBeat(atHostTime: mach_absolute_time()))
            _ = (target as? any KeepsAsItGoes)?.keepNow()
        } else {
            finishTake(at: nil)
        }
        if isCapturing {
            if keeping {
                endCapture(endedAt: app.playhead)
            } else {
                isCapturing = false
                captured = []
                captureClock = nil
            }
        }
        let handles = held.values.flatMap { $0 }
        held = [:]
        letGo.formUnion(starting.keys)
        release(handles)
    }

    // MARK: Record, on a surface (I8)

    /// The surface Record is on, if one is: the Grid, the Piano roll or a lead sheet. Every key
    /// goes to it, through its own sound, until Record is pressed again.
    public private(set) var takeSurface: SurfaceID?
    /// What it is called, for the transport's line.
    public private(set) var takeName: String?
    /// Keys that reached the surface this take.
    public private(set) var takeNotes = 0
    /// Whether the take runs against the song: the transport turns red for it, as for Play in.
    public var isTakingInTime: Bool { takeSurface != nil && takeClock != nil }

    /// Weak: a surface closed in the middle of a take is not kept alive by it.
    private weak var takeTarget: (any TakesFromController)?
    private var takeClock: TransportClock?
    /// Song seconds of the section's first bar, which a note's beat is counted from.
    private var takeSectionStart: Double = 0
    /// Song seconds the section ends at, where an in-time take stops by itself.
    private var takePunchOut: Double?
    private var takeWatch: Task<Void, Never>?
    /// Whether the take started the song, so its end stops it.
    private var takeStartedTransport = false
    /// Counts presses of Record, so a run still starting the song knows it has been stopped.
    private var takeRun = 0

    public func isTaking(into surface: SurfaceID) -> Bool { takeSurface == surface }

    /// Record on a surface, or off again when it is that surface's already.
    ///
    /// In time — the Grid, the Piano roll — the song plays from the lit section after a bar of
    /// click, and the take ends at the section's last bar or at Stop. On a lead sheet nothing
    /// plays: each chord is written as the hand comes off it, until Record is pressed again.
    /// Either way the controller sounds the surface's own kit, bass or instrument, whatever the
    /// footer's mode says, and is connected if the mode had left it off.
    public func record(into target: any TakesFromController) async {
        if let current = takeSurface {
            await stopRecording()
            if current == target.surfaceID { return }
        }
        guard !isCapturing else {
            lastError = "The controller is already being recorded — stop Play in or the Booth first."
            return
        }
        lastError = nil
        connectIfNeeded()
        guard input != nil else { return }
        guard target.takesInTime else {
            beginTake(into: target, clock: nil, sectionStart: 0, bars: nil, punchOut: nil)
            return
        }
        guard let song = app.song else {
            lastError = "Open a song to record into: the take is timed against it."
            return
        }
        let section = app.activeSection ?? song.sections.first?.id
        let length = section.flatMap { id in song.sections.first { $0.id == id }?.lengthInBars }
        // The surface is the controller's from the press, so its button says Stop while the song
        // starts: a key played before the song's clock is running sounds, and lands nowhere. A
        // second press in that time stops this run, and the run sees it after each wait.
        takeRun &+= 1
        let run = takeRun
        takeTarget = target
        takeSurface = target.surfaceID
        takeName = target.takeName
        takeClock = nil
        takeNotes = 0
        // One pass from the section, counted in, as a take in the Booth is.
        if app.transport.isPlaying { await app.stopTransport() }
        guard takeRun == run else { return }
        takeStartedTransport = true
        await app.startTransport(fromSection: section, countInBars: song.sections.isEmpty ? 0 : 1, click: true)
        guard takeRun == run else {
            // Stopped while the song was starting: the song it started stops too, unless another
            // take has it now.
            if takeSurface == nil, app.transport.isPlaying { await app.stopTransport() }
            return
        }
        guard app.transport.isPlaying else {
            lastError = "The song did not start, so there is nothing to play to."
            forgetTake()
            return
        }
        guard let clock = await BoothAdapter(app: app, service: service).songClock(), takeRun == run else {
            if takeRun == run {
                lastError = "No running engine to time the notes against."
                forgetTake()
            }
            if takeSurface == nil, app.transport.isPlaying { await app.stopTransport() }
            return
        }
        let startBar = section.flatMap { app.sectionStartBar($0) } ?? 0
        beginTake(into: target, clock: clock, sectionStart: clock.seconds(forBar: startBar), bars: length,
                  punchOut: length.map { clock.seconds(forBar: startBar + $0) })
        takeStartedTransport = true
        watchTake()
    }

    /// Lets go of a take that never began on its surface: the song would not start under it.
    private func forgetTake() {
        takeTarget = nil
        takeSurface = nil
        takeName = nil
        takeClock = nil
        takeStartedTransport = false
    }

    /// Record off: the take lands on its surface, and a song the take started stops.
    public func stopRecording() async {
        guard takeSurface != nil else { return }
        let stopsSong = takeStartedTransport
        finishTake(at: takeBeat(atHostTime: mach_absolute_time()))
        if stopsSong, app.transport.isPlaying { await app.stopTransport() }
    }

    /// Starts keeping keys for `target`, against `clock` when the take is in time. The transport
    /// is the caller's; a test hands it a clock and plays events at it.
    func beginTake(into target: any TakesFromController, clock: TransportClock?, sectionStart: Double,
                   bars: Int?, punchOut: Double?) {
        takeTarget = target
        takeSurface = target.surfaceID
        takeName = target.takeName
        takeClock = clock
        takeSectionStart = sectionStart
        takePunchOut = punchOut
        takeNotes = 0
        takeStartedTransport = false
        target.beginTake(bars: bars)
    }

    /// Ends the take on its surface, at `beat` from the section's first bar, and forgets it.
    func finishTake(at beat: Double?) {
        takeWatch?.cancel()
        takeWatch = nil
        guard takeSurface != nil else { return }
        takeRun &+= 1
        let target = takeTarget
        let landed = takeNotes
        let name = takeName ?? "the surface"
        takeTarget = nil
        takeSurface = nil
        takeName = nil
        takeClock = nil
        takePunchOut = nil
        takeStartedTransport = false
        takeNotes = 0
        target?.endTake(at: beat)
        if landed == 0, target != nil {
            app.note(.session, "Nothing was recorded into \(name)",
                     detail: "Play the controller while Record is on; what you play lands as you play it.")
        }
    }

    /// One key, while a surface has Record on: through the surface's sound, and onto it.
    private func take(_ event: MIDIEvent) {
        guard let target = takeTarget else {
            // The surface went away mid-take: the take ends, and a song it started stops.
            Task { await stopRecording() }
            play(event, on: sound())
            return
        }
        play(event, on: target.controllerVoice) { [weak target] note, velocity in
            target?.soundTakeHit(note, velocity: velocity) ?? false
        }
        let beat = takeBeat(atHostTime: event.hostTime)
        // In time, a key needs the clock: one played before the song had started sounds, and lands
        // nowhere.
        if target.takesInTime, beat == nil { return }
        switch event.kind {
        case .noteOn(let note, let velocity):
            target.takeNoteOn(note, velocity: velocity, beat: beat)
            takeNotes += 1
        case .noteOff(let note):
            target.takeNoteOff(note, beat: beat)
        case .controlChange:
            break
        }
    }

    /// Beats from the take's section's first bar to `hostTime`; nil when the take is not in time.
    private func takeBeat(atHostTime hostTime: UInt64) -> Double? {
        guard let clock = takeClock, let seconds = clock.seconds(forHostTime: hostTime) else { return nil }
        return clock.beat(forSeconds: seconds - takeSectionStart)
    }

    /// Ends an in-time take at the section's end, or when the song stops under it.
    private func watchTake() {
        takeWatch?.cancel()
        takeWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.takeSurface != nil else { return }
                if self.takeTarget == nil || !self.app.transport.isPlaying {
                    await self.stopRecording()
                    return
                }
                if let end = self.takePunchOut, self.app.playhead >= end - 1e-3 {
                    await self.stopRecording()
                    return
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
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
