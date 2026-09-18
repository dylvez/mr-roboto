import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph

/// What the transport would play, as a plain value.
///
/// The transport bar has always looked like a player: play, stop, loop, the key and tempo, the
/// section strip. It was not one. `AppState` started a `TransportClock` and nothing was ever
/// scheduled against it, so pressing play moved a boolean and made a sound exactly as often as
/// pressing it did nothing. Surfaces auditioned; the song did not play.
///
/// This is the missing half, and it is deliberately a *value* computed from the song graph before
/// any audio is touched, for three reasons:
///
/// * it is what makes "nothing playable" an answer rather than a silent no-op — a song with a lyric
///   and a progression in it has nothing Gate A can sound, and the transport should say which;
/// * it decides **what** to play without knowing **how**, so the decision is testable on a machine
///   with no audio device (`TransportPlanTests`), which is every machine this is built on;
/// * it is the same shape whether the song has a groove, an audio take, stems, or all three.
///
/// The rule it encodes, in order:
///
/// 1. **A groove** — the newest `.groove` version — plays through `GroovePlayer` into the shared
///    `VoiceSampler`, on the machine the song's newest `.sound` part names (the 808 if it names
///    none). That is the same engine and the same sampler a Grid step auditions through.
/// 2. **Audio** — the separated stems if the song has them, otherwise the imported take. Stems
///    rather than the take when both exist, because they *are* the take: playing both would play
///    the record twice.
/// 3. **Both together**, at the song's tempo and meter, when it has both.
public struct SongPlayback: Equatable, Sendable {

    /// One audio file, placed on the transport's timeline.
    public struct Track: Equatable, Sendable, Identifiable {
        /// The part version this came from, so the ledger and the transport agree about what is
        /// sounding.
        public var version: VersionID
        /// "Record", "Drums stem" — `PartLabel.title`, so it reads the way the ledger reads.
        public var name: String
        public var url: URL
        /// Transport seconds at which this file's first frame sounds. `Audio.alignmentOffset` when
        /// the record carries one, 0 when it does not.
        public var startsAt: Double
        public var duration: Double

        public var id: VersionID { version }

        public init(version: VersionID, name: String, url: URL,
                    startsAt: Double = 0, duration: Double = 0) {
            self.version = version
            self.name = name
            self.url = url
            self.startsAt = max(0, startsAt)
            self.duration = duration
        }
    }

    /// A dusty chop, placed on the transport: its bar of the record, looped from transport zero,
    /// through its own chain.
    public struct ChopTrack: Equatable, Sendable, Identifiable {
        public var version: VersionID
        public var name: String
        /// The media the chop was cut from.
        public var url: URL
        /// The span of that media the chop covers, in the media's own seconds.
        public var region: SongGraph.TimeRange
        /// The chain it plays through, first pass nearest the media. Never empty: a dry chop is
        /// the lane's raw material and is not put on the transport.
        public var passes: [Degradation]

        public var id: VersionID { version }

        public init(version: VersionID, name: String, url: URL, region: SongGraph.TimeRange,
                    passes: [Degradation]) {
            self.version = version
            self.name = name
            self.url = url
            self.region = region
            self.passes = passes
        }
    }

    /// Why there is nothing to play. Non-nil exactly when `isPlayable` is false.
    public struct Silence: Equatable, Sendable {
        /// The line the transport shows: short, and about this song.
        public var headline: String
        /// The quieter second line: what would make it playable.
        public var detail: String

        public init(headline: String, detail: String) {
            self.headline = headline
            self.detail = detail
        }
    }

    public var tempo: Double
    public var timeSignature: TimeSignature
    /// The pattern, if the song has one.
    public var groove: Groove?
    public var grooveVersion: VersionID?
    /// The chain the groove plays through. Empty plays it live on the shared sampler, as it always
    /// did; non-empty bounces it and plays the bounce through these passes.
    public var grooveChain: [Degradation]
    /// The song's dusty chop, when its newest chop has been dirtied.
    public var chop: ChopTrack?
    /// The drum machine the groove is played on: a `SynthMachine.id`.
    public var machine: String
    public var tracks: [Track]
    public var silence: Silence?
    /// Whether playback repeats. The frame's own loop flag, carried into the plan so the sources
    /// honour it rather than the flag being a light that nothing reads.
    public var loops: Bool
    /// The song's length in bars, when its sections say. With the loop off a groove plays this many
    /// bars and stops; with it on, it plays until you stop it.
    public var lengthInBars: Int?

    public init(tempo: Double = 120, timeSignature: TimeSignature = .fourFour,
                groove: Groove? = nil, grooveVersion: VersionID? = nil,
                machine: String = SynthMachine.tr808.id,
                tracks: [Track] = [], silence: Silence? = nil,
                loops: Bool = false, lengthInBars: Int? = nil,
                chop: ChopTrack? = nil) {
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.groove = groove
        self.grooveVersion = grooveVersion
        self.grooveChain = groove?.degradation ?? []
        self.chop = chop
        self.machine = machine
        self.tracks = tracks
        self.silence = silence
        self.loops = loops
        self.lengthInBars = lengthInBars
    }

    /// The same plan with the frame's loop flag applied.
    public func looping(_ loops: Bool) -> SongPlayback {
        var copy = self
        copy.loops = loops
        return copy
    }

    public var isPlayable: Bool { groove != nil || !tracks.isEmpty || chop != nil }

    /// How many of the engine's player nodes the plan's dusty sources take: one for a bounced
    /// groove, one for a chop. The audio tracks get what is left.
    public var dustyPlayers: Int { (groove != nil && !grooveChain.isEmpty ? 1 : 0) + (chop != nil ? 1 : 0) }

    /// What the transport bar says it is playing: "Groove · 4 stems", "Record", "Groove · sp1200".
    public var summary: String {
        var pieces: [String] = []
        if groove != nil {
            pieces.append(grooveChain.isEmpty ? "Groove" : "Groove · \(Dust.describe(grooveChain))")
        }
        if let chop { pieces.append("\(chop.name) · \(Dust.describe(chop.passes))") }
        if tracks.count == 1 { pieces.append(tracks[0].name) }
        else if tracks.count > 1 { pieces.append("\(tracks.count) stems") }
        return pieces.isEmpty ? (silence?.headline ?? "Nothing to play") : pieces.joined(separator: " · ")
    }

    /// The longest thing in the plan, in seconds; nil when only a groove is playing, because a
    /// groove loops until you stop it.
    public var audioDuration: Double? {
        let ends = tracks.map { $0.startsAt + $0.duration }.filter { $0 > 0 }
        return ends.max()
    }

    // MARK: Deciding what to play

    /// Reads the song graph and says what the transport would play.
    ///
    /// - Parameters:
    ///   - song: the open song. Nil is a legitimate answer, not an error.
    ///   - maximumTracks: how many audio files can be scheduled at once. The engine has a fixed
    ///     number of player nodes and there is no point planning a fifth.
    ///   - mediaURL: resolves a `MediaRef` to a file that is actually on disk. A stem whose media is
    ///     missing from the package is *not* playable, and saying so is better than scheduling
    ///     silence.
    public static func plan(for song: Song?,
                            maximumTracks: Int = 4,
                            mediaURL: (MediaRef) -> URL?) -> SongPlayback {
        guard let song else {
            return SongPlayback(silence: Silence(headline: "No song open",
                                                 detail: "Open a song from the library and the transport plays it."))
        }

        var plan = SongPlayback(tempo: song.tempo, timeSignature: song.timeSignature)
        plan.machine = machineID(in: song)
        plan.lengthInBars = song.lengthInBars > 0 ? song.lengthInBars : nil

        if let version = Guidance.grooves(in: song).last, case .groove(let groove) = version.kind,
           groove.patterns.contains(where: { $0.steps.contains { $0 != .rest } }) {
            plan.groove = groove
            plan.grooveVersion = version.id
            plan.grooveChain = groove.degradation
        }

        // A dusty chop. Only the newest chop, and only when it has been dirtied: a clean chop is the
        // lane's raw material, but a dirtied one is a sound decision about the song, and the one move
        // this app's first idiom is built around. It stands in for the audio it was cut from — the
        // drums stem and a loop of one of its bars together would be the drums twice, for the same
        // reason the stems stand in for the take.
        var missingMedia = false
        var shadowed: MediaRef?
        if let version = Guidance.samples(in: song).last, case .sample(let sample) = version.kind,
           !sample.degradation.isEmpty {
            if let url = mediaURL(sample.media) {
                let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: song)?.bars ?? [],
                                                    tempo: sample.detectedTempo ?? song.tempo)
                plan.chop = ChopTrack(version: version.id, name: PartLabel.title(of: version), url: url,
                                      region: region, passes: sample.degradation)
                shadowed = sample.media
            } else {
                missingMedia = true
            }
        }

        // Stems rather than the take when both exist: the stems *are* the take.
        let stems = Guidance.stems(in: song)
        let audioVersions = (stems.isEmpty ? [Guidance.take(in: song)].compactMap { $0 } : stems)
            .filter { Guidance.audio(of: $0)?.media != shadowed }
        for version in audioVersions.prefix(max(0, maximumTracks - plan.dustyPlayers)) {
            guard let audio = Guidance.audio(of: version) else { continue }
            guard let url = mediaURL(audio.media) else { missingMedia = true; continue }
            plan.tracks.append(Track(version: version.id,
                                     name: PartLabel.title(of: version),
                                     url: url,
                                     startsAt: audio.alignmentOffset ?? 0,
                                     duration: audio.duration))
        }

        if !plan.isPlayable {
            plan.silence = silence(for: song, audioVersions: audioVersions, missingMedia: missingMedia)
        }
        return plan
    }

    /// The song's own drum machine, from its newest `.sound` part. A song that has never opened the
    /// Sound surface plays its groove on the 808, which is what a new Grid opens on.
    private static func machineID(in song: Song) -> String {
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind else { continue }
            if SynthMachine.preset(id: sound.instrument) != nil { return sound.instrument }
        }
        return SynthMachine.tr808.id
    }

    /// Why this song cannot be played, in its own terms. Never a shrug: it names what is there and
    /// what would make it sound.
    private static func silence(for song: Song, audioVersions: [PartVersion],
                                missingMedia: Bool) -> Silence {
        if missingMedia || !audioVersions.isEmpty {
            let files = count(audioVersions.count, "file")
            return Silence(headline: "\(song.title)'s audio is missing",
                           detail: "The song refers to \(files) that its package does not hold. "
                               + "Re-import the record, or open Record and drop it again.")
        }
        if song.versions.isEmpty {
            return Silence(headline: "\(song.title) is empty",
                           detail: "Nothing has been made in this song yet. Open Record and drop a file on it.")
        }
        if Guidance.grooves(in: song).isEmpty == false {
            return Silence(headline: "The groove is silent",
                           detail: "\(song.title)'s groove has no hits in it. Paint a step in the Grid and the "
                               + "transport plays it.")
        }
        let kinds = Set(song.versions.map(\.type.rawValue)).sorted().joined(separator: ", ")
        return Silence(headline: "Nothing in \(song.title) plays yet",
                       detail: "It holds \(count(song.versions.count, "version")) (\(kinds)). The transport plays a "
                           + "groove or a recording; chop a bar, or drop a record on Record.")
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

// MARK: - The host

/// Where a playing tick comes from. Polled by the frame while the transport runs, so the position
/// readout, the section strip and the play control all report what the *engine* is doing rather
/// than what was last asked of it.
public struct PlaybackReading: Equatable, Sendable {
    /// Whether the engine's transport is still running.
    public var isRunning: Bool
    /// Transport seconds. 0 before the first render.
    public var seconds: Double
    /// Hits the groove player has handed to the sampler since the transport started. The cheapest
    /// honest proof that something is actually being scheduled, and what the tests assert on.
    public var scheduledHits: Int

    public init(isRunning: Bool, seconds: Double, scheduledHits: Int = 0) {
        self.isRunning = isRunning
        self.seconds = seconds
        self.scheduledHits = scheduledHits
    }

    public static let stopped = PlaybackReading(isRunning: false, seconds: 0)
}

/// What actually schedules a plan. `LiveSongPlayer` is the app's, built around the one
/// `AuditionService` — the same engine and the same sampler the surfaces audition through, because
/// two graphs contending for one output device is the bug this whole layer exists to avoid.
///
/// Not main-actor: the implementation lives on `@AudioActor` with the rest of the audio. The frame
/// only ever awaits it.
public protocol SongPlaybackHost: AnyObject, Sendable {
    /// Prepare everything the plan names and hand it to the engine's transport. Throws if the graph
    /// cannot be built or the media cannot be read — the frame turns that into `.unavailable`.
    func begin(_ plan: SongPlayback, clock: TransportClock) async throws
    /// Stop and give the graph back. Never throws: stopping is always allowed.
    func end() async
    /// Where playback is now.
    func reading() async -> PlaybackReading
}
