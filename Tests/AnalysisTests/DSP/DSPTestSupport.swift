import Foundation
@testable import Analysis

/// Paths into the repository, resolved from this source file's location so tests can read
/// bench fixtures without a resource bundle.
enum DSPFixtures {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // DSP
        .deletingLastPathComponent()  // AnalysisTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo

    static let stftGolden = repoRoot.appending(path: "Bench/goldens/dsp/stft_golden.json")
    static let arrivalDrums = repoRoot.appending(path: "Bench/goldens/Arrival/stems/drums.wav")
    static let arrivalBeats = repoRoot.appending(path: "Bench/goldens/Arrival/beats.json")

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

struct STFTGolden: Decodable {
    let generator: String
    let sampleRate: Double
    let duration: Double
    let nFft: Int
    let hop: Int
    let frames: Int
    let bins: Int
    let totalFrames: Int
    let signalLength: Int
    let signalSum: Double
    let signalAbsSum: Double
    let signalHead: [Float]
    let clickTimes: [Double]
    let magnitudes: [[Float]]

    enum CodingKeys: String, CodingKey {
        case generator
        case sampleRate = "sample_rate"
        case duration
        case nFft = "n_fft"
        case hop, frames, bins
        case totalFrames = "total_frames"
        case signalLength = "signal_length"
        case signalSum = "signal_sum"
        case signalAbsSum = "signal_abs_sum"
        case signalHead = "signal_head"
        case clickTimes = "click_times"
        case magnitudes
    }

    static func load() throws -> STFTGolden {
        let data = try Data(contentsOf: DSPFixtures.stftGolden)
        return try JSONDecoder().decode(STFTGolden.self, from: data)
    }
}

struct BeatGolden: Decodable {
    let beats: [Double]
    let downbeats: [Double]

    static func load() throws -> BeatGolden {
        let data = try Data(contentsOf: DSPFixtures.arrivalBeats)
        return try JSONDecoder().decode(BeatGolden.self, from: data)
    }
}

/// Deterministic pseudo-random Floats in [-1, 1] (64-bit LCG), for round-trip tests.
struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let v = Double(state >> 11) / Double(1 << 53)
        return Float(v * 2 - 1)
    }
}

func rms(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
}
