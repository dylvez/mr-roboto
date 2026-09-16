import MusicTheory
import Testing
import AVFAudio
import Foundation
@testable import AudioEngine

@Suite struct MetronomeTests {
    /// An irregular grid (accelerando) so the test proves grid-driven timing, not tempo math.
    static let grid = BeatGrid(
        beats: [0.0, 0.55, 1.08, 1.6, 2.1, 2.58, 3.05, 3.5, 3.93, 4.34, 4.74, 5.12],
        bars: [0.0, 2.1, 3.93]
    )

    @Test @AudioActor func clicksLandOnGridBeatsWithinOneSample() throws {
        let sr = 48_000.0
        let engine = try makeOfflineEngine(sampleRate: sr)
        let metronome = try Metronome(engine: engine, playerIndex: 0, grid: Self.grid)
        engine.add(metronome)
        try engine.start()
        try engine.startTransport(clock: TransportClock(tempo: 120))

        let seconds = 5.5
        let buffer = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(seconds * sr))
        #expect(metronome.scheduledBeatCount == Self.grid.beats.count)

        let x = Analysis.samples(buffer)
        // A click's first sample is at full amplitude; it decays below 0.05 within ~10 ms.
        let onsets = Analysis.onsets(in: x, threshold: 0.4, quietWindow: 2000, quietLevel: 0.05)
        let expected = Self.grid.beats.map { Int(($0 * sr).rounded()) }
        #expect(onsets.count == expected.count, "onsets \(onsets) expected \(expected)")
        for (found, wanted) in zip(onsets, expected) {
            #expect(abs(found - wanted) <= 1, "onset \(found) vs beat \(wanted)")
        }
        // Accents on downbeats are louder than plain beats.
        let downbeats = Self.grid.downbeatIndices()
        for (i, onset) in onsets.enumerated() where onset < x.count {
            let level = abs(x[onset])
            if downbeats.contains(i) {
                #expect(level > 0.9, "downbeat \(i) level \(level)")
            } else {
                #expect(level > 0.6 && level < 0.8, "beat \(i) level \(level)")
            }
        }
        engine.stop()
    }

    @Test @AudioActor func clockDrivenMetronomeSchedulesEveryBeat() throws {
        let sr = 44_100.0
        let engine = try makeOfflineEngine(sampleRate: sr, channels: 2)
        let clock = TransportClock(tempo: 150, timeSignature: .threeFour)
        let metronome = try Metronome(engine: engine, clock: clock, bars: 4)
        engine.add(metronome)
        try engine.start()
        try engine.startTransport(clock: clock)
        let buffer = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(clock.secondsPerBar * 4 * sr))
        #expect(metronome.scheduledBeatCount == 12)
        for channel in 0..<2 {
            let x = Analysis.samples(buffer, channel: channel)
            let onsets = Analysis.onsets(in: x, threshold: 0.4, quietWindow: 1000, quietLevel: 0.05)
            #expect(onsets.count == 12)
            for (i, onset) in onsets.enumerated() {
                #expect(abs(onset - Int((clock.seconds(forBeat: Double(i)) * sr).rounded())) <= 1)
            }
        }
        engine.stop()
    }
}
