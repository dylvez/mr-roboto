import Analysis
import AnalysisMLX
import ArgumentParser
import Foundation
import MusicTheory
import SongGraph

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a song package in a library from an audio file.",
        discussion: "Stores the file as a library record, records it as the song's seed, appends an analysis part version from the Music Understanding report and an audio take for the mix, and adds one audio stem part per stem when <Name>.stems/ exists or --separate is passed."
    )

    @Argument(help: "Audio file to import.")
    var file: String

    @Option(help: "Library directory; created if it does not exist.")
    var library: String = "~/Music/MrRoboto"

    @Option(help: "Song title (default: the file name without extension).")
    var title: String?

    @Option(help: "Artist name for the song and record.")
    var artist: String = ""

    @Flag(help: "Run Demucs if <Name>.stems/ does not exist yet, so stems are imported too.")
    var separate = false

    @Option(help: "Demucs model for --separate.")
    var model: DemucsModel = .htdemucs

    @Flag(name: .customLong("no-cache"), help: "Ignore the cached analysis and analyse again.")
    var noCache = false

    func run() async throws {
        let url = try resolveInputFile(file)
        let songTitle = title ?? url.deletingPathExtension().lastPathComponent
        let libraryURL = fileURL(library)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw CLIError.notADirectory(libraryURL.path)
        }

        // 1. Analysis (cached) and stems.
        let (report, cached) = try await analysisReport(for: url, useCache: !noCache)
        if cached { note("analysis from cache (\(report.analyzedAt.formatted(date: .abbreviated, time: .shortened)))") }
        let stemsDir = stemsDirectory(for: url)
        var stems = existingStems(in: stemsDir)
        if stems.isEmpty, separate {
            let result = try await separateStems(url: url, model: model, into: stemsDir)
            note(String(format: "separated in %.1f s", result.wallTime))
            stems = existingStems(in: stemsDir)
        }

        // 2. Open or create the library; store the record media by hash.
        let store = LibraryStore(directoryURL: libraryURL)
        var lib = store.exists ? try store.load() : Library()
        let recordMedia = try store.addMedia(copying: url, kind: .record)
        var record = Record(title: songTitle, artist: artist, media: recordMedia)
        let mixInfo = try audioInfo(url)

        // 3. The song, its seed, and the versions that describe the record.
        let grid = report.beatGrid
        var song = Song(title: songTitle, artist: artist, key: report.dominantKey,
                        tempo: report.beats?.bpm ?? grid?.bpm ?? 120,
                        timeSignature: grid?.timeSignature ?? .fourFour)
        let seed = Seed(kind: .importedRecord(record.id), note: "imported from \(url.path)")
        song.seeds.append(seed)

        let analysis = MusicAnalysis(report: report, fallbackDuration: mixInfo.duration)
        let analysisVersion = PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user,
                                          operation: Operation.imported, note: "analysis of \(url.lastPathComponent)", origin: seed.id)
        try song.append(analysisVersion)
        record.analysis = analysisVersion

        let take = Audio(media: recordMedia, role: .take, stem: nil, sampleRate: mixInfo.sampleRate,
                         channelCount: mixInfo.channels, duration: mixInfo.duration)
        let takeVersion = PartVersion(partID: PartID(), kind: .audio(take), author: .user,
                                      operation: Operation.imported, note: "the record, as imported", origin: seed.id)
        try song.append(takeVersion)

        // 4. Save so the package exists, then copy stems into it and append their versions.
        lib.records.append(record)
        lib.upsert(song)
        try store.save(lib)
        let songStore = try store.songStore(for: song.id)

        var stemVersions: [PartVersion] = []
        for (name, stemURL) in stems.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let media = try songStore.addMedia(copying: stemURL)
            let info = try audioInfo(stemURL)
            let audio = Audio(media: media, role: .stem, stem: name.rawValue, sampleRate: info.sampleRate,
                              channelCount: info.channels, duration: info.duration)
            let version = takeVersion.spawning(.audio(audio), by: .user, operation: Operation.separate,
                                               note: "\(name.rawValue) stem from \(stemURL.lastPathComponent)")
            try song.append(version)
            stemVersions.append(version)
        }
        if !stemVersions.isEmpty {
            lib.upsert(song)
            try store.save(lib)
        }

        // 5. Prove it reads back.
        let reloaded = try store.load()
        guard let saved = reloaded.song(song.id) else { throw SongGraphError.missingSongPackage(song.id) }
        try store.verifyMedia(for: reloaded)

        // 6. Report.
        print("library  \(store.directoryURL.path)  (\(reloaded.songs.count) songs, \(reloaded.records.count) records)")
        print("package  \(songStore.packageURL.path)")
        let keyName = saved.key?.name ?? "unknown key"
        print(String(format: "song     %@  %@  %.1f bpm %@  id %@", saved.title, keyName, saved.tempo, "\(saved.timeSignature)", saved.id.description))
        print("record   \(record.id)  records/\(recordMedia.fileName)")
        print("seed     \(seed.id)  importedRecord")
        print("parts    \(saved.versions.count) versions across \(saved.partIDs.count) parts")
        for version in saved.versions {
            print("  " + describe(version, in: saved))
        }
        if stems.isEmpty {
            print("no stems imported: \(stemsDir.path) does not exist (run `m0 separate` or pass --separate)")
        }
    }

    private func describe(_ version: PartVersion, in song: Song) -> String {
        let id = String(version.id.description.prefix(8))
        let kind: String
        switch version.kind {
        case .analysis(let analysis):
            let sections = analysis.sections.count
            kind = String(format: "analysis  %d beats, %d bars, %d sections, %d keys, %@", analysis.beats.count, analysis.bars.count,
                          sections, analysis.keys.count, analysis.analyzer ?? "unknown analyzer")
        case .audio(let audio):
            let role = audio.role == .stem ? "stem \(audio.stem ?? "?")" : "take"
            kind = String(format: "audio     %@  media %@…%@  %.2f s, %.0f Hz, %d ch", role, audio.media.hash.short,
                          audio.media.fileExtension.isEmpty ? "" : ".\(audio.media.fileExtension)", audio.duration, audio.sampleRate, audio.channelCount)
        default:
            kind = "\(version.type)"
        }
        let parents = version.parents.isEmpty ? "root" : "from " + version.parents.map { String($0.description.prefix(8)) }.joined(separator: ",")
        let origin = version.origin.map { " seed \(String($0.description.prefix(8)))" } ?? ""
        return "\(id)  \(kind)  [\(version.operation) by \(version.author), \(parents)\(origin)]"
    }
}

// MARK: - AnalysisReport → MusicAnalysis

extension MusicAnalysis {
    /// The song-graph form of a report. Both modules define `TimeRange`, `KeyRange` and
    /// `InstrumentActivity`, so everything here is module-qualified.
    init(report: AnalysisReport, fallbackDuration: Double) {
        let duration = report.duration ?? fallbackDuration
        let grid = report.beatGrid

        let keys = (report.key?.ranges ?? []).map { SongGraph.KeyRange(start: $0.start, end: $0.end, key: $0.key) }

        var beats: [BeatMarker] = []
        var bars: [SongGraph.TimeRange] = []
        var tempo: [TempoRange] = []
        if let grid {
            let downbeats = grid.downbeatIndices()
            beats = grid.beats.enumerated().map { BeatMarker(time: $0.element, isDownbeat: downbeats.contains($0.offset)) }
            bars = (0..<grid.barCount).compactMap { index in
                grid.bounds(ofBar: index).map { SongGraph.TimeRange(start: $0.start, end: $0.end) }
            }
            if let bpm = report.beats?.bpm ?? grid.bpm {
                tempo = [TempoRange(start: 0, end: duration, bpm: bpm)]
            }
        }

        let sections = (report.structure?.sections ?? []).map { SectionRange(start: $0.start, end: $0.end, label: nil) }

        var instruments: [SongGraph.InstrumentActivity] = []
        if let activity = report.instruments {
            for instrument in Instrument.allCases {
                let ranges = activity.presence[instrument] ?? []
                guard !ranges.isEmpty else { continue }
                instruments.append(SongGraph.InstrumentActivity(instrument: instrument.songGraphKind,
                                                                ranges: ranges.map { SongGraph.TimeRange(start: $0.start, end: $0.end) }))
            }
        }

        let loudness = report.loudness.map { Loudness(integrated: $0.integrated, range: $0.range, truePeak: $0.truePeak) }

        let analyzers = report.provenance.values.sorted()
        let analyzer = analyzers.isEmpty ? nil : Set(analyzers).sorted().joined(separator: "+")

        self.init(duration: duration, keys: keys, beats: beats, bars: bars, tempo: tempo, sections: sections,
                  instruments: instruments, loudness: loudness, analyzer: analyzer)
    }
}

extension Instrument {
    var songGraphKind: InstrumentKind {
        switch self {
        case .vocal: return .vocals
        case .drums: return .drums
        case .bass: return .bass
        case .other: return .other
        }
    }
}
