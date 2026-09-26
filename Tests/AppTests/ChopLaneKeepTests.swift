import Foundation
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

/// The keep verbs the view presses, what the lane owns up to still holding, and the two lines of
/// small print that have to tell the truth: the sensitivity warning and the slider readouts.
@MainActor
@Suite("Chop lane keeping")
struct ChopLaneKeepTests {

    private static let feelName = "Boom-Bap Pocket"

    /// A lane opened on a version, the way `ChopLaneBinding` opens one.
    private func versionedLane() -> (ChopLaneSurface, ChopLaneHostStub) {
        let host = ChopLaneHostStub()
        let source = ChopLaneFixtures.source(ChopLaneFixtures.cleanBar(), label: "Bar 1 of Fixture")
        return (ChopLaneSurface(source: source, host: host, version: VersionID()), host)
    }

    // MARK: Keep chop

    @Test("opening a lane on a version is not a change; an edit is; keeping clears it")
    func unkeptFollowsEdits() throws {
        let (lane, host) = versionedLane()
        #expect(!lane.hasUnkeptChanges)
        #expect(!lane.canKeepChop)
        #expect(lane.whyChopCannotBeKept?.contains("Nothing has changed") == true)

        // An override changes the class a marker carries, which is in the version.
        lane.override(slice: 0, as: .hat)
        #expect(lane.hasUnkeptChanges)
        #expect(lane.hasUnkeptChopEdits)
        #expect(lane.canKeepChop)
        #expect(lane.whyChopCannotBeKept == nil)

        lane.keepChop()
        #expect(lane.lastError == nil)
        #expect(host.madeVersions.count == 1)
        #expect(!lane.hasUnkeptChanges)
        #expect(!lane.canKeepChop)
        #expect(lane.bound == [host.madeVersions[0].id])

        // So does a marker.
        lane.addMarker(at: 0.5)
        #expect(lane.hasUnkeptChanges)
        lane.keepChop()
        #expect(host.madeVersions.count == 2)
        #expect(!lane.hasUnkeptChanges)
        // The second derives from the first, on the same part: the keep path is the commit path.
        let second = try #require(host.madeVersions.last)
        #expect(second.parents == [host.madeVersions[0].id])
        #expect(second.operation == SongGraph.Operation.chop)
        #expect(second.note == "Bar 1 of Fixture")
    }

    @Test("a lane with no version holds a chop nobody has kept")
    func unversionedLaneIsUnkept() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        #expect(lane.hasUnkeptChanges)
        #expect(lane.canKeepChop)
        lane.keepChop()
        #expect(lane.lastError == nil)
        #expect(host.madeVersions.count == 1)
        #expect(lane.bound.count == 1)
        #expect(!lane.hasUnkeptChanges)
    }

    @Test("a trim is kept with the chop, and comes back when the lane is opened on it")
    func trimsAreKept() throws {
        let (lane, host) = versionedLane()
        lane.autoKeep.delay = nil
        lane.setGain(-6, slice: 1)
        lane.setTune(-1200, slice: 2)
        lane.setReverse(true, slice: 2)
        #expect(lane.hasUnkeptChopEdits && lane.canKeepChop, "a trim is work the ledger does not have yet")
        let kept = try lane.commitChop()
        #expect(!lane.hasUnkeptChopEdits)
        guard case .sample(let sample) = kept.kind else { Issue.record("not a sample"); return }
        #expect(sample.pads == [PadTrim(slice: 1, gainDB: -6), PadTrim(slice: 2, tuneCents: -1200, reverse: true)])

        // Reopened on that version: the same trims, and nothing unkept.
        let reopened = ChopLaneSurface(source: ChopLaneFixtures.source(ChopLaneFixtures.cleanBar(), label: "Bar 1 of Fixture"),
                                       host: host, version: kept.id)
        reopened.restore(sample.slices, pads: sample.pads)
        #expect(reopened.edits == lane.edits)
        #expect(!reopened.hasUnkeptChanges)
        // Putting a trim back to neutral is a change too.
        reopened.setGain(0, slice: 1)
        #expect(reopened.hasUnkeptChopEdits)
    }

    @Test("turning the dial back to the kept cut is not a change either")
    func resliceToTheSameCutIsNotAChange() {
        let (lane, _) = versionedLane()
        lane.sensitivity = 0.2
        // The clean bar is silent between its hits, so every threshold finds the same eight.
        #expect(!lane.hasUnkeptChanges)
        lane.sensitivity = ChopLaneSurface.defaultSensitivity
        #expect(!lane.hasUnkeptChanges)
    }

    @Test("a refused keep is reported in the footer and the edit is kept in the lane")
    func refusedKeepIsReported() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        host.refuseVersions = true
        lane.override(slice: 0, as: .hat)

        lane.keepChop()
        #expect(lane.lastError == ChopLaneError.versionRefused.description)
        #expect(lane.hasUnkeptChanges)
        #expect(lane.overrides[0] == .hat)
        #expect(host.madeVersions.isEmpty)

        host.refuseVersions = false
        lane.keepChop()
        #expect(lane.lastError == nil)
        #expect(!lane.hasUnkeptChanges)
        #expect(host.madeVersions.count == 1)
    }

    @Test("with no host the keep says so rather than trapping")
    func keepWithoutAHost() {
        let lane = ChopLaneSurface(source: ChopLaneFixtures.source(ChopLaneFixtures.cleanBar(),
                                                                   label: "Bar"))
        #expect(lane.canKeepChop)
        lane.keepChop()
        #expect(lane.lastError == ChopLaneError.noHost.description)
        #expect(lane.hasUnkeptChanges)
    }

    // MARK: Keep re-groove

    @Test("a groove can be made once the re-groove has been heard; making it keeps the chop first")
    func regrooveKeepPath() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.feelName = Self.feelName

        // Picked but not played is a setting, not a re-groove.
        #expect(!lane.hasUnkeptRegroove)
        #expect(!lane.canKeepRegroove)
        #expect(lane.whyRegrooveCannotBeKept?.contains("Play") == true)

        lane.playRegroove()
        #expect(lane.lastError == nil)
        #expect(lane.hasUnkeptRegroove)
        // A re-groove heard is a thing tried, not work to lose: what is unkept here is only the
        // chop itself, which this lane (opened on no version) has never kept.
        #expect(lane.hasUnkeptChanges == lane.hasUnkeptChopEdits)
        // Making the groove keeps the chop it was played with first, so the lineage is right.
        #expect(lane.canKeepRegroove)
        lane.keepRegroove()
        #expect(lane.lastError == nil)
        #expect(host.madeVersions.count == 2)
        let groove = try #require(host.madeVersions.last)
        #expect(groove.operation == SongGraph.Operation.regroove)
        #expect(groove.parents == [host.madeVersions[0].id])
        #expect(groove.note?.contains(Self.feelName) == true)
        #expect(!lane.hasUnkeptRegroove)
        #expect(!lane.hasUnkeptChanges)
        #expect(!lane.canKeepRegroove)
        #expect(lane.whyRegrooveCannotBeKept?.contains("already") == true)

        // A new tempo is a re-groove nobody has heard yet: nothing to keep, nothing unkept.
        lane.tempo += 5
        #expect(!lane.canKeepRegroove)
        #expect(!lane.hasUnkeptChanges)
        lane.playRegroove()
        #expect(lane.canKeepRegroove)
        lane.keepRegroove()
        #expect(host.madeVersions.count == 3)
        #expect(!lane.hasUnkeptChanges)
    }

    @Test("with no feel there is no re-groove to keep")
    func noFeelNoKeep() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.feelName = nil
        #expect(!lane.canKeepRegroove)
        #expect(lane.whyRegrooveCannotBeKept?.contains("feel") == true)
        lane.keepRegroove()
        #expect(lane.lastError == lane.whyRegrooveCannotBeKept)
        #expect(host.madeVersions.isEmpty)
    }

    @Test("a refused re-groove stays unkept")
    func refusedRegroove() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.feelName = Self.feelName
        lane.keepChop()
        lane.playRegroove()
        host.refuseVersions = true
        lane.keepRegroove()
        #expect(lane.lastError == ChopLaneError.versionRefused.description)
        #expect(lane.hasUnkeptRegroove)
        #expect(lane.canKeepRegroove)
    }

    // MARK: The sensitivity warning

    @Test("the warning names exactly what the dial would drop")
    func resliceWarningWording() {
        #expect(ChopLaneSurface.resliceWarning(handEdited: false, overrides: 0, trims: 0) == nil)
        #expect(ChopLaneSurface.resliceWarning(handEdited: true, overrides: 0, trims: 0)
                == "Moving this re-slices the bar and drops your marker edits.")
        #expect(ChopLaneSurface.resliceWarning(handEdited: false, overrides: 2, trims: 0)
                == "Moving this re-slices the bar and drops 2 pad overrides.")
        #expect(ChopLaneSurface.resliceWarning(handEdited: false, overrides: 0, trims: 1)
                == "Moving this re-slices the bar and drops 1 pad's trims.")
        #expect(ChopLaneSurface.resliceWarning(handEdited: false, overrides: 1, trims: 3)
                == "Moving this re-slices the bar and drops 1 pad override and 3 pads' trims.")
        #expect(ChopLaneSurface.resliceWarning(handEdited: true, overrides: 1, trims: 3)
                == "Moving this re-slices the bar and drops your marker edits, 1 pad override and 3 pads' trims.")
    }

    @Test("and it is on the lane whenever a trim or an override exists, not only after a drag")
    func resliceWarningFollowsTheLane() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        #expect(lane.resliceWarning == nil)

        lane.setGain(-6, slice: 1)
        #expect(!lane.handEdited)
        #expect(lane.resliceWarning?.contains("trims") == true)
        #expect(lane.resliceWarning?.contains("override") == false)

        lane.override(slice: 0, as: .hat)
        #expect(lane.resliceWarning?.contains("1 pad override") == true)

        lane.addMarker(at: 0.5)
        #expect(lane.resliceWarning?.contains("marker edits") == true)

        // The dial was moved anyway; everything it warned about is gone, and so is the warning.
        lane.sensitivity = 0.2
        #expect(lane.resliceWarning == nil)
    }

    // MARK: Readouts

    @Test("readouts carry a sign and a unit")
    func readouts() {
        #expect(ChopLaneReadout.pitch(0) == "0¢")
        #expect(ChopLaneReadout.pitch(0.4) == "0¢")
        #expect(ChopLaneReadout.pitch(120) == "+120¢")
        #expect(ChopLaneReadout.pitch(-1200) == "-1200¢")

        #expect(ChopLaneReadout.gain(0) == "0.0 dB")
        #expect(ChopLaneReadout.gain(-0.04) == "0.0 dB")
        #expect(ChopLaneReadout.gain(-6) == "-6.0 dB")
        #expect(ChopLaneReadout.gain(3.5) == "+3.5 dB")

        #expect(ChopLaneReadout.stretch(nil) == "×1.00")
        #expect(ChopLaneReadout.stretch(1.5) == "×1.50")
        #expect(ChopLaneReadout.stretch(0.25) == "×0.25")
    }

    @Test("reopened on a kept chop, the lane has the cut that was kept — a marker added by hand, a class set by hand — and no change")
    func reopensOnTheKeptCut() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        let detected = lane.sliceMarkers.count
        // A marker in the middle of the widest slice, where nothing is too close to it.
        let starts = lane.sliceMarkers.map { $0.position - lane.source.sourceOffset } + [lane.source.duration]
        let widest = zip(starts, starts.dropFirst()).max { $0.1 - $0.0 < $1.1 - $1.0 }!
        lane.addMarker(at: (widest.0 + widest.1) / 2)
        lane.override(slice: 0, as: .hat)
        let kept = try lane.commitChop(note: "Cut by hand")
        guard case .sample(let sample) = kept.kind else { Issue.record("not a sample"); return }
        #expect(sample.slices.count == detected + 1)

        let reopened = ChopLaneSurface(source: lane.source, host: host, version: kept.id)
        #expect(reopened.sliceMarkers.count == detected, "opening detects afresh")
        reopened.restore(sample.slices)
        #expect(reopened.sliceMarkers.map(\.position) == sample.slices.map(\.position), "the kept cut, marker for marker")
        #expect(ChopLaneSurface.overrides(from: reopened.sliceMarkers) == ChopLaneSurface.overrides(from: sample.slices),
                "and class for class")
        #expect(!reopened.hasUnkeptChanges, "and not an edit")
    }
}
