import Foundation
import MusicTheory
import Performance
import SongGraph

// Mashup: stems of two songs in the library, moved onto one grid, as a new song.

/// What to make: which songs, whose grid, which stems from each.
public struct MashupRequest: Equatable, Sendable {
    public var a: SongID
    public var b: SongID
    public var backbone: MashupPlan.Side
    /// Stem names per side: "vocals", "drums", "bass", "other", or "full" for the whole record.
    public var stemsA: [String]
    public var stemsB: [String]
    public var barShift: Int
    public var semitonesA: Int?
    public var semitonesB: Int?
    public var title: String?

    public init(a: SongID, b: SongID, backbone: MashupPlan.Side = .a, stemsA: [String], stemsB: [String], barShift: Int = 0,
                semitonesA: Int? = nil, semitonesB: Int? = nil, title: String? = nil) {
        self.a = a
        self.b = b
        self.backbone = backbone
        self.stemsA = stemsA
        self.stemsB = stemsB
        self.barShift = barShift
        self.semitonesA = semitonesA
        self.semitonesB = semitonesB
        self.title = title
    }
}

public enum MashupError: Error, CustomStringConvertible, Equatable {
    case noLibrary
    case noSuchSong
    case sameSong
    case notAnalysed(String)
    case nothingChosen
    case tooManyStems(Int)
    case noStem(String, String)
    case missingMedia(String)

    public var description: String {
        switch self {
        case .noLibrary: return "There is no library to make the mashup in."
        case .noSuchSong: return "One of those songs is not in the library."
        case .sameSong: return "A mashup needs two different songs."
        case .notAnalysed(let title): return "\(title) has no analysis — import it as a record first, so its bars and key are known."
        case .nothingChosen: return "No stems were chosen."
        case .tooManyStems(let count): return "\(count) stems were chosen; the transport plays \(Mashups.maximumStems) audio files at once."
        case .noStem(let stem, let title): return "\(title) has no \(stem) stem — separate its stems on the Record surface, or take the full record."
        case .missingMedia(let what): return "The audio for \(what) is not on disk."
        }
    }
}

/// One stem to carry across, resolved.
struct MashupPick: Sendable {
    var side: MashupPlan.Side
    var stem: String
    var url: URL
    var move: MergeMove
    var offset: Double
    var songTitle: String
    var record: RecordID?
}

public enum Mashups {
    /// The engine has four player nodes for audio files.
    public static let maximumStems = 4
    public static let full = "full"

    /// What a song says about itself for the plan. Nil when it has never been analysed.
    public static func source(for song: Song) -> MashupSource? {
        guard let analysis = Guidance.analysis(in: song) else { return nil }
        let downbeat = analysis.beats.first { $0.isDownbeat }?.time ?? analysis.bars.first?.start ?? 0
        let duration = analysis.duration > 0 ? analysis.duration : (Guidance.take(in: song).flatMap { Guidance.audio(of: $0)?.duration } ?? 0)
        return MashupSource(label: song.title, key: analysis.dominantKey ?? song.key, tempo: analysis.dominantTempo ?? song.tempo,
                            firstDownbeat: downbeat, duration: duration)
    }

    /// The stems a song can give: the separated ones by name, and always the full record.
    public static func stems(of song: Song) -> [String] {
        var names: [String] = []
        for version in Guidance.stems(in: song) {
            if let name = Guidance.audio(of: version)?.stem, !names.contains(name) { names.append(name) }
        }
        let order = ["vocals", "drums", "bass", "other"]
        names.sort { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
        if Guidance.take(in: song) != nil { names.append(full) }
        return names
    }

    public static func plan(_ request: MashupRequest, a: Song, b: Song) throws -> MashupPlan {
        guard let sourceA = source(for: a) else { throw MashupError.notAnalysed(a.title) }
        guard let sourceB = source(for: b) else { throw MashupError.notAnalysed(b.title) }
        let beats = (request.backbone == .a ? a : b).timeSignature.beatsPerBar
        return Mashup.plan(a: sourceA, b: sourceB, backbone: request.backbone, barShift: request.barShift,
                           semitonesA: request.semitonesA, semitonesB: request.semitonesB, beatsPerBar: beats)
    }

    /// The backbone's sections on the mashup's bars: a lead-in when there is one, each analysed
    /// section from the bar it starts on, and a tail when the other record outlasts it.
    public static func sections(plan: MashupPlan, backbone: Song) -> [Section] {
        var starts: [(bar: Int, name: String)] = []
        if plan.leadBars > 0 { starts.append((0, "Lead-in")) }
        let ranges = Guidance.analysis(in: backbone)?.sections ?? []
        var counts: [String: Int] = [:]
        for range in ranges {
            let bar = Int(Mashup.bar(of: range.start, in: plan.backbone, plan: plan).rounded())
            let previous = starts.last?.bar ?? -1
            guard plan.lengthInBars > bar, previous < bar else { continue }
            let label = (range.label?.isEmpty == false ? range.label! : "Part").capitalized
            counts[label, default: 0] += 1
            starts.append((max(0, bar), counts[label]! > 1 ? "\(label) \(counts[label]!)" : label))
        }
        if starts.isEmpty { starts.append((0, "Song")) }
        if starts[0].bar > 0 { starts.insert((0, "Intro"), at: 0) }
        var out: [Section] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].bar : plan.lengthInBars
            guard end > start.bar else { continue }
            out.append(Section(name: start.name, stitch: [], lengthInBars: end - start.bar))
        }
        return out
    }

    /// Reads one stem, moves it, and writes the result. Off the main actor: minutes of audio.
    static func render(_ pick: MashupPick, to url: URL) throws -> (sampleRate: Double, channels: Int, duration: Double) {
        let (planar, rate) = try BoothAdapter.planar(pick.url)
        let moved = try MergeRender.audio(planar, sampleRate: rate, move: pick.move)
        try BoothAdapter.write(moved, sampleRate: rate, to: url)
        return (rate, moved.count, Double(moved.first?.count ?? 0) / rate)
    }
}

extension Mashups {
    /// A few bars of the mashup as one stereo buffer: each chosen stem's slice of those bars, moved
    /// and summed. For hearing a bar shift or a semitone before minutes of audio are rendered.
    static func preview(_ picks: [MashupPick], plan: MashupPlan, fromBar: Int, bars: Int) throws -> (planar: [[Float]], sampleRate: Double) {
        let start = Double(fromBar) * plan.secondsPerBar, length = Double(bars) * plan.secondsPerBar
        var rate = 48_000.0
        var mix: [[Float]] = []
        for (index, pick) in picks.enumerated() {
            let (planar, fileRate) = try BoothAdapter.planar(pick.url)
            if index == 0 { rate = fileRate; mix = [[Float]](repeating: [Float](repeating: 0, count: Int(length * rate)), count: 2) }
            // The source seconds that land in the window, once moved.
            let from = max(0, (start - pick.offset) / pick.move.ratio), to = (start + length - pick.offset) / pick.move.ratio
            guard to > from, let frames = planar.first?.count else { continue }
            let lower = min(frames, Int(from * fileRate)), upper = min(frames, Int(to * fileRate))
            guard upper > lower else { continue }
            let moved = try MergeRender.audio(planar.map { Array($0[lower..<upper]) }, sampleRate: fileRate, move: pick.move)
            // Where the slice's first frame sits in the window, and a nearest-frame rate match.
            let landing = max(0, pick.offset + Double(lower) / fileRate * pick.move.ratio - start)
            let base = Int(landing * rate), step = fileRate / rate
            for channel in 0..<2 {
                let source = moved[min(channel, moved.count - 1)]
                var i = 0
                while base + i < mix[channel].count, Int(Double(i) * step) < source.count {
                    mix[channel][base + i] += source[Int(Double(i) * step)] * 0.7
                    i += 1
                }
            }
        }
        return (mix, rate)
    }
}

extension AppState {

    /// The chosen stems, resolved to files and moves.
    func mashupPicks(_ request: MashupRequest) throws -> (picks: [MashupPick], plan: MashupPlan, a: Song, b: Song) {
        guard let store else { throw MashupError.noLibrary }
        guard request.a != request.b else { throw MashupError.sameSong }
        guard let songA = librarySong(request.a), let songB = librarySong(request.b) else { throw MashupError.noSuchSong }
        let chosen = request.stemsA.count + request.stemsB.count
        guard chosen > 0 else { throw MashupError.nothingChosen }
        guard chosen <= Mashups.maximumStems else { throw MashupError.tooManyStems(chosen) }
        let plan = try Mashups.plan(request, a: songA, b: songB)
        var picks: [MashupPick] = []
        for (side, source, names) in [(MashupPlan.Side.a, songA, request.stemsA), (.b, songB, request.stemsB)] {
            let record = Guidance.take(in: source).flatMap { Guidance.audio(of: $0) }.flatMap { library.record(forMedia: $0.media)?.id }
            for name in names {
                let version = name == Mashups.full
                    ? Guidance.take(in: source)
                    : Guidance.stems(in: source).last { Guidance.audio(of: $0)?.stem == name }
                guard let version, let audio = Guidance.audio(of: version) else { throw MashupError.noStem(name, source.title) }
                guard let url = try? store.mediaURL(for: audio.media, song: source.id) else { throw MashupError.missingMedia("\(name) of \(source.title)") }
                picks.append(MashupPick(side: side, stem: name, url: url, move: name == "drums" ? plan.drumMove(side) : plan.move(side),
                                        offset: plan.offset(side), songTitle: source.title, record: record))
            }
        }
        return (picks, plan, songA, songB)
    }

    /// A few bars of the mashup, rendered off the main actor, for the surface to play.
    func previewMashup(_ request: MashupRequest, fromBar: Int, bars: Int) async throws -> (planar: [[Float]], sampleRate: Double) {
        let (picks, plan, _, _) = try mashupPicks(request)
        return try await Task.detached(priority: .userInitiated) { try Mashups.preview(picks, plan: plan, fromBar: fromBar, bars: bars) }.value
    }

    /// The song with this id: the open one when it is that (so unsaved work counts), else the library's.
    func librarySong(_ id: SongID) -> Song? { (song?.id == id ? song : nil) ?? library.song(id) }

    /// Makes the mashup: plans it, renders every chosen stem through its move, and saves a new
    /// song whose stems sit on the backbone's grid. The new song is opened. The open song is saved
    /// first, so nothing is lost to the switch.
    @discardableResult
    public func makeMashup(_ request: MashupRequest, progress: (@MainActor (String, Double) -> Void)? = nil) async throws -> Song {
        guard let store, libraryIsWritable else { throw MashupError.noLibrary }
        let (picks, plan, songA, songB) = try mashupPicks(request)

        if hasUnsavedChanges { save() }
        let backbone = request.backbone == .a ? songA : songB
        // In the key the backbone was moved to: both sides are rendered there, and a part written
        // into the mashup later is written to it. `target.key` is the key before any nudge.
        var mashup = Song(title: request.title ?? "\(songA.title) × \(songB.title)",
                          key: plan.move(request.backbone).key ?? plan.target.key, tempo: plan.target.tempo ?? backbone.tempo,
                          timeSignature: backbone.timeSignature, sections: Mashups.sections(plan: plan, backbone: backbone))
        // The package has to exist before media can go in it.
        var updated = library
        updated.upsert(mashup)
        try store.save(updated)
        let package = try store.songStore(for: mashup.id)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto/mashup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (index, pick) in picks.enumerated() {
            progress?("\(pick.stem == Mashups.full ? "The record" : pick.stem.capitalized) of \(pick.songTitle)", Double(index) / Double(picks.count))
            let out = scratch.appendingPathComponent("\(index).wav")
            let info = try await Task.detached(priority: .userInitiated) { try Mashups.render(pick, to: out) }.value
            let media = try package.addMedia(copying: out)
            let audio = Audio(media: media, role: .stem, stem: pick.stem == Mashups.full ? "record" : pick.stem, sampleRate: info.sampleRate,
                              channelCount: info.channels, duration: info.duration, alignmentOffset: pick.offset, sourceRecord: pick.record)
            let what = pick.stem == Mashups.full ? "The record" : pick.stem.capitalized
            let version = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.mashup,
                                      note: "\(what) of \(pick.songTitle). \(pick.move.sentence)")
            try mashup.append(version)
        }
        progress?("Saving", 1)
        // Onto the library as it is now, not as it was before the render: edits autosaved while it
        // ran used to be written over with the older copies.
        var latest = library
        latest.upsert(mashup)
        try store.save(latest)
        reloadLibrary()
        open(librarySong(mashup.id) ?? mashup)
        note(.session, "Made \(mashup.title)", detail: plan.sentences.joined(separator: " "))
        return mashup
    }
}
