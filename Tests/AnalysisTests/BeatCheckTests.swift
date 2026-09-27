import Foundation
import Testing
@testable import Analysis

// A second beat tracker's word on the first's grid: it stands in when the first found none, and
// otherwise says how far the two agree.

@Suite("Beat check")
struct BeatCheckTests {
    private func grid(every seconds: Double, count: Int, bpm: Double? = nil) -> BeatTrackingResult {
        let beats = (0..<count).map { 0.5 + Double($0) * seconds }
        return BeatTrackingResult(beats: beats, downbeats: stride(from: 0, to: count, by: 4).map { beats[$0] }, bpm: bpm)
    }

    @Test("two grids that agree keep the first, checked")
    func agreeing() throws {
        let first = grid(every: 0.5, count: 64, bpm: 120)
        let second = grid(every: 0.5, count: 64).beats.map { $0 + 0.012 }
        let (beats, check) = BeatCheck.reconcile(primary: first, checker: "beat-this",
                                                 checked: BeatTrackingResult(beats: second, downbeats: []))
        #expect(beats == first)
        let made = try #require(check)
        #expect(made.agreement == 1 && !made.usedChecker && made.agrees)
        #expect(made.primaryBPM == 120)
        #expect(abs((made.checkerBPM ?? 0) - 120) < 0.01, "from the beats' spacing when a tracker gives no tempo")
    }

    @Test("with no grid from the first, the checker's stands in")
    func standsIn() throws {
        let second = grid(every: 0.5, count: 32, bpm: 120)
        for primary in [nil, grid(every: 0.5, count: 2)] {
            let (beats, check) = BeatCheck.reconcile(primary: primary, checker: "beat-this", checked: second)
            #expect(beats == second)
            #expect(check?.usedChecker == true && check?.agreement == nil)
        }
        let (none, noCheck) = BeatCheck.reconcile(primary: nil, checker: "beat-this", checked: nil)
        #expect(none == nil && noCheck == nil)
        let first = grid(every: 0.5, count: 32)
        #expect(BeatCheck.reconcile(primary: first, checker: "beat-this", checked: nil).check == nil)
    }

    @Test("a grid heard in double time is a disagreement, and says so")
    func doubleTime() throws {
        let (_, check) = BeatCheck.reconcile(primary: grid(every: 0.25, count: 128), checker: "beat-this",
                                             checked: grid(every: 0.5, count: 64))
        let made = try #require(check)
        #expect(abs((made.agreement ?? 0) - 2.0 / 3) < 0.02, "\(made.agreement ?? -1)")
        #expect(!made.agrees && made.isOctaveApart)
    }
}
