import AVFoundation
import Accelerate
import Analysis
import DemucsMLX
import Foundation
import MLX
import Testing
@testable import AnalysisMLX

// MARK: - Fast tests (no weights, no GPU work beyond what the smoke test already does)

@Test func demucsModelsEnumerate() {
    #expect(DemucsModel.default == .htdemucs)
    #expect(Set(DemucsModel.allCases) == [.htdemucs, .htdemucs_6s, .htdemucs_ft])
    #expect(DemucsModel.htdemucs.stems == [.drums, .bass, .other, .vocals])
    #expect(DemucsModel.htdemucs_ft.stems == [.drums, .bass, .other, .vocals])
    #expect(DemucsModel.htdemucs_6s.stems == [.drums, .bass, .other, .vocals, .guitar, .piano])
    #expect(DemucsModel.htdemucs.weightFileNames == ["htdemucs.safetensors", "htdemucs_config.json"])
    #expect(DemucsModel.htdemucs_ft.subModelCount == 4)
    for m in DemucsModel.allCases {
        #expect(m.sampleRate == 44_100)
        #expect(m.defaultSegmentSeconds == 7.8)
    }
}

@Test func weightsStoreDefaultsToApplicationSupport() {
    let store = WeightsStore()
    #expect(store.directory.path.hasSuffix("Library/Application Support/MrRoboto/models"))
    #expect(store.directory(for: .htdemucs_6s).lastPathComponent == "htdemucs_6s")
    #expect(store.repo == "iky1e/demucs-mlx")
    // A store pointed at an empty directory reports nothing installed and does not create anything.
    let empty = WeightsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-no-models-\(UUID())"))
    #expect(!empty.isInstalled(.htdemucs))
    #expect(!FileManager.default.fileExists(atPath: empty.directory.path))
}

@Test func chunkPlanMatchesLibraryOverlapAdd() {
    // A 2:45 track at 44.1 kHz with the htdemucs defaults (7.8 s windows, 25% overlap).
    let frames = 7_275_748
    let plan = ChunkPlan(frames: frames)
    #expect(plan.segmentFrames == 343_980)
    #expect(plan.strideFrames == 257_985)
    #expect(plan.offsets.first == 0)
    #expect(plan.offsets == stride(from: 0, to: frames, by: 257_985).map { $0 })
    #expect(plan.windowCount == 29)
    #expect(plan.batchCount == 29)
    #expect(!plan.isSingleWindow)
    // Every frame is covered by at least one window.
    var covered = 0
    for o in plan.offsets { covered = max(covered, min(frames, o + plan.segmentFrames)) }
    #expect(covered == frames)
    // Batch I/O for one window is a few MB; memory is bounded by the window, not the song.
    #expect(plan.batchIOBytes() == 343_980 * 2 * 5 * 4)
    #expect(ChunkPlan(frames: frames, batchSize: 4).batchCount == 8)

    // Short clips (<= segment + stride) take the library's single-pass path.
    let short = ChunkPlan(frames: 44_100 * 10)
    #expect(short.isSingleWindow)
    #expect(short.offsets == [0])
    #expect(short.segmentFrames == 441_000)

    // Options flow through.
    var opts = AnalysisMLX.DemucsSeparator.Options()
    opts.segmentSeconds = 4
    opts.overlap = 0.5
    opts.batchSize = 2
    let custom = ChunkPlan(frames: frames, model: .htdemucs, options: opts)
    #expect(custom.segmentFrames == 176_400)
    #expect(custom.strideFrames == 88_200)
    #expect(custom.batchSize == 2)
}

@Test func separatorOptionsMapToLibraryParameters() {
    var opts = AnalysisMLX.DemucsSeparator.Options()
    opts.shifts = 2
    opts.seed = 7
    opts.overlap = 0.1
    opts.batchSize = 3
    opts.segmentSeconds = 5
    let p = opts.libraryParameters
    #expect(p.shifts == 2)
    #expect(p.seed == 7)
    #expect(p.overlap == 0.1)
    #expect(p.batchSize == 3)
    #expect(p.segmentSeconds == 5)
    #expect(p.split)
    #expect(AnalysisMLX.DemucsSeparator.Options().mlxCacheLimitBytes == 512 << 20)
}

@Test func wavWriterRoundTripsStereo44k() throws {
    let frames = 44_100
    var channelMajor = [Float](repeating: 0, count: 2 * frames)
    for t in 0..<frames {
        channelMajor[t] = 0.5 * sin(2 * .pi * 440 * Float(t) / 44_100)
        channelMajor[frames + t] = 0.25 * sin(2 * .pi * 660 * Float(t) / 44_100)
    }
    let audio = try DemucsAudio(channelMajor: channelMajor, channels: 2, sampleRate: 44_100)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-wav-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for (format, tolerance) in [(DemucsSeparator.StemFileFormat.wavInt16, Float(1.0 / 32_000)), (.wavFloat32, 0)] {
        let url = dir.appendingPathComponent("x.wav")
        try StemWAV.write(audio, to: url, format: format)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 44_100)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.length == Int64(frames))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        try file.read(into: buf)
        let back = try StemWAV.demucsAudio(from: buf)
        #expect(back.frameCount == frames)
        var maxErr: Float = 0
        for i in 0..<(2 * frames) { maxErr = max(maxErr, abs(back.channelMajorSamples[i] - channelMajor[i])) }
        #expect(maxErr <= tolerance, "\(format): max error \(maxErr)")
    }

    // Buffer -> DemucsAudio -> buffer preserves layout.
    let buffer = try StemWAV.pcmBuffer(from: audio)
    #expect(buffer.frameLength == AVAudioFrameCount(frames))
    #expect(buffer.format.channelCount == 2)
    #expect(!buffer.format.isInterleaved)
    #expect(buffer.floatChannelData![1][100] == channelMajor[frames + 100])
}

@Test func conformsToAnalysisStemSeparator() {
    let sep: any StemSeparator = AnalysisMLX.DemucsSeparator()
    #expect(sep.providerName == "demucsMLX")
    #expect(sep.models.map(\.name) == ["htdemucs", "htdemucs_6s", "htdemucs_ft"])
    #expect(sep.defaultModel?.name == "htdemucs")
    #expect(sep.models[1].stems.contains(.piano))
    let p = SeparationProgress(phase: .separating, fraction: 0.5, stage: "x")
    #expect(abs(p.overallFraction - 0.56) < 1e-9)
    #expect(SeparationProgress(phase: .writing, fraction: 1, stage: "x").overallFraction == 1)
}

@Test func resamplerConverts48kTo44kWithoutArtifacts() throws {
    // 1 s of a 1 kHz tone at 48 kHz -> 44.1 kHz; expect ~44100 frames and the tone intact.
    let inRate = 48_000, outRate = 44_100, frames = inRate
    var channelMajor = [Float](repeating: 0, count: 2 * frames)
    for t in 0..<frames {
        let v = 0.5 * sin(2 * Float.pi * 1000 * Float(t) / Float(inRate))
        channelMajor[t] = v
        channelMajor[frames + t] = -v
    }
    let src = try DemucsAudio(channelMajor: channelMajor, channels: 2, sampleRate: inRate)
    let out = try StemWAV.resampled(src, to: outRate)
    #expect(out.sampleRate == outRate)
    #expect(out.channels == 2)
    #expect(abs(out.frameCount - outRate) <= 2)
    // Compare the middle against the ideal tone at the new rate (skip converter edges).
    var maxErr: Float = 0
    for t in 2_000..<(out.frameCount - 2_000) {
        let ideal = 0.5 * sin(2 * Float.pi * 1000 * Float(t) / Float(outRate))
        maxErr = max(maxErr, abs(out.channelMajorSamples[t] - ideal))
        maxErr = max(maxErr, abs(out.channelMajorSamples[out.frameCount + t] + ideal))
    }
    #expect(maxErr < 0.01, "max error \(maxErr)")
    // Same rate is a pass-through.
    #expect(try StemWAV.resampled(src, to: inRate).channelMajorSamples == channelMajor)
}

@Test func processMemoryReads() {
    #expect(ProcessMemory.residentBytes() > 1 << 20)
    #expect(ProcessMemory.peakResidentBytes() >= ProcessMemory.residentBytes())
}

// MARK: - Parity against the Python-MLX goldens (needs weights, GPU, and the local corpus)

private let arrivalMP3 = URL(fileURLWithPath: "/Users/dylanfulmer/Documents/projects/vessel/public/assets/audio/interiorseason/Arrival.mp3")
private let goldenStemsDir = URL(fileURLWithPath: "/Users/dylanfulmer/Documents/projects/mr-roboto/Bench/goldens/Arrival/stems", isDirectory: true)

private func parityInputsAvailable() -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: arrivalMP3.path) else {
        print("[demucs-parity] skipped: track missing at \(arrivalMP3.path)")
        return false
    }
    for s in DemucsModel.htdemucs.stems where !fm.fileExists(atPath: goldenStemsDir.appendingPathComponent("\(s.rawValue).wav").path) {
        print("[demucs-parity] skipped: golden \(s.rawValue).wav missing in \(goldenStemsDir.path)")
        return false
    }
    return true
}

/// AVAudioFile.read(into:frameCount:) on a compressed file may return fewer frames than asked (notably
/// right after a seek), so read until the buffer is full.
private func readExcerpt(_ file: AVAudioFile, fromSecond: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    file.framePosition = AVAudioFramePosition(fromSecond * file.processingFormat.sampleRate)
    let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    while out.frameLength < frames {
        try file.read(into: chunk, frameCount: frames - out.frameLength)
        guard chunk.frameLength > 0 else { break }
        let n = Int(chunk.frameLength)
        for c in 0..<Int(file.processingFormat.channelCount) {
            (out.floatChannelData![c] + Int(out.frameLength)).update(from: chunk.floatChannelData![c], count: n)
        }
        out.frameLength += chunk.frameLength
    }
    return out
}

/// Benchmark knobs for `make test-mlx` runs (pass as TEST_RUNNER_MRROBOTO_DEMUCS_* to xcodebuild).
private func benchOptions() -> AnalysisMLX.DemucsSeparator.Options {
    var o = AnalysisMLX.DemucsSeparator.Options()
    let env = ProcessInfo.processInfo.environment
    if let mb = env["MRROBOTO_DEMUCS_CACHE_MB"].flatMap(Int.init) { o.mlxCacheLimitBytes = mb << 20 }
    if let b = env["MRROBOTO_DEMUCS_BATCH"].flatMap(Int.init) { o.batchSize = b }
    if let s = env["MRROBOTO_DEMUCS_SEGMENT"].flatMap(Double.init) { o.segmentSeconds = s }
    return o
}

@Suite(.serialized)
struct DemucsParityTests {
    static let separator = AnalysisMLX.DemucsSeparator(options: benchOptions())

    @Test func htdemucsMatchesPythonGoldens() async throws {
        guard parityInputsAvailable() else { return }
        let sep = Self.separator
        let clock = ContinuousClock()

        let loadStart = clock.now
        try await sep.prepare(.htdemucs, progress: { p in
            if p.phase == .downloadingWeights, Int(p.fraction * 100) % 10 == 0 { print("[demucs-parity] \(p)") }
        })
        let loadTime = clock.now - loadStart
        let o = sep.options
        print("[demucs-parity] options: cache \(o.mlxCacheLimitBytes >> 20) MB, batch \(o.batchSize), segment \(o.segmentSeconds ?? DemucsModel.htdemucs.defaultSegmentSeconds) s, build \(isDebugBuild ? "debug" : "release"), env \(ProcessInfo.processInfo.environment.filter { $0.key.contains("MRROBOTO") })")
        print("[demucs-parity] weights: \(try await sep.weights.ensure(.htdemucs).path)")
        print("[demucs-parity] model load (incl. any download): \(loadTime); MLX peak after load \(ProcessMemory.mlxPeakBytes() >> 20) MB, MLX active \(Memory.activeMemory >> 20) MB")

        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-stems-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let residentBefore = ProcessMemory.residentBytes()
        let sepStart = clock.now
        let urls = try await sep.separate(url: arrivalMP3, model: .htdemucs, outputDirectory: outDir, progress: nil)
        let wall = clock.now - sepStart
        let peakResident = ProcessMemory.peakResidentBytes()
        let mlxPeak = ProcessMemory.mlxPeakBytes()
        print("[demucs-parity] wall time (decode + separate + write 4 WAVs): \(wall)")
        print("[demucs-parity] resident before \(residentBefore >> 20) MB, peak resident \(peakResident >> 20) MB, MLX peak \(mlxPeak >> 20) MB")
        #expect(wall < .seconds(60))
        #expect(peakResident < 2_000_000_000)
        #expect(Set(urls.keys) == Set(DemucsModel.htdemucs.stems))

        // Align on the sum of stems (≈ the mixture) to absorb any decoder delay difference between
        // AVAudioFile and the ffmpeg/librosa path the goldens were made with.
        let est = try DemucsModel.htdemucs.stems.map { try loadWAV(urls[$0]!) }
        let ref = try DemucsModel.htdemucs.stems.map { try loadWAV(goldenStemsDir.appendingPathComponent("\($0.rawValue).wav")) }
        for r in ref { #expect(r.sampleRate == 44_100 && r.channels.count == 2) }
        let estMix = sumStems(est)
        let refMix = sumStems(ref)
        let lag = bestLag(est: estMix, ref: refMix, maxLag: 4_096)
        print("[demucs-parity] est frames \(estMix.count), golden frames \(refMix.count), lag (golden - est) \(lag)")

        let thresholds: [StemName: Double] = [.drums: 0.99, .bass: 0.99, .other: 0.98, .vocals: 0.98]
        for (i, stem) in DemucsModel.htdemucs.stems.enumerated() {
            var corrs: [Double] = []
            var sdrs: [Double] = []
            for c in 0..<2 {
                let (e, r) = overlap(est: est[i].channels[c], ref: ref[i].channels[c], lag: lag)
                corrs.append(pearson(e, r))
                sdrs.append(sdrDB(reference: r, estimate: e))
            }
            let corr = corrs.reduce(0, +) / 2
            let sdr = sdrs.reduce(0, +) / 2
            print(String(format: "[demucs-parity] %-7@ corr %.5f (L %.5f R %.5f)  SDR %6.2f dB (L %.2f R %.2f)",
                         stem.rawValue as NSString, corr, corrs[0], corrs[1], sdr, sdrs[0], sdrs[1]))
            #expect(corr > thresholds[stem]!, "\(stem.rawValue) correlation \(corr) below \(thresholds[stem]!)")
        }
    }

    @Test func separationCanBeCancelled() async throws {
        guard parityInputsAvailable() else { return }
        let sep = Self.separator
        try await sep.prepare(.htdemucs)
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-cancel-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let task = Task {
            try await sep.separate(url: arrivalMP3, model: .htdemucs, outputDirectory: outDir, progress: nil)
        }
        try await Task.sleep(for: .milliseconds(800))
        let cancelAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let latency = ContinuousClock.now - cancelAt
        print("[demucs-parity] cancellation observed after \(latency)")
        #expect(latency < .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("drums.wav").path))
    }

    @Test func analysisProtocolPathFiltersStemsAndReportsProgress() async throws {
        guard parityInputsAvailable() else { return }
        let sep: any StemSeparator = Self.separator
        let file = try AVAudioFile(forReading: arrivalMP3)
        let frames: AVAudioFrameCount = 44_100 * 10
        let input = try readExcerpt(file, fromSecond: 60, frames: frames)
        #expect(input.frameLength == frames)
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-proto-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let last = ProgressBox()
        let result = try await sep.separate(
            .buffer(AVReadOnlyAudioPCMBuffer(copying: input)),
            options: StemSeparationOptions(model: "htdemucs", outputDirectory: outDir, stems: [.vocals, .drums]),
            progress: { last.set($0) })
        let expectedFrames = try StemWAV.resampled(StemWAV.demucsAudio(from: input), to: 44_100).frameCount
        #expect(result.model == "htdemucs")
        #expect(Set(result.names) == [.vocals, .drums])
        #expect(result[.vocals]?.buffer?.frameLength == expectedFrames)
        #expect(result[.vocals]?.buffer?.format.sampleRate == 44_100)
        #expect(result[.vocals]?.fileURL?.lastPathComponent == "vocals.wav")
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("drums.wav").path))
        #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("bass.wav").path))
        #expect(result.wallTime > 0 && result.wallTime < 30)
        #expect(last.value == 1)
        await #expect(throws: DemucsSeparatorError.self) {
            try await sep.separate(.file(arrivalMP3), options: StemSeparationOptions(model: "nope"))
        }
    }

    @Test func bufferAPIReturnsStemsThatSumToTheInput() async throws {
        guard parityInputsAvailable() else { return }
        let sep = Self.separator
        let file = try AVAudioFile(forReading: arrivalMP3)
        let frames: AVAudioFrameCount = 44_100 * 10
        let input = try readExcerpt(file, fromSecond: 30, frames: frames)
        #expect(input.frameLength == frames)
        // Arrival.mp3 is 48 kHz; the API promises 44.1 kHz stems, so compare against the resampled input.
        let modelInput = try StemWAV.resampled(StemWAV.demucsAudio(from: input), to: 44_100)
        let n = modelInput.frameCount
        print("[demucs-parity] buffer API: \(input.frameLength) frames @ \(Int(input.format.sampleRate)) Hz in -> \(n) frames @ 44100 Hz out")
        #expect(abs(Double(n) - Double(frames) * 44_100 / input.format.sampleRate) <= 2)

        let stems = try await sep.separate(buffer: input, model: .htdemucs, progress: nil)
        #expect(Set(stems.keys) == Set(DemucsModel.htdemucs.stems))
        for (_, b) in stems {
            #expect(b.format.sampleRate == 44_100)
            #expect(b.format.channelCount == 2)
            #expect(Int(b.frameLength) == n)
        }
        // Demucs stems reconstruct the mixture closely.
        var sum = [Float](repeating: 0, count: n)
        for (_, b) in stems { vDSP_vadd(sum, 1, b.floatChannelData![0], 1, &sum, 1, vDSP_Length(n)) }
        let corr = pearson(sum, Array(modelInput.channelMajorSamples[0..<n]))
        print("[demucs-parity] 10 s buffer API: stems-sum vs input correlation \(corr)")
        #expect(corr > 0.95)
    }
}

private var isDebugBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    var value: Double { lock.withLock { v } }
    func set(_ x: Double) { lock.withLock { v = x } }
}

// MARK: - Metrics helpers

private struct WAV {
    let channels: [[Float]]
    let sampleRate: Double
}

private func loadWAV(_ url: URL) throws -> WAV {
    let file = try AVAudioFile(forReading: url)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let n = Int(buf.frameLength)
    let chans = (0..<Int(buf.format.channelCount)).map { Array(UnsafeBufferPointer(start: buf.floatChannelData![$0], count: n)) }
    return WAV(channels: chans, sampleRate: file.processingFormat.sampleRate)
}

private func sumStems(_ stems: [WAV]) -> [Float] {
    let n = stems.map { $0.channels[0].count }.min()!
    var out = [Float](repeating: 0, count: n)
    for s in stems { for c in s.channels { vDSP_vadd(out, 1, c, 1, &out, 1, vDSP_Length(n)) } }
    return out
}

/// Lag L (in frames) such that ref[i + L] best matches est[i], searched over a window in the middle.
private func bestLag(est: [Float], ref: [Float], maxLag: Int) -> Int {
    let window = 44_100 * 5
    let start = max(maxLag, min(est.count, ref.count) / 2 - window / 2)
    guard start + window + maxLag < ref.count, start + window < est.count else { return 0 }
    var best = 0
    var bestScore = -Float.infinity
    est.withUnsafeBufferPointer { e in
        ref.withUnsafeBufferPointer { r in
            for lag in -maxLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(e.baseAddress! + start, 1, r.baseAddress! + start + lag, 1, &dot, vDSP_Length(window))
                if dot > bestScore { bestScore = dot; best = lag }
            }
        }
    }
    return best
}

private func overlap(est: [Float], ref: [Float], lag: Int) -> ([Double], [Double]) {
    let lo = max(0, -lag)
    let hi = min(est.count, ref.count - lag)
    let e = est[lo..<hi].map(Double.init)
    let r = ref[(lo + lag)..<(hi + lag)].map(Double.init)
    return (e, r)
}

private func pearson(_ a: [Double], _ b: [Double]) -> Double {
    let n = vDSP_Length(a.count)
    var ma = 0.0, mb = 0.0
    vDSP_meanvD(a, 1, &ma, n)
    vDSP_meanvD(b, 1, &mb, n)
    var ca = [Double](repeating: 0, count: a.count)
    var cb = [Double](repeating: 0, count: b.count)
    var nma = -ma, nmb = -mb
    vDSP_vsaddD(a, 1, &nma, &ca, 1, n)
    vDSP_vsaddD(b, 1, &nmb, &cb, 1, n)
    var dot = 0.0, aa = 0.0, bb = 0.0
    vDSP_dotprD(ca, 1, cb, 1, &dot, n)
    vDSP_dotprD(ca, 1, ca, 1, &aa, n)
    vDSP_dotprD(cb, 1, cb, 1, &bb, n)
    return dot / (aa * bb).squareRoot()
}

private func pearson(_ a: [Float], _ b: [Float]) -> Double {
    pearson(a.map(Double.init), b.map(Double.init))
}

/// 10·log10(‖ref‖² / ‖ref − est‖²).
private func sdrDB(reference r: [Double], estimate e: [Double]) -> Double {
    let n = vDSP_Length(r.count)
    var diff = [Double](repeating: 0, count: r.count)
    vDSP_vsubD(e, 1, r, 1, &diff, 1, n)  // diff = r - e
    var num = 0.0, den = 0.0
    vDSP_svesqD(r, 1, &num, n)
    vDSP_svesqD(diff, 1, &den, n)
    return 10 * log10(num / max(den, 1e-30))
}
