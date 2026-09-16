import AVFAudio
import Analysis
import AnalysisMLX
import ArgumentParser
import AudioEngine
import Foundation
import MusicTheory

// `m0 loop` and `m0 bounce` share everything but the last step: loop plays the schedule through
// the realtime engine, bounce renders the same schedule offline to a WAV.

// MARK: - Options

enum StemChoice: String, CaseIterable, ExpressibleByArgument {
    case drums, bass, other, vocals, mix, none

    /// The Demucs stem, or nil for the whole file (`mix`) or the click alone (`none`).
    var stemName: StemName? {
        switch self {
        case .drums: return .drums
        case .bass: return .bass
        case .other: return .other
        case .vocals: return .vocals
        case .mix, .none: return nil
        }
    }

    /// `none` renders the click track alone; the file is still loaded for its timeline.
    var playsAudio: Bool { self != .none }
}

struct LoopOptions: ParsableArguments {
    @Argument(help: "Audio file to loop.")
    var file: String

    @Option(help: "How many bars to loop.")
    var bars: Int = 4

    @Option(name: .customLong("start-bar"), help: "First bar of the loop, 0-based, counted on the analysed grid.")
    var startBar: Int = 0

    @Option(help: "What to play: drums, bass, other, vocals (separated with Demucs, reusing <Name>.stems/ if present), mix (the file itself) or none (click only).")
    var stem: StemChoice = .drums

    @Flag(inversion: .prefixedNo, help: "Click on every beat, accented on bar starts.")
    var click: Bool = true

    @Option(help: "Demucs model, if a stem has to be separated.")
    var model: DemucsModel = .htdemucs

    @Flag(name: .customLong("no-cache"), help: "Ignore the cached analysis and analyse again.")
    var noCache = false

    func validate() throws {
        guard bars >= 1 else { throw ValidationError("--bars must be at least 1") }
        guard startBar >= 0 else { throw ValidationError("--start-bar must be 0 or more") }
    }
}

// MARK: - Plan

/// Everything the engine needs, computed once and shared by realtime and offline playback.
struct LoopPlan: Sendable {
    /// The analysed grid on the source file's timeline.
    let sourceGrid: BeatGrid
    let startBar: Int
    let endBar: Int
    /// Region on the source timeline, in seconds and in frames (rounded the way `LoopPlayer` rounds).
    let regionStart: Double
    let regionEnd: Double
    let startFrame: Int
    let endFrame: Int
    let sampleRate: Double
    /// Iterations to play, and the frames that covers.
    let iterations: Int
    let totalFrames: Int
    /// Beat and bar times on the transport timeline for every iteration: iteration 0 starts at 0.
    let clickGrid: BeatGrid
    let click: Bool
    /// False for `--stem none`: only the click is scheduled.
    let playsAudio: Bool

    var regionFrames: Int { endFrame - startFrame }
    /// One iteration, as the engine will play it (frame-exact, so it can differ from `regionEnd - regionStart` by under a sample).
    var period: Double { Double(regionFrames) / sampleRate }
    var bars: Int { endBar - startBar }
    var totalSeconds: Double { Double(totalFrames) / sampleRate }

    var clock: TransportClock {
        let bpm = sourceGrid.bpm ?? 120
        return TransportClock(tempo: bpm > 0 ? bpm : 120, timeSignature: sourceGrid.timeSignature, sampleRate: sampleRate)
    }

    /// - Parameter seconds: how long to play; nil plays the region exactly once.
    init(grid: BeatGrid, startBar: Int, bars: Int, audio: LoadedAudio, seconds: Double?, click: Bool, playsAudio: Bool = true) throws {
        let endBar = startBar + bars
        guard let start = grid.time(ofBar: startBar), let end = grid.time(ofBar: endBar), start < end else {
            throw CLIError.barRangeOutOfGrid(startBar: startBar, bars: bars, barCount: grid.barCount)
        }
        let sampleRate = audio.sampleRate
        let startFrame = Int((start * sampleRate).rounded())
        let endFrame = Int((end * sampleRate).rounded())
        guard startFrame >= 0, endFrame > startFrame, endFrame <= audio.frames else {
            throw CLIError.regionOutsideAudio(startFrame: startFrame, endFrame: endFrame, frames: audio.frames, file: audio.url.lastPathComponent)
        }
        let regionFrames = endFrame - startFrame
        let period = Double(regionFrames) / sampleRate

        let iterations: Int
        let totalFrames: Int
        if let seconds {
            totalFrames = max(1, Int((seconds * sampleRate).rounded()))
            iterations = (totalFrames + regionFrames - 1) / regionFrames
        } else {
            iterations = 1
            totalFrames = regionFrames
        }

        // Beats and bars inside [start, end), moved so the region starts at transport zero, then tiled.
        let epsilon = 1e-6
        let beatsInRegion = grid.beats.filter { $0 >= start - epsilon && $0 < end - epsilon }.map { $0 - start }
        let barsInRegion = grid.bars.filter { $0 >= start - epsilon && $0 < end - epsilon }.map { $0 - start }
        var beats: [Double] = []
        var bars: [Double] = []
        for k in 0..<iterations {
            let offset = Double(k) * period
            beats.append(contentsOf: beatsInRegion.map { $0 + offset })
            bars.append(contentsOf: barsInRegion.map { $0 + offset })
        }

        self.sourceGrid = grid
        self.startBar = startBar
        self.endBar = endBar
        self.regionStart = start
        self.regionEnd = end
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.sampleRate = sampleRate
        self.iterations = iterations
        self.totalFrames = totalFrames
        self.clickGrid = BeatGrid(beats: beats, bars: bars, bpm: grid.bpm, timeSignature: grid.timeSignature)
        self.click = click
        self.playsAudio = playsAudio
    }

    /// The grid times in use, for the user.
    func describe(source: LoadedAudio, report: AnalysisReport) -> String {
        var lines: [String] = []
        let bpm = sourceGrid.bpm.map { String(format: "%.1f", $0) } ?? "?"
        let provider = report.provenance[.beats] ?? "?"
        lines.append("grid   \(bpm) bpm \(sourceGrid.timeSignature), \(sourceGrid.beatCount) beats, \(sourceGrid.barCount) bars (\(provider))")
        lines.append(String(format: "source %@  %.0f Hz, %d ch, %@", source.url.lastPathComponent, sampleRate, source.channels, secondsText(source.duration, 2)))
        lines.append(String(format: "loop   bars %d..<%d  %@ – %@  (%.3f s = %d frames)", startBar, endBar, timestamp(regionStart), timestamp(regionEnd), period, regionFrames))
        for bar in startBar..<endBar {
            guard let bounds = sourceGrid.bounds(ofBar: bar) else { continue }
            let beats = sourceGrid.beats.filter { $0 >= bounds.start - 1e-6 && $0 < bounds.end - 1e-6 }
            let list = beats.map { String(format: "%.3f", $0) }.joined(separator: " ")
            lines.append(String(format: "  bar %-3d %@  beats %@", bar, timestamp(bounds.start), list))
        }
        let clicks = click ? "\(clickGrid.beatCount) clicks (\(clickGrid.barCount) accented)" : "no click"
        let audio = playsAudio ? "" : ", click only (no audio)"
        lines.append(String(format: "play   %d iteration%@ = %.3f s, %@%@", iterations, iterations == 1 ? "" : "s", totalSeconds, clicks, audio))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Preparation

/// Analyse, find or separate the stem, load it, and build the plan.
func prepareLoop(_ options: LoopOptions, seconds: Double?) async throws -> (plan: LoopPlan, audio: LoadedAudio, report: AnalysisReport) {
    let url = try resolveInputFile(options.file)
    var (report, cached) = try await analysisReport(for: url, useCache: !options.noCache)
    if let diag = ProcessInfo.processInfo.environment["M0_DIAG_TEMPO"], let tempo = Double(diag) {
        let regular = BeatGrid.regular(bpm: tempo, bars: 78)
        report.beats = BeatTrackingResult(beats: regular.beats, downbeats: regular.bars, bpm: tempo)
        note("DIAG: regular grid at \(tempo) bpm")
    }
    if cached { note("analysis from cache (\(report.analyzedAt.formatted(date: .abbreviated, time: .shortened)))") }
    guard let grid = report.beatGrid, !grid.beats.isEmpty, !grid.bars.isEmpty else { throw CLIError.noBeatGrid(url.lastPathComponent) }
    guard options.startBar + options.bars <= grid.barCount else {
        throw CLIError.barRangeOutOfGrid(startBar: options.startBar, bars: options.bars, barCount: grid.barCount)
    }

    let source: URL
    if let stem = options.stem.stemName {
        let directory = stemsDirectory(for: url)
        if let existing = existingStems(in: directory)[stem] {
            note("using existing stem \(existing.path)")
            source = existing
        } else {
            note("no \(stem.rawValue).wav in \(directory.path); separating")
            let result = try await separateStems(url: url, model: options.model, into: directory)
            guard let written = result[stem]?.fileURL else {
                throw CLIError.stemMissing(stem: stem.rawValue, directory: directory.path, available: result.names.map(\.rawValue))
            }
            note(String(format: "separated in %.1f s", result.wallTime))
            source = written
        }
    } else {
        source = url
    }

    let audio = try loadAudio(source)
    let plan = try LoopPlan(grid: grid, startBar: options.startBar, bars: options.bars, audio: audio, seconds: seconds,
                            click: options.click, playsAudio: options.stem.playsAudio)
    return (plan, audio, report)
}

// MARK: - Engine driving

enum LoopRunner {
    @AudioActor
    private static func build(plan: LoopPlan, audio: LoadedAudio, offline: Bool) throws -> (engine: Engine, loop: LoopPlayer?, metronome: Metronome) {
        do {
            let channels = AVAudioChannelCount(audio.channels)
            let engine = try Engine(playerCount: 2, sampleRate: audio.sampleRate, channels: channels)
            if offline {
                try engine.prepare(offlineSampleRate: audio.sampleRate, channels: channels, maximumFrames: 4096)
            }
            var loop: LoopPlayer?
            if plan.playsAudio {
                let player = try LoopPlayer(engine: engine, playerIndex: 1, buffer: audio.buffer, grid: plan.sourceGrid,
                                            startBar: plan.startBar, endBar: plan.endBar)
                player.maxIterations = plan.iterations
                loop = player
            }
            let metronome = try Metronome(engine: engine, playerIndex: 0, grid: plan.clickGrid)
            metronome.isEnabled = plan.click
            engine.add(metronome)
            if let loop { engine.add(loop) }
            return (engine, loop, metronome)
        } catch let error as EngineError {
            throw CLIError.engine(error.cliDescription)
        }
    }

    /// Renders `plan.totalFrames` frames to `url` in manual rendering mode.
    @AudioActor
    static func bounce(plan: LoopPlan, audio: LoadedAudio, to url: URL) throws -> OfflineRenderer.FileResult {
        let (engine, _, _) = try build(plan: plan, audio: audio, offline: true)
        defer { engine.stop() }
        do {
            try engine.start()
            try engine.startTransport(clock: plan.clock)
            return try OfflineRenderer.render(engine: engine, frames: AVAudioFramePosition(plan.totalFrames), to: url, sampleFormat: .float32)
        } catch let error as EngineError {
            throw CLIError.engine(error.cliDescription)
        }
    }

    /// Plays the plan through the default output device for `seconds`.
    @AudioActor
    static func play(plan: LoopPlan, audio: LoadedAudio, seconds: Double) async throws {
        let (engine, loop, _) = try build(plan: plan, audio: audio, offline: false)
        let iterations = plan.iterations
        loop?.onLoop = { k in note("  iteration \(k + 1)/\(iterations) played") }
        do {
            try engine.start()
        } catch {
            throw CLIError.engineUnavailable(describe(error))
        }
        do {
            try engine.startTransport(clock: plan.clock, leadTime: 0.2)
        } catch let error as EngineError {
            engine.stop()
            throw CLIError.engine(error.cliDescription)
        }
        try? await Task.sleep(for: .milliseconds(Int((seconds + 0.25) * 1000)))
        engine.stop()
    }
}

extension EngineError: EngineErrorDescribing {
    var cliDescription: String {
        switch self {
        case .notRunning: return "engine is not running"
        case .alreadyRunning: return "engine is already running"
        case .notInOfflineMode: return "engine is not in offline mode"
        case .transportNotStarted: return "transport not started"
        case .transportAlreadyStarted: return "transport already started"
        case .playerIndexOutOfRange(let index): return "player \(index) does not exist"
        case .formatMismatch(let reason): return "format mismatch: \(reason)"
        case .invalidRegion(let reason): return "invalid region: \(reason)"
        case .renderFailed(let reason): return "render failed: \(reason)"
        case .noAudioFiles(let url): return "no audio files in \(url.path)"
        }
    }
}

// MARK: - Commands

struct Loop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Play bars of a stem on repeat through the realtime engine, with a click.",
        discussion: "Analyses the file (cached), separates the stem if <Name>.stems/ does not already hold it, and loops bars [start, start+bars) with a click on beats and an accent on bar starts. Needs an audio output device: run it from a normal Terminal."
    )

    @OptionGroup var options: LoopOptions

    @Option(help: "How long to play, in seconds.")
    var seconds: Double = 20

    func validate() throws {
        guard seconds > 0 else { throw ValidationError("--seconds must be positive") }
    }

    func run() async throws {
        let (plan, audio, report) = try await prepareLoop(options, seconds: seconds)
        print(plan.describe(source: audio, report: report))
        print("playing for \(secondsText(self.seconds, 1)) through the default output device. If you hear nothing, run this from a normal Terminal (automated shells have no audio device).")
        let watch = Stopwatch()
        try await LoopRunner.play(plan: plan, audio: audio, seconds: seconds)
        print(String(format: "stopped after %.1f s", watch.elapsed))
    }
}

struct Bounce: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the same loop offline to a WAV file.",
        discussion: "Identical schedule to `m0 loop`, rendered through the engine's manual rendering mode. Without --seconds the region is rendered exactly once, so the file is exactly the bars' length."
    )

    @OptionGroup var options: LoopOptions

    @Option(help: "Render this many seconds (the loop repeats); default is one pass over the bars.")
    var seconds: Double?

    @Option(help: "Output WAV path.")
    var out: String = "loop.wav"

    @Flag(help: "Read the WAV back and check its length and click positions against the grid.")
    var verify = false

    func validate() throws {
        if let seconds, seconds <= 0 { throw ValidationError("--seconds must be positive") }
    }

    func run() async throws {
        let (plan, audio, report) = try await prepareLoop(options, seconds: seconds)
        print(plan.describe(source: audio, report: report))
        let target = fileURL(out)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        let watch = Stopwatch()
        let result = try await LoopRunner.bounce(plan: plan, audio: audio, to: target)
        let wall = watch.elapsed
        let duration = Double(result.frameCount) / plan.sampleRate
        print(String(format: "wrote  %@  %lld frames = %.6f s at %.0f Hz (rendered in %.2f s)", result.url.path, result.frameCount, duration, plan.sampleRate, wall))

        if verify {
            let check = try BounceVerification.run(url: result.url, plan: plan)
            print(check.description)
            guard check.passed else { throw CLIError.engine("verification failed: " + check.failures.joined(separator: "; ")) }
        }
    }
}

// MARK: - Verification

/// Reads a bounce back and checks the two things the loop logic promises: the file is exactly the
/// scheduled length, and a click transient sits on every grid beat (within 1 ms).
struct BounceVerification: CustomStringConvertible {
    let frames: Int
    let expectedFrames: Int
    let expectedSeconds: Double
    let clicksExpected: Int
    let clicksWithinTolerance: Int
    let maxOffsetFrames: Int
    let meanAbsOffsetFrames: Double
    let weakestClick: Float
    let sampleRate: Double
    let tolerance: Double

    var durationErrorSeconds: Double { Double(frames - expectedFrames) / sampleRate }

    var failures: [String] {
        var list: [String] = []
        if abs(durationErrorSeconds) > tolerance { list.append(String(format: "duration off by %.3f ms", durationErrorSeconds * 1000)) }
        if clicksWithinTolerance < clicksExpected { list.append("\(clicksExpected - clicksWithinTolerance) clicks outside \(Int(tolerance * 1000)) ms") }
        return list
    }

    var passed: Bool { failures.isEmpty }

    var description: String {
        var lines: [String] = []
        lines.append(String(format: "verify duration: %d frames = %.6f s; grid says %.6f s (%d frames); error %+.3f ms  %@",
                            frames, Double(frames) / sampleRate, expectedSeconds, expectedFrames, durationErrorSeconds * 1000,
                            abs(durationErrorSeconds) <= tolerance ? "ok" : "FAIL"))
        if clicksExpected == 0 {
            lines.append("verify clicks: none expected (--no-click)")
        } else {
            lines.append(String(format: "verify clicks: %d/%d on the grid within %.0f ms; max |offset| %d frames = %.3f ms, mean %.2f frames; weakest click step %.2f  %@",
                                clicksWithinTolerance, clicksExpected, tolerance * 1000, maxOffsetFrames, Double(maxOffsetFrames) / sampleRate * 1000,
                                meanAbsOffsetFrames, weakestClick, clicksWithinTolerance == clicksExpected ? "ok" : "FAIL"))
        }
        return lines.joined(separator: "\n")
    }

    /// Finds each click as the largest sample-to-sample step within ±25 ms of its scheduled frame.
    /// `AudioSynth.click` puts its full amplitude on the first sample, so the step at the click is
    /// the click amplitude (0.7 / 0.95) plus whatever the stem is doing, far above anything the stem
    /// produces on its own in one sample.
    static func run(url: URL, plan: LoopPlan, tolerance: Double = 0.001) throws -> BounceVerification {
        let file = try AVAudioFile(forReading: url)
        let frames = Int(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw CLIError.notAudio(url.path, reason: "could not allocate a buffer to verify")
        }
        if frames > 0 { try file.read(into: buffer) }
        let mono = try Resampler.mono(buffer)
        let sampleRate = file.processingFormat.sampleRate

        let expected = plan.click ? plan.clickGrid.beats.map { Int(($0 * sampleRate).rounded()) } : []
        let window = Int((0.025 * sampleRate).rounded())
        let toleranceFrames = Int((tolerance * sampleRate).rounded())
        var within = 0
        var maxOffset = 0
        var sumAbs = 0.0
        var weakest = Float.greatestFiniteMagnitude
        for target in expected {
            let lower = max(1, target - window)
            let upper = min(mono.count - 1, target + window)
            guard lower <= upper else { continue }
            var best = lower
            var bestStep: Float = -1
            for i in lower...upper {
                let step = abs(mono[i] - mono[i - 1])
                if step > bestStep { bestStep = step; best = i }
            }
            let offset = best - target
            if abs(offset) <= toleranceFrames { within += 1 }
            maxOffset = max(maxOffset, abs(offset))
            sumAbs += Double(abs(offset))
            weakest = min(weakest, bestStep)
        }
        return BounceVerification(
            frames: frames, expectedFrames: plan.totalFrames, expectedSeconds: plan.totalSeconds,
            clicksExpected: expected.count, clicksWithinTolerance: within, maxOffsetFrames: maxOffset,
            meanAbsOffsetFrames: expected.isEmpty ? 0 : sumAbs / Double(expected.count),
            weakestClick: expected.isEmpty ? 0 : weakest, sampleRate: sampleRate, tolerance: tolerance)
    }
}
