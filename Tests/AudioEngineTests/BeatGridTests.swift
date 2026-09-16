import MusicTheory
import Testing
import AVFAudio
@testable import AudioEngine

@Suite struct BeatGridTests {
    /// An irregular grid: a ritardando, bars every 4 beats.
    static let grid = BeatGrid(
        beats: [0.0, 0.5, 1.0, 1.5, 2.0, 2.6, 3.2, 3.8, 4.4, 5.1, 5.8, 6.5],
        bars: [0.0, 2.0, 4.4]
    )

    @Test func nearestBeat() {
        let g = Self.grid
        #expect(g.nearestBeatIndex(to: -1) == 0)
        #expect(g.nearestBeatIndex(to: 0.24) == 0)
        #expect(g.nearestBeatIndex(to: 0.26) == 1)
        #expect(g.nearestBeat(to: 2.95) == 3.2)
        #expect(g.nearestBeat(to: 2.8) == 2.6)
        #expect(g.nearestBeatIndex(to: 100) == 11)
        #expect(BeatGrid(beats: [], bars: []).nearestBeatIndex(to: 1) == nil)
    }

    @Test func barForTime() {
        let g = Self.grid
        #expect(g.barIndex(at: -0.1) == nil)
        #expect(g.barIndex(at: 0) == 0)
        #expect(g.barIndex(at: 1.99) == 0)
        #expect(g.barIndex(at: 2.0) == 1)
        #expect(g.barIndex(at: 4.39) == 1)
        #expect(g.barIndex(at: 4.4) == 2)
        #expect(g.barIndex(at: 50) == 2)
        #expect(g.beatIndex(at: 2.7) == 5)
    }

    @Test func timeOfBar() {
        let g = Self.grid
        #expect(g.time(ofBar: 0) == 0)
        #expect(g.time(ofBar: 2) == 4.4)
        // One past the last bar: extrapolated from the last bar length (4.4 - 2.0).
        #expect(abs((g.time(ofBar: 3) ?? -1) - 6.8) < 1e-9)
        #expect(g.time(ofBar: 4) == nil)
        #expect(g.time(ofBar: -1) == nil)
        #expect(abs((g.duration(ofBar: 1) ?? 0) - 2.4) < 1e-9)
        #expect(g.downbeatIndices() == [0, 4, 8])
    }

    @Test func regularGridMatchesClock() {
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)
        let g = clock.grid(bars: 4)
        #expect(g.beats.count == 16)
        #expect(g.bars == [0, 2, 4, 6])
        #expect(g.beats[5] == 2.5)
        #expect(g.endOfLastBar == 8)
        #expect(clock.seconds(forBar: 3, beat: 1) == 6.5)
        #expect(clock.frame(forBeat: 1) == 24_000)
        let pos = clock.position(forSeconds: 6.75)
        #expect(pos.bar == 3)
        #expect(abs(pos.beat - 1.5) < 1e-9)
    }

    @Test func hostTimeConversionsRoundTrip() {
        var clock = TransportClock(tempo: 100, sampleRate: 44_100)
        #expect(clock.hostTime(forSeconds: 1) == nil)
        #expect(clock.audioTime(forSeconds: 1).isSampleTimeValid)
        #expect(clock.audioTime(forSeconds: 1).sampleTime == 44_100)

        clock.startHostTime = 1_000_000_000
        let t = clock.hostTime(forBeat: 4)!  // 2.4 s
        #expect(t > clock.startHostTime!)
        #expect(abs(clock.seconds(forHostTime: t)! - 2.4) < 1e-6)
        #expect(abs(clock.beat(forHostTime: t)! - 4) < 1e-6)
        #expect(clock.audioTime(forSeconds: 2.4).isHostTimeValid)
        #expect(!clock.audioTime(forSeconds: 2.4).isSampleTimeValid)
        // Before transport zero.
        #expect(clock.seconds(forHostTime: clock.hostTime(forSeconds: -0.5)!)! < 0)
    }
}
