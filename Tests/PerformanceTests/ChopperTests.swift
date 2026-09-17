import Foundation
import MusicTheory
import Testing
@testable import Performance

@Suite("Chopper")
struct ChopperTests {
    static let sr: Double = 48_000

    // MARK: Onsets

    @Test("four on the floor gives exactly four slices, on the beats")
    func onsetSlicingFindsFourKicks() {
        let (signal, times) = ChopFixtures.fourOnTheFloor(bpm: 120, sampleRate: Self.sr)
        let chop = Chopper().sliceByOnsets(signal, sampleRate: Self.sr)

        #expect(chop.count == 4)
        for (slice, expected) in zip(chop.slices, times) {
            let error = abs(slice.startSeconds - expected)
            #expect(error < 0.003, "slice \(slice.index) at \(slice.startSeconds) s, expected \(expected) s")
        }
        // The kick at frame 0 cannot be *detected* — there is no earlier frame to difference
        // against — so it arrives as the lead-in. That is the mechanism, and it is worth pinning:
        // without it a chop of a bar that starts on the downbeat would silently lose its downbeat.
        #expect(chop.slices[0].origin == .leadIn)
        #expect(chop.slices.dropFirst().allSatisfy { $0.origin == .onset })
    }

    @Test("slices tile the buffer with no gaps and no overlaps")
    func slicesTileTheBuffer() {
        let (signal, _) = ChopFixtures.fourOnTheFloor(bpm: 120, sampleRate: Self.sr)
        let chop = Chopper().sliceByOnsets(signal, sampleRate: Self.sr)

        #expect(chop.slices.first?.start == 0)
        #expect(chop.slices.last?.end == signal.count)
        for (a, b) in zip(chop.slices, chop.slices.dropFirst()) {
            #expect(a.end == b.start, "gap or overlap between slice \(a.index) and \(b.index)")
        }
    }

    @Test("each slice reports its own peak and RMS")
    func slicesAreMeasured() {
        let (signal, _) = ChopFixtures.fourOnTheFloor(bpm: 120, sampleRate: Self.sr)
        let chop = Chopper().sliceByOnsets(signal, sampleRate: Self.sr)

        for slice in chop.slices {
            let expectedPeak = ChopSignal.peak(Array(signal[slice.range]))
            #expect(abs(slice.peak - expectedPeak) < 1e-6)
            #expect(abs(Double(slice.rms) - ChopSignal.rms(signal[slice.range])) < 1e-5)
            #expect(slice.rms <= slice.peak)
        }
    }

    // MARK: Grid

    @Test("grid slicing follows an uneven grid, not a metronome")
    func gridSlicingFollowsAnUnevenGrid() {
        let beats = [0.0, 0.5, 1.1, 1.5, 2.2]
        let grid = BeatGrid(beats: beats, bars: [0.0], bpm: 120, timeSignature: .fourFour)
        let signal = [Float](repeating: 0.1, count: Int(2.5 * Self.sr))
        let chop = Chopper().sliceByGrid(signal, sampleRate: Self.sr, grid: grid)

        #expect(chop.slices.map(\.start) == beats.map { Int(($0 * Self.sr).rounded()) })
        #expect(chop.slices.allSatisfy { $0.origin == .grid })
        // Uneven in, uneven out: the 0.6 s beat produces a 0.6 s slice.
        let lengths = chop.slices.map { ($0.duration * 10).rounded() / 10 }
        #expect(lengths == [0.5, 0.6, 0.4, 0.7, 0.3])
    }

    @Test("grid slicing subdivides each beat in proportion")
    func gridSlicingSubdivides() {
        let grid = BeatGrid(beats: [0.0, 0.5, 1.1], bars: [0.0], bpm: 120)
        let signal = [Float](repeating: 0.1, count: Int(1.5 * Self.sr))
        let chop = Chopper().sliceByGrid(signal, sampleRate: Self.sr, grid: grid, division: 2)

        let starts = chop.slices.map { ($0.startSeconds * 1000).rounded() / 1000 }
        #expect(starts == [0.0, 0.25, 0.5, 0.8, 1.1, 1.4])
    }

    // MARK: Snapping

    @Test("an 8 ms early onset snaps to the grid; a 40 ms early one is left alone")
    func snappingMovesTheEarlyOneOnly() {
        let grid = BeatGrid.regular(bpm: 120, bars: 1)
        let signal = [Float](repeating: 0.1, count: Int(2 * Self.sr))
        // 8 ms before beat 2, 40 ms before beat 3.
        let chop = Chopper().slice(atOnsets: [0.492, 0.960], signal: signal, sampleRate: Self.sr,
                                   snappingTo: grid, division: 4)

        #expect(chop.count == 3)  // lead-in plus the two onsets
        let early = chop.slices[1]
        #expect(early.origin == .snapped)
        #expect(early.start == Int(0.5 * Self.sr))
        #expect(abs(early.snapOffset - 0.008) < 1e-6)

        let dragged = chop.slices[2]
        #expect(dragged.origin == .onset)
        #expect(dragged.start == Int((0.960 * Self.sr).rounded()))
        #expect(dragged.snapOffset == 0)
    }

    @Test("snapping does nothing without a grid")
    func snappingNeedsAGrid() {
        let signal = [Float](repeating: 0.1, count: Int(2 * Self.sr))
        let chop = Chopper().slice(atOnsets: [0.492, 0.960], signal: signal, sampleRate: Self.sr)

        #expect(chop.slices.dropFirst().allSatisfy { $0.origin == .onset })
        #expect(chop.slices[1].start == Int((0.492 * Self.sr).rounded()))
    }

    @Test("snapping works on detected onsets too")
    func snappingOnDetectedOnsets() {
        let grid = BeatGrid.regular(bpm: 120, bars: 1)
        let kick = ChopFixtures.kick(Self.sr)
        // Placed 8 ms early and 40 ms early against the same grid.
        let signal = ChopFixtures.place([(0.492, kick), (0.960, kick)], length: 2,
                                        sampleRate: Self.sr)
        let chop = Chopper().sliceByOnsets(signal, sampleRate: Self.sr, snappingTo: grid, division: 4)

        let snapped = chop.slices.filter { $0.origin == .snapped }
        let loose = chop.slices.filter { $0.origin == .onset }
        #expect(snapped.count == 1)
        #expect(snapped.first?.start == Int(0.5 * Self.sr))
        #expect(loose.count == 1)
        #expect(abs((loose.first?.startSeconds ?? 0) - 0.960) < 0.005)
    }

    @Test("the tolerance is the boundary")
    func toleranceIsTheBoundary() {
        let grid = BeatGrid.regular(bpm: 120, bars: 1)
        let signal = [Float](repeating: 0.1, count: Int(2 * Self.sr))
        var chopper = Chopper()
        chopper.snapTolerance = 0.010
        chopper.includeLeadIn = false

        let inside = chopper.slice(atOnsets: [0.4915], signal: signal, sampleRate: Self.sr,
                                   snappingTo: grid, division: 4)
        let outside = chopper.slice(atOnsets: [0.4885], signal: signal, sampleRate: Self.sr,
                                    snappingTo: grid, division: 4)
        #expect(inside.slices[0].origin == .snapped)
        #expect(outside.slices[0].origin == .onset)
    }

    // MARK: Divisions

    @Test("equal divisions need no analysis at all")
    func equalDivisions() {
        let signal = [Float](repeating: 0.25, count: Int(2 * Self.sr))
        let chop = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 16)

        #expect(chop.count == 16)
        #expect(chop.slices.allSatisfy { $0.origin == .division })
        #expect(chop.slices.allSatisfy { $0.frameCount == signal.count / 16 })
        #expect(chop.slices.map(\.start) == (0..<16).map { $0 * signal.count / 16 })
    }

    @Test("onsets closer than the floor are one attack, not two")
    func tooCloseOnsetsMerge() {
        let signal = [Float](repeating: 0.1, count: Int(1 * Self.sr))
        var chopper = Chopper()
        chopper.includeLeadIn = false
        chopper.minimumSliceDuration = 0.02
        let chop = chopper.slice(atOnsets: [0.2, 0.205, 0.4], signal: signal, sampleRate: Self.sr)

        #expect(chop.count == 2)
        #expect(chop.slices.map(\.startSeconds) == [0.2, 0.4])
    }

    // MARK: SongGraph

    @Test("markers come out in the record's own time")
    func markersUseTheRecordsTime() {
        let signal = [Float](repeating: 0.1, count: Int(2 * Self.sr))
        let chop = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 4,
                                              sourceOffset: 14.2, detectedTempo: 93)

        #expect(chop.markers.map { ($0.position * 100).rounded() / 100 } == [14.2, 14.7, 15.2, 15.7])
        #expect(chop.markers.allSatisfy { $0.label == "division" })
        #expect(chop.detectedTempo == 93)
    }
}
