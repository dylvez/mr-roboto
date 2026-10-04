import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Observation
import Performance
import SongGraph

/// What hearing something in the Library needs from the app: where a file is, a way to sound it
/// under the app's one player, and a song's preview.
@MainActor
protocol LibraryListeningHost: AnyObject {
    /// A record's, a stem's, a sample's or an idea's file in the library.
    func mediaURL(_ media: MediaRef) -> URL?
    /// Audio, now, under the player's name for it; the song's transport stops first. `seconds` nil
    /// is "until stopped": a loop.
    func play(planar: [[Float]], sampleRate: Double, loops: Bool, id: String, label: String, seconds: Double?) async
    /// An idea or a sample, alone, as a part plays: grooves on their machine, lines on their bass.
    func play(_ version: PartVersion, standingIn song: Song, id: String, label: String) async
    func stop() async
    /// Whether the player's sound is this one.
    func isSounding(_ id: String) -> Bool
    /// The song's preview, made now when there is none for the song as it stands, saying how far
    /// the making has got.
    func songPreview(_ song: Song, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// A phrase on an instrument, at a tempo: how an instrument on the shelf is heard.
    func play(phrase notes: [NoteEvent], instrument: String, tempo: Double, id: String, label: String) async
    /// A groove on a kit, at a tempo: how a kit on the shelf is heard.
    func play(groove: Groove, machine: SynthMachine, tempo: Double, id: String, label: String) async
}

/// Listening in the Library: one thing at a time, through the app's player, so the transport bar
/// and Stop know about it, and giving way to the song's transport and it to them. A record can be
/// heard whole or a stem at a time, from any bar, or a run of bars looped; a song is heard from a
/// preview made the first time it is asked for.
@MainActor
@Observable
final class LibraryPreview {
    enum State: Equatable {
        case idle
        /// Reading a file, or making a song's preview: what is being done.
        case preparing(String)
        /// What started sounding, and from where: enough to say where it is now.
        case sounding(Sounding)
        case failed(String)
    }

    struct Sounding: Equatable {
        var id: String
        /// Seconds into the item where it started.
        var from: Double
        /// How long it runs before it ends or comes round.
        var length: Double
        var loops: Bool
        var started: Date
    }

    let app: AppState
    @ObservationIgnored private weak var host: LibraryListeningHost?
    private(set) var state: State = .idle

    /// The record whose bars and stems are drawn, and which of its stems is heard (nil: the record).
    private(set) var record: RecordID?
    private(set) var stem: String?
    /// The record's (or the stem's) shape, for drawing.
    private(set) var waveform: ImportWaveform?
    /// Bars chosen to be heard as a loop and brought into a song, 0-based, the end not included.
    private(set) var bars: Range<Int>?

    /// The audio last read, kept so a second press does not read the file again.
    @ObservationIgnored private var loaded: (media: MediaRef, planar: [[Float]], sampleRate: Double)?

    /// The song whose preview is being made, and how far it has got, 0…1.
    fileprivate(set) var making: (song: SongID, progress: Double)?
    @ObservationIgnored private var makingTask: (song: SongID, task: Task<URL, Error>)?

    init(app: AppState, host: LibraryListeningHost) {
        self.app = app
        self.host = host
    }

    // MARK: What can be heard

    /// The player's name for an item heard from here, and for a stem of a record.
    static func id(_ item: LibraryItemID, stem: String? = nil) -> String {
        "library:\(item)" + (stem.map { ":\($0)" } ?? "")
    }

    /// Whether the item has a sound: a record with its file, a song that plays something, a sample,
    /// an idea with notes or audio. Albums are heard a song at a time.
    func canHear(_ item: LibraryItemID) -> Bool {
        switch item.shelf {
        // Cheap enough to ask of every row: whether a file is really there is said when it plays.
        case .records: return app.library.record(RecordID(rawValue: item.id)) != nil
        case .songs: return song(SongID(rawValue: item.id)).map { !$0.versions.isEmpty } ?? false
        case .samples: return app.library.sample(SampleID(rawValue: item.id)) != nil
        case .ideas: return idea(VersionID(rawValue: item.id)).map(PartPlayer.canPlay) ?? false
        case .albums: return false
        case .instruments, .kits: return app.libraryIndex.facts(item)?.code != nil
        }
    }

    /// Whether this item (any stem of it) is what is sounding.
    func isSounding(_ item: LibraryItemID) -> Bool {
        guard case .sounding(let now) = state, host?.isSounding(now.id) == true else { return false }
        return now.id == Self.id(item) || now.id.hasPrefix(Self.id(item) + ":")
    }

    var soundingNow: Sounding? {
        guard case .sounding(let now) = state, host?.isSounding(now.id) == true else { return nil }
        return now
    }

    /// Seconds into the item at `date`, while it sounds: round again for a loop, held at the end.
    func position(at date: Date = Date()) -> Double? {
        guard let now = soundingNow else { return nil }
        let elapsed = max(0, date.timeIntervalSince(now.started))
        let into = now.loops && now.length > 0 ? elapsed.truncatingRemainder(dividingBy: now.length) : min(elapsed, now.length)
        return now.from + into
    }

    // MARK: A record's bars and stems

    /// The record shown for listening, and its shape read; the stem and the bars chosen go with
    /// another record.
    func show(record id: RecordID?) async {
        guard id != record else { return }
        record = id
        stem = nil
        bars = nil
        waveform = nil
        guard let id else { return }
        await loadShape(of: id)
    }

    /// Which stem is heard and drawn: nil for the whole record.
    func choose(stem name: String?) async {
        guard let record, name != stem else { return }
        stem = name
        waveform = nil
        await loadShape(of: record)
    }

    /// The bars from `first` through `last`, either way round; the same bar twice is that bar.
    func choose(bars first: Int, through last: Int) {
        let count = recordBars.count
        guard count > 0 else { return }
        let low = min(max(0, min(first, last)), count - 1), high = min(max(0, max(first, last)), count - 1)
        bars = low..<(high + 1)
    }

    func clearBars() { bars = nil }

    /// The bars of the record shown, as its reading has them.
    var recordBars: [TimeRange] {
        record.flatMap { app.library.record($0)?.reading?.bars } ?? []
    }

    /// The stems the record shown has, in the order the strip lists them.
    var stems: [String] {
        (record.flatMap { app.library.record($0)?.stems } ?? []).map(\.name).sorted { RecordStems.order($0) < RecordStems.order($1) }
    }

    /// "Add bars 5–8 to this song": Sources, asked for those bars of what is heard.
    func addBarsToSong() {
        guard let record, let bars else { return }
        app.askForSource(AskedSource(origin: .record(record), stem: stem, bars: bars))
    }

    // MARK: Playing

    /// Plays it, or stops it when it is what is sounding.
    func toggle(_ item: LibraryItemID) async {
        if isSounding(item) { await stop() } else { await play(item) }
    }

    /// Plays an item from its start — a record from `bar` when one is given — or the chosen bars
    /// as a loop when `looping` is set.
    func play(_ item: LibraryItemID, fromBar bar: Int? = nil, looping: Bool = false) async {
        guard let host else { return }
        switch item.shelf {
        case .records:
            await playRecord(RecordID(rawValue: item.id), fromBar: bar, looping: looping, host: host)
        case .songs:
            await playSong(SongID(rawValue: item.id), host: host)
        case .samples:
            guard let entry = app.library.sample(SampleID(rawValue: item.id)) else { return }
            let version = PartVersion(partID: PartID(), kind: .sample(entry.sample), author: .user, operation: Operation.adopted)
            await playAlone(version, item: item, label: entry.name, tempo: entry.sample.detectedTempo, host: host)
        case .ideas:
            guard let idea = idea(VersionID(rawValue: item.id)) else { return }
            await playAlone(idea, item: item, label: PartLabel.title(of: idea), tempo: nil, host: host)
        case .albums:
            return
        case .instruments:
            guard let id = app.libraryIndex.facts(item)?.code, let spec = InstrumentVoiceSpec.preset(id: id) else { return }
            let notes = LibraryPhrases.phrase(for: spec)
            await host.play(phrase: notes, instrument: spec.id, tempo: LibraryPhrases.tempo, id: Self.id(item), label: spec.name)
            state = .sounding(Sounding(id: Self.id(item), from: 0, length: LibraryPhrases.seconds(notes), loops: false, started: Date()))
        case .kits:
            guard let id = app.libraryIndex.facts(item)?.code, let machine = SynthMachine.preset(id: id) else { return }
            await host.play(groove: LibraryPhrases.groove, machine: machine, tempo: LibraryPhrases.grooveTempo, id: Self.id(item), label: machine.name)
            let length = Double(LibraryPhrases.groove.bars * 4) * 60 / LibraryPhrases.grooveTempo
            state = .sounding(Sounding(id: Self.id(item), from: 0, length: length, loops: false, started: Date()))
        }
    }

    func stop() async {
        if case .sounding(let now) = state, host?.isSounding(now.id) == true { await host?.stop() }
        state = .idle
    }

    /// The song's transport is starting: what sounds from here gives way.
    func yieldToTransport() async {
        guard soundingNow != nil else { return }
        await stop()
    }

    private func playRecord(_ id: RecordID, fromBar bar: Int?, looping: Bool, host: LibraryListeningHost) async {
        guard let record = app.library.record(id) else { return }
        // The stem and the bars chosen are the shown record's; another record's row plays it whole.
        let shown = self.record == id
        let stem = shown ? self.stem : nil
        let bars = shown ? self.bars : nil
        let recordBars = record.reading?.bars ?? []
        let heard = stem.flatMap { record.stem(named: $0)?.media } ?? record.media
        guard let (planar, rate) = await read(heard, what: "\(record.title)") else { return }
        let frames = planar.first?.count ?? 0
        let duration = Double(frames) / rate
        let span: (from: Double, to: Double)
        if looping, let bars, let first = recordBars[safe: bars.lowerBound], let last = recordBars[safe: bars.upperBound - 1] {
            span = (first.start, last.end)
        } else {
            span = (bar.flatMap { recordBars[safe: $0]?.start } ?? 0, duration)
        }
        let lower = min(frames, max(0, Int(span.from * rate))), upper = min(frames, max(lower, Int(span.to * rate)))
        guard upper > lower else { return }
        let slice = planar.map { Array($0[lower..<upper]) }
        let length = Double(upper - lower) / rate
        let id = Self.id(.record(id), stem: stem)
        let label = looping && bars != nil ? "\(barsName) of \(record.title)" : stem.map { "\(record.title), \($0)" } ?? record.title
        await host.play(planar: slice, sampleRate: rate, loops: looping, id: id, label: label, seconds: looping ? nil : length)
        state = .sounding(Sounding(id: id, from: span.from, length: length, loops: looping, started: Date()))
    }

    /// Starts making a song's preview, when it has none for the song as it stands: choosing a song
    /// is the likeliest sign it is about to be heard. One is made at a time; choosing another song
    /// lets go of the one being made.
    func prepare(song id: SongID) {
        guard let song = song(id), makingTask?.song != id, SongPreviews.cached(song) == nil else { return }
        makingTask?.task.cancel()
        _ = startMaking(song)
    }

    private func startMaking(_ song: Song) -> Task<URL, Error> {
        let id = song.id
        making = (id, 0)
        let reporter = MakingReporter(preview: self, song: id)
        let task = Task { [host] () throws -> URL in
            guard let host else { throw CancellationError() }
            return try await host.songPreview(song, progress: reporter.report)
        }
        makingTask = (id, task)
        // Made, failed or let go of: it is no longer being made, whoever was waiting for it.
        Task { [weak self] in
            _ = try? await task.value
            guard let self, self.makingTask?.song == id else { return }
            self.makingTask = nil
            self.making = nil
        }
        return task
    }

    private func playSong(_ id: SongID, host: LibraryListeningHost) async {
        guard let song = song(id) else { return }
        let task = makingTask?.song == id ? makingTask!.task : startMaking(song)
        state = .preparing(making?.song == id ? "Making a preview of \(song.title)…" : "Reading \(song.title)…")
        defer {
            if makingTask?.song == id {
                makingTask = nil
                making = nil
            }
        }
        do {
            let url = try await task.value
            let (planar, rate) = try await Task.detached { try BoothAdapter.planar(url) }.value
            let length = Double(planar.first?.count ?? 0) / rate
            let soundID = Self.id(.song(id))
            await host.play(planar: planar, sampleRate: rate, loops: false, id: soundID, label: song.title, seconds: length)
            state = .sounding(Sounding(id: soundID, from: 0, length: length, loops: false, started: Date()))
        } catch {
            state = .failed("\(error)")
        }
    }

    private func playAlone(_ version: PartVersion, item: LibraryItemID, label: String, tempo: Double?, host: LibraryListeningHost) async {
        // A song for it to stand in: the open one's tempo and sounds, else its own tempo.
        let song = app.song ?? Song(title: label, tempo: tempo ?? 120)
        let soundID = Self.id(item)
        await host.play(version, standingIn: song, id: soundID, label: label)
        state = .sounding(Sounding(id: soundID, from: 0, length: 0, loops: false, started: Date()))
    }

    /// "Bars 5–8", "Bar 5".
    var barsName: String {
        guard let bars else { return "" }
        return bars.count == 1 ? "Bar \(bars.lowerBound + 1)" : "Bars \(bars.lowerBound + 1)–\(bars.upperBound)"
    }

    // MARK: Reading

    private func read(_ media: MediaRef, what: String) async -> ([[Float]], Double)? {
        if let loaded, loaded.media == media { return (loaded.planar, loaded.sampleRate) }
        guard let url = host?.mediaURL(media) else {
            state = .failed("\(what)'s audio is not in the library folder.")
            return nil
        }
        state = .preparing("Reading \(what)…")
        do {
            let (planar, rate) = try await Task.detached { try BoothAdapter.planar(url) }.value
            loaded = (media, planar, rate)
            if case .preparing = state { state = .idle }
            return (planar, rate)
        } catch {
            state = .failed("\(what) could not be read: \(error)")
            return nil
        }
    }

    private func loadShape(of id: RecordID) async {
        guard let record = app.library.record(id) else { return }
        let media = stem.flatMap { record.stem(named: $0)?.media } ?? record.media
        guard let (planar, rate) = await read(media, what: record.title), self.record == id else { return }
        let shape = await Task.detached { Self.shape(planar, sampleRate: rate) }.value
        if self.record == id { waveform = shape }
    }

    /// Low and high per bucket, the channels mixed: what the Record surface draws, from audio
    /// already read.
    nonisolated static func shape(_ planar: [[Float]], sampleRate: Double, buckets: Int = 600) -> ImportWaveform {
        let frames = planar.first?.count ?? 0
        guard frames > 0, sampleRate > 0 else { return .empty }
        let count = max(1, min(buckets, frames))
        let per = Double(frames) / Double(count)
        var peaks: [ImportWaveform.Peak] = []
        peaks.reserveCapacity(count)
        for bucket in 0..<count {
            let lower = Int(Double(bucket) * per), upper = max(lower + 1, min(frames, Int(Double(bucket + 1) * per)))
            var low: Float = 0, high: Float = 0
            for frame in stride(from: lower, to: upper, by: max(1, (upper - lower) / 64)) {
                var value: Float = 0
                for channel in planar { value += channel[frame] }
                value /= Float(planar.count)
                low = min(low, value)
                high = max(high, value)
            }
            peaks.append(.init(low: low, high: high))
        }
        return ImportWaveform(peaks: peaks, duration: Double(frames) / sampleRate)
    }

    // MARK: Finding things

    private func song(_ id: SongID) -> Song? { app.song?.id == id ? app.song : app.library.song(id) }

    private func idea(_ id: VersionID) -> PartVersion? { app.library.ideas.first { $0.id == id } }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What an instrument or a kit on the shelf is heard by: a few bars that suit what it is.
enum LibraryPhrases {
    static let tempo = 96.0
    static let grooveTempo = 92.0

    /// Chords for what holds them — keys, organs, pads, strings, guitars — a low line for a bass, a
    /// tune for the rest; moved by octaves into the keys a recorded instrument reaches.
    static func phrase(for spec: InstrumentVoiceSpec) -> [NoteEvent] {
        let notes: [NoteEvent]
        switch spec.family {
        case "keys", "organ", "pad", "strings", "plucked", "guitar":
            notes = Voicing.notes(for: chords)
        case "bass":
            notes = line([36, 36, 43, 45, 41, 41, 43, 47], beats: 1)
        default:
            notes = line([72, 74, 76, 79, 81, 79, 76, 74, 72], beats: 0.5, last: 2)
        }
        guard spec.engine == .sampled, let range = ImportedInstruments.range(of: spec) else { return notes }
        return fitted(notes, into: range)
    }

    static func seconds(_ notes: [NoteEvent]) -> Double {
        (notes.map { $0.start + $0.duration }.max() ?? 0) * 60 / tempo + 0.5
    }

    /// Cmaj7, Am7, Fmaj7, G7, a bar each.
    static let chords = Progression(key: .cMajor, bars: [
        ProgressionBar(Chord(.c, .majorSeventh)), ProgressionBar(Chord(.a, .minorSeventh)),
        ProgressionBar(Chord(.f, .majorSeventh)), ProgressionBar(Chord(.g, .dominantSeventh)),
    ])

    /// Two bars of kick, snare and hats, with a ghost and an open hat: enough of every voice.
    static var groove: Groove {
        func pattern(_ voice: DrumVoice, _ steps: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: steps.map { $0 == "X" ? .accent : $0 == "x" ? .normal : $0 == "g" ? .ghost : .rest })
        }
        return Groove(stepsPerBar: 16, bars: 2, patterns: [
            pattern(.kick, "X-----x---x-----X-----x-----x---"),
            pattern(.snare, "----X------g--g-----X------g-X--"),
            pattern(.closedHat, "x-x-x-x-x-x-x-x-x-x-x-x-x-x-x---"),
            pattern(.openHat, "------------------------------x-"),
        ])
    }

    private static func line(_ keys: [Int], beats: Double, last: Double? = nil) -> [NoteEvent] {
        keys.enumerated().map { index, key in
            let length = index == keys.count - 1 ? (last ?? beats) : beats
            return NoteEvent(pitch: Pitch(midi: key), start: Double(index) * beats, duration: length * 0.9, velocity: 92)
        }
    }

    /// Left where it is when it fits; else moved by whole octaves into `range`, or as near as it can.
    static func fitted(_ notes: [NoteEvent], into range: ClosedRange<Int>) -> [NoteEvent] {
        guard let low = notes.map(\.pitch.midi).min(), let high = notes.map(\.pitch.midi).max() else { return notes }
        if range.contains(low), range.contains(high) { return notes }
        let middle = (range.lowerBound + range.upperBound) / 2
        var shift = Int((Double(middle - (low + high) / 2) / 12).rounded()) * 12
        while low + shift < range.lowerBound, high + shift + 12 <= range.upperBound { shift += 12 }
        while high + shift > range.upperBound, low + shift - 12 >= range.lowerBound { shift -= 12 }
        return notes.map { var note = $0; note.pitch = Pitch(midi: note.pitch.midi + shift); return note }
    }
}

/// How far a song's preview has got, said from the thread that renders it to the preview on the
/// main actor, without keeping the preview alive.
private final class MakingReporter: @unchecked Sendable {
    // Read and written only on the main actor.
    private weak var preview: LibraryPreview?
    private let song: SongID

    @MainActor init(preview: LibraryPreview, song: SongID) {
        self.preview = preview
        self.song = song
    }

    func report(_ fraction: Double) {
        Task { @MainActor in
            guard let preview = self.preview, preview.making?.song == self.song else { return }
            preview.making = (self.song, fraction)
        }
    }
}

// MARK: - The app's side

/// The Library's listening as the app does it: files from the library folder, sound through the
/// one `PartPlayer` and its audition service, and previews in the caches.
@MainActor
final class LiveLibraryListening: LibraryListeningHost {
    let app: AppState

    init(app: AppState) { self.app = app }

    private var player: PartPlayer { SurfaceWiring.shared.player(for: app) }

    func mediaURL(_ media: MediaRef) -> URL? { try? app.store?.mediaURL(for: media) }

    func play(planar: [[Float]], sampleRate: Double, loops: Bool, id: String, label: String, seconds: Double?) async {
        if app.transport.isPlaying { await app.stopTransport() }
        let service = SurfaceWiring.shared.service(for: app)
        await player.play(id: id, label: label, seconds: seconds) {
            await service.play(planar: planar, sampleRate: sampleRate, loops: loops)
        }
    }

    func play(_ version: PartVersion, standingIn song: Song, id: String, label: String) async {
        if app.transport.isPlaying { await app.stopTransport() }
        await player.play(version, standingIn: song, as: id, label: label)
    }

    func stop() async { await player.stopSounding() }

    func isSounding(_ id: String) -> Bool { player.nowPlaying?.id == id }

    func songPreview(_ song: Song, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await SongPreviews.make(song, store: app.store, progress: progress)
    }

    func play(phrase notes: [NoteEvent], instrument: String, tempo: Double, id: String, label: String) async {
        if app.transport.isPlaying { await app.stopTransport() }
        let player = player
        let clock = TransportClock(tempo: tempo)
        await player.play(id: id, label: label, seconds: LibraryPhrases.seconds(notes)) {
            await player.playOnInstrument(notes, instrument: instrument, clock: clock)
        }
    }

    func play(groove: Groove, machine: SynthMachine, tempo: Double, id: String, label: String) async {
        if app.transport.isPlaying { await app.stopTransport() }
        let player = player
        let clock = TransportClock(tempo: tempo)
        await player.play(id: id, label: label, seconds: Double(groove.bars * 4) * 60 / tempo + 0.5) {
            await player.play(groove, machine: machine, clock: clock)
        }
    }
}
