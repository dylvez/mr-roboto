import Foundation
import MusicTheory
import Testing
@testable import Analysis

@Suite("Result types")
struct ResultRoundTripTests {
    static func sampleReport() -> AnalysisReport {
        let dMajor = Key(tonic: Tonic.d, mode: .ionian)
        let bMinor = Key(tonic: Tonic.b, mode: .aeolian)
        return AnalysisReport(
            sourcePath: "/tmp/Arrival.mp3",
            duration: 164.96,
            key: KeyEstimate(ranges: [KeyRange(start: 0, end: 100, key: dMajor, confidence: 0.9), KeyRange(start: 100, end: 164.96, key: bMinor)]),
            beats: BeatTrackingResult(beats: [0.5, 1.0, 1.5, 2.0, 2.5], downbeats: [0.5, 2.5], bpm: 120, confidence: [1, 0.9, 0.8, 0.7, 0.6]),
            structure: StructureAnalysis(sections: [TimeRange(0, 30), TimeRange(30, 60)], segments: [TimeRange(0, 15)], phrases: [TimeRange(0, 7.5)]),
            loudness: LoudnessAnalysis(integrated: -13.7, truePeak: -0.3, momentary: [TimedSample(time: 0.1, value: -20)], shortTerm: [TimedSample(time: 1, value: -15)]),
            instruments: InstrumentActivity(presence: [.vocal: [TimeRange(10, 20)], .drums: [TimeRange(0, 60)]], activity: [.bass: [TimedSample(time: 0, value: 0.5)]]),
            pace: [RangedSample(range: TimeRange(0, 60), value: 0.4)],
            capabilities: [.key, .beats, .structure, .loudness, .instrumentActivity, .pace],
            provenance: [.key: "musicUnderstanding", .beats: "beatThis"],
            analyzedAt: Date(timeIntervalSince1970: 1_700_000_000),
            wallTime: 21.5,
            notes: ["synthetic"])
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let report = Self.sampleReport()
        let data = try report.jsonData()
        let decoded = try AnalysisReport(jsonData: data)
        #expect(decoded == report)
        // Enum-keyed dictionaries encode as JSON objects, not key/value arrays.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provenance = try #require(object["provenance"] as? [String: String])
        #expect(provenance["beats"] == "beatThis")
        let presence = try #require((object["instruments"] as? [String: Any])?["presence"] as? [String: Any])
        #expect(presence.keys.sorted() == ["drums", "vocal"])
    }

    @Test func reportWritesAndReadsFile() throws {
        let report = Self.sampleReport()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-tests/\(UUID().uuidString)/report.json")
        try report.write(to: url)
        let loaded = try AnalysisReport(contentsOf: url)
        #expect(loaded == report)
        #expect(loaded.summary.contains("D major"))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func keyEstimateDominantAndLookup() {
        let dMajor = Key(tonic: Tonic.d)
        let bMinor = Key(tonic: Tonic.b, mode: .aeolian)
        let estimate = KeyEstimate(ranges: [
            KeyRange(start: 60, end: 100, key: bMinor),
            KeyRange(start: 0, end: 60, key: dMajor),
            KeyRange(start: 100, end: 130, key: dMajor),
        ])
        #expect(estimate.ranges.map(\.start) == [0, 60, 100])
        #expect(estimate.dominantKey == dMajor)
        #expect(estimate.key(at: 70) == bMinor)
        #expect(estimate.key(at: 200) == nil)
        #expect(!estimate.isStable)
        #expect(KeyEstimate(key: dMajor, duration: 10).isStable)
    }

    @Test func mergingFillsOnlyMissingFields() {
        var a = AnalysisReport(sourcePath: "/x", key: KeyEstimate(key: Key(tonic: Tonic.a), duration: 5), capabilities: [.key], provenance: [.key: "one"], wallTime: 1, notes: ["n1"])
        let b = AnalysisReport(sourcePath: "/x", key: KeyEstimate(key: Key(tonic: Tonic.b), duration: 5),
                               beats: BeatTrackingResult(beats: [1], downbeats: [1], bpm: 60), capabilities: [.key, .beats], provenance: [.key: "two", .beats: "two"], wallTime: 2, notes: ["n1", "n2"])
        a = a.merging(b)
        #expect(a.key?.dominantKey == Key(tonic: Tonic.a))
        #expect(a.beats?.bpm == 60)
        #expect(a.capabilities == [.key, .beats])
        #expect(a.provenance == [.key: "one", .beats: "two"])
        #expect(a.wallTime == 3)
        #expect(a.notes == ["n1", "n2"])
    }

    @Test func loudnessRangeAndInstrumentHelpers() {
        let loudness = LoudnessAnalysis(integrated: -14, truePeak: -1, shortTerm: (0..<100).map { TimedSample(time: Double($0), value: -30 + Double($0) * 0.2) })
        let range = loudness.range
        #expect(range != nil && range! > 15 && range! < 19)
        let activity = InstrumentActivity(presence: [.vocal: [TimeRange(10, 20), TimeRange(30, 35)], .other: []])
        #expect(activity.instruments == [.vocal])
        #expect(activity.isPresent(.vocal, at: 12))
        #expect(!activity.isPresent(.vocal, at: 25))
        #expect(activity.presentDuration(of: .vocal) == 15)
        #expect(StructureAnalysis(sections: [TimeRange(0, 10), TimeRange(10, 20)]).sectionIndex(at: 15) == 1)
    }

    @Test func errorsDescribeThemselves() {
        let url = URL(fileURLWithPath: "/nowhere/song.mp3")
        #expect(AnalysisError.fileNotFound(url).description.contains("song.mp3"))
        #expect(AnalysisError.analysisFailed(url, capabilities: [.beats, .key], reason: "boom").description.contains("[beats, key]"))
        #expect(AnalysisError.providerUnavailable(.stemSeparation, name: nil).description.contains("stemSeparation"))
    }
}
