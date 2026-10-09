import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import SongGraph

// The guides: every section of the open song, rendered with a count-in of click in front, into
// the Mr. Roboto folder the phone is pointed at. Roboto Capture plays a guide in the headphones
// while it records, and names the take with how much of the file is count-in, so the inbox trims
// that off and the take lands on the section's first bar in time with the song.
enum PhoneGuides {

    /// `Guides/guides.json`: what the phone reads to offer a song and a section, and to know how
    /// long each guide's count-in is. The phone keeps a copy of these three types.
    struct Manifest: Codable, Equatable {
        var version: Int = 1
        var writtenAt: String
        var songs: [SongEntry]
    }

    struct SongEntry: Codable, Equatable {
        var title: String
        var tempo: Double
        var beatsPerBar: Int
        var beatUnit: Int
        var sections: [SectionEntry]
    }

    struct SectionEntry: Codable, Equatable {
        var name: String
        var bars: Int
        /// The guide's path under `Guides/`.
        var file: String
        var countInBars: Int
        /// Seconds of click before the section's first beat: the lead the phone reports, before
        /// it adds the latency it measured.
        var countInSeconds: Double
        /// The whole file, count-in and tail included.
        var seconds: Double
    }

    static let manifestName = "guides.json"
    static var folder: URL { InboxWatcher.guidesFolder }

    /// The bars of click a guide leads with: the Booth's count-in when one is set, else one bar.
    /// A singer who wants two bars in the Booth wants them on the phone.
    @MainActor
    static var defaultCountInBars: Int {
        let bars = UserDefaults.standard.integer(forKey: BoothModel.countInKey)
        return (1...2).contains(bars) ? bars : 1
    }

    /// Renders every section of the open song into `folder`, each with `countInBars` of click in
    /// front, and writes the song into the manifest there — in place of its last entry, beside the
    /// other songs'. The section's own takes are left out of its guide, as the Booth leaves them
    /// out: the take before is not in the headphones while the next is sung.
    /// - Returns: the song's folder of guides, and its manifest entry.
    @MainActor
    static func export(_ app: AppState, to folder: URL = PhoneGuides.folder, countInBars: Int = defaultCountInBars,
                       kitsDirectory: URL = AuditionService.defaultKitsDirectory,
                       pacing: SectionBounce.Pacing? = nil) async throws -> (folder: URL, entry: SongEntry) {
        // What is on screen is in the song before it is rendered, as it is before the transport plays.
        app.keepSurfaceWork()
        guard let song = app.song else { throw Failure.noSong }
        guard !song.sections.isEmpty else { throw Failure.noSections }
        var plan = app.playback.looping(false)
        if plan.mix == nil { plan.mix = .unity }
        guard plan.isPlayable else { throw Failure.nothingToBounce }
        if plan.missingMedia {
            app.note(.session, "\(song.title)'s guides went out without some of its audio",
                     detail: "A take or a stem's file is missing from the song's package, so it is not in them.")
        }
        let bars = max(1, countInBars)
        let clock = TransportClock(tempo: song.tempo, timeSignature: song.timeSignature)
        let countInSeconds = Double(bars) * clock.secondsPerBar
        let songFolder = folder.appendingPathComponent(Export.safe(song.title), isDirectory: true)
        try FileManager.default.createDirectory(at: songFolder, withIntermediateDirectories: true)

        var sections: [SectionEntry] = []
        var used: Set<String> = []
        for section in song.sections {
            var one = plan
            let sung = Set(Guidance.takes(in: song).filter { Guidance.audio(of: $0)?.take?.section == section.id }.map(\.partID))
            one.tracks.removeAll { track in track.part.map(sung.contains) ?? false }
            let stems = try await SectionBounce.render(one, section: section.id, kitsDirectory: kitsDirectory,
                                                       onlyTheMix: true, pacing: pacing)
            let channels = max(1, stems.mix.count)
            let lead = countIn(bars: bars, clock: clock, sampleRate: stems.sampleRate, channels: channels)
            let planar = zip(lead, stems.mix).map { $0 + $1 }
            // Two sections with one name are two files: the second is "Verse 2.m4a".
            var name = Export.safe(section.name)
            var n = 2
            while used.contains(name.lowercased()) { name = "\(Export.safe(section.name)) \(n)"; n += 1 }
            used.insert(name.lowercased())
            let url = songFolder.appendingPathComponent("\(name).m4a")
            try? FileManager.default.removeItem(at: url)
            try SongPreviews.writeAAC(planar, sampleRate: stems.sampleRate, to: url)
            sections.append(SectionEntry(name: section.name, bars: section.lengthInBars,
                                         file: "\(songFolder.lastPathComponent)/\(name).m4a",
                                         countInBars: bars, countInSeconds: countInSeconds,
                                         seconds: Double(planar.first?.count ?? 0) / stems.sampleRate))
        }
        // A guide of a section the song no longer has is not left behind to be offered.
        let kept = Set(sections.map { ($0.file as NSString).lastPathComponent.lowercased() })
        for stale in (try? FileManager.default.contentsOfDirectory(atPath: songFolder.path)) ?? []
        where stale.lowercased().hasSuffix(".m4a") && !kept.contains(stale.lowercased()) {
            try? FileManager.default.removeItem(at: songFolder.appendingPathComponent(stale))
        }

        let entry = SongEntry(title: song.title, tempo: song.tempo, beatsPerBar: song.timeSignature.beatsPerBar,
                              beatUnit: song.timeSignature.beatUnit, sections: sections)
        var manifest = readManifest(at: folder) ?? Manifest(writtenAt: "", songs: [])
        manifest.songs.removeAll { $0.title.caseInsensitiveCompare(song.title) == .orderedSame }
        manifest.songs.append(entry)
        manifest.songs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        manifest.writtenAt = ISO8601DateFormatter().string(from: Date())
        try write(manifest, at: folder)
        app.note(.session, "Guides for the phone: \(sections.count) section\(sections.count == 1 ? "" : "s") of \(song.title)",
                 detail: "\(bars) bar\(bars == 1 ? "" : "s") of click in front of each → \(songFolder.path)")
        return (songFolder, entry)
    }

    /// `bars` of click, the Booth's sound — the accent on each bar's first beat — in the silence
    /// before the section. One lane, repeated for every channel the section has.
    static func countIn(bars: Int, clock: TransportClock, sampleRate: Double, channels: Int,
                        sound: Metronome.Sound = .default) -> [[Float]] {
        let beatsPerBar = max(1, clock.timeSignature.beatsPerBar)
        let frames = Int((Double(bars) * clock.secondsPerBar * sampleRate).rounded())
        var lane = [Float](repeating: 0, count: frames)
        if let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) {
            for beat in 0..<(bars * beatsPerBar) {
                let accent = beat % beatsPerBar == 0
                guard let click = AudioSynth.click(format: format, frequency: accent ? sound.accentFrequency : sound.frequency,
                                                   duration: sound.duration, amplitude: accent ? sound.accentAmplitude : sound.amplitude,
                                                   decay: sound.decay),
                      let data = click.floatChannelData?[0] else { continue }
                let at = Int((clock.seconds(forBeat: Double(beat)) * sampleRate).rounded())
                for i in 0..<Int(click.frameLength) where at + i < frames { lane[at + i] += data[i] }
            }
        }
        return Array(repeating: lane, count: max(1, channels))
    }

    static func readManifest(at folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    static func write(_ manifest: Manifest, at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent(manifestName), options: .atomic)
    }

    enum Failure: Error, CustomStringConvertible {
        case noSong, noSections, nothingToBounce
        var description: String {
            switch self {
            case .noSong: return "No song is open."
            case .noSections: return "The song has no sections to guide: give it a form on the Structure surface first."
            case .nothingToBounce: return "The song plays nothing, so there is nothing to sing to."
            }
        }
    }
}
