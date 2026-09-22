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
    /// One thing sounding: what it plays, the part it belongs to, and the sound it plays on.
    ///
    /// Before this, a `Segment` held at most one groove, one bass line, one progression, one melody
    /// and one chop, and the whole plan held one `instrument` and one `machine`. A pad playing the
    /// chords under a lead playing the tune could not sound together — not because the graph could
    /// not do it, but because there was nowhere in the plan to say it. This is that place.
    ///
    /// `sound` is never nil. The plan has already resolved the part's own pick, then the song's,
    /// then the app's default, so nothing downstream re-derives a default and nothing can end up
    /// playing on a voice the plan did not choose.
    public struct Voice: Equatable, Sendable, Identifiable {

        public enum Play: Equatable, Sendable {
            case groove(Groove)
            case bassline(Bassline)
            case progression(Progression)
            case melody(Melody)
            case chop(ChopTrack)
        }

        public var play: Play
        public var version: VersionID
        /// The part: which strip it plays through, and which sampler holds its kit.
        public var part: PartID?
        /// What the ledger calls it — `PartLabel.title(of:)`.
        public var name: String
        /// A `SynthMachine.id` for a groove, a `BassVoiceSpec.id` for a bass line, an
        /// `InstrumentVoiceSpec.id` for chords and a tune. Empty for a chop, which is audio.
        public var sound: String
        /// The dust it plays through: a groove's chain, a chop's passes. Empty is dry.
        public var chain: [Degradation]

        public var id: VersionID { version }

        public init(play: Play, version: VersionID = VersionID(), part: PartID? = nil,
                    name: String = "", sound: String = "", chain: [Degradation] = []) {
            self.play = play
            self.version = version
            self.part = part
            self.name = name
            self.sound = sound
            self.chain = chain
        }

        // Readers that only ask "is there one of these" — the transport bar's summary, the stem
        // filter, a test — go through these rather than matching the enum.
        public var groove: Groove? { if case .groove(let g) = play { return g } else { return nil } }
        public var bassline: Bassline? { if case .bassline(let b) = play { return b } else { return nil } }
        public var progression: Progression? { if case .progression(let p) = play { return p } else { return nil } }
        public var melody: Melody? { if case .melody(let m) = play { return m } else { return nil } }
        public var chop: ChopTrack? { if case .chop(let c) = play { return c } else { return nil } }

        /// Whether this is a pitched part — the chords or the tune — which share a sampler family.
        public var isPitched: Bool { progression != nil || melody != nil }

        // MARK: Building one

        public static func groove(_ groove: Groove, version: VersionID = VersionID(), part: PartID? = nil,
                                  name: String = "Groove", sound: String = SynthMachine.tr808.id) -> Voice {
            Voice(play: .groove(groove), version: version, part: part, name: name, sound: sound,
                  chain: groove.degradation)
        }

        public static func bassline(_ line: Bassline, version: VersionID = VersionID(), part: PartID? = nil,
                                    name: String = "Bass", sound: String? = nil) -> Voice {
            Voice(play: .bassline(line), version: version, part: part, name: name,
                  sound: sound ?? line.sound ?? BassVoiceSpec.finger.id)
        }

        public static func progression(_ progression: Progression, version: VersionID = VersionID(),
                                       part: PartID? = nil, name: String = "Chords",
                                       sound: String = InstrumentVoiceSpec.rhodes.id) -> Voice {
            Voice(play: .progression(progression), version: version, part: part, name: name, sound: sound)
        }

        public static func melody(_ melody: Melody, version: VersionID = VersionID(), part: PartID? = nil,
                                  name: String = "Tune",
                                  sound: String = InstrumentVoiceSpec.rhodes.id) -> Voice {
            Voice(play: .melody(melody), version: version, part: part, name: name, sound: sound)
        }

        public static func chop(_ chop: ChopTrack) -> Voice {
            Voice(play: .chop(chop), version: chop.version, part: chop.part, name: chop.name,
                  chain: chop.passes)
        }
    }

    /// The unarranged plan above plays the song's *newest* of everything, looping. A song with
    /// sections plays *these* — the versions the section names, for the bars it says — one after
    /// another, so a verse and a hook can hold different grooves and the form is what you hear.
    public struct Segment: Equatable, Sendable, Identifiable {
        public var section: SectionID
        public var name: String
        /// The bar of the song this section starts on, 0-based.
        public var startBar: Int
        public var lengthInBars: Int
        /// Everything this section sounds, in stitch order. A section may hold two grooves, or a
        /// pad on the chords and a lead on the tune; the one-of-each readings below are the first
        /// of a kind, for the callers that only ask whether there is one.
        public var voices: [Voice]

        public var id: SectionID { section }

        public init(section: SectionID, name: String, startBar: Int, lengthInBars: Int,
                    voices: [Voice] = []) {
            self.section = section
            self.name = name
            self.startBar = startBar
            self.lengthInBars = max(1, lengthInBars)
            self.voices = voices
        }

        /// A section with one of each, as the plan used to hold. Kept because most of what builds a
        /// segment by hand — a test, a bounce — really does mean one groove and one bass line.
        public init(section: SectionID, name: String, startBar: Int, lengthInBars: Int,
                    groove: Groove?, grooveVersion: VersionID? = nil,
                    bassline: Bassline? = nil, basslineVersion: VersionID? = nil, bassSound: String? = nil,
                    chop: ChopTrack? = nil) {
            var voices: [Voice] = []
            if let groove { voices.append(.groove(groove, version: grooveVersion ?? VersionID())) }
            if let bassline {
                voices.append(.bassline(bassline, version: basslineVersion ?? VersionID(), sound: bassSound))
            }
            if let chop { voices.append(.chop(chop)) }
            self.init(section: section, name: name, startBar: startBar, lengthInBars: lengthInBars,
                      voices: voices)
        }

        // MARK: One of a kind, for the readers that only ask whether there is one
        //
        // These were stored properties, and a section could hold exactly what they could name. They
        // are the *first* of a kind now: anything that schedules reads `voices`, because a section
        // can hold two of something and playing only the first is the bug this change ends.

        public var groove: Groove? { voices.compactMap(\.groove).first }
        public var grooveVersion: VersionID? { voices.first { $0.groove != nil }?.version }
        public var grooveChain: [Degradation] { voices.first { $0.groove != nil }?.chain ?? [] }
        public var groovePart: PartID? { voices.first { $0.groove != nil }?.part }
        public var bassline: Bassline? { voices.compactMap(\.bassline).first }
        public var basslineVersion: VersionID? { voices.first { $0.bassline != nil }?.version }
        public var bassSound: String? { voices.first { $0.bassline != nil }?.sound }
        public var basslinePart: PartID? { voices.first { $0.bassline != nil }?.part }
        public var progression: Progression? { voices.compactMap(\.progression).first }
        public var progressionVersion: VersionID? { voices.first { $0.progression != nil }?.version }
        public var progressionPart: PartID? { voices.first { $0.progression != nil }?.part }
        public var melody: Melody? { voices.compactMap(\.melody).first }
        public var melodyVersion: VersionID? { voices.first { $0.melody != nil }?.version }
        public var melodyPart: PartID? { voices.first { $0.melody != nil }?.part }
        public var chop: ChopTrack? { voices.compactMap(\.chop).first }

        /// Whether anything in this section makes a sound. A section stitched from nothing is a
        /// rest of its own length, which is a legitimate thing for a form to hold.
        public var isSounding: Bool { !voices.isEmpty }
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
    /// Everything an unarranged song sounds: the newest of each kind it holds, each with the part
    /// it belongs to and the sound it plays on. The one-of-each readings below are the first of a
    /// kind, for the callers that only ask whether there is one.
    public var voices: [Voice]
    /// The song's default drum machine and pitched instrument — a `SynthMachine.id` and an
    /// `InstrumentVoiceSpec.id`. A voice carries its own `sound`, resolved from its part's own pick
    /// and falling back to these; these are what a part that has never chosen plays on.
    public var machine: String
    public var instrument: String
    public var tracks: [Track]
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
                voices: [Voice] = [],
                machine: String = SynthMachine.tr808.id,
                instrument: String = InstrumentVoiceSpec.rhodes.id,
                tracks: [Track] = [], silence: Silence? = nil,
                loops: Bool = false, lengthInBars: Int? = nil) {
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.voices = voices
        self.machine = machine
        self.instrument = instrument
        self.tracks = tracks
        self.segments = []
        self.silence = silence
        self.loops = loops
        self.lengthInBars = lengthInBars
    }

    /// A plan with one of each, as it used to be built by hand. Kept because most of what builds a
    /// plan outside `plan(for:)` — a test, a bounce — really does mean one groove and one chop.
    public init(tempo: Double = 120, timeSignature: TimeSignature = .fourFour,
                groove: Groove?, grooveVersion: VersionID? = nil,
                machine: String = SynthMachine.tr808.id,
                instrument: String = InstrumentVoiceSpec.rhodes.id,
                tracks: [Track] = [], silence: Silence? = nil,
                loops: Bool = false, lengthInBars: Int? = nil,
                chop: ChopTrack? = nil) {
        var voices: [Voice] = []
        if let groove {
            voices.append(.groove(groove, version: grooveVersion ?? VersionID(), sound: machine))
        }
        if let chop { voices.append(.chop(chop)) }
        self.init(tempo: tempo, timeSignature: timeSignature, voices: voices, machine: machine,
                  instrument: instrument, tracks: tracks, silence: silence, loops: loops,
                  lengthInBars: lengthInBars)
    }

    /// The same plan with the frame's loop flag applied.
    public func looping(_ loops: Bool) -> SongPlayback {
        var copy = self
        copy.loops = loops
        return copy
    }

    // MARK: One of a kind, for the readers that only ask whether there is one
    //
    // As on `Segment`: these were stored, and the plan could hold exactly what they could name.
    // Anything that schedules reads `voices`.

    public var groove: Groove? { voices.compactMap(\.groove).first }
    public var grooveVersion: VersionID? { voices.first { $0.groove != nil }?.version }
    public var grooveChain: [Degradation] { voices.first { $0.groove != nil }?.chain ?? [] }
    public var groovePart: PartID? { voices.first { $0.groove != nil }?.part }
    public var bassline: Bassline? { voices.compactMap(\.bassline).first }
    public var basslineVersion: VersionID? { voices.first { $0.bassline != nil }?.version }
    public var bassSound: String? { voices.first { $0.bassline != nil }?.sound }
    public var basslinePart: PartID? { voices.first { $0.bassline != nil }?.part }
    public var progression: Progression? { voices.compactMap(\.progression).first }
    public var progressionVersion: VersionID? { voices.first { $0.progression != nil }?.version }
    public var progressionPart: PartID? { voices.first { $0.progression != nil }?.part }
    public var melody: Melody? { voices.compactMap(\.melody).first }
    public var melodyVersion: VersionID? { voices.first { $0.melody != nil }?.version }
    public var melodyPart: PartID? { voices.first { $0.melody != nil }?.part }
    public var chop: ChopTrack? { voices.compactMap(\.chop).first }

    public var isPlayable: Bool {
        !voices.isEmpty || !tracks.isEmpty || segments.contains(where: \.isSounding)
    }

    /// Whether the transport is playing sections in order rather than the newest of everything.
    public var isArranged: Bool { !segments.isEmpty }

    /// How many of the engine's player nodes the plan's dusty sources take: one for a bounced
    /// groove, one for a chop. The audio tracks get what is left. An arranged song's dusty
    /// sections share one node each, because sections never sound at once.
    public var dustyPlayers: Int {
        // The most that sound at once, not the number of kinds. Sections never overlap, so a form
        // needs one node per kind across them — but a *single* section holding two dusty grooves
        // needs two, and counting kinds would quietly hand it one and drop the other.
        func dusty(_ voices: [Voice]) -> Int {
            voices.count { $0.chop != nil || ($0.groove != nil && !$0.chain.isEmpty) }
        }
        if isArranged { return segments.map { dusty($0.voices) }.max() ?? 0 }
        return dusty(voices)
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
        for voice in voices { add(voice.part) }
        for track in tracks { add(track.part) }
        for segment in segments { for voice in segment.voices { add(voice.part) } }
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
        /// "Groove", "2 grooves" — a kind, and how many of it when a section holds more than one.
        func kinds(_ all: [Voice]) -> [String] {
            [("Groove", all.count { $0.groove != nil }),
             ("Bass", all.count { $0.bassline != nil }),
             ("Chords", all.count { $0.progression != nil }),
             ("Tune", all.count { $0.melody != nil })]
                .filter { $0.1 > 0 }
                .map { $0.1 == 1 ? $0.0 : "\($0.1) \($0.0.lowercased())s" }
        }
        if isArranged {
            pieces.append("\(segments.count) section\(segments.count == 1 ? "" : "s")")
            // The most a single section plays, so a form whose hook doubles the groove says so.
            let busiest = segments.max { kinds($0.voices).count < kinds($1.voices).count }?.voices ?? []
            pieces += kinds(busiest)
            if let chop = segments.compactMap({ $0.chop }).first { pieces.append(chop.name) }
            return pieces.joined(separator: " · ")
        }
        if groove != nil {
            pieces.append(grooveChain.isEmpty ? "Groove" : "Groove · \(Dust.describe(grooveChain))")
        }
        pieces += kinds(voices).filter { $0 != "Groove" }
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
    ///     number of player nodes — see `Engine(playerCount:)` where the app builds it — and there
    ///     is no point planning one more than it holds.
    ///   - mediaURL: resolves a `MediaRef` to a file that is actually on disk. A stem whose media is
    ///     missing from the package is *not* playable, and saying so is better than scheduling
    ///     silence.
    public static func plan(for song: Song?,
                            maximumTracks: Int = 8,
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

        // The newest of every kind that sounds, each resolved to the part it belongs to and the
        // instrument that part plays on. The chords and the tune were the two kinds you could
        // write, keep, see drawn and audition and never hear in the song; now they can also be two
        // different instruments, because each voice carries its own.
        var shadowed: MediaRef?
        for versions in [Guidance.grooves(in: song), Guidance.basslines(in: song),
                         Guidance.progressions(in: song), Guidance.melodies(in: song)] {
            guard let version = versions.last,
                  let voice = voice(for: version, in: song, mediaURL: mediaURL,
                                    missingMedia: &missingMedia) else { continue }
            plan.voices.append(voice)
        }

        // A dusty chop. Only the newest chop, and only when it has been dirtied: a clean chop is the
        // lane's raw material, but a dirtied one is a sound decision about the song, and the one move
        // this app's first idiom is built around. It stands in for the audio it was cut from — the
        // drums stem and a loop of one of its bars together would be the drums twice, for the same
        // reason the stems stand in for the take.
        if let version = Guidance.samples(in: song).last, case .sample(let sample) = version.kind,
           !sample.degradation.isEmpty {
            if let voice = voice(for: version, in: song, mediaURL: mediaURL, missingMedia: &missingMedia) {
                plan.voices.append(voice)
                shadowed = sample.media
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

    /// The sections as segments. Each section's stitch is read for the grooves, bass lines,
    /// chords, tunes and dirtied chops it names — the five things the transport can sound. Anything
    /// else in it, an analysis or a sound pick, is not a thing that sounds and is left to the
    /// surfaces that draw it. A stem in a stitch is not played either: the record does not run to
    /// the form.
    ///
    /// A section that names two of a kind now sounds both. It used to sound the last of them, and
    /// say nothing about the others — which is what made stitching a second bass line look like it
    /// had worked.
    static func segments(of song: Song, mediaURL: (MediaRef) -> URL?, missingMedia: inout Bool) -> [Segment] {
        var out: [Segment] = []
        var bar = 0
        for section in song.sections {
            var voices: [Voice] = []
            for id in section.stitch {
                guard let version = song.version(id) else { continue }
                guard let voice = voice(for: version, in: song, mediaURL: mediaURL,
                                        missingMedia: &missingMedia) else { continue }
                voices.append(voice)
            }
            let segment = Segment(section: section.id, name: section.name, startBar: bar,
                                  lengthInBars: section.lengthInBars, voices: voices)
            out.append(segment)
            bar = segment.endBar
        }
        return out
    }

    /// One version as a thing that sounds, or nil when it is not one.
    ///
    /// The sound is resolved here, against the part, so every voice carries the instrument it will
    /// actually play on and nothing downstream has to work it out again. That is what lets a pad
    /// hold the chords while a lead plays the tune: two parts, two picks, two samplers.
    static func voice(for version: PartVersion, in song: Song, mediaURL: (MediaRef) -> URL?,
                      missingMedia: inout Bool) -> Voice? {
        switch version.kind {
        case .groove(let groove) where groove.patterns.contains(where: { $0.steps.contains { $0 != .rest } }):
            return .groove(groove, version: version.id, part: version.partID,
                           name: PartLabel.title(of: version),
                           sound: machineID(for: version.partID, in: song))
        case .bassline(let line) where !line.notes.isEmpty:
            return .bassline(line, version: version.id, part: version.partID,
                             name: PartLabel.title(of: version), sound: line.sound)
        case .progression(let progression) where !progression.chords.isEmpty:
            return .progression(progression, version: version.id, part: version.partID,
                                name: PartLabel.title(of: version),
                                sound: instrumentID(for: version.partID, in: song))
        case .melody(let melody) where !melody.notes.isEmpty:
            return .melody(melody, version: version.id, part: version.partID,
                           name: PartLabel.title(of: version),
                           sound: instrumentID(for: version.partID, in: song))
        case .sample(let sample) where !sample.degradation.isEmpty:
            if let chop = chopTrack(version, sample, in: song, mediaURL: mediaURL) { return .chop(chop) }
            missingMedia = true
            return nil
        default:
            return nil
        }
    }

    /// The song's own drum machine, from its newest `.sound` part that names one and is *the
    /// song's* — not a part's own. A song that has never opened the Sound surface plays its groove
    /// on the 808, which is what a new Grid opens on.
    static func machineID(in song: Song) -> String {
        sound(in: song, for: nil, recognisedBy: { SynthMachine.preset(id: $0) != nil })
            ?? SynthMachine.tr808.id
    }

    /// The machine a groove part plays on: its own newest pick, then the song's, then the 808.
    static func machineID(for part: PartID?, in song: Song) -> String {
        sound(in: song, for: part, recognisedBy: { SynthMachine.preset(id: $0) != nil })
            ?? machineID(in: song)
    }

    /// The song's pitched instrument, from its newest `.sound` part that names one. A song that
    /// has never chosen gets the Rhodes, which is the one that suits this app's first idiom.
    static func instrumentID(in song: Song) -> String {
        sound(in: song, for: nil, recognisedBy: { InstrumentVoiceSpec.preset(id: $0) != nil })
            ?? InstrumentVoiceSpec.rhodes.id
    }

    /// The instrument a pitched part plays on: its own newest pick, then the song's, then the
    /// Rhodes. This is what lets a pad hold the chords while a lead plays the tune over them —
    /// before it, a song had one pitched instrument and the two shared it.
    static func instrumentID(for part: PartID?, in song: Song) -> String {
        sound(in: song, for: part, recognisedBy: { InstrumentVoiceSpec.preset(id: $0) != nil })
            ?? instrumentID(in: song)
    }

    /// The newest `.sound` belonging to `part` — or to the song itself, when `part` is nil — whose
    /// instrument the given registry recognises.
    ///
    /// The two filters matter in opposite directions. `part` nil must skip a sound that names a
    /// part, or one part's pick would quietly become every part's default; and a sound naming a
    /// part must skip the registries that do not know its id, because the same version list holds
    /// the drum machines and the pitched instruments and they are told apart only by which
    /// registry answers.
    private static func sound(in song: Song, for part: PartID?,
                              recognisedBy known: (String) -> Bool) -> String? {
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind, sound.forPart == part else { continue }
            if known(sound.instrument) { return sound.instrument }
        }
        return nil
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
