import AVFAudio
import Foundation
import Performance
import SongGraph

// M6 X10: the door out. A master (24-bit WAV and a report), the stems (one WAV per strip, through
// its strip, dry of the master), and the written parts as MIDI.

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
        case noSong, nothingToBounce, noWrittenParts
        public var description: String {
            switch self {
            case .noSong: return "No song is open."
            case .nothingToBounce: return "The song plays nothing, so there is nothing to bounce."
            case .noWrittenParts: return "The song has no written parts to put in a MIDI file."
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
        return cleaned.isEmpty ? "Untitled" : cleaned
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
        guard let song = app.song else { throw Failure.noSong }
        let plan = app.playback.looping(false)
        guard plan.isPlayable else { throw Failure.nothingToBounce }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stems = try await SectionBounce.render(plan, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory)
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

    /// One WAV per strip, each bounced alone through its strip, dry of the master's gain and
    /// ceiling, so they sum to the mix before mastering.
    @MainActor
    public static func stems(_ app: AppState, to directory: URL) async throws -> [URL] {
        guard let song = app.song else { throw Failure.noSong }
        let plan = app.playback.looping(false)
        guard plan.isPlayable else { throw Failure.nothingToBounce }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [URL] = []
        for strip in MixReader.strips(of: plan, song: song) {
            var solo = plan
            var mix = plan.mix ?? .unity
            mix.strips = mix.strips.map { var s = $0; s.isSoloed = s.part == strip.part; s.isMuted = false; return s }
            var own = mix.strip(for: strip.part, label: strip.label)
            own.isSoloed = true
            mix.set(own)
            mix.master.gainDB = 0
            solo.mix = mix
            // No ceiling on a stem: `renderOne` reads the plan's master for the limiter, so the
            // master is at unity and the ceiling is lifted to 0 with its head room.
            solo.mix?.master.ceilingDBTP = 0
            let stems = try await SectionBounce.render(solo, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory)
            let url = unique(directory.appendingPathComponent("\(safe(song.title)) — \(safe(strip.label)).wav"))
            try writeWAV24(stems.mix, sampleRate: stems.sampleRate, to: url)
            out.append(url)
        }
        app.note(.session, "Exported \(out.count) stem\(out.count == 1 ? "" : "s")", detail: directory.path)
        return out
    }

    /// The written parts as one Standard MIDI File.
    @MainActor
    public static func midi(_ app: AppState, to directory: URL) throws -> URL {
        guard let song = app.song else { throw Failure.noSong }
        let file = MIDIExport.file(for: song)
        guard !file.tracks.isEmpty else { throw Failure.noWrittenParts }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = unique(directory.appendingPathComponent("\(safe(song.title)).mid"))
        try file.write(to: url)
        app.note(.session, "Exported \(file.tracks.count) track\(file.tracks.count == 1 ? "" : "s") of MIDI", detail: url.path)
        return url
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
        // caller that did not gets the error rather than a file quietly gone.
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
