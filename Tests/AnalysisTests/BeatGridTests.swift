import MusicTheory
import Testing
@testable import Analysis

@Suite("BeatGrid")
struct BeatGridTests {
    // 120 BPM, 4/4, 4 bars starting at 1.0 s: beats every 0.5 s, bars every 2 s.
    let grid = BeatGrid.regular(bpm: 120, bars: 4, startingAt: 1.0)

    @Test func regularGridShape() {
        #expect(grid.beatCount == 16)
        #expect(grid.barCount == 4)
        #expect(grid.bars == [1.0, 3.0, 5.0, 7.0])
        #expect(grid.bpm == 120)
        #expect(grid.timeSignature == .fourFour)
        #expect(grid.medianBeatInterval == 0.5)
    }

    @Test func nearestBeat() {
        #expect(grid.nearestBeat(to: 1.2) == 1.0)
        #expect(grid.nearestBeat(to: 1.3) == 1.5)
        #expect(grid.nearestBeat(to: -5) == 1.0)
        #expect(grid.nearestBeat(to: 100) == 8.5)
        #expect(grid.nearestBeatIndex(to: 3.0) == 4)
        #expect(BeatGrid(beats: [], bars: []).nearestBeat(to: 1) == nil)
    }

    @Test func barLookups() {
        #expect(grid.barIndex(at: 0.5) == nil)
        #expect(grid.barIndex(at: 1.0) == 0)
        #expect(grid.barIndex(at: 2.99) == 0)
        #expect(grid.barIndex(at: 3.0) == 1)
        #expect(grid.bar(at: 7.5) == 3)
        #expect(grid.bar(at: 50) == 3)
        #expect(grid.time(ofBar: 0) == 1.0)
        #expect(grid.time(ofBar: 3) == 7.0)
        #expect(grid.time(ofBar: 4) == 9.0)  // extrapolated end of the last bar
        #expect(grid.time(ofBar: 5) == nil)
        #expect(grid.time(ofBar: -1) == nil)
        #expect(grid.duration(ofBar: 2) == 2.0)
        #expect(grid.range(ofBars: 1..<3) == TimeRange(3.0, 7.0))
        #expect(grid.beatIndex(at: 1.6) == 1)
        let position = grid.position(at: 3.6)
        #expect(position?.bar == 1 && position?.beat == 1)
    }

    @Test func downbeatsAndShift() {
        #expect(grid.downbeatIndices() == [0, 4, 8, 12])
        let shifted = grid.shifted(by: -1.0)
        #expect(shifted.bars == [0, 2, 4, 6])
        #expect(shifted.beats.first == 0)
    }

    @Test func guessesMeterAndTempoFromData() {
        // 3/4 at 90 BPM: beats every 2/3 s, bars every 2 s. Given unsorted, without a bpm.
        let beats = (0..<12).map { Double($0) * 2 / 3 }.reversed()
        let bars = [4.0, 0.0, 2.0, 6.0]
        let grid = BeatGrid(beats: Array(beats), bars: bars)
        #expect(grid.beats.first == 0 && grid.bars == [0, 2, 4, 6])
        #expect(grid.timeSignature == .threeFour)
        #expect(abs((grid.bpm ?? 0) - 90) < 0.01)
        #expect(BeatGrid(beats: [0, 1], bars: [0]).timeSignature == .fourFour)
    }

    @Test func singleBarEndUsesBeatSpacing() {
        let grid = BeatGrid(beats: [0, 0.5, 1.0, 1.5], bars: [0])
        #expect(grid.endOfLastBar == 2.0)
    }

    @Test func trackingResultProducesGrid() {
        let result = BeatTrackingResult(beats: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5], downbeats: [0, 2], bpm: 121)
        #expect(result.grid.bpm == 121)
        #expect(result.grid.barCount == 2)
    }
}
