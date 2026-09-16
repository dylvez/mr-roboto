import Analysis
import AnalysisMLX
import ArgumentParser
import Foundation

struct Separate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Separate a file into stems with Demucs (MLX) and write them as WAV.",
        discussion: "Stems go to <Name>.stems/ beside the file unless --out is given. Model weights are downloaded on first use."
    )

    @Argument(help: "Audio file to separate.")
    var file: String

    @Option(help: "Demucs model: htdemucs (4 stems, default), htdemucs_6s (adds guitar, piano) or htdemucs_ft (fine-tuned, ~4x slower).")
    var model: DemucsModel = .htdemucs

    @Option(help: "Directory for the stem files (default: <Name>.stems/ beside the file).")
    var out: String?

    func run() async throws {
        let url = try resolveInputFile(file)
        let directory = out.map(fileURL) ?? stemsDirectory(for: url)
        let weights = WeightsStore()
        if !weights.isInstalled(model) {
            note("\(model.rawValue) weights are not in \(weights.directory(for: model).path); downloading (~\(megabytes(UInt64(model.approximateWeightBytes))))")
        }

        let watch = Stopwatch()
        let result = try await separateStems(url: url, model: model, into: directory)
        let wall = watch.elapsed

        print("stems from \(url.lastPathComponent) (\(result.model)):")
        for stem in result.stems {
            let path = stem.fileURL?.path ?? "(in memory only)"
            print("  \(stem.name.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(path)")
        }
        print(String(format: "separation %.1f s, wall %.1f s", result.wallTime, wall))
        print("peak memory: process \(megabytes(ProcessMemory.peakResidentBytes())) resident, MLX \(megabytes(ProcessMemory.mlxPeakBytes()))")
    }
}

