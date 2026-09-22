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
/// * it is what makes "nothing playable" an answer rather than a silent no-op — a song holding only
///   a lyric has nothing that can be sounded, and the transport should say which;
/// * it decides **what** to play without knowing **how**, so the decision is testable on a machine
///   with no audio device (`TransportPlanTests`), which is every machine this is built on;
/// * it is the same shape whether the song has a groove, an audio take, stems, or all three.
///
/// The rule it encodes, in order:
///
/// 1. **A groove** — the newest `.groove` version — plays through `GroovePlayer` into the shared
///    `VoiceSampler`, on the machine the song's newest `.sound` part names (the 808 if it names
///    none). That is the same engine and the same sampler a Grid step auditions through.
/// 2. **A bass line**, on its own sampler, through the voice the line names.
/// 3. **The chords and the tune** — the newest `.progression` and the newest `.melody` — on the
///    song's one pitched instrument, the `InstrumentVoiceSpec` its newest `.sound` part names.
/// 4. **Audio** — the separated stems if the song has them, otherwise the imported take. Stems
///    rather than the take when both exist, because they *are* the take: playing both would play
///    the record twice.
/// 5. **All of it together**, at the song's tempo and meter.
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
        /// The part the version belongs to: which strip it plays through (M6).
        public var part: PartID?

        public var id: VersionID { version }

        public init(version: VersionID, name: String, url: URL,
                    startsAt: Double = 0, duration: Double = 0, part: PartID? = nil) {
            self.version = version
            self.name = name
            self.url = url
            self.startsAt = max(0, startsAt)
            self.duration = duration
            self.part = part
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
        /// The part the chop belongs to: which strip it plays through (M6).
        public var part: PartID?

        public var id: VersionID { version }

        public init(version: VersionID, name: String, url: URL, region: SongGraph.TimeRange,
                    passes: [Degradation], part: PartID? = nil) {
            self.version = version
            self.name = name
            self.url = url
            self.region = region
            self.passes = passes
            self.part = part
        }
    }

    /// One section of an arranged song, placed on the transport: its bars, and what its stitch
    /// plays through them.
    ///
    /// The unarranged plan above plays the song's *newest* of everything, looping. A song with
    /// sections plays *these* — the versions the section names, for the bars it says — one after
    /// another, so a verse and a hook can hold different grooves and the form is what you hear.
    public struct Segment: Equatable, Sendable, Identifiable {
        public var section: SectionID
        public var name: String
        /// The bar of the song this section starts on, 0-based.
        public var startBar: Int
        public var lengthInBars: Int
        public var groove: Groove?
        public var grooveVersion: VersionID?
        public var grooveChain: [Degradation]
        public var bassline: Bassline?
        public var basslineVersion: VersionID?
        public var bassSound: String?
        /// The chords the section holds, and the tune over them. Both play on the song's one
        /// pitched instrument, which is why neither carries a sound of its own.
        public var progression: Progression?
        public var progressionVersion: VersionID?
        public var melody: Melody?
        public var melodyVersion: VersionID?
        public var chop: ChopTrack?
        /// Which strips the section's groove, bass line, chords and tune play through (M6).
        public var groovePart: PartID?
        public var basslinePart: PartID?
        public var progressionPart: PartID?
        public var melodyPart: PartID?

        public var id: SectionID { section }

        public init(section: SectionID, name: String, startBar: Int, lengthInBars: Int,
                    groove: Groove? = nil, grooveVersion: VersionID? = nil,
                    bassline: Bassline? = nil, basslineVersion: VersionID? = nil, bassSound: String? = nil,
                    chop: ChopTrack? = nil) {
            self.section = section
            self.name = name
            self.startBar = startBar
            self.lengthInBars = max(1, lengthInBars)
            self.groove = groove
            self.grooveVersion = grooveVersion
            self.grooveChain = groove?.degradation ?? []
            self.bassline = bassline
            self.basslineVersion = basslineVersion
            self.bassSound = bassSound
            self.chop = chop
        }

        /// Whether anything in this section makes a sound. A section stitched from nothing is a
        /// rest of its own length, which is a legitimate thing for a form to hold.
        public var isSounding: Bool {
            groove != nil || bassline != nil || chop != nil || progression != nil || melody != nil
        }
        public var endBar: Int { startBar + lengthInBars }
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
    /// The song's newest bass line, and the voice it plays through (`BassVoiceSpec.id`).
    public var bassline: Bassline?
    public var basslineVersion: VersionID?
    public var bassSound: String?
    /// The song's newest chords and newest tune, and the pitched instrument both play on: an
    /// `InstrumentVoiceSpec.id`. One instrument, because a song names one — the Sound surface's
    /// pick is "for the chords and the tune".
    public var progression: Progression?
    public var progressionVersion: VersionID?
    public var melody: Melody?
    public var melodyVersion: VersionID?
    public var instrument: String
    public var tracks: [Track]
    /// M6: the strips the flat plan's parts play through, and the mix itself.
    public var groovePart: PartID?
    public var basslinePart: PartID?
    public var progressionPart: PartID?
    public var melodyPart: PartID?
    /// The newest mix version, or nil for unity.
    public var mix: Mix?
    public var mixVersion: VersionID?
    /// The song's sections in order, when it has any with something stitched into them. Non-empty
    /// means the transport plays the *form*: the flat fields above are left empty and nothing
    /// loops on its own.
    public var segments: [Segment]
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
                instrument: String = InstrumentVoiceSpec.rhodes.id,
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
        self.instrument = instrument
        self.tracks = tracks
        self.segments = []
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

    public var isPlayable: Bool {
        groove != nil || !tracks.isEmpty || chop != nil || bassline != nil || progression != nil
            || melody != nil || segments.contains(where: \.isSounding)
    }

    /// Whether the transport is playing sections in order rather than the newest of everything.
    public var isArranged: Bool { !segments.isEmpty }

    /// How many of the engine's player nodes the plan's dusty sources take: one for a bounced
    /// groove, one for a chop. The audio tracks get what is left. An arranged song's dusty
    /// sections share one node each, because sections never sound at once.
    public var dustyPlayers: Int {
        if isArranged {
            return (segments.contains { $0.groove != nil && !$0.grooveChain.isEmpty } ? 1 : 0)
                + (segments.contains { $0.chop != nil } ? 1 : 0)
        }
        return (groove != nil && !grooveChain.isEmpty ? 1 : 0) + (chop != nil ? 1 : 0)
    }

    /// Every part this plan sounds, in transport order, deduplicated: one strip each.
    ///
    /// The Mixer draws these and `MixGraph.reserve` claims a slot for each before the transport
    /// connects anything, so which parts get a fader is the plan's own order rather than whichever
    /// source happened to be scheduled first.
    public var parts: [PartID] {
        var seen = Set<PartID>()
        var out: [PartID] = []
        func add(_ part: PartID?) {
            guard let part, seen.insert(part).inserted else { return }
            out.append(part)
        }
        add(groovePart)
        add(basslinePart)
        add(progressionPart)
        add(melodyPart)
        add(chop?.part)
        for track in tracks { add(track.part) }
        for segment in segments {
            add(segment.groovePart)
            add(segment.basslinePart)
            add(segment.progressionPart)
            add(segment.melodyPart)
            add(segment.chop?.part)
        }
        return out
    }

    /// The form's length in seconds, when the plan is arranged: what one pass takes and, with the
    /// loop on, how often it comes round.
    public var formSeconds: Double? {
        guard isArranged, let bars = lengthInBars, tempo > 0 else { return nil }
        return Double(bars * timeSignature.beatsPerBar) * 60 / tempo
    }

    /// What the transport bar says it is playing: "Groove · 4 stems", "Record", "Groove · sp1200".
    public var summary: String {
        var pieces: [String] = []
        if isArranged {
            pieces.append("\(segments.count) section\(segments.count == 1 ? "" : "s")")
            if segments.contains(where: { $0.groove != nil }) { pieces.append("Groove") }
            if segments.contains(where: { $0.bassline != nil }) { pieces.append("Bass") }
            if segments.contains(where: { $0.progression != nil }) { pieces.append("Chords") }
            if segments.contains(where: { $0.melody != nil }) { pieces.append("Tune") }
            if let chop = segments.first(where: { $0.chop != nil })?.chop { pieces.append(chop.name) }
            return pieces.joined(separator: " · ")
        }
        if groove != nil {
            pieces.append(grooveChain.isEmpty ? "Groove" : "Groove · \(Dust.describe(grooveChain))")
        }
        if bassline != nil { pieces.append("Bass") }
        if progression != nil { pieces.append("Chords") }
        if melody != nil { pieces.append("Tune") }
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
        plan.instrument = instrumentID(in: song)
        plan.lengthInBars = song.lengthInBars > 0 ? song.lengthInBars : nil
        if let version = Guidance.mixes(in: song).last, case .mix(let mix) = version.kind {
            plan.mix = mix
            plan.mixVersion = version.id
        }

        // Arranged: the sections say what plays, and in what order. Sections that name nothing
        // fall through to the newest-of-everything plan below, with the form's length still
        // bounding it, which is what the sections meant before anything could be stitched.
        var missingMedia = false
        if song.sections.contains(where: { !$0.stitch.isEmpty }) {
            plan.segments = segments(of: song, mediaURL: mediaURL, missingMedia: &missingMedia)
            if !plan.isPlayable {
                plan.silence = missingMedia
                    ? silence(for: song, audioVersions: [], missingMedia: true)
                    : Silence(headline: "\(song.title)'s sections play nothing yet",
                              detail: "Open Structure and stitch a groove, a bass line or a dusty chop into a section.")
            }
            return plan
        }

        if let version = Guidance.grooves(in: song).last, case .groove(let groove) = version.kind,
           groove.patterns.contains(where: { $0.steps.contains { $0 != .rest } }) {
            plan.groove = groove
            plan.grooveVersion = version.id
            plan.grooveChain = groove.degradation
            plan.groovePart = version.partID
        }

        // The newest bass line, on its own sampler, alongside the groove.
        if let version = Guidance.basslines(in: song).last, case .bassline(let bassline) = version.kind,
           !bassline.notes.isEmpty {
            plan.bassline = bassline
            plan.basslineVersion = version.id
            plan.bassSound = bassline.sound
            plan.basslinePart = version.partID
        }

        // The newest chords and the newest tune, both on the song's one pitched instrument. Before
        // this they were the two kinds you could write, keep, see drawn and audition — and never
        // hear in the song, because the transport had no way to sound a pitched part at all.
        if let version = Guidance.progressions(in: song).last, case .progression(let progression) = version.kind,
           !progression.chords.isEmpty {
            plan.progression = progression
            plan.progressionVersion = version.id
            plan.progressionPart = version.partID
        }

        if let version = Guidance.melodies(in: song).last, case .melody(let melody) = version.kind,
           !melody.notes.isEmpty {
            plan.melody = melody
            plan.melodyVersion = version.id
            plan.melodyPart = version.partID
        }

        // A dusty chop. Only the newest chop, and only when it has been dirtied: a clean chop is the
        // lane's raw material, but a dirtied one is a sound decision about the song, and the one move
        // this app's first idiom is built around. It stands in for the audio it was cut from — the
        // drums stem and a loop of one of its bars together would be the drums twice, for the same
        // reason the stems stand in for the take.
        var shadowed: MediaRef?
        if let version = Guidance.samples(in: song).last, case .sample(let sample) = version.kind,
           !sample.degradation.isEmpty {
            if let chop = chopTrack(version, sample, in: song, mediaURL: mediaURL) {
                plan.chop = chop
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
                                     duration: audio.duration,
                                     part: version.partID))
        }

        if !plan.isPlayable {
            plan.silence = silence(for: song, audioVersions: audioVersions, missingMedia: missingMedia)
        }
        return plan
    }

    /// A dirtied chop on the transport, or nil when its media is not in the package.
    private static func chopTrack(_ version: PartVersion, _ sample: Sample, in song: Song,
                                  mediaURL: (MediaRef) -> URL?) -> ChopTrack? {
        guard let url = mediaURL(sample.media) else { return nil }
        let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: song)?.bars ?? [],
                                            tempo: sample.detectedTempo ?? song.tempo)
        return ChopTrack(version: version.id, name: PartLabel.title(of: version), url: url,
                         region: region, passes: sample.degradation, part: version.partID)
    }

    /// The sections as segments. Each section's stitch is read for the groove, the bass line, the
    /// chords, the tune and the dirtied chop it names — the five things the transport can sound.
    /// Anything else in it, an analysis or a sound pick, is not a thing that sounds and is left to
    /// the surfaces that draw it. A stem in a stitch is not played either: the record does not run
    /// to the form.
    ///
    /// Where a stitch names two of a kind the last wins, as it always has: a `Segment` holds one
    /// of each, and a section playing two grooves at once is not a form, it is a mistake.
    static func segments(of song: Song, mediaURL: (MediaRef) -> URL?, missingMedia: inout Bool) -> [Segment] {
        var out: [Segment] = []
        var bar = 0
        for section in song.sections {
            var segment = Segment(section: section.id, name: section.name, startBar: bar,
                                  lengthInBars: section.lengthInBars)
            for id in section.stitch {
                guard let version = song.version(id) else { continue }
                switch version.kind {
                case .groove(let groove) where groove.patterns.contains(where: { $0.steps.contains { $0 != .rest } }):
                    segment.groove = groove
                    segment.grooveVersion = version.id
                    segment.grooveChain = groove.degradation
                    segment.groovePart = version.partID
                case .bassline(let line) where !line.notes.isEmpty:
                    segment.bassline = line
                    segment.basslineVersion = version.id
                    segment.bassSound = line.sound
                    segment.basslinePart = version.partID
                case .progression(let progression) where !progression.chords.isEmpty:
                    segment.progression = progression
                    segment.progressionVersion = version.id
                    segment.progressionPart = version.partID
                case .melody(let melody) where !melody.notes.isEmpty:
                    segment.melody = melody
                    segment.melodyVersion = version.id
                    segment.melodyPart = version.partID
                case .sample(let sample) where !sample.degradation.isEmpty:
                    if let chop = chopTrack(version, sample, in: song, mediaURL: mediaURL) {
                        segment.chop = chop
                    } else {
                        missingMedia = true
                    }
                default:
                    break
                }
            }
            out.append(segment)
            bar = segment.endBar
        }
        return out
    }

    /// The song's own drum machine, from its newest `.sound` part. A song that has never opened the
    /// Sound surface plays its groove on the 808, which is what a new Grid opens on.
    static func machineID(in song: Song) -> String {
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind else { continue }
            if SynthMachine.preset(id: sound.instrument) != nil { return sound.instrument }
        }
        return SynthMachine.tr808.id
    }

    /// The song's pitched instrument, from its newest `.sound` part that names one. A song that
    /// has never chosen gets the Rhodes, which is the one that suits this app's first idiom.
    static func instrumentID(in song: Song) -> String {
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind else { continue }
            if InstrumentVoiceSpec.preset(id: sound.instrument) != nil { return sound.instrument }
        }
        return InstrumentVoiceSpec.rhodes.id
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
    /// M6: the mix changed, or the playhead moved into another section. A host with no strips
    /// ignores it.
    func mixChanged(_ mix: Mix?, section: SectionID?) async
    /// Parts the graph had no strip left for, known once `begin` has run. They play — straight into
    /// the main mixer — but unmixed, unmetered and un-soloable, which is worth saying out loud
    /// rather than leaving as a fader that does nothing. A host with no strips has none.
    func unmixedParts() async -> [PartID]
}

extension SongPlaybackHost {
    public func mixChanged(_ mix: Mix?, section: SectionID?) async {}
    public func unmixedParts() async -> [PartID] { [] }
}
