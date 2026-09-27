import Analysis
import Foundation
import MusicTheory
import Testing
@testable import AnalysisONNX

// MARK: - Locations

private let arrivalMP3 = URL(fileURLWithPath: "/Users/dylanfulmer/Documents/projects/vessel/public/assets/audio/interiorseason/Arrival.mp3")
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let goldenBeatsURL = repoRoot.appendingPathComponent("Bench/goldens/Arrival/beats.json")
private let benchModelURL = repoRoot.appendingPathComponent("Bench/models/beat_this.onnx")

/// The installed model, else the bench copy, else nil with a note (tests that need it skip).
private func availableModelURL(_ tag: String) -> URL? {
    for url in [BeatThisTracker.defaultModelURL, benchModelURL] where FileManager.default.fileExists(atPath: url.path) {
        return url
    }
    print("[\(tag)] skipped: no beat_this.onnx at \(BeatThisTracker.defaultModelURL.path) or \(benchModelURL.path); run `uv run Bench/python/fetch_models.py`")
    return nil
}

private func fileExists(_ url: URL, _ tag: String, _ what: String) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("[\(tag)] skipped: \(what) missing at \(url.path)")
        return false
    }
    return true
}

private func loadFloats(_ url: URL) throws -> [Float] {
    try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
}

// MARK: - Module

@Test func moduleVersion() {
    #expect(AnalysisONNXModule.version == "0.1.0")
}

@Test func registryOffersBeatThisWithoutChangingTheDefault() throws {
    var providers = AnalysisProviders.makeDefaultWithONNX()
    #expect(providers.selection[.beats] == "musicUnderstanding")
    #expect(providers.names(for: .beats).contains("beat-this"))
    try providers.select("beat-this", for: .beats)
    #expect(try providers.beatTracker().providerName == "beat-this")

    // On an empty registry the registry's own rule makes the only beat tracker the selection.
    var empty = AnalysisProviders()
    empty.registerONNXProviders(beatThisModelURL: URL(fileURLWithPath: "/nonexistent/beat_this.onnx"))
    #expect(empty.selection[.beats] == "beat-this")
    #expect((try empty.beatTracker() as? BeatThisTracker)?.modelURL.path == "/nonexistent/beat_this.onnx")
}

// MARK: - Front end

@Test func frontEndUsesBeatThisParameters() {
    let frontEnd = BeatThisFrontEnd()
    #expect(BeatThisFrontEnd.sampleRate == 22050)
    #expect(BeatThisFrontEnd.nFFT == 1024 && BeatThisFrontEnd.hop == 441)
    #expect(BeatThisFrontEnd.framesPerSecond == 50)
    #expect(frontEnd.stft.nFFT == 1024 && frontEnd.stft.hop == 441)
    #expect(frontEnd.filterbank.melCount == 128)
    #expect(frontEnd.filterbank.scale == .slaney && frontEnd.filterbank.normalization == .none)
    #expect(frontEnd.filterbank.centerFrequencies.first! > 30 && frontEnd.filterbank.centerFrequencies.last! < 11000)
    // Arrival at 22.05 kHz is 3 637 368 samples and the Python front end gives 8249 frames.
    #expect(frontEnd.stft.frameCount(forLength: 3_637_368) == 8249)
    #expect(BeatThisFrontEnd.time(ofFrame: 45) == 0.9)

    // A 1 s 440 Hz tone: 51 frames, energy in the band nearest 440 Hz, values finite and >= 0 (log1p).
    let tone = (0..<22050).map { Float(sin(2 * Double.pi * 440 * Double($0) / 22050)) }
    let spect = frontEnd.logMel(samples: tone)
    #expect(spect.frameCount == 51 && spect.binCount == 128)
    let middle = Array(spect.frame(25))
    let peakBand = middle.indices.max { middle[$0] < middle[$1] }!
    #expect(abs(frontEnd.filterbank.centerFrequencies[peakBand] - 440) < 40)
    #expect(spect.values.allSatisfy { $0.isFinite && $0 >= 0 })
    // Silence is exactly zero after log1p, and tiny inputs are padded rather than rejected.
    #expect(frontEnd.logMel(samples: [Float](repeating: 0, count: 2205)).values.allSatisfy { $0 == 0 })
    #expect(frontEnd.logMel(samples: [0.5, -0.5]).frameCount == 2)
}

// MARK: - Chunking

@Test func chunkingMatchesPythonSplitPiece() {
    typealias Chunk = BeatThisChunking.Chunk
    let chunking = BeatThisChunking()
    #expect(chunking.chunkFrames == 1500 && chunking.border == 6)

    // Arrival: 8249 frames. np.arange(-6, 8243, 1488) with the last start moved to 8249 - 1494.
    let chunks = chunking.chunks(frameCount: 8249)
    #expect(chunks.map(\.start) == [-6, 1482, 2970, 4458, 5946, 6755])
    #expect(chunks.allSatisfy { $0.frames == 1500 })
    #expect(chunks.first == Chunk(start: -6, sliceStart: 0, sliceEnd: 1494, leftPad: 6, rightPad: 0))
    #expect(chunks[1] == Chunk(start: 1482, sliceStart: 1482, sliceEnd: 2982, leftPad: 0, rightPad: 0))
    #expect(chunks.last == Chunk(start: 6755, sliceStart: 6755, sliceEnd: 8249, leftPad: 0, rightPad: 6))

    // A short piece is one chunk: the piece with six zero frames on each side.
    let short = chunking.chunks(frameCount: 1000)
    #expect(short == [Chunk(start: -6, sliceStart: 0, sliceEnd: 1000, leftPad: 6, rightPad: 6)])
    #expect(chunking.chunks(frameCount: 0).isEmpty)

    // keep_first aggregation: each frame comes from the earliest chunk whose bordered region covers it.
    let predictions = chunks.enumerated().map { index, chunk in [Float](repeating: Float(index), count: chunk.frames) }
    let aggregated = chunking.aggregate(predictions, chunks: chunks, frameCount: 8249)
    #expect(aggregated.count == 8249)
    #expect(!aggregated.contains(-1000))
    #expect(aggregated[0] == 0 && aggregated[1487] == 0)
    #expect(aggregated[1488] == 1 && aggregated[2975] == 1)
    #expect(aggregated[2976] == 2)
    #expect(aggregated[6760] == 4 && aggregated[7439] == 4)  // chunk 4 (region 5952..<7440) wins over chunk 5 (6761..<8249)
    #expect(aggregated[7440] == 5 && aggregated[8248] == 5)

    // Chunk inputs are the spectrogram rows with zero padding.
    let spect = Spectrogram(frameCount: 1000, binCount: 128, values: (0..<128_000).map(Float.init))
    let input = chunking.input(for: short[0], from: spect)
    #expect(input.count == 1012 * 128)
    #expect(input[0..<(6 * 128)].allSatisfy { $0 == 0 })
    #expect(input[6 * 128 + 5] == 5)
    #expect(input[(6 + 999) * 128 + 127] == 127_999)
    #expect(input[((6 + 1000) * 128)...].allSatisfy { $0 == 0 })
}

// MARK: - Post-processing

@Test func peakPickingMatchesPythonMinimalPostprocessor() {
    // Beat logits: a peak at 10; a two-frame plateau at 20–21 (merged to 20.5); a negative "peak" at 30
    // (below the 0.5-probability threshold); 40 with a lower neighbour at 41 (shadowed); 60 shadowing 63.
    var beat = [Float](repeating: -3, count: 120)
    beat[10] = 3
    beat[20] = 2; beat[21] = 2
    beat[30] = -1
    beat[40] = 1; beat[41] = 0.9
    beat[60] = 2.5; beat[63] = 2
    // Downbeat logits: 12 snaps to the beat at 0.2 s, 21 to 0.41 s, 100 to the last beat at 1.2 s.
    var downbeat = [Float](repeating: -3, count: 120)
    downbeat[12] = 1; downbeat[21] = 1; downbeat[100] = 0.5

    #expect(BeatThisPostprocessor.peakFrames(beat) == [10, 20, 21, 40, 60])
    #expect(BeatThisPostprocessor.deduplicate([10, 20, 21, 40, 60]) == [10, 20.5, 40, 60])
    // The reference compares each peak to the run's running mean, not its last member: 7 - 5.5 > 1 starts a new run.
    #expect(BeatThisPostprocessor.deduplicate([5, 6, 7, 9]) == [5.5, 7, 9])
    #expect(BeatThisPostprocessor.deduplicate([5, 6, 8, 9]) == [5.5, 8.5])
    #expect(BeatThisPostprocessor.deduplicate([]).isEmpty)

    let output = BeatThisPostprocessor(tempoConsistency: nil).process(beatLogits: beat, downbeatLogits: downbeat)
    #expect(output.beats == [0.2, 0.41, 0.8, 1.2])
    #expect(output.downbeats == [0.2, 0.41, 1.2])
    #expect(output.rejectedBeats.isEmpty)
    #expect(output.confidence.count == 4)
    #expect(abs(output.confidence[0] - 1 / (1 + exp(-3.0))) < 1e-6)
    // No beats at all: downbeats are left where they are, no tempo.
    let none = BeatThisPostprocessor(tempoConsistency: nil).process(beatLogits: [Float](repeating: -3, count: 120), downbeatLogits: downbeat)
    #expect(none.beats.isEmpty && none.downbeats == [0.24, 0.42, 2.0] && none.bpm == nil)
}

@Test func tempoConsistencyRejectsOnlyIsolatedInsertions() {
    let regular = stride(from: 0.5, through: 10.0, by: 0.5).map { $0 }  // 120 bpm, 20 beats
    #expect(BeatThisPostprocessor.rejectIsolated(regular, tolerance: 0.25, window: 8).rejected.isEmpty)

    // An inserted beat halfway between two real ones is rejected; its neighbours are not.
    let inserted = (regular + [3.25]).sorted()
    let pass = BeatThisPostprocessor.rejectIsolated(inserted, tolerance: 0.25, window: 8)
    #expect(pass.rejected == [3.25])
    #expect(pass.kept == regular)

    // A beat that is merely early (0.4 / 0.6 intervals, 20 % off) stays.
    let early = regular.map { $0 == 5.0 ? 4.9 : $0 }
    #expect(BeatThisPostprocessor.rejectIsolated(early, tolerance: 0.25, window: 8).rejected.isEmpty)

    // A missed beat (one 1 s gap) does not take its neighbours with it.
    let missing = regular.filter { $0 != 5.0 }
    #expect(BeatThisPostprocessor.rejectIsolated(missing, tolerance: 0.25, window: 8).rejected.isEmpty)

    // A tempo change (120 → 150 bpm) is untouched.
    let change = stride(from: 0.5, through: 5.0, by: 0.5).map { $0 } + stride(from: 5.4, through: 9.0, by: 0.4).map { $0 }
    #expect(BeatThisPostprocessor.rejectIsolated(change, tolerance: 0.25, window: 8).rejected.isEmpty)

    // End to end: an inserted beat at frame 163 (3.26 s) and the downbeat sitting on it go, tempo is 120.
    var beatLogits = [Float](repeating: -3, count: 550)
    for time in regular { beatLogits[Int((time * 50).rounded())] = 2 }
    beatLogits[163] = 2
    var downbeatLogits = [Float](repeating: -3, count: 550)
    for time in [0.5, 2.5, 4.5] { downbeatLogits[Int((time * 50).rounded())] = 1 }
    downbeatLogits[163] = 1
    let output = BeatThisPostprocessor().process(beatLogits: beatLogits, downbeatLogits: downbeatLogits)
    #expect(output.beats == regular)
    #expect(output.rejectedBeats == [3.26])
    #expect(output.downbeats == [0.5, 2.5, 4.5])
    #expect(output.bpm.map { abs($0 - 120) < 1e-9 } == true)
    #expect(output.confidence.count == regular.count)
}

// MARK: - Model loading

@Test func missingOrInvalidModelGivesAClearError() throws {
    #expect(BeatThisTracker.defaultModelURL.path.hasSuffix("Library/Application Support/MrRoboto/models/beat_this.onnx"))
    #expect(BeatThisTracker().modelURL == BeatThisTracker.defaultModelURL)
    #expect(BeatThisTracker().providerName == "beat-this")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-beat-this-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let missing = directory.appendingPathComponent("beat_this.onnx")
    let tracker = BeatThisTracker(modelURL: missing)
    #expect(!tracker.isModelInstalled)
    #expect(throws: BeatThisError.modelNotFound(missing)) { try tracker.model() }
    let message = BeatThisError.modelNotFound(missing).description
    #expect(message.contains(missing.path) && message.contains("fetch_models.py"))

    let junk = directory.appendingPathComponent("junk.onnx")
    try Data("not a model".utf8).write(to: junk)
    let error = #expect(throws: BeatThisError.self) { try BeatThisModel(contentsOf: junk) }
    if case .invalidModel(let url, _)? = error { #expect(url == junk) } else { Issue.record("expected invalidModel, got \(String(describing: error))") }
}

@Test func installedModelLoadsAndRuns() throws {
    guard let url = availableModelURL("beat-this-model") else { return }
    let tracker = BeatThisTracker(modelURL: url)
    #expect(tracker.isModelInstalled)
    let model = try tracker.model()
    #expect(try tracker.model() === model)  // loaded once
    let frames = 100
    let silence = try model.predict([Float](repeating: 0, count: frames * 128), frames: frames)
    #expect(silence.beat.count == frames && silence.downbeat.count == frames)
    #expect(silence.beat.allSatisfy(\.isFinite) && silence.downbeat.allSatisfy(\.isFinite))
    // Variable time axis: a different length runs too.
    #expect(try model.predict([Float](repeating: 0, count: 37 * 128), frames: 37).beat.count == 37)
}

// MARK: - Parity against the Python golden (needs the model and the local corpus)

@Suite(.serialized)
struct BeatThisParityTests {
    @Test func arrivalMatchesPythonGolden() async throws {
        let tag = "beat-this-parity"
        guard let modelURL = availableModelURL(tag),
              fileExists(arrivalMP3, tag, "track"), fileExists(goldenBeatsURL, tag, "golden") else { return }
        let golden = try BeatComparison.Golden(contentsOf: goldenBeatsURL)
        let tracker = BeatThisTracker(modelURL: modelURL)

        let report = try await tracker.analyze(url: arrivalMP3)
        let result = report.result
        let comparison = BeatComparison.compare(estimate: result, golden: golden, tolerance: 0.02)
        let raw = BeatThisPostprocessor(tempoConsistency: nil).process(beatLogits: report.beatLogits, downbeatLogits: report.downbeatLogits)
        let rawComparison = BeatComparison.compare(estimate: BeatTrackingResult(beats: raw.beats, downbeats: raw.downbeats), golden: golden, tolerance: 0.02)

        print("[\(tag)] model \(modelURL.path)")
        print("[\(tag)] \(comparison)")
        print("[\(tag)] before tempo pass: \(rawComparison)")
        print(String(format: "[%@] beats %d (golden %d), downbeats %d (golden %d), bpm %.2f, rejected %d %@",
                     tag, result.beats.count, golden.beats.count, result.downbeats.count, golden.downbeats.count,
                     result.bpm ?? 0, report.rejectedBeats.count, report.rejectedBeats.description))
        print(String(format: "[%@] offset mean %+.2f ms, median %+.2f ms, mean |offset| %.2f ms",
                     tag, comparison.meanOffset * 1000, comparison.medianOffset * 1000, comparison.meanAbsoluteOffset * 1000))
        print(String(format: "[%@] %d frames in %d chunks; decode %.2f s, front end %.2f s, inference %.2f s, wall %.2f s (build %@)",
                     tag, report.frameCount, report.chunkCount, report.decodeTime, report.frontEndTime, report.inferenceTime, report.wallTime,
                     isDebugBuild ? "debug" : "release"))
        let unmatchedGolden = golden.beats.filter { g in !result.beats.contains { abs($0 - g) <= 0.02 } }
        let unmatchedEstimate = result.beats.filter { e in !golden.beats.contains { abs($0 - e) <= 0.02 } }
        if !unmatchedGolden.isEmpty || !unmatchedEstimate.isEmpty {
            print("[\(tag)] unmatched golden beats \(unmatchedGolden), unmatched estimated beats \(unmatchedEstimate)")
        }

        #expect(comparison.fMeasure > 0.95)
        #expect((comparison.downbeatAgreement ?? 0) > 0.95)
        #expect(abs(comparison.medianOffset) <= 0.02)
        #expect(result.bpm.map { $0 > 40 && $0 < 240 } == true)
        #expect(result.confidence?.count == result.beats.count)
    }

    /// Stage-by-stage check against tensors dumped by `Bench/python/check_beat_this_onnx.py --dump DIR`
    /// (`sig22.f32`, `spect.f32`, `beat_logits_torch.f32`, `down_logits_torch.f32`, raw little-endian
    /// float32). Runs only with `MRROBOTO_BEAT_THIS_REFERENCE_DIR` set.
    @Test func stagesMatchPythonReferenceDump() throws {
        let tag = "beat-this-stages"
        guard let directory = ProcessInfo.processInfo.environment["MRROBOTO_BEAT_THIS_REFERENCE_DIR"] else { return }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let signal = try loadFloats(dir.appendingPathComponent("sig22.f32"))
        let referenceSpect = try loadFloats(dir.appendingPathComponent("spect.f32"))
        let referenceBeat = try loadFloats(dir.appendingPathComponent("beat_logits_torch.f32"))
        let referenceDownbeat = try loadFloats(dir.appendingPathComponent("down_logits_torch.f32"))
        let frames = referenceBeat.count
        #expect(referenceSpect.count == frames * 128)

        // Front end on the Python-decoded, soxr-resampled signal: isolates STFT + mel + log1p.
        let frontEnd = BeatThisFrontEnd()
        let spect = frontEnd.logMel(samples: signal)
        #expect(spect.frameCount == frames)
        let spectDiff = maxAbsDifference(spect.values, referenceSpect)
        let spectMean = zip(spect.values, referenceSpect).map { abs($0 - $1) }.reduce(0, +) / Float(referenceSpect.count)
        print(String(format: "[%@] log-mel vs torchaudio: max |diff| %.3g, mean |diff| %.3g (values 0…%.2f)", tag, spectDiff, spectMean, referenceSpect.max() ?? 0))
        #expect(spectDiff < 0.05)

        guard let modelURL = availableModelURL(tag) else { return }
        let tracker = BeatThisTracker(modelURL: modelURL)

        // Model on the reference spectrogram: isolates ONNX Runtime vs torch.
        let fromReference = try tracker.frameLogits(of: Spectrogram(frameCount: frames, binCount: 128, values: referenceSpect))
        print(String(format: "[%@] logits from reference spect vs torch: beat %.3g, downbeat %.3g", tag,
                     maxAbsDifference(fromReference.beat, referenceBeat), maxAbsDifference(fromReference.downbeat, referenceDownbeat)))
        #expect(maxAbsDifference(fromReference.beat, referenceBeat) < 1e-2)

        // Whole chain from the signal.
        let fromSignal = try tracker.frameLogits(of: spect)
        print(String(format: "[%@] logits from Swift spect vs torch: beat %.3g, downbeat %.3g", tag,
                     maxAbsDifference(fromSignal.beat, referenceBeat), maxAbsDifference(fromSignal.downbeat, referenceDownbeat)))
        if fileExists(goldenBeatsURL, tag, "golden") {
            let golden = try BeatComparison.Golden(contentsOf: goldenBeatsURL)
            let output = BeatThisPostprocessor(tempoConsistency: nil).process(beatLogits: fromSignal.beat, downbeatLogits: fromSignal.downbeat)
            let comparison = BeatComparison.compare(estimate: BeatTrackingResult(beats: output.beats, downbeats: output.downbeats), golden: golden, tolerance: 0.02)
            print("[\(tag)] Swift front end + ONNX on Python audio vs golden: \(comparison)")
            #expect(output.beats == golden.beats && output.downbeats == golden.downbeats)
        }
    }
}

private var isDebugBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
}

// MARK: - Core ML on the GPU

@Test func missingCoreMLModelRunsEverythingOnONNXRuntime() throws {
    guard let url = availableModelURL("beat-this-coreml-missing") else { return }
    let missing = URL(fileURLWithPath: "/nonexistent/beat_this_1500.mlmodelc")
    let tracker = BeatThisTracker(modelURL: url, options: .init(coreMLModelURL: missing))
    #expect(tracker.coreMLModel() == nil)
    #expect(tracker.coreMLUnavailableReason?.contains(missing.path) == true)
    let logits = try tracker.frameLogits(of: Spectrogram(frameCount: 3000, binCount: 128, values: [Float](repeating: 0, count: 3000 * 128)))
    #expect(logits.beat.count == 3000 && logits.coreMLChunks == 0)

    #expect(BeatThisTracker(modelURL: url).coreMLModel() == nil)  // none asked for
    #expect(BeatThisTracker.Options.installed.coreMLModelURL == BeatThisTracker.defaultCoreMLModelURL)
}

@Suite(.serialized)
struct BeatThisCoreMLTests {
    /// The installed Core ML model against ONNX Runtime on Arrival: every chunk on the GPU, the same beats
    /// and downbeats. Skips when either model is not installed.
    @Test func arrivalOnTheGPUMatchesONNXRuntime() async throws {
        let tag = "beat-this-coreml"
        guard let url = availableModelURL(tag), fileExists(arrivalMP3, tag, "track"),
              fileExists(BeatThisTracker.defaultCoreMLModelURL, tag, "Core ML model (run `uv run Bench/python/convert_beat_this_coreml.py`)") else { return }
        let onnx = BeatThisTracker(modelURL: url)
        let gpu = BeatThisTracker(modelURL: url, options: .installed)
        #expect(gpu.coreMLModel() != nil, "\(gpu.coreMLUnavailableReason ?? "")")

        _ = try await gpu.analyze(url: arrivalMP3)  // warm
        let a = try await onnx.analyze(url: arrivalMP3)
        let b = try await gpu.analyze(url: arrivalMP3)
        print(String(format: "[%@] inference over %d chunks: ONNX Runtime %.3f s, Core ML %.3f s (%d chunks on Core ML); max |logit diff| beat %.3f downbeat %.3f",
                     tag, a.chunkCount, a.inferenceTime, b.inferenceTime, b.coreMLChunkCount,
                     maxAbsDifference(a.beatLogits, b.beatLogits), maxAbsDifference(a.downbeatLogits, b.downbeatLogits)))
        #expect(a.coreMLChunkCount == 0 && b.coreMLChunkCount == b.chunkCount)
        #expect(maxAbsDifference(a.beatLogits, b.beatLogits) < 0.5)
        #expect(b.result.beats == a.result.beats)
        #expect(b.result.downbeats == a.result.downbeats)

        // A piece shorter than one chunk has one shorter chunk, which stays on ONNX Runtime.
        let short = try gpu.frameLogits(of: Spectrogram(frameCount: 1000, binCount: 128, values: [Float](repeating: 0, count: 1000 * 128)))
        #expect(short.beat.count == 1000 && short.coreMLChunks == 0)
    }
}
