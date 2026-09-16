import Foundation
import MusicTheory
import Testing
@testable import Analysis

/// The Arrival test track and its goldens. One shared provider so the ≈20 s analysis runs once
/// for the whole suite; the suite is serialized so wall-time figures are not confounded.
enum Arrival {
    static let url = URL(fileURLWithPath: "/Users/dylanfulmer/Documents/projects/vessel/public/assets/audio/interiorseason/Arrival.mp3")
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = packageRoot.appendingPathComponent("Bench/goldens/Arrival")
    static let provider = MusicUnderstandingProvider()

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Suite("MusicUnderstandingProvider on Arrival.mp3", .serialized)
struct MusicUnderstandingProviderTests {
    @Test func analyzesArrival() async throws {
        guard Arrival.isAvailable else {
            Issue.record("Arrival.mp3 not found at \(Arrival.url.path); skipping the Music Understanding integration test")
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await Arrival.provider.analyze(url: Arrival.url)
        let wall = started.duration(to: clock.now).seconds
        print("[Arrival] analysis wall time: \(String(format: "%.1f", wall)) s (session reported \(String(format: "%.1f", report.wallTime)) s)")
        print(report.summary)

        let key = try #require(report.key)
        #expect(key.dominantKey == Key(tonic: Tonic.d, mode: .ionian), "expected D major, got \(key.dominantKey?.name ?? "nil")")

        let beats = try #require(report.beats)
        #expect((70...86).contains(beats.downbeats.count), "bars: \(beats.downbeats.count)")
        let bpm = try #require(beats.bpm)
        #expect((110...116).contains(bpm), "bpm: \(bpm)")
        #expect(beats.beats.count > 250)
        #expect(beats.grid.timeSignature == .fourFour)

        let loudness = try #require(report.loudness)
        #expect((-15 ... -12).contains(loudness.integrated), "integrated: \(loudness.integrated) LUFS")
        #expect(!loudness.momentary.isEmpty && !loudness.shortTerm.isEmpty)

        let structure = try #require(report.structure)
        #expect((6...12).contains(structure.sections.count), "sections: \(structure.sections.count)")

        let instruments = try #require(report.instruments)
        #expect(instruments.instruments.contains(.drums))
        #expect(report.duration.map { abs($0 - 164.96) < 1 } == true, "duration: \(report.duration ?? -1)")
        #expect(report.capabilities == .musicUnderstanding)
        #expect(report.provenance[.beats] == "musicUnderstanding")

        // The cached second request must not analyse again.
        let cachedStart = clock.now
        let second = try await Arrival.provider.trackBeats(url: Arrival.url)
        let cachedSeconds = cachedStart.duration(to: clock.now).seconds
        print("[Arrival] cached trackBeats returned in \(String(format: "%.2f", cachedSeconds * 1000)) ms")
        #expect(cachedSeconds < 0.05, "cached call took \(cachedSeconds * 1000) ms")
        #expect(second == beats)
        let cachedKey = try await Arrival.provider.estimateKey(url: Arrival.url)
        #expect(cachedKey == key)

        // The JSON dump round-trips.
        let json = try await Arrival.provider.reportJSON(for: Arrival.url)
        var decoded = try AnalysisReport(jsonData: json)
        #expect(abs(decoded.analyzedAt.timeIntervalSince(report.analyzedAt)) < 0.001)  // ISO 8601 keeps milliseconds
        decoded.analyzedAt = report.analyzedAt
        #expect(decoded == report)
    }

    @Test func beatsAgreeWithBeatThisGolden() async throws {
        guard Arrival.isAvailable else {
            Issue.record("Arrival.mp3 not found; skipping the goldens comparison")
            return
        }
        let goldenURL = Arrival.goldens.appendingPathComponent("beats.json")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            Issue.record("golden beats.json not found at \(goldenURL.path); skipping")
            return
        }
        let golden = try BeatComparison.Golden(contentsOf: goldenURL)
        let beats = try await Arrival.provider.trackBeats(url: Arrival.url)
        let comparison = BeatComparison.compare(estimate: beats, golden: golden)
        print("[Arrival] Music Understanding vs Beat This!: \(comparison)")
        print("[Arrival] MU beats \(beats.beats.count) bars \(beats.downbeats.count) bpm \(beats.bpm.map { String(format: "%.2f", $0) } ?? "nil"); golden beats \(golden.beats.count) downbeats \(golden.downbeats.count)")
        #expect(comparison.fMeasure > 0.8, "F-measure \(comparison.fMeasure)")
        #expect(abs(comparison.medianOffset) < 0.07)
    }

    @Test func missingFileIsATypedError() async {
        let provider = MusicUnderstandingProvider()
        let url = URL(fileURLWithPath: "/nowhere/missing.mp3")
        await #expect(throws: AnalysisError.fileNotFound(url)) {
            try await provider.trackBeats(url: url)
        }
    }

    @Test func unreadableFileIsATypedError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try Data("this is not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = MusicUnderstandingProvider()
        do {
            _ = try await provider.estimateKey(url: url)
            Issue.record("expected an error for a non-audio file")
        } catch let error as AnalysisError {
            print("[non-audio] \(error)")
            switch error {
            case .unsupportedAsset, .analysisFailed, .missingResult: break
            default: Issue.record("unexpected error kind: \(error)")
            }
        } catch {
            Issue.record("expected AnalysisError, got \(error)")
        }
    }

    @Test func cancellationStopsAnalysis() async throws {
        guard Arrival.isAvailable else { return }
        let provider = MusicUnderstandingProvider()
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { try await provider.trackBeats(url: Arrival.url) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let result = await task.result
        let elapsed = started.duration(to: clock.now).seconds
        print("[Arrival] cancelled analysis returned after \(String(format: "%.2f", elapsed)) s")
        switch result {
        case .success: Issue.record("cancelled analysis returned a result after \(elapsed) s")
        case .failure(let error): #expect(error is CancellationError, "expected CancellationError, got \(error)")
        }
        #expect(elapsed < 10, "cancellation took \(elapsed) s")
        #expect(await provider.cachedReport(for: Arrival.url) == nil)
    }
}
