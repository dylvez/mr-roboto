import AudioEngine
import AVFAudio
import Foundation
import ImageIO
import Performance
import SongGraph
import UniformTypeIdentifiers

// M6 X10: the door out. A master (24-bit WAV and a report, or an MP3 to send), the stems (one WAV
// per strip, through its strip, dry of the master), the written parts as MIDI, and the words as a
// lyric sheet.

public enum Export {

    /// What left with the master.
    public struct MasterReport: Codable, Sendable {
        public struct Clearance: Codable, Sendable {
            public var source: String
            public var status: String
        }
        public var song: String
        public var artist: String
        public var mixVersion: String?
        public var sampleRate: Double
        public var bitDepth: Int
        public var durationSeconds: Double
        public var integratedLUFS: Double
        public var truePeakDBTP: Double
        public var crestDB: Double
        public var targetLUFS: Double
        public var ceilingDBTP: Double
        public var key: String?
        public var tempo: Double
        public var clearances: [Clearance]
        public var exportedAt: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case noSong, nothingToBounce, noWrittenParts, noWords
        public var description: String {
            switch self {
            case .noSong: return "No song is open."
            case .nothingToBounce: return "The song plays nothing, so there is nothing to bounce."
            case .noWrittenParts: return "The song has no written parts to put in a MIDI file."
            case .noWords: return "The song has no words to write out. Write them on the Lyrics surface."
            }
        }
    }

    /// Where exports go when nobody chose: ~/Music/Mr. Roboto/Exports/<song>.
    public static func defaultDirectory(for song: Song) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Mr. Roboto/Exports", isDirectory: true)
        return base.appendingPathComponent(safe(song.title), isDirectory: true)
    }

    static func safe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        // "." and ".." are this folder and the one above it, not names.
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    /// A path nothing is at yet: the one asked for, or the same name with " 2", " 3"… before the
    /// extension. An export used to delete whatever was at its path first, so exporting twice
    /// silently replaced the first master — the one you might already have sent somewhere.
    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) \(suffix)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    /// The whole song through the mix, limited at the ceiling, as a 24-bit WAV beside a JSON report.
    @MainActor
    public static func master(_ app: AppState, to directory: URL) async throws -> (wav: URL, report: URL, summary: MasterReport) {
        // What is on screen is in the song before it leaves, as it is before the transport plays.
        app.keepSurfaceWork()
        guard let song = app.song else { throw Failure.noSong }
        return try await master(of: song, plan: app.playback, in: app, to: directory)
    }

    /// Any song in the library, open or not, exported the same way: its own plan, read from its own
    /// package. `pacing` shares the audio actor while it renders, for a batch of them.
    @MainActor
    static func master(of song: Song, plan given: SongPlayback, in app: AppState, to directory: URL,
                       pacing: SectionBounce.Pacing? = nil) async throws -> (wav: URL, report: URL, summary: MasterReport) {
        let (plan, stems) = try await renderMaster(of: song, plan: given, in: app, to: directory, pacing: pacing)
        let planar = stems.mix
        let wav = unique(directory.appendingPathComponent("\(safe(song.title)) — master.wav"))
        try writeWAV24(planar, sampleRate: stems.sampleRate, to: wav)
        let mix = plan.mix ?? .unity
        let clearances = app.library.albums.first { $0.songs.contains(song.id) }.map { app.sources(of: $0) } ?? []
        let summary = MasterReport(
            song: song.title, artist: song.artist, mixVersion: plan.mixVersion?.description,
            sampleRate: stems.sampleRate, bitDepth: 24, durationSeconds: Double(planar.first?.count ?? 0) / stems.sampleRate,
            integratedLUFS: MixMeter.integratedLoudness(planar, sampleRate: stems.sampleRate),
            truePeakDBTP: MixMeter.truePeakDB(planar, sampleRate: stems.sampleRate),
            crestDB: MixMeter.crestDB(planar),
            targetLUFS: mix.master.targetLUFS, ceilingDBTP: mix.master.ceilingDBTP,
            key: song.key.map { "\($0)" }, tempo: song.tempo,
            clearances: clearances.map { .init(source: $0.source, status: $0.status.rawValue) },
            exportedAt: ISO8601DateFormatter().string(from: Date()))
        let report = wav.deletingPathExtension().appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: report)
        app.note(.session, "Exported the master", detail: String(format: "%.1f LUFS, true peak %.1f dBTP → %@", summary.integratedLUFS, summary.truePeakDBTP, wav.path))
        return (wav, report, summary)
    }

    /// The same master as an MP3 to send: 320 kbps, tagged with the title and the artist and, for
    /// a song on an album, the album, its artist, the track's number and the cover. No report
    /// beside it: that goes with the WAV, the print of record.
    @MainActor
    public static func masterMP3(_ app: AppState, to directory: URL) async throws -> URL {
        app.keepSurfaceWork()
        guard let song = app.song else { throw Failure.noSong }
        return try await masterMP3(of: song, plan: app.playback, in: app, to: directory)
    }

    /// Any song in the library as an MP3, as `master(of:)` renders it.
    @MainActor
    static func masterMP3(of song: Song, plan given: SongPlayback, in app: AppState, to directory: URL,
                          pacing: SectionBounce.Pacing? = nil) async throws -> URL {
        let (_, stems) = try await renderMaster(of: song, plan: given, in: app, to: directory, pacing: pacing)
        let mp3 = unique(directory.appendingPathComponent("\(safe(song.title)) — master.mp3"))
        let tags = mp3Tags(for: song, in: app)
        // Off the main actor: LAME takes seconds over a whole song, and the window would stop.
        try await Task.detached(priority: .userInitiated) {
            try MP3Writer.write(stems.mix, sampleRate: stems.sampleRate, tags: tags, to: mp3)
        }.value
        app.note(.session, "Exported the master as MP3",
                 detail: String(format: "%.1f LUFS, true peak %.1f dBTP before encoding, %d kbps → %@",
                                MixMeter.integratedLoudness(stems.mix, sampleRate: stems.sampleRate),
                                MixMeter.truePeakDB(stems.mix, sampleRate: stems.sampleRate), MP3Writer.bitRate, mp3.path))
        return mp3
    }

    /// The whole song through the mix, limited at the ceiling: what a master of either kind is
    /// written from.
    @MainActor
    private static func renderMaster(of song: Song, plan given: SongPlayback, in app: AppState, to directory: URL,
                                     pacing: SectionBounce.Pacing?) async throws -> (plan: SongPlayback, stems: SectionBounce.Stems) {
        var plan = given.looping(false)
        // A song never mixed goes out on the mix the Master tab reads it on — the album's target
        // and ceiling — not on none.
        if plan.mix == nil {
            var unity = Mix.unity
            if let album = app.library.albums.first(where: { $0.songs.contains(song.id) }) {
                unity.master = Master(gainDB: 0, ceilingDBTP: album.targets.truePeakDBTP, targetLUFS: album.targets.integratedLUFS)
            }
            plan.mix = unity
        }
        guard plan.isPlayable else { throw Failure.nothingToBounce }
        if plan.missingMedia {
            app.note(.session, "\(song.title) went out without some of its audio",
                     detail: "A take or a stem's file is missing from the song's package, so it is not in the master.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stems = try await SectionBounce.render(plan, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory,
                                                   onlyTheMix: true, pacing: pacing)
        return (plan, stems)
    }

    /// What an MP3's tag says of `song`: the album is the first one it is on, as for the mastering
    /// targets, and the year is the year it was exported.
    @MainActor
    static func mp3Tags(for song: Song, in app: AppState, now: Date = Date()) -> MP3Writer.Tags {
        var tags = MP3Writer.Tags(title: song.title, artist: song.artist,
                                  year: Calendar(identifier: .gregorian).component(.year, from: now))
        if let album = app.library.albums.first(where: { $0.songs.contains(song.id) }),
           let index = album.songs.firstIndex(of: song.id) {
            tags.album = album.title
            tags.albumArtist = album.artist
            tags.track = index + 1
            tags.trackCount = album.songs.count
            tags.cover = coverForTag(of: album, in: app)
        }
        // A song's own artist left blank is the album's.
        if song.artist.trimmingCharacters(in: .whitespaces).isEmpty { tags.artist = tags.albumArtist }
        return tags
    }

    /// The album's cover as a JPEG at most 600 pixels across: small enough to ride in every
    /// track's tag, large enough for a player's artwork. Nil when there is none to read.
    @MainActor
    static func coverForTag(of album: Album, in app: AppState) -> Data? {
        let source: Data?
        switch album.cover {
        case .image(let media):
            source = (try? app.store?.mediaURL(for: media)).flatMap { try? Data(contentsOf: $0) }
        case .drawn(let design):
            source = CoverRenderer.png(design, title: album.title, artist: album.artist, pixels: 600)
        }
        guard let source, let image = CGImageSourceCreateWithData(source as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// One WAV per strip, each bounced alone through its strip, dry of the master's gain and
    /// ceiling, so they sum to the mix before mastering.
    @MainActor
    public static func stems(_ app: AppState, to directory: URL) async throws -> [URL] {
        app.keepSurfaceWork()
        guard let song = app.song else { throw Failure.noSong }
        let plan = app.playback.looping(false)
        guard plan.isPlayable else { throw Failure.nothingToBounce }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [URL] = []
        let base = plan.mix ?? .unity
        for strip in heardStrips(of: plan, song: song) {
            var solo = plan
            var mix = base
            mix.strips = mix.strips.map { var s = $0; s.isSoloed = s.part == strip.part; s.isMuted = false; return s }
            var own = mix.strip(for: strip.part, label: strip.label)
            own.isSoloed = true
            mix.set(own)
            mix.master.gainDB = 0
            // Nor a fade: a stem is the strip, and the ending is the master's.
            mix.master.fadeOutBars = nil
            solo.mix = mix
            // Not mastered — no limiter at all — and written as floats, so a strip hotter than full
            // scale is kept as it is and the stems still add up to the mix before the master. They
            // used to be limited just under 0 and then clamped.
            let stems = try await SectionBounce.render(solo, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory,
                                                       onlyTheMix: true, mastered: false)
            let url = unique(directory.appendingPathComponent("\(safe(song.title)) — \(safe(strip.label)).wav"))
            try writeWAVFloat(stems.mix, sampleRate: stems.sampleRate, to: url)
            out.append(url)
        }
        app.note(.session, "Exported \(out.count) stem\(out.count == 1 ? "" : "s")", detail: directory.path)
        return out
    }

    /// The strips a stem is written for: the ones the mix is heard with. A muted strip is not in
    /// the mix, and with any soloed only the soloed are; a strip for a part the song no longer
    /// plays would be a silent file. Stems used to clear mutes and solos and write every strip.
    @MainActor
    static func heardStrips(of plan: SongPlayback, song: Song) -> [(part: PartID, label: String)] {
        let base = plan.mix ?? .unity
        let playing = Set(plan.parts + plan.tracks.compactMap(\.part))
        let soloing = base.strips.contains { $0.isSoloed }
        return MixReader.strips(of: plan, song: song).filter { strip in
            guard playing.contains(strip.part) else { return false }
            guard let set = base.strip(for: strip.part) else { return !soloing }
            return !set.isMuted && (!soloing || set.isSoloed)
        }
    }

    /// The written parts as one Standard MIDI File.
    @MainActor
    public static func midi(_ app: AppState, to directory: URL) throws -> URL {
        app.keepSurfaceWork()
        guard let song = app.song else { throw Failure.noSong }
        let file = MIDIExport.file(for: song)
        guard !file.tracks.isEmpty else { throw Failure.noWrittenParts }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = unique(directory.appendingPathComponent("\(safe(song.title)).mid"))
        try file.write(to: url)
        app.note(.session, "Exported \(file.tracks.count) track\(file.tracks.count == 1 ? "" : "s") of MIDI", detail: url.path)
        return url
    }

    /// The song's words as a lyric sheet: the title, the artist when there is one, and the newest
    /// lyric with its stanza labels — "[Verse]", "[Hook]" — as they were written. Nil when the song
    /// has no lyric with anything to sing in it.
    public static func lyricSheet(for song: Song) -> String? {
        guard let version = song.versions.last(where: { $0.type == .lyric }), case .lyric(let lyric) = version.kind,
              lyric.lines.contains(where: { !$0.syllables.isEmpty }) else { return nil }
        var head = [song.title]
        if !song.artist.trimmingCharacters(in: .whitespaces).isEmpty { head.append(song.artist) }
        let words = lyric.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.joined(separator: "\n") + "\n\n" + words + "\n"
    }

    /// The lyric sheet as a UTF-8 text file beside the other exports.
    @MainActor
    public static func lyrics(_ app: AppState, to directory: URL) throws -> URL {
        app.keepSurfaceWork()
        guard let song = app.song else { throw Failure.noSong }
        guard let sheet = lyricSheet(for: song) else { throw Failure.noWords }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = unique(directory.appendingPathComponent("\(safe(song.title)) — lyrics.txt"))
        try Data(sheet.utf8).write(to: url, options: .withoutOverwriting)
        app.note(.session, "Exported the lyrics", detail: url.path)
        return url
    }

    /// 32-bit float PCM: a stem, which is not mastered and may run past full scale.
    public static func writeWAVFloat(_ planar: [[Float]], sampleRate: Double, to url: URL) throws {
        let channels = AVAudioChannelCount(max(1, planar.count))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = planar.first?.count ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let lane = planar[min(channel, planar.count - 1)]
            for i in 0..<frames { buffer.floatChannelData![channel][i] = lane[i] }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// 24-bit linear PCM, the sample rate as rendered.
    public static func writeWAV24(_ planar: [[Float]], sampleRate: Double, to url: URL) throws {
        let channels = AVAudioChannelCount(max(1, planar.count))
        let processing = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let frames = planar.first?.count ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let lane = planar[min(channel, planar.count - 1)]
            for i in 0..<frames { buffer.floatChannelData![channel][i] = max(-1, min(1, lane[i])) }
        }
        // Never over something already there: the callers pick a free name with `unique`, and a
        // caller that did not gets the error rather than a file quietly gone. `AVAudioFile` itself
        // replaces whatever is at the path without a word, so it is asked here.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

extension AppState {
    /// M6 X11: a Standard MIDI File's tracks as parts of the open song.
    @discardableResult
    public func importMIDI(from url: URL) -> [PartVersion] {
        guard let song else {
            note(.session, "No song open to import MIDI into")
            return []
        }
        let file: MIDIFile
        do { file = try MIDIFile(contentsOf: url) } catch {
            note(.session, "\(url.lastPathComponent) could not be read", detail: "\(error)")
            return []
        }
        let imported = MIDIImport.parts(from: file, key: song.key)
        var versions: [PartVersion] = []
        for part in imported.parts {
            let version = PartVersion(partID: PartID(), kind: part.kind, author: .user, operation: Operation.imported,
                                      note: "\(part.name), from \(url.lastPathComponent)")
            if record(version) { versions.append(version) }
        }
        if song.versions.isEmpty, imported.tempo > 0, abs(imported.tempo - song.tempo) > 0.5 {
            updateSong { $0.tempo = imported.tempo }
        }
        note(.session, "Imported \(versions.count) part\(versions.count == 1 ? "" : "s") from \(url.lastPathComponent)",
             detail: imported.parts.map(\.name).joined(separator: ", "))
        return versions
    }
}
