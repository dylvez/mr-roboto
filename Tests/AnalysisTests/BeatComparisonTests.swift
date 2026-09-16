import Foundation
import Testing
@testable import Analysis

@Suite("BeatComparison")
struct BeatComparisonTests {
    @Test func identicalListsScorePerfectly() {
        let beats = (0..<20).map { Double($0) * 0.5 }
        let c = BeatComparison.compare(estimate: beats, reference: beats)
        #expect(c.fMeasure == 1)
        #expect(c.precision == 1 && c.recall == 1)
        #expect(c.matched == 20)
        #expect(c.meanOffset == 0 && c.medianOffset == 0)
        #expect(c.downbeatFMeasure == nil)
    }

    @Test func knownFMeasure() {
        // Reference: 10 beats. Estimate: 8 of them shifted +30 ms (matched), plus 2 spurious ones.
        let reference = (0..<10).map { Double($0) * 0.5 }
        var estimate = (0..<8).map { Double($0) * 0.5 + 0.03 }
        estimate += [4.25, 4.75]
        let c = BeatComparison.compare(estimate: estimate, reference: reference, tolerance: 0.07)
        #expect(c.matched == 8)
        #expect(abs(c.precision - 0.8) < 1e-9)
        #expect(abs(c.recall - 0.8) < 1e-9)
        #expect(abs(c.fMeasure - 0.8) < 1e-9)
        #expect(abs(c.meanOffset - 0.03) < 1e-9)
        #expect(abs(c.medianOffset - 0.03) < 1e-9)
        #expect(abs(c.meanAbsoluteOffset - 0.03) < 1e-9)
    }

    @Test func toleranceMatters() {
        let reference = (0..<10).map { Double($0) * 0.5 }
        let estimate = reference.map { $0 + 0.1 }
        #expect(BeatComparison.compare(estimate: estimate, reference: reference, tolerance: 0.07).fMeasure == 0)
        #expect(BeatComparison.compare(estimate: estimate, reference: reference, tolerance: 0.15).fMeasure == 1)
    }

    @Test func offsetsAreSigned() {
        let reference = (0..<9).map { Double($0) * 0.5 }
        let estimate = reference.map { $0 - 0.02 }
        let c = BeatComparison.compare(estimate: estimate, reference: reference)
        #expect(abs(c.medianOffset + 0.02) < 1e-9)
    }

    @Test func halfTempoEstimateScoresAsExpected() {
        let reference = (0..<20).map { Double($0) * 0.5 }
        let estimate = (0..<10).map { Double($0) * 1.0 }
        let c = BeatComparison.compare(estimate: estimate, reference: reference)
        #expect(c.precision == 1)
        #expect(c.recall == 0.5)
        #expect(abs(c.fMeasure - 2.0 / 3.0) < 1e-9)
    }

    @Test func emptyListsDoNotCrash() {
        let c = BeatComparison.compare(estimate: [], reference: [1, 2, 3])
        #expect(c.fMeasure == 0 && c.matched == 0)
        let d = BeatComparison.compare(estimate: [], reference: [])
        #expect(d.fMeasure == 0)
    }

    @Test func downbeatAgreement() {
        let reference = BeatTrackingResult(beats: (0..<16).map { Double($0) * 0.5 }, downbeats: [0, 2, 4, 6])
        // Same beats, downbeats shifted by one beat: downbeat F = 0, agreement = half the beats disagree.
        let wrong = BeatTrackingResult(beats: reference.beats, downbeats: [0.5, 2.5, 4.5, 6.5])
        let c = BeatComparison.compare(estimate: wrong, reference: reference)
        #expect(c.fMeasure == 1)
        #expect(c.downbeatFMeasure == 0)
        #expect(c.downbeatAgreement == 0.5)
        let right = BeatComparison.compare(estimate: reference, reference: reference)
        #expect(right.downbeatFMeasure == 1 && right.downbeatAgreement == 1)
    }

    @Test func readsGoldenShape() throws {
        let json = #"{"beats":[0.5,1.0,1.5,2.0],"downbeats":[0.5],"extra":true}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let golden = try BeatComparison.Golden(contentsOf: url)
        #expect(golden.beats.count == 4 && golden.downbeats == [0.5])
        let c = BeatComparison.compare(estimate: BeatTrackingResult(beats: golden.beats, downbeats: golden.downbeats), golden: golden)
        #expect(c.fMeasure == 1 && c.downbeatFMeasure == 1)
        #expect(c.description.contains("F=1.000"))
    }
}
