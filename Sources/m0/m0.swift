import Analysis
import AnalysisMLX
import AnalysisONNX
import ArgumentParser
import AudioEngine
import Foundation
import MusicTheory
import SongGraph

@main
struct M0: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "m0",
        abstract: "M0 acceptance tool: analyze, separate, loop, bounce, import.",
        subcommands: [Analyze.self, Separate.self, Loop.self, Bounce.self, Import.self, Doctor.self],
        defaultSubcommand: Doctor.self
    )
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report the toolchain, package versions, models on disk and analysis providers.")

    func run() throws {
        print("MrRoboto m0")
        print("  MusicTheory  \(MusicTheoryModule.version)")
        print("  SongGraph    \(SongGraphModule.version)  schema \(SongGraphModule.schemaVersion)")
        print("  Analysis     \(AnalysisModule.version)")
        print("  AnalysisMLX  \(AnalysisMLXModule.version)  mlx smoke = \(AnalysisMLXModule.smoke())")
        print("  AnalysisONNX \(AnalysisONNXModule.version)")
        print("  AudioEngine  \(AudioEngineModule.version)")

        print("models")
        let weights = WeightsStore()
        for model in DemucsModel.allCases {
            let state = weights.isInstalled(model) ? "present" : "missing (downloaded on first use)"
            print("  demucs \(model.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(state)  \(weights.directory(for: model).path)")
        }
        let beatThis = Doctor.beatThisModels()
        if beatThis.isEmpty {
            let looked = Doctor.beatThisCandidates.map(\.path).joined(separator: ", ")
            print("  beat this!            missing; looked in \(looked)")
        } else {
            for url in beatThis { print("  beat this!            present  \(url.path)") }
        }

        print("analysis providers  (selected; registered)")
        let providers = makeProviders()
        for capability in AnalysisCapability.allCases {
            let selected = providers.selection[capability] ?? "-"
            let registered = providers.names(for: capability)
            let list = registered.isEmpty ? "none registered" : registered.joined(separator: ", ")
            print("  \(capability.rawValue.padding(toLength: 19, withPad: " ", startingAt: 0)) \(selected); \(list)")
        }
        print("analysis cache  \(ReportCache.directory.path)")
    }

    /// Where a Beat This! ONNX export is looked for until AnalysisONNX owns its model store: the
    /// bench directory of the checkout, and the shared models directory.
    static var beatThisCandidates: [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let models = WeightsStore.defaultDirectory
        return [
            cwd.appendingPathComponent("Bench/models/beat_this.onnx"),
            models.appendingPathComponent("beat_this/beat_this.onnx"),
            models.appendingPathComponent("beat_this.onnx"),
        ]
    }

    static func beatThisModels() -> [URL] {
        beatThisCandidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
