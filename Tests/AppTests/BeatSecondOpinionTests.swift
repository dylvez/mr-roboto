import Analysis
import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// The import hears the beats twice: Music Understanding's grid, checked by Beat This!, which stands
// in when Music Understanding finds none. Stand-in trackers here; the real ones are the analysis
// modules' to test.

private struct StubBeats: BeatTracker {
    struct Failed: Error {}
    let providerName: String
    let beats: [Double]?

    func trackBeats(url: URL) async throws -> BeatTrackingResult {
        guard let beats else { throw Failed() }
        return BeatTrackingResult(beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] })
    }
}

@Suite("A second opinion on the beats") @MainActor
struct BeatSecondOpinionTests {
    private let steady = (0..<64).map { 0.5 + Double($0) * 0.5 }

    private func analyze(primary: [Double]?, checker: [Double]?) async throws -> AnalysisReport {
        var registry = AnalysisProviders()
        registry.register(StubBeats(providerName: "musicUnderstanding", beats: primary), for: [.beats])
        registry.register(StubBeats(providerName: LiveImportHost.beatChecker, beats: checker), for: [.beats])
        let directory = GuidanceFixture.temporaryDirectory("second-opinion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = LiveImportHost(library: LibraryStore(directoryURL: directory), providers: registry)
        return try await host.analyze(directory.appendingPathComponent("record.wav")) { _ in }
    }

    @Test("the app registers Beat This! beside Music Understanding, which stays the beat tracker")
    func registry() {
        let providers = AnalysisProviders.app()
        #expect(providers.selection[.beats] == "musicUnderstanding")
        #expect(providers.provider(named: LiveImportHost.beatChecker, for: .beats) is any BeatTracker)
    }

    @Test("both hear the same grid: Music Understanding's is kept, and checked")
    func agree() async throws {
        let report = try await analyze(primary: steady, checker: steady.map { $0 + 0.01 })
        #expect(report.provenance[.beats] == "musicUnderstanding")
        #expect(report.beatCheck?.agreement == 1 && report.beatCheck?.usedChecker == false)
        let analysis = ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: 40)
        #expect(analysis.beatCheck?.checker == LiveImportHost.beatChecker)
        #expect(BeatCheckReading(analysis.beatCheck).value == "100% agree")
    }

    @Test("Music Understanding finds no grid: Beat This! supplies it, and the record still has bars")
    func standIn() async throws {
        let report = try await analyze(primary: nil, checker: steady)
        #expect(report.beats?.beats == steady)
        #expect(report.provenance[.beats] == LiveImportHost.beatChecker)
        #expect(report.capabilities.contains(.beats))
        #expect(report.beatCheck?.usedChecker == true)
        let analysis = ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: 40)
        #expect(analysis.bars.count >= 15, "\(analysis.bars.count) bars")
        #expect(BeatCheckReading(analysis.beatCheck).value == "Beat This!")
    }

    @Test("double time is flagged; a checker that fails costs the import nothing")
    func disagreeAndFail() async throws {
        let doubled = (0..<128).map { 0.5 + Double($0) * 0.25 }
        let report = try await analyze(primary: doubled, checker: steady)
        let reading = BeatCheckReading(ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: 40).beatCheck)
        #expect(reading.warns && reading.value == "67% agree")
        #expect(reading.help.contains("double time"), "\(reading.help)")

        let unchecked = try await analyze(primary: steady, checker: nil)
        #expect(unchecked.beats?.beats == steady && unchecked.beatCheck == nil)
        #expect(unchecked.notes.contains { $0.hasPrefix("no second opinion on the beats") })
        #expect(BeatCheckReading(nil).value == "1 tracker")
    }

    @Test("an analysis saved before the check loads without one")
    func oldAnalyses() throws {
        let old = #"{"duration":30,"keys":[],"beats":[],"bars":[],"tempo":[],"sections":[],"instruments":[]}"#
        let analysis = try JSONDecoder().decode(MusicAnalysis.self, from: Data(old.utf8))
        #expect(analysis.beatCheck == nil)
        var checked = analysis
        checked.beatCheck = BeatGridCheck(checker: "beat-this", agreement: 0.97, primaryBPM: 92, checkerBPM: 92, usedChecker: false)
        let again = try JSONDecoder().decode(MusicAnalysis.self, from: JSONEncoder().encode(checked))
        #expect(again == checked)
    }

    /// The real thing on a real record: MRROBOTO_REAL_IMPORT=/path/to/audio. Prints what the check found.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_REAL_IMPORT"] != nil))
    func realRecord() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MRROBOTO_REAL_IMPORT"]!)
        let directory = GuidanceFixture.temporaryDirectory("second-opinion-real")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = LiveImportHost(library: LibraryStore(directoryURL: directory))
        let clock = ContinuousClock()
        let start = clock.now
        let report = try await host.analyze(url) { _ in }
        let analysis = ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: 0)
        let reading = BeatCheckReading(analysis.beatCheck)
        print("[real-import] \(url.lastPathComponent): \(clock.now - start); beats from \(report.provenance[.beats] ?? "-"); \(analysis.bars.count) bars")
        print("[real-import] check \(String(describing: report.beatCheck))")
        print("[real-import] reading: \(reading.value) — \(reading.help)")
        print("[real-import] notes \(report.notes)")
        #expect(report.beatCheck != nil)
    }
}
