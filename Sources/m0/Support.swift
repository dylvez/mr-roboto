import AVFAudio
import Analysis
import AnalysisMLX
import ArgumentParser
import CryptoKit
import Foundation
import MusicTheory
import Synchronization

// Shared plumbing for the m0 subcommands: typed errors, path helpers, audio loading, the
// provider registry the CLI uses, an on-disk analysis cache, and progress printing.

// MARK: - Errors

/// Every failure the CLI raises itself. Package errors (`AnalysisError`, `DemucsSeparatorError`,
/// `SongGraphError`) already describe themselves and pass through untouched; `EngineError` does
/// not, so engine failures are wrapped in `.engine`.
enum CLIError: Error, CustomStringConvertible, LocalizedError {
    case fileNotFound(String)
    case notAudio(String, reason: String)
    case noBeatGrid(String)
    case barRangeOutOfGrid(startBar: Int, bars: Int, barCount: Int)
    case regionOutsideAudio(startFrame: Int, endFrame: Int, frames: Int, file: String)
    case stemMissing(stem: String, directory: String, available: [String])
    case engine(String)
    case engineUnavailable(String)
    case invalidOption(String)
    case notADirectory(String)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "file not found: \(path)"
        case .notAudio(let path, let reason):
            return "could not open \(path) as audio: \(reason)"
        case .noBeatGrid(let name):
            return "the analysis of \(name) has no beats, so no bars can be looped"
        case .barRangeOutOfGrid(let startBar, let bars, let barCount):
            return "bars \(startBar)..<\(startBar + bars) are outside the grid, which has \(barCount) bars (0..<\(barCount))"
        case .regionOutsideAudio(let startFrame, let endFrame, let frames, let file):
            return "the loop region (frames \(startFrame)..<\(endFrame)) runs past the end of \(file) (\(frames) frames); the stem is shorter than the analysed file"
        case .stemMissing(let stem, let directory, let available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "no \(stem).wav in \(directory) (available: \(list)); run `m0 separate` first or pass --stem mix"
        case .engine(let reason):
            return "audio engine: \(reason)"
        case .engineUnavailable(let reason):
            return "the realtime audio engine could not start (\(reason)). Realtime playback needs an output device: run this from a normal Terminal, or use `m0 bounce` to render offline."
        case .invalidOption(let reason):
            return reason
        case .notADirectory(let path):
            return "\(path) exists but is not a directory"
        }
    }

    var errorDescription: String? { description }
}

/// `EngineError` is a bare enum; give it a sentence for the CLI.
func describe(_ error: Error) -> String {
    if let engine = error as? EngineErrorDescribing { return engine.cliDescription }
    return "\(error)"
}

protocol EngineErrorDescribing { var cliDescription: String { get } }

// MARK: - Output

/// Write a line to stderr (progress, notes) so stdout stays clean for `--json`.
func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func secondsText(_ value: Double, _ digits: Int = 3) -> String {
    String(format: "%.\(digits)f s", value)
}

/// `m:ss.mmm` for positions in a track.
func timestamp(_ value: Double) -> String {
    let whole = Int(value.rounded(.down))
    let millis = Int(((value - Double(whole)) * 1000).rounded())
    return String(format: "%d:%02d.%03d", whole / 60, whole % 60, min(millis, 999))
}

func megabytes(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
func megabytes(_ bytes: Int) -> String { megabytes(UInt64(max(bytes, 0))) }

struct Stopwatch {
    let start = ContinuousClock.now
    var elapsed: Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

// MARK: - Paths

func expandingTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }

/// A URL for a user-supplied path, tilde expanded and standardized.
func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: expandingTilde(path)).standardizedFileURL
}

/// The input file, checked to exist.
func resolveInputFile(_ path: String) throws -> URL {
    let url = fileURL(path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.fileNotFound(url.path) }
    return url
}

/// `<Name>.stems/` beside `<Name>.<ext>`: where `m0 separate` writes and `m0 loop` / `m0 import` look.
func stemsDirectory(for file: URL) -> URL {
    file.deletingPathExtension().appendingPathExtension("stems")
}

/// The stem WAVs present in `directory`, by name.
func existingStems(in directory: URL) -> [StemName: URL] {
    var found: [StemName: URL] = [:]
    for name in StemName.allCases {
        let url = directory.appendingPathComponent("\(name.rawValue).wav")
        if FileManager.default.fileExists(atPath: url.path) { found[name] = url }
    }
    return found
}

// MARK: - Audio

/// A whole file decoded to float32 at its own sample rate, ready for the engine.
struct LoadedAudio: Sendable {
    let url: URL
    let buffer: AVReadOnlyAudioPCMBuffer
    let sampleRate: Double
    let channels: Int
    let frames: Int

    var duration: Double { Double(frames) / sampleRate }
}

func loadAudio(_ url: URL) throws -> LoadedAudio {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw CLIError.notAudio(url.path, reason: error.localizedDescription)
    }
    let format = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw CLIError.notAudio(url.path, reason: "empty file or unsupported format \(format)")
    }
    do {
        try file.read(into: buffer)
    } catch {
        throw CLIError.notAudio(url.path, reason: error.localizedDescription)
    }
    return LoadedAudio(url: url, buffer: AVReadOnlyAudioPCMBuffer(copying: buffer),
                       sampleRate: format.sampleRate, channels: Int(format.channelCount), frames: Int(buffer.frameLength))
}

/// Sample rate, channel count and duration without decoding the audio.
struct AudioInfo {
    let sampleRate: Double
    let channels: Int
    let duration: Double
}

func audioInfo(_ url: URL) throws -> AudioInfo {
    do {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        return AudioInfo(sampleRate: format.sampleRate, channels: Int(format.channelCount),
                         duration: Double(file.length) / format.sampleRate)
    } catch {
        throw CLIError.notAudio(url.path, reason: error.localizedDescription)
    }
}

// MARK: - Providers

/// The registry every command uses: Music Understanding for the whole-track capabilities and
/// Demucs on MLX for stem separation.
func makeProviders() -> AnalysisProviders {
    var providers = AnalysisProviders.makeDefault()
    providers.register(DemucsSeparator(), for: [.stemSeparation])
    return providers
}

extension DemucsModel: ExpressibleByArgument {}

/// Runs the Demucs separator on `url`, writing `<stem>.wav` files into `directory`, with progress on stderr.
func separateStems(url: URL, model: DemucsModel, into directory: URL) async throws -> StemSeparationResult {
    let separator = try makeProviders().stemSeparator()
    let progress = ProgressPrinter(label: "separating \(url.lastPathComponent) with \(model.rawValue)")
    let options = StemSeparationOptions(model: model.rawValue, outputDirectory: directory)
    let result = try await separator.separate(.file(url), options: options) { progress.report($0) }
    progress.finish()
    return result
}

// MARK: - Analysis, with an on-disk cache

/// Music Understanding takes ~20 s per file and `MusicUnderstandingProvider` only caches in memory,
/// so the CLI keeps each report as JSON under `~/Library/Caches/MrRoboto/analysis/`, keyed by the
/// file's path, size and modification date. `--no-cache` bypasses it.
enum ReportCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("MrRoboto/analysis", isDirectory: true)
    }

    static func location(for url: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)|\(size)|\(modified)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    static func load(for url: URL) -> AnalysisReport? {
        guard let location = location(for: url), FileManager.default.fileExists(atPath: location.path) else { return nil }
        return try? AnalysisReport(contentsOf: location)
    }

    static func store(_ report: AnalysisReport, for url: URL) {
        guard let location = location(for: url) else { return }
        try? report.write(to: location)
    }
}

/// The Music Understanding report for `url`: from the disk cache when allowed, else a fresh run
/// through the default providers (which is then cached).
func analysisReport(for url: URL, useCache: Bool) async throws -> (report: AnalysisReport, cached: Bool) {
    if useCache, let cached = ReportCache.load(for: url) { return (cached, true) }
    note("analysing \(url.lastPathComponent) with Music Understanding …")
    var report = try await makeProviders().analyze(url: url)
    // `AnalysisProviders.analyze` merges capability results only and drops the provider's duration.
    if report.duration == nil, let info = try? audioInfo(url) { report.duration = info.duration }
    ReportCache.store(report, for: url)
    return (report, false)
}

// MARK: - Progress

/// Prints a 0…1 progress fraction on stderr every 5 %, on one updating line.
final class ProgressPrinter: Sendable {
    private let label: String
    private let lastStep = Mutex<Int>(-1)

    init(label: String) {
        self.label = label
    }

    func report(_ fraction: Double) {
        let step = Int((fraction * 20).rounded(.down))
        let changed = lastStep.withLock { last -> Bool in
            guard step > last else { return false }
            last = step
            return true
        }
        guard changed else { return }
        FileHandle.standardError.write(Data("\r\(label) … \(step * 5)%".utf8))
    }

    func finish() {
        FileHandle.standardError.write(Data("\r\(label) … done\n".utf8))
    }
}
