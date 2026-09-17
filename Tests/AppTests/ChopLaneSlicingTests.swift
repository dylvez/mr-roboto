import Foundation
import MusicTheory
import Performance
import Testing
@testable import MrRobotoApp

/// The sensitivity dial and the marker drag: the two things in this surface that decide where a
/// slice begins.
@MainActor
@Suite("Chop lane slicing")
struct ChopLaneSlicingTests {

    // MARK: Sensitivity

    @Test("the dial is δ, inverted")
    func dialIsThreshold() {
        #expect(ChopLaneSurface.threshold(forSensitivity: 0) == ChopLaneSurface.thresholdAtZero)
        #expect(ChopLaneSurface.threshold(forSensitivity: 1) == ChopLaneSurface.thresholdAtOne)
        // Higher sensitivity is a lower threshold, which is the whole reason the control is
        // inverted: nobody turns "threshold" up to get more slices.
        #expect(ChopLaneSurface.threshold(forSensitivity: 0.25)
                > ChopLaneSurface.threshold(forSensitivity: 0.75))
        // The dial opens on δ = 4 — one notch looser than the analysis default of 5.
        #expect(ChopLaneSurface.threshold(
            forSensitivity: ChopLaneSurface.defaultSensitivity) == 4)
    }

    @Test("sensitivity finds more slices, with the counts the spec describes")
    func sensitivityChangesSliceCount() {
        let (lane, _) = ChopLaneFixtures.ghostLane()

        // Pinned on this fixture, which behaves like a bar of a real drum stem: at the analysis
        // default the bar reads as its five accents, and one notch looser it finds the ghosts.
        lane.sensitivity = 0
        #expect(lane.sliceCount == 5)          // δ 9
        lane.sensitivity = 0.5
        #expect(lane.sliceCount == 6)          // δ 5, the Analysis default
        lane.sensitivity = ChopLaneSurface.defaultSensitivity
        #expect(lane.onsetThreshold == 4)
        #expect(lane.sliceCount == 7)          // δ 4, where the lane opens: six to eight
        lane.sensitivity = 0.75
        #expect(lane.sliceCount >= 10)         // δ 3, into the room tone
        lane.sensitivity = 1
        #expect(lane.sliceCount >= 20)         // δ 1, everything the detector can see

        // And it never goes backwards as the dial goes up.
        var previous = 0
        for step in stride(from: 0.0, through: 1.0, by: 0.125) {
            lane.sensitivity = step
            #expect(lane.sliceCount >= previous,
                    "slice count fell from \(previous) at sensitivity \(step)")
            previous = lane.sliceCount
        }
    }

    @Test("the dial is clamped and the headline follows it")
    func dialIsClamped() {
        let (lane, _) = ChopLaneFixtures.ghostLane()
        lane.sensitivity = 4
        #expect(lane.sensitivity == 1)
        lane.sensitivity = -2
        #expect(lane.sensitivity == 0)
        #expect(lane.sliceCount == 5)
        #expect(lane.headline.contains("5 slices"))
        #expect(lane.title == lane.headline)
    }

    @Test("re-slicing drops hand edits, and says so first")
    func reslicingDropsHandEdits() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        #expect(!lane.handEdited)
        lane.override(slice: 0, as: .hat)
        lane.setGain(-6, slice: 1)
        lane.addMarker(at: 0.5)
        #expect(lane.handEdited)
        #expect(!lane.overrides.isEmpty)

        lane.sensitivity = 0.2
        #expect(!lane.handEdited)
        #expect(lane.overrides.isEmpty)
        #expect(lane.edits.isEmpty)
    }

    // MARK: The clean bar's shape
    //
    // Everything below leans on this, so it is asserted once rather than assumed eight times.

    @Test("the clean bar cuts into eight slices, classified")
    func cleanBarShape() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        #expect(lane.sliceCount == 8)
        #expect(lane.classifications.map(\.kind) == [.kick, .hat, .snare, .kick, .hat, .kick,
                                                     .snare, .hat])
        // The bar's first kick is at frame 0, where the detector cannot see it — there is no
        // earlier frame to be a jump from — so it becomes the lead-in slice rather than being
        // lost. Six of the rest sit on a grid line. The eighth is the hat that drags behind
        // step 14, kept where the record put it rather than pulled onto the line.
        #expect(lane.chop.slices[0].origin == .leadIn)
        #expect(lane.chop.slices.filter { $0.origin == .snapped }.count == 6)
        let late = lane.chop.slices[lane.sliceCount - 1]
        #expect(late.origin == .onset)
        #expect(abs(late.startSeconds - ChopLaneFixtures.lateHatStep
                    * ChopLaneFixtures.step) < 0.01)
    }

    // MARK: Snapping

    /// A grid line with no transient anywhere near it — the "and" of beat 2 in this bar.
    private func emptyGridLine(_ lane: ChopLaneSurface) -> Double? {
        lane.gridLines.first { line in
            lane.detectedOnsets.allSatisfy { abs($0 - line) > 0.1 } && line > 0.2
        }
    }

    @Test("a dragged marker snaps to a grid line inside the tolerance")
    func dragSnapsToGrid() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let line = try #require(emptyGridLine(lane))
        let slice = try #require(lane.chop.slices.first { $0.startSeconds > line }).index

        lane.beginDrag(slice: slice)
        lane.dragMarker(to: line + lane.snapTolerance * 0.8)
        let drag = try #require(lane.drag)
        #expect(drag.snapped?.kind == .grid)
        #expect(abs(drag.time - line) < 1e-9)
        // The free position is kept alongside the landed one — that difference is what the plate
        // draws to show the snap.
        #expect(drag.free > drag.time)
        #expect(drag.snapped?.label.isEmpty == false)
    }

    @Test("and not beyond it")
    func dragDoesNotSnapBeyondTolerance() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let line = try #require(emptyGridLine(lane))
        let slice = try #require(lane.chop.slices.first { $0.startSeconds > line }).index
        let free = line + lane.snapTolerance * 1.6

        lane.beginDrag(slice: slice)
        lane.dragMarker(to: free)
        let drag = try #require(lane.drag)
        #expect(drag.snapped == nil)
        #expect(abs(drag.time - free) < 1e-9)
    }

    @Test("a marker snaps back onto a transient, not only onto the grid")
    func dragSnapsToOnset() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        // The late hat: the one onset in this bar that no grid line explains.
        let lines = lane.gridLines
        func offGrid(_ t: Double) -> Double { lines.map { abs($0 - t) }.min() ?? 0 }
        let furthest = lane.detectedOnsets.max { offGrid($0) < offGrid($1) }
        let late = try #require(furthest)
        let slice = try #require(lane.chop.slices.first { abs($0.startSeconds - late) < 0.01 }).index

        lane.beginDrag(slice: slice)
        lane.dragMarker(to: late - lane.snapTolerance * 0.8)
        let drag = try #require(lane.drag)
        #expect(drag.snapped?.kind == .onset)
        #expect(drag.snapped?.label == "onset")
        #expect(abs(drag.time - late) < 1e-9)
    }

    @Test("letting go moves the marker and re-cuts the bar")
    func endDragMovesTheMarker() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        let line = try #require(emptyGridLine(lane))
        let slice = try #require(lane.chop.slices.first { $0.startSeconds > line }).index
        let before = lane.sliceCount

        lane.beginDrag(slice: slice)
        lane.dragMarker(to: line + lane.snapTolerance * 0.8)
        lane.endDrag()

        #expect(lane.drag == nil)
        #expect(lane.handEdited)
        #expect(lane.sliceCount == before)
        #expect(abs(lane.chop.slices[slice].startSeconds - line) < 0.002)
        // The bar moved, so whatever the host is holding is stale until it is re-sent.
        #expect(lane.needsAuditionRefresh)
        #expect(host.preparedKits.isEmpty)
    }

    @Test("a cancelled drag changes nothing")
    func cancelDragChangesNothing() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let before = lane.chop.slices.map(\.start)
        lane.beginDrag(slice: 2)
        lane.dragMarker(to: 0.5)
        lane.cancelDrag()
        #expect(lane.drag == nil)
        #expect(lane.chop.slices.map(\.start) == before)
        #expect(!lane.handEdited)
    }

    @Test("a marker cannot be dragged through its neighbours")
    func dragIsClamped() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let previous = lane.chop.slices[1].startSeconds
        lane.beginDrag(slice: 2)
        lane.dragMarker(to: 0)
        let drag = try #require(lane.drag)
        #expect(drag.time > previous)
        // Clamped against a neighbour is not landed on anything, so nothing claims it snapped.
        #expect(drag.snapped == nil)
    }

    @Test("markers can be added and deleted")
    func addAndRemoveMarkers() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let before = lane.sliceCount
        let line = try #require(emptyGridLine(lane))
        lane.addMarker(at: line + 0.004)
        #expect(lane.sliceCount == before + 1)
        let added = try #require(lane.chop.slices.first { abs($0.startSeconds - line) < 0.005 })
        // It caught the line on the way in.
        #expect(added.origin.isGridAligned)

        lane.removeMarker(slice: added.index)
        #expect(lane.sliceCount == before)
    }
}
