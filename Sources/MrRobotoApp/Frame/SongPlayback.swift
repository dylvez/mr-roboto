import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
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
        /// Seconds of the file's head that are not played: what falls before the bar the
        /// transport was started from (`starting(atBar:)`). The file's frame at `skip` is what
        /// sounds at `startsAt`.
        public var skip: Double
        /// How much longer the file plays than it is: a take sung at another tempo, played at the
        /// song's (`Audio.stretch(in:)`). `duration` and `skip` are in the stretched file's seconds.
        public var stretch: Double
        /// The transport seconds the file is heard in, in order: a stem a form names sounds in the
        /// sections that name it and is silent in the rest, while its place along the song runs on.
        /// Nil is the whole file — a take, and everything in a song with no form.
        public var windows: [Range<Double>]? = nil

        public var id: VersionID { version }

        public init(version: VersionID, name: String, url: URL,
                    startsAt: Double = 0, duration: Double = 0, part: PartID? = nil, skip: Double = 0, stretch: Double = 1) {
            self.version = version
            self.name = name
            self.url = url
            self.startsAt = max(0, startsAt)
            self.duration = duration
            self.part = part
            self.skip = max(0, skip)
            self.stretch = stretch
        }
    }

    /// A chop, placed on the transport: its bar of the record, looped from transport zero,
    /// through its own chain.
    public struct ChopTrack: Equatable, Sendable, Identifiable {
        public var version: VersionID
        public var name: String
        /// The media the chop was cut from.
        public var url: URL
        /// The span of that media the chop covers, in the media's own seconds.
        public var region: SongGraph.TimeRange
        /// The chain it plays through, first pass nearest the media. Empty is a dry chop, played
        /// as it was cut.
        public var passes: [Degradation]
        /// The part the chop belongs to: which strip it plays through (M6).
        public var part: PartID?
        /// The cut the Chop lane kept, in the media's own seconds, each labelled with the class its
        /// slice was called. What a groove played on this chop is played on; a looped chop ignores
        /// it. One marker, or none, is a bar that was never cut.
        public var slices: [SliceMarker]
        /// The tempo the chop was cut at, when it was detected.
        public var tempo: Double?
        /// The pads' trims, by slice in `slices` order. A groove on this chop plays them.
        public var pads: [PadTrim]
        /// The level the chop is played at over its media's own (`Sample.gainDB`). Nil is as recorded.
        public var gainDB: Double?

        public var id: VersionID { version }

        /// The bars the chop covers at its own tempo, rounded up. One when its tempo is unknown.
        public func bars(beatsPerBar: Int) -> Int {
            guard let tempo, tempo > 0, beatsPerBar > 0 else { return 1 }
            let bar = Double(beatsPerBar) * 60 / tempo
            return max(1, Int((region.duration / bar - 1e-6).rounded(.up)))
        }

        /// How long a loop of the chop lasts at `songTempo`. A chop that covers whole bars at its
        /// own tempo, near enough — a tracker's bar is never exact — lasts as many of the song's
        /// bars, so the loop lands on the song's downbeats. Any other span keeps its length in
        /// beats. Nil when its tempo is unknown: it plays as it was cut.
        public func loopSeconds(songTempo: Double, beatsPerBar: Int) -> Double? {
            guard let tempo, tempo > 0, songTempo > 0, beatsPerBar > 0 else { return nil }
            let exact = region.duration / (Double(beatsPerBar) * 60 / tempo)
            let whole = exact.rounded()
            if whole >= 1, abs(exact - whole) <= 0.1 * whole {
                return whole * Double(beatsPerBar) * 60 / songTempo
            }
            return region.duration * tempo / songTempo
        }

        public init(version: VersionID, name: String, url: URL, region: SongGraph.TimeRange,
                    passes: [Degradation], part: PartID? = nil, slices: [SliceMarker] = [],
                    tempo: Double? = nil, pads: [PadTrim] = [], gainDB: Double? = nil) {
            self.version = version
            self.name = name
            self.url = url
            self.region = region
            self.passes = passes
            self.part = part
            self.slices = slices
            self.tempo = tempo
            self.pads = pads
            self.gainDB = gainDB
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
        /// The chop a groove plays on instead of a machine: its steps land on the chop's own
        /// slices, the way the Chop lane re-grooved them. `sound` is then `ChopSound.id` of it.
        public var kit: ChopTrack?
        /// A groove's machine as the song has shaped it (`SongPlayback.shaped`): `sound`'s preset
        /// with the voice edits the song has kept. Nil plays the preset.
        public var machine: SynthMachine?

        public var id: VersionID { version }

        public init(play: Play, version: VersionID = VersionID(), part: PartID? = nil,
                    name: String = "", sound: String = "", chain: [Degradation] = [],
                    kit: ChopTrack? = nil, machine: SynthMachine? = nil) {
            self.play = play
            self.version = version
            self.part = part
            self.name = name
            self.sound = sound
            self.chain = chain
            self.kit = kit
            self.machine = machine
        }

        /// The machine a groove plays on: the shaped one the plan resolved, or `sound`'s preset.
        public var drumMachine: SynthMachine { machine ?? SynthMachine.preset(id: sound) ?? .tr808 }

        /// Whether this is played as audio on a player node rather than live on a sampler: a chop,
        /// a groove through dust — the chain is applied to audio — and a groove on a chop, whose
        /// slices are a kit of its own rendered for the pass.
        public var isBounced: Bool {
            chop != nil || (groove != nil && (!chain.isEmpty || kit != nil))
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
                                  name: String = "Groove", sound: String = SynthMachine.tr808.id,
                                  kit: ChopTrack? = nil, machine: SynthMachine? = nil) -> Voice {
            Voice(play: .groove(groove), version: version, part: part, name: name,
                  sound: kit.flatMap { $0.part.map(ChopSound.id(for:)) } ?? sound,
                  chain: groove.degradation, kit: kit, machine: kit == nil ? machine : nil)
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
    /// Whether some audio the song holds was not in its package, and was left out. The song can
    /// still play what remains; an export or release says it went out without it.
    public var missingMedia = false

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

    /// The song bar this plan's transport zero is: 0 for the top, or the bar `starting(atBar:)`
    /// moved it to — negative when the transport counts in before the song's first bar. The frame
    /// adds it back to every reading, so the readout says the song's bar.
    public var startsAtBar: Int = 0

    /// A metronome for the whole of playback: the transport's Click, or the Booth's.
    public var click = false
    /// Bars of click before anything sounds: the Booth's count-in. Always clicked, whatever
    /// `click` says; the parts start when it ends.
    public var countInBars = 0

    /// Transport seconds at which an unarranged song's looping parts start: 0, or the end of a
    /// count-in. An arranged plan places its sections by bar and needs no such thing.
    public var voicesStartAt: Double = 0

    /// The same plan with the frame's click applied.
    public func clicking(_ on: Bool) -> SongPlayback {
        var copy = self
        copy.click = on
        return copy
    }

    /// The same plan from `bar`, with `countIn` bars of click before it. The count-in is played as
    /// the bars *before* the section, so a take sung against it lands where it was sung.
    public func starting(atBar bar: Int, countIn: Int) -> SongPlayback {
        let lead = max(0, countIn)
        var copy = starting(atBar: bar - lead)
        copy.countInBars = lead
        return copy
    }

    /// The same plan from bar `bar` of the song: everything before it dropped, everything after it
    /// moved up so that the bar is transport zero. Playback always began at bar 1, so to hear the
    /// hook you sat through the intro and the verse, and the Booth recorded from bar 1 whatever
    /// section you picked.
    ///
    /// Sections: those over by `bar` go; one straddling it keeps its remaining bars and starts its
    /// parts again from their own first beat (a section boundary, which is what a person picks, is
    /// exact). Takes and the record: moved by the same seconds, and one already sounding at `bar`
    /// is played from that point of the file (`Track.skip`). An unarranged song's voices loop from
    /// their own start whatever the bar, which is what looping means.
    public func starting(atBar bar: Int) -> SongPlayback {
        guard bar != 0 else { return self }
        var copy = self
        copy.startsAtBar = bar
        let clock = TransportClock(tempo: max(1, tempo), timeSignature: timeSignature)
        let offset = clock.seconds(forBar: bar)
        copy.segments = segments.compactMap { segment in
            guard segment.endBar > bar else { return nil }
            var moved = segment
            moved.startBar = max(0, segment.startBar - bar)
            moved.lengthInBars = segment.endBar - max(segment.startBar, bar)
            return moved
        }
        copy.lengthInBars = lengthInBars.map { max(1, $0 - bar) }
        copy.tracks = tracks.compactMap { track in
            var moved = track
            let startsAt = track.startsAt - offset
            if startsAt < 0 {
                let skip = track.skip - startsAt
                guard skip < track.duration else { return nil }
                moved.skip = skip
                moved.startsAt = 0
            } else {
                moved.startsAt = startsAt
            }
            // The sections it sounds in move with it; one over by `bar` is gone, and a stem with
            // none left has nothing to play.
            if let windows = track.windows {
                moved.windows = windows.compactMap { window in
                    let end = window.upperBound - offset
                    return end > 0 ? max(0, window.lowerBound - offset)..<end : nil
                }
                guard moved.windows?.isEmpty == false else { return nil }
            }
            return moved
        }
        // Before the song's first bar there is nothing to play: an unarranged song's loops wait
        // for the song to begin rather than starting under the count-in.
        if bar < 0 { copy.voicesStartAt = voicesStartAt - offset }
        if isArranged, !copy.isPlayable {
            copy.silence = Silence(headline: "Nothing plays from bar \(bar + 1)",
                                   detail: "Every section is over by then. Pick an earlier one, or press play for the top.")
        }
        return copy
    }

    /// Seconds from the song's top to this plan's transport zero.
    public var startOffsetSeconds: Double {
        guard startsAtBar != 0, tempo > 0 else { return 0 }
        return TransportClock(tempo: tempo, timeSignature: timeSignature).seconds(forBar: startsAtBar)
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
            voices.count(where: \.isBounced)
        }
        if isArranged { return segments.map { dusty($0.voices) }.max() ?? 0 }
        return dusty(voices)
    }

    /// The plan's mix with any solo on a part the plan does not sound set aside. A strip left
    /// soloed after its part was taken out of every section silenced the whole song, live and in
    /// export, with the soloed part nowhere to be heard.
    mutating func settingAsideSilentSolos() {
        guard var mix, mix.hasSolo else { return }
        let sounding = Set(parts)
        mix.strips = mix.strips.map { strip in
            var strip = strip
            if strip.isSoloed, !sounding.contains(strip.part) { strip.isSoloed = false }
            return strip
        }
        self.mix = mix
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
        // Plurals are spelled out. "Bass" + "s" is "basss" and "Chords" + "s" is "chordss", which
        // is what a lowercase-and-append rule gives you and what the bar briefly said.
        func kinds(_ all: [Voice]) -> [String] {
            [("Groove", "grooves", all.count { $0.groove != nil }),
             ("Bass", "bass lines", all.count { $0.bassline != nil }),
             ("Chords", "sets of chords", all.count { $0.progression != nil }),
             ("Tune", "tunes", all.count { $0.melody != nil })]
                .filter { $0.2 > 0 }
                .map { $0.2 == 1 ? $0.0 : "\($0.2) \($0.1)" }
        }
        if isArranged {
            pieces.append("\(segments.count) section\(segments.count == 1 ? "" : "s")")
            // The most a single section plays — by how many voices, not how many kinds, so a hook
            // that doubles the groove beats a verse that merely has one of everything.
            let busiest = segments.max { $0.voices.count < $1.voices.count }?.voices ?? []
            pieces += kinds(busiest)
            if let chop = segments.compactMap({ $0.chop }).first { pieces.append(chop.name) }
            // The stems the form names: they are tracks, not a section's voices, and a song that
            // is mostly a record's stems said only "Groove".
            let stems = tracks.filter { $0.windows != nil }
            if stems.count == 1 { pieces.append(stems[0].name) } else if stems.count > 1 { pieces.append("\(stems.count) stems") }
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
        // What is scheduled is the file after its skipped head: a take counted in plays from its
        // own bar, and counting the head as well kept the transport running on silence.
        let ends = tracks.map { $0.startsAt + max(0, $0.duration - $0.skip) }.filter { $0 > 0 }
        return ends.max()
    }

    // MARK: Deciding what to play

    /// The player nodes the transport's engine has, and a bounce's: one per strip the mix graph
    /// can seat (`MixGraph.slotCount`), so a form never has a part it can mix and not play.
    public static let playerNodes = 16

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
                            maximumTracks: Int = SongPlayback.playerNodes,
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
            // What was sung, where it was sung. The record does not run to the form, but a take
            // was recorded *against* the form, on a bar of it, and it plays there. The arranged
            // player lays each bounced part — a chop, a dusty groove, a groove on a chop — on a node
            // of its own for the whole form, and the click takes one more; the rest are for these.
            // This used to assume two, so a form with three chops and six takes would not start.
            let bounced = Set(plan.segments.flatMap { $0.voices.filter(\.isBounced).map { $0.part } }).count
            // A mashup's stems are the song itself, laid on its grid when it was made: they play
            // under the form as takes do. A part added to a mashup used to arrange it, and the
            // arranged plan silenced every stem — the vocal and the backing it was made from.
            plan.tracks = Array((stemTracks(in: song, mediaURL: mediaURL, missingMedia: &missingMedia)
                                 + takeTracks(in: song, mediaURL: mediaURL, missingMedia: &missingMedia))
                                    .prefix(max(0, maximumTracks - bounced - 1)))
            if !plan.isPlayable {
                plan.silence = missingMedia
                    ? silence(for: song, audioVersions: [], missingMedia: true)
                    : Silence(headline: "\(song.title)'s sections play nothing yet",
                              detail: "Open Structure and stitch a groove, a bass line or a chop into a section.")
            }
            plan.settingAsideSilentSolos()
            plan.missingMedia = missingMedia
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

        // The newest chop, dry or dusty. A chop used to play only once it had been dirtied — the
        // clean one was "the lane's raw material" — so cutting a bar was a thing you made and could
        // not hear in the song. It sounds as cut now, and dust is a choice about its sound rather
        // than the gate to hearing it. It stands in for the audio it was cut from: the drums stem
        // and a loop of one of its bars together would be the drums twice, for the same reason the
        // stems stand in for the take.
        if let version = Guidance.samples(in: song).last, case .sample(let sample) = version.kind {
            if plan.voices.contains(where: { $0.kit?.part == version.partID }) {
                // A groove plays this chop's slices: the chop, re-grooved. Its loop under the
                // groove would be the same drums twice, as it would be in a section.
                shadowed = sample.media
            } else if let voice = voice(for: version, in: song, mediaURL: mediaURL, missingMedia: &missingMedia) {
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
            // At the song's tempo, as its chops are: a tempo set since the import used to leave the
            // record and its stems at their own while the chops, grooves and bass moved, and eight
            // bars in they were two beats apart.
            let stretch = recordStretch(of: version, in: song)
            plan.tracks.append(Track(version: version.id,
                                     name: PartLabel.title(of: version),
                                     url: url,
                                     startsAt: (audio.alignmentOffset ?? 0) * stretch,
                                     duration: audio.duration * stretch,
                                     part: version.partID,
                                     stretch: stretch))
        }
        // Then what was sung, on the nodes the record left.
        let room = max(0, maximumTracks - plan.dustyPlayers - plan.tracks.count)
        plan.tracks += takeTracks(in: song, mediaURL: mediaURL, missingMedia: &missingMedia).prefix(room)

        if !plan.isPlayable {
            plan.silence = silence(for: song, audioVersions: audioVersions, missingMedia: missingMedia)
        }
        plan.settingAsideSilentSolos()
        plan.missingMedia = missingMedia
        return plan
    }

    /// The sung parts, placed where they were sung: for every part whose newest version is a take
    /// or a comp, that version. A comp is a version of its takes' part, so a comped part plays the
    /// comp and one still being sung plays its last pass — never every pass at once.
    ///
    /// These were the one kind of audio the transport never played. The Booth recorded them on a
    /// bar, the Takes surface flagged and comped them, and neither the song nor an export ever
    /// sounded them: you could sing a hook and not hear it in the hook.
    static func takeTracks(in song: Song, mediaURL: (MediaRef) -> URL?, missingMedia: inout Bool) -> [Track] {
        let clock = TransportClock(tempo: max(1, song.tempo), timeSignature: song.timeSignature)
        var out: [Track] = []
        for partID in song.partIDs {
            // Graph order, not `latestVersion`: two versions made in the same millisecond — a
            // comp kept straight after its takes — are ordered by id there, and the ledger already
            // counts the graph for the same reason.
            // Placed by its own take or comp, or by the take a corrected version was corrected from:
            // a take with a Check's fix applied used to have neither, and fell silent in the song.
            guard let version = sungVersion(of: partID, in: song),
                  let audio = TakePlacement.audio(of: version, in: song) else { continue }
            guard let url = mediaURL(audio.media) else { missingMedia = true; continue }
            // Where the audio's first frame sits, and where the take itself begins: the bar the
            // Booth was recording for. They differ by a count-in — the audio starts in it, bars
            // before the section — and what plays is the take, not the breath before it.
            // Moved with its section: a take sung to the Hook plays in the Hook wherever the form has
            // put it since, not at the seconds it was sung at. And at the song's tempo: sung at 92
            // and played at 100, it is stretched to 0.92 of its length, its pitch kept.
            // And in its meter: a take sung in 4/4 to the Hook starts on the Hook's first bar in 3/4.
            let placed = TakePlacement.placement(of: audio, in: song, clock: clock)
            let aligned = placed.audio
            let begins = max(0, aligned, placed.take.map { $0 - 0.05 } ?? aligned)
            out.append(Track(version: version.id, name: PartLabel.title(of: version), url: url,
                             startsAt: begins, duration: TakePlacement.duration(of: audio, in: song), part: partID,
                             skip: max(0, begins - aligned), stretch: audio.stretch(in: song)))
        }
        return out
    }

    /// The stems the form names, each laid along the form and heard in the sections that name it.
    ///
    /// A stem runs with the song rather than starting again in each section: a vocal over three
    /// verses is one vocal, and the second verse is where the record had got to. So it is placed
    /// once — a mashup's stem where the mashup laid it, a record's own stem with its first bar on
    /// the form's first, at the song's tempo — and its `windows` are the sections that play it,
    /// neighbours joined so a stem that carries on has no seam.
    ///
    /// A mashup's stems used to play under every section whatever the form said, and a record's
    /// own stems under none: "the drums from bar 3" and "the voice only in the hook" could not be
    /// said, only approached with a level.
    static func stemTracks(in song: Song, mediaURL: (MediaRef) -> URL?, missingMedia: inout Bool) -> [Track] {
        let clock = TransportClock(tempo: max(1, song.tempo), timeSignature: song.timeSignature)
        var order: [PartVersion] = []
        var windows: [PartID: [Range<Double>]] = [:]
        var bar = 0
        for section in song.sections {
            let start = clock.seconds(forBar: bar), end = clock.seconds(forBar: bar + section.lengthInBars)
            bar += section.lengthInBars
            for lane in section.stitch {
                guard let version = song.version(playing: lane), Guidance.audio(of: version)?.role == .stem else { continue }
                if windows[version.partID] == nil { order.append(version) }
                var spans = windows[version.partID] ?? []
                if let last = spans.last, abs(last.upperBound - start) < 1e-6 {
                    spans[spans.count - 1] = last.lowerBound..<end
                } else if end > start {
                    spans.append(start..<end)
                }
                windows[version.partID] = spans
            }
        }
        return order.compactMap { version in
            guard let audio = Guidance.audio(of: version) else { return nil }
            guard let url = mediaURL(audio.media) else { missingMedia = true; return nil }
            var track: Track
            if version.operation == Operation.mashup {
                track = Track(version: version.id, name: PartLabel.title(of: version), url: url,
                              startsAt: audio.alignmentOffset ?? 0, duration: audio.duration, part: version.partID)
            } else {
                // A record's own stem: its first analysed bar on the form's first bar, at the
                // song's tempo, as its chops are.
                let stretch = recordStretch(of: version, in: song)
                let analysis = Guidance.analysis(for: version, in: song)
                let lead = analysis?.bars.first?.start ?? analysis?.downbeats.first ?? 0
                track = Track(version: version.id, name: PartLabel.title(of: version), url: url,
                              startsAt: (audio.alignmentOffset ?? 0) * stretch, duration: audio.duration * stretch,
                              part: version.partID, skip: lead * stretch, stretch: stretch)
            }
            track.windows = windows[version.partID]
            return track
        }
    }

    /// How much longer the record (or a stem of it) plays in the song than it is: the tempo it was
    /// read at over the song's. 1 when its tempo was never read, and when the fit would more than
    /// halve or double it — a tempo read at half or double time is a misreading, not a request, the
    /// rule a chop of the same record follows (`ChopTrack.loopSeconds`, `LiveSongPlayer.fitted`).
    static func recordStretch(of version: PartVersion, in song: Song) -> Double {
        guard let read = Guidance.analysis(for: version, in: song)?.dominantTempo, read > 0, song.tempo > 0 else { return 1 }
        let ratio = read / song.tempo
        guard abs(ratio - 1) > 0.001, ratio > 0.5, ratio < 2 else { return 1 }
        return ratio
    }

    /// The version of a sung part that plays: its newest, except that a take recorded after a comp
    /// is a new candidate for the comp, not a replacement for it. It used to take the comp's place
    /// in the song while the Takes surface still said the comp was current. A restore, or a new
    /// comp, is chosen and plays.
    static func sungVersion(of part: PartID, in song: Song) -> PartVersion? {
        let history = song.versions.filter { $0.partID == part }
        guard let newest = history.last else { return nil }
        guard let comp = history.lastIndex(where: { Guidance.audio(of: $0)?.comp != nil }) else { return newest }
        let since = history[(comp + 1)...]
        return since.allSatisfy({ $0.operation == Operation.recorded }) ? history[comp] : newest
    }

    /// A dirtied chop on the transport, or nil when its media is not in the package.
    private static func chopTrack(_ version: PartVersion, _ sample: Sample, in song: Song,
                                  mediaURL: (MediaRef) -> URL?) -> ChopTrack? {
        guard let url = mediaURL(sample.media) else { return nil }
        let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: song)?.bars ?? [],
                                            tempo: sample.detectedTempo ?? song.tempo)
        return ChopTrack(version: version.id, name: PartLabel.title(of: version), url: url,
                         region: region, passes: sample.degradation, part: version.partID,
                         slices: sample.slices, tempo: sample.detectedTempo, pads: sample.pads, gainDB: sample.gainDB)
    }

    /// The chop a groove part plays on, resolved to what the transport can read: the chop part's
    /// newest version, when its part's newest drum pick is `ChopSound.id` of it. Nil plays the
    /// groove on its machine — no pick, a machine picked since, or a chop the song no longer holds.
    static func kit(for part: PartID?, in song: Song, mediaURL: (MediaRef) -> URL?) -> ChopTrack? {
        guard let part, let chop = ChopSound.part(of: drumSoundID(for: part, in: song)) else { return nil }
        return chopTrack(of: chop, in: song, mediaURL: mediaURL)
    }

    /// A chop part's newest version, as the transport reads it. Nil when the part is not a chop or
    /// its media is not on disk.
    static func chopTrack(of chop: PartID, in song: Song, mediaURL: (MediaRef) -> URL?) -> ChopTrack? {
        guard let version = song.versions.last(where: { $0.partID == chop }),
              case .sample(let sample) = version.kind else { return nil }
        return chopTrack(version, sample, in: song, mediaURL: mediaURL)
    }

    /// The sections as segments. Each section's stitch is read for the grooves, bass lines,
    /// chords, tunes and dirtied chops it names — the five things the transport can sound. Anything
    /// else in it, an analysis or a sound pick, is not a thing that sounds and is left to the
    /// surfaces that draw it. A stem in a stitch is not a voice of its section: it runs along the
    /// form on a track of its own, heard where it is named (`stemTracks`).
    ///
    /// A section that names two of a kind now sounds both. It used to sound the last of them, and
    /// say nothing about the others — which is what made stitching a second bass line look like it
    /// had worked.
    static func segments(of song: Song, mediaURL: (MediaRef) -> URL?, missingMedia: inout Bool) -> [Segment] {
        var out: [Segment] = []
        var bar = 0
        for (index, section) in song.sections.enumerated() {
            var voices: [Voice] = []
            for lane in section.stitch {
                // What the lane plays *now*: its part's newest version, unless it is pinned. This
                // is the point of the whole change — keep a new groove and the form plays it.
                guard let version = song.version(playing: lane) else { continue }
                guard var voice = voice(for: version, in: song, mediaURL: mediaURL,
                                        missingMedia: &missingMedia) else { continue }
                // A groove on a kit is played to the section's edges: a fill into the next section,
                // a crash coming out of the last. A groove on a chop is left as cut — its "toms" are
                // slices of a record, and a fill made of them would be noise. A section that says
                // how it leaves or enters is taken at its word: a build runs its roll to the bar
                // line, and a fill down the toms over the last of it would be the roll stopping.
                if song.playsFills, voice.kit == nil, case .groove(let groove) = voice.play {
                    voice.play = .groove(SectionFill.arranged(
                        groove, bars: section.lengthInBars, beatsPerBar: song.timeSignature.beatsPerBar,
                        fillIntoNext: index < song.sections.count - 1 && fills(out: section),
                        crashIn: index > 0 && crashes(into: section)))
                }
                voices.append(voice)
            }
            let segment = Segment(section: section.id, name: section.name, startBar: bar,
                                  lengthInBars: section.lengthInBars, voices: voices)
            out.append(segment)
            bar = segment.endBar
        }
        return out
    }

    /// Whether a section's drums fill into the next: yes, unless it says it leaves another way.
    static func fills(out section: Section) -> Bool {
        section.transitionOut.map { $0.kind == .fill } ?? true
    }

    /// Whether a section opens on a crash: yes, unless it says it is cut to.
    static func crashes(into section: Section) -> Bool {
        section.transitionIn.map { $0.kind != .cut } ?? true
    }

    /// One version as a thing that sounds, or nil when it is not one.
    ///
    /// The sound is resolved here, against the part, so every voice carries the instrument it will
    /// actually play on and nothing downstream has to work it out again. That is what lets a pad
    /// hold the chords while a lead plays the tune: two parts, two picks, two samplers.
    ///
    /// A variation plays as the part it varies (`Song.strip(of:)`): the breakdown's drums are the
    /// drums, on the drums' strip, machine and sampler, and only the steps are different.
    static func voice(for version: PartVersion, in song: Song, mediaURL: (MediaRef) -> URL?,
                      missingMedia: inout Bool) -> Voice? {
        let part = song.strip(of: version.partID)
        switch version.kind {
        case .groove(let groove) where groove.patterns.contains(where: { $0.steps.contains { $0 != .rest } }):
            return .groove(groove, version: version.id, part: part,
                           name: PartLabel.title(of: version),
                           sound: machineID(for: part, in: song),
                           kit: kit(for: part, in: song, mediaURL: mediaURL),
                           machine: machine(for: part, in: song))
        case .bassline(let line) where !line.notes.isEmpty:
            return .bassline(line, version: version.id, part: part,
                             name: PartLabel.title(of: version), sound: line.sound)
        case .progression(let progression) where !progression.chords.isEmpty:
            return .progression(progression, version: version.id, part: part,
                                name: PartLabel.title(of: version),
                                sound: instrumentID(for: part, in: song))
        case .melody(let melody) where !melody.notes.isEmpty:
            return .melody(melody, version: version.id, part: part,
                           name: PartLabel.title(of: version),
                           sound: instrumentID(for: part, in: song))
        case .sample(let sample) where !sample.slices.isEmpty:
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

    /// The machine a groove part plays on, as the song has shaped it: the pick (`machineID`), with
    /// every voice the Sound surface has kept an edit of at the knob positions it was kept at.
    static func machine(for part: PartID?, in song: Song) -> SynthMachine {
        shaped(SynthMachine.preset(id: machineID(for: part, in: song)) ?? .tr808, in: song)
    }

    /// The song's own machine, shaped the same way.
    static func machine(in song: Song) -> SynthMachine {
        shaped(SynthMachine.preset(id: machineID(in: song)) ?? .tr808, in: song)
    }

    /// `machine` with the song's voice edits on it. The Sound surface keeps a voice as a `.sound`
    /// called `"drum.<machine>.<voice>"` carrying its knob positions and its chain; the newest of
    /// each voice is the one in effect, and one kept for another machine is that machine's. A kit is built from
    /// the machine's voices, so this is what makes a kept knob something the song plays — before
    /// it, a voice was kept in the ledger and heard nowhere but on the surface.
    static func shaped(_ machine: SynthMachine, in song: Song) -> SynthMachine {
        var shaped = machine
        var seen = Set<SynthVoiceKind>()
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind, let state = SoundState(sound),
                  state.machine == machine.id, seen.insert(state.voice).inserted,
                  let index = shaped.voices.firstIndex(where: { $0.kind == state.voice }) else { continue }
            shaped.voices[index].controls = state.controls
            shaped.voices[index].dust = state.degrade.isBypass ? nil : state.degrade
        }
        return shaped
    }

    /// The newest edit of one voice of a machine the song has kept, if it has kept one.
    static func voiceEdit(of voice: SynthVoiceKind, on machine: String, in song: Song) -> PartVersion? {
        song.versions.last { version in
            guard case .sound(let sound) = version.kind, let state = SoundState(sound) else { return false }
            return state.machine == machine && state.voice == voice
        }
    }

    /// What a groove part's drums are, by its newest pick: a machine's id, or `ChopSound.id` of a
    /// chop when it plays on one. A part that has never chosen gets the song's machine.
    ///
    /// `machineID(for:in:)` stays machines only, because it answers what a Grid auditions on; this
    /// is what the part is heard on, and the newest pick of either kind wins.
    static func drumSoundID(for part: PartID?, in song: Song) -> String {
        sound(in: song, for: part, recognisedBy: isDrumSound) ?? machineID(in: song)
    }

    /// A `.sound` that picks a groove's drums: a machine, or a chop.
    static func isDrumSound(_ id: String) -> Bool {
        SynthMachine.preset(id: id) != nil || ChopSound.part(of: id) != nil
    }

    /// The chop a groove part plays on, as the song holds it now, or nil when it plays on a machine.
    /// What the form, the band's question and the Director read to say what a groove is heard on:
    /// a groove on a chop is that chop in a rhythm, and is drums only when the chop was.
    static func chop(under part: PartID, in song: Song) -> PartVersion? {
        guard let chop = ChopSound.part(of: drumSoundID(for: part, in: song)),
              let version = song.versions.last(where: { $0.partID == chop }), version.type == .sample else { return nil }
        return version
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
        // A variation's sound is the sound of the part it varies.
        let part = part.map(song.strip(of:))
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
    /// Grooves that could not be played on their chop's slices this run, and why, known once
    /// `begin` has run. They played on a machine instead.
    func chopFailures() async -> [String]
    /// How far into the song's fade-out the playhead is: 1 untouched, 0 silent. A host with no
    /// master ignores it.
    func fade(_ gain: Double) async
}

extension SongPlaybackHost {
    public func fade(_ gain: Double) async {}
    public func mixChanged(_ mix: Mix?, section: SectionID?) async {}
    public func unmixedParts() async -> [PartID] { [] }
    public func chopFailures() async -> [String] { [] }
}

extension Song {
    /// The stems the form plays: every stem some section names, in the order the form meets them.
    /// What a form written again carries over, so rewriting the sections does not take the record
    /// out of the song.
    var seatedStems: [PartID] {
        var seen = Set<PartID>()
        return sections.flatMap(\.stitch).compactMap { lane in
            guard let version = latestVersion(of: lane.part), StructureModel.isStem(version),
                  seen.insert(lane.part).inserted else { return nil }
            return lane.part
        }
    }

    /// The stem lanes one section holds, in its own order.
    func stemLanes(in section: Section) -> [Lane] {
        section.stitch.filter { lane in latestVersion(of: lane.part).map(StructureModel.isStem) ?? false }
    }
}
