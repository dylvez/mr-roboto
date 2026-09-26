import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// One way to hear one thing. Every surface's header, every row of the parts ledger and the
// transport bar go through this, so "what is sounding" has one answer and one Stop.

/// Plays a single part version — alone, or as the song with it in — and says what is sounding.
@MainActor
@Observable
public final class PartPlayer {

    public struct NowPlaying: Equatable, Sendable {
        /// The version's id, or a surface's, as text: what a control compares itself to.
        public var id: String
        /// "Boom-bap pocket", "bars 5–8 of Arrival".
        public var label: String
    }

    public enum Mode: String, CaseIterable, Sendable {
        /// The part and nothing else.
        case alone
        /// The song's transport, so the part is heard against everything it plays with.
        case inSong

        public var title: String { self == .alone ? "Alone" : "In the song" }
    }

    /// What is sounding. A part heard in the song stops being "now playing" the moment the
    /// transport stops, whoever stopped it.
    public var nowPlaying: NowPlaying? {
        if startedTransport, !app.transport.isPlaying { return nil }
        return sounding
    }
    private var sounding: NowPlaying?
    public private(set) var lastError: String?
    public var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    private let app: AppState
    private let service: AuditionService
    private let defaults: UserDefaults
    private var ending: Task<Void, Never>?
    private(set) var startedTransport = false
    static let modeKey = "play.mode"

    public init(app: AppState, service: AuditionService, defaults: UserDefaults = .standard) {
        self.app = app
        self.service = service
        self.defaults = defaults
        self.mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .alone
    }

    // MARK: What can be heard

    /// Whether a version is something with a sound of its own.
    public nonisolated static func canPlay(_ version: PartVersion) -> Bool {
        switch version.kind {
        case .groove(let groove): return groove.patterns.contains { $0.steps.contains { $0 != .rest } }
        case .bassline(let line): return !line.notes.isEmpty
        case .melody(let melody): return !melody.notes.isEmpty
        case .progression(let progression): return !progression.chords.isEmpty
        case .audio, .sample: return true
        case .lyric, .sound, .analysis, .mix: return false
        }
    }

    public func isPlaying(_ id: String) -> Bool { nowPlaying?.id == id }
    public func isPlaying(_ version: PartVersion) -> Bool { isPlaying(version.id.description) }

    // MARK: Playing

    /// Plays it, or stops it when it is the thing sounding.
    public func toggle(_ version: PartVersion) {
        if isPlaying(version) { stop() } else { Task { await play(version) } }
    }

    public func play(_ version: PartVersion) async {
        guard Self.canPlay(version), let song = app.song ?? app.library.songs.first(where: { $0.version(version.id) != nil }) else { return }
        await stopSounding()
        let label = PartLabel.title(of: version)
        if mode == .inSong, app.song?.version(version.id) != nil {
            await playSong(id: version.id.description, label: "\(label), in the song", from: version)
            return
        }
        lastError = nil
        let clock = TransportClock(tempo: song.tempo, timeSignature: song.timeSignature)
        do {
            let seconds = try await sound(version, in: song, clock: clock)
            began(NowPlaying(id: version.id.description, label: label), seconds: seconds)
        } catch {
            lastError = "\(error)"
            app.note(.session, "Could not play \(label)", detail: "\(error)")
        }
    }

    /// Something a surface plays itself — a working groove not yet kept, a bar of a chop, a merge
    /// as planned — under this player's name, so the header, the bar and Stop all know about it.
    public func play(id: String, label: String, seconds: Double?, _ body: @escaping @MainActor () async -> Void) async {
        await stopSounding()
        lastError = nil
        began(NowPlaying(id: id, label: label), seconds: seconds)
        await body()
    }

    /// The song's transport, under a name: "the song", or a part heard in it.
    public func playSong(id: String, label: String, from version: PartVersion? = nil) async {
        await stopSounding()
        // The section whose form names this version's *part*. It used to look for the version id,
        // which stopped matching the moment you kept a new version of what a section plays.
        if let version, let section = app.song?.sections.first(where: { $0.stitch.contains(part: version.partID) }) {
            app.setActiveSection(section.id)
        }
        if !app.transport.isPlaying { await app.startTransport() }
        guard app.transport.isPlaying else { return }
        startedTransport = true
        sounding = NowPlaying(id: id, label: label)
    }

    public func stop() {
        Task { await stopSounding() }
    }

    /// Space, and the transport's play button: a part sounding on its own is stopped; otherwise the
    /// song plays or stops, as it always has. One key never leaves two things sounding.
    public func spaceBar() async {
        if nowPlaying != nil {
            await stopSounding()
        } else {
            await app.toggleTransport()
        }
    }

    /// Everything this player started, silenced. The transport only when this player started it.
    public func stopSounding() async {
        ending?.cancel()
        ending = nil
        let wasTransport = startedTransport
        startedTransport = false
        sounding = nil
        await service.stop()
        if wasTransport, app.transport.isPlaying { await app.stopTransport() }
    }

    private func began(_ playing: NowPlaying, seconds: Double?) {
        sounding = playing
        startedTransport = false
        guard let seconds else { return }
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.sounding == playing else { return }
            self.sounding = nil
        }
    }

    // MARK: One part, alone

    /// Starts the sound and says how long it lasts.
    private func sound(_ version: PartVersion, in song: Song, clock: TransportClock) async throws -> Double {
        switch version.kind {
        case .groove(let groove):
            // On what the song plays this part on: its chop's slices, or its own machine.
            if let chop = ChopSound.part(of: SongPlayback.drumSoundID(for: version.partID, in: song)),
               let track = app.chopTrack(chop),
               let seconds = await play(groove, on: track, clock: clock) {
                return seconds
            }
            return await play(groove, machine: SynthMachine.preset(id: SongPlayback.machineID(for: version.partID, in: song)) ?? .tr808,
                              clock: clock)
        case .bassline(let line):
            return await play(line.notes, sound: line.sound, clock: clock)
        case .melody(let melody):
            return await playOnInstrument(melody.notes, in: song, for: version.partID, clock: clock)
        case .progression(let progression):
            return await play(progression, in: song, for: version.partID, clock: clock)
        case .audio(let audio):
            let url = try mediaURL(audio.media, song: song)
            // A sung take at the song's tempo, as every other part alone plays at it; the record
            // and its stems, as they are.
            let stretch = TakePlacement.audio(of: version, in: song)?.stretch(in: song) ?? 1
            let (planar, rate) = try await Task.detached { try TakePlacement.planar(url, stretch: stretch) }.value
            await service.play(planar: planar, sampleRate: rate)
            return audio.duration * stretch
        case .sample(let sample):
            let url = try mediaURL(sample.media, song: song)
            let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: song)?.bars ?? [], tempo: sample.detectedTempo ?? song.tempo)
            let (planar, rate) = try await Task.detached { () -> ([[Float]], Double) in
                let (whole, rate) = try BoothAdapter.planar(url)
                let frames = whole.first?.count ?? 0
                let lower = min(frames, max(0, Int(region.start * rate))), upper = min(frames, max(lower, Int(region.end * rate)))
                return (upper > lower ? whole.map { Array($0[lower..<upper]) } : whole, rate)
            }.value
            await service.play(planar: planar, sampleRate: rate, through: sample.degradation)
            return Double(planar.first?.count ?? 0) / rate
        case .lyric, .sound, .analysis, .mix:
            return 0
        }
    }

    @discardableResult
    public func play(_ groove: Groove, machine: SynthMachine, clock: TransportClock) async -> Double {
        await service.play(groove: groove, machine: machine, tempo: clock.tempo, timeSignature: clock.timeSignature, through: groove.degradation)
        return Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature) + 0.5
    }

    @discardableResult
    public func play(_ notes: [NoteEvent], sound: String?, clock: TransportClock) async -> Double {
        let voice = BassVoiceSpec.all.first { $0.id == sound } ?? .finger
        if await service.currentBassID != voice.id { try? await service.prepare(bass: voice) }
        let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature)
        await service.playBass(BasslinePlayer.hits(for: Bassline(notes: notes, sound: sound), on: timeline, offsetBeats: 0))
        return clock.seconds(forBeat: notes.map { $0.start + $0.duration }.max() ?? 0) + 0.5
    }

    /// A groove on its chop's slices, once, through its own dust. Nil when the chop cannot be read,
    /// and the caller plays it on a machine instead.
    func play(_ groove: Groove, on chop: SongPlayback.ChopTrack, clock: TransportClock) async -> Double? {
        do {
            let prepared = try await Task.detached { try ChopGroove.prepare(chop) }.value
            let played = try ChopGroove.perform(groove, on: prepared, tempo: clock.tempo,
                                                timeSignature: clock.timeSignature, passes: 1)
            let seconds = Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature) + Dust.tail
            let dry = try await service.bounce(played.hits, chop: played.kit, seconds: seconds)
            await service.play(planar: dry.planar, sampleRate: dry.sampleRate, through: groove.degradation)
            return seconds
        } catch {
            return nil
        }
    }

    /// A part's pitched instrument — its own pick, else the song's — loaded.
    @discardableResult
    func prepareInstrument(in song: Song?, for part: PartID? = nil) async -> InstrumentVoiceSpec {
        let spec = song.map { InstrumentVoiceSpec.preset(id: SongPlayback.instrumentID(for: part, in: $0)) ?? .rhodes } ?? .rhodes
        return await prepare(spec)
    }

    private func prepare(_ spec: InstrumentVoiceSpec) async -> InstrumentVoiceSpec {
        if await service.currentInstrumentID != spec.id { try? await service.prepare(instrument: spec) }
        return spec
    }

    /// A melody on a named instrument, at its written beats: what a Piano roll in melody mode plays.
    @discardableResult
    public func playOnInstrument(_ notes: [NoteEvent], instrument: String, clock: TransportClock) async -> Double {
        _ = await prepare(InstrumentVoiceSpec.preset(id: instrument) ?? .rhodes)
        return await playHeld(notes, clock: clock)
    }

    /// A melody on its part's instrument, at its written beats.
    @discardableResult
    public func playOnInstrument(_ notes: [NoteEvent], in song: Song?, for part: PartID? = nil,
                                 clock: TransportClock) async -> Double {
        _ = await prepareInstrument(in: song, for: part)
        return await playHeld(notes, clock: clock)
    }

    private func playHeld(_ notes: [NoteEvent], clock: TransportClock) async -> Double {
        let hits = notes.map { note in
            VoiceSampler.Hit(note: note.pitch.midi, velocity: note.velocity,
                             at: clock.seconds(forBeat: note.start),
                             duration: clock.seconds(forBeat: note.duration))
        }
        await service.playInstrument(hits)
        return clock.seconds(forBeat: notes.map { $0.start + $0.duration }.max() ?? 0) + 0.5
    }

    @discardableResult
    public func play(_ progression: Progression, in song: Song?, for part: PartID? = nil,
                     clock: TransportClock) async -> Double {
        _ = await prepareInstrument(in: song, for: part)
        await service.playInstrument(Self.hits(for: progression, clock: clock))
        return clock.seconds(forBeat: progression.bars.reduce(0) { $0 + $1.beats }) + 0.5
    }

    /// Every chord as held notes from the beat it starts on.
    ///
    /// The voicing itself is `Performance.Voicing`, not a rule of its own: this is the audition,
    /// and the transport plays the same progression through `KeysPlayer`. Two voicings of one
    /// chord would mean the Chords surface and the song disagreed about what you wrote.
    public nonisolated static func hits(for progression: Progression, clock: TransportClock) -> [VoiceSampler.Hit] {
        Voicing.notes(for: progression).map { note in
            VoiceSampler.Hit(note: note.pitch.midi, velocity: note.velocity,
                             at: clock.seconds(forBeat: note.start),
                             duration: clock.seconds(forBeat: note.duration))
        }
    }

    private func mediaURL(_ media: MediaRef, song: Song) throws -> URL {
        guard let store = app.store else { throw MashupError.noLibrary }
        return try store.mediaURL(for: media, song: song.id)
    }
}
