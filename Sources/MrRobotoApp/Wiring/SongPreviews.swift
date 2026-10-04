import AVFAudio
import CryptoKit
import Foundation
import SongGraph

/// A whole song heard without opening it: rendered through its own playback plan the way its
/// master is — every section in order, limited at its ceiling, faded as it ends — and kept as a
/// compressed file in the caches. Named by the song and by a digest of what it holds, so a song
/// changed since makes a new one, and nothing is ever written into the library.
enum SongPreviews {
    /// Raised when the render changes what a preview sounds like, so every older one is made again.
    static let renderVersion = 1

    /// `~/Library/Caches/MrRoboto/previews`. Deleting it costs a render per song, never a version.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("MrRoboto/previews", isDirectory: true)
    }

    enum Failure: Error, CustomStringConvertible {
        case nothingToHear(String)
        case unwritable(String)

        var description: String {
            switch self {
            case .nothingToHear(let why): return why
            case .unwritable(let why): return "The preview could not be written: \(why)"
            }
        }
    }

    /// "<song id>-<digest>-r1.m4a": the song, what it holds as it would be saved, and the render.
    static func fileName(for song: Song) throws -> String {
        let digest = SHA256.hash(data: try SongGraphCodec.encodeSong(song)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(song.id.rawValue.uuidString)-\(digest)-r\(renderVersion).m4a"
    }

    /// The preview of the song as it stands, when one has been made.
    static func cached(_ song: Song, in directory: URL = defaultDirectory) -> URL? {
        guard let name = try? fileName(for: song) else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The song's plan, read from its own package: the plan the transport would play it by.
    static func plan(for song: Song, store: LibraryStore?) -> SongPlayback {
        SongPlayback.plan(for: song) { ref in try? store?.mediaURL(for: ref, song: song.id) }.looping(false)
    }

    /// Renders the song and keeps it, letting go of the song's older previews. Returns where it is.
    ///
    /// Paced, a quarter of a second at a time: a whole song takes from seconds to minutes to render,
    /// and the audio actor it renders on is the one every other sound in the app goes through.
    /// Cancelling the task stops it between pieces, and nothing is written.
    static func make(_ song: Song, store: LibraryStore?, in directory: URL = defaultDirectory,
                     kitsDirectory: URL = AuditionService.defaultKitsDirectory,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let url = directory.appendingPathComponent(try fileName(for: song))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let plan = plan(for: song, store: store)
        guard plan.isPlayable else {
            throw Failure.nothingToHear(plan.silence?.headline ?? "\(song.title) plays nothing yet.")
        }
        let stems = try await SectionBounce.render(plan, section: nil, kitsDirectory: kitsDirectory, onlyTheMix: true,
                                                   pacing: .init(frames: 12_000, progress: progress))
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).m4a")
        do {
            try writeAAC(stems.mix, sampleRate: stems.sampleRate, to: partial)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.unwritable("\(error)")
        }
        forgetOlder(than: url, of: song, in: directory)
        return url
    }

    /// Every other preview of this song: a song changed since, or a render since replaced.
    static func forgetOlder(than kept: URL, of song: Song, in directory: URL) {
        let prefix = song.id.rawValue.uuidString + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name != kept.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// AAC at 192 kbps, about 1.4 MB a minute of stereo.
    static func writeAAC(_ planar: [[Float]], sampleRate: Double, to url: URL) throws {
        let channels = max(1, min(2, planar.count))
        let frames = planar.first?.count ?? 0
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw Failure.unwritable("nothing to write")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            planar[channel].withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: frames)
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
