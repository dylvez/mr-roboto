import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

/// The classification override and what it does downstream, and the versions an edit produces.
@MainActor
@Suite("Chop lane re-groove")
struct ChopLaneRegrooveTests {

    private static let feelName = "Boom-Bap Pocket"

    private func lane() -> (ChopLaneSurface, ChopLaneHostStub) {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.feelName = Self.feelName
        return (lane, host)
    }

    @Test("feels come from the library, and one is offered for the bar's tempo")
    func feelsComeFromTheLibrary() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        #expect(!lane.suggestedFeels.isEmpty)
        #expect(lane.feel != nil, "the lane opens with a feel already offered")
        lane.feelName = Self.feelName
        let feel = try #require(lane.feel)
        #expect(feel.name == Self.feelName)
        #expect(feel.suits(tempo: lane.tempo))
        #expect(lane.feels.feel(named: "nothing called this") == nil)
    }

    @Test("a chop plays in the feel's rhythm")
    func regroovePlacesEverySlice() throws {
        let (lane, _) = lane()
        let performance = try lane.regroove()

        #expect(!performance.placements.isEmpty)
        #expect(performance.unplacedSteps == 0)
        #expect(performance.substitutedClasses.isEmpty,
                "the clean bar has all three classes, so nothing should be substituted")
        #expect(performance.hits.count == performance.placements.count)
        #expect(performance.hits.allSatisfy { $0.time >= 0 })
        // Times are ascending and inside the re-groove's own duration.
        #expect(zip(performance.hits, performance.hits.dropFirst()).allSatisfy { $0.time <= $1.time })
        #expect(performance.hits.allSatisfy { $0.time <= performance.duration })
        // Every placement plays a pad the map can find.
        #expect(performance.placements.allSatisfy { $0.note != nil })
    }

    @Test("an override sticks, and moves the slice to a different voice")
    func overrideChangesPlacement() throws {
        let (lane, _) = lane()

        // Slice 0 is the bar's first kick, and the feel only ever asks for it on kick steps.
        let before = try lane.regroove()
        let beforeVoices = Set(before.placements.filter { $0.sliceIndex == 0 }.map(\.voice))
        #expect(beforeVoices == [.kick])

        lane.override(slice: 0, as: .hat)
        let classification = try #require(lane.classification(forSlice: 0))
        #expect(classification.kind == .hat)
        #expect(classification.isOverride)
        #expect(classification.confidence == 1)
        // The measurement it disagreed with is kept, so the disagreement stays visible.
        #expect(classification.centroid < 500)

        let after = try lane.regroove()
        let afterVoices = Set(after.placements.filter { $0.sliceIndex == 0 }.map(\.voice))
        #expect(!afterVoices.contains(.kick))
        #expect(afterVoices.contains(.closedHat))
        #expect(after.substitutedClasses.isEmpty,
                "two kicks remain, so nothing had to be substituted for the class")

        // And giving it back to the classifier undoes it.
        lane.clearOverride(slice: 0)
        #expect(lane.classification(forSlice: 0)?.kind == .kick)
        #expect(lane.classification(forSlice: 0)?.isOverride == false)
        let restored = try lane.regroove()
        #expect(Set(restored.placements.filter { $0.sliceIndex == 0 }.map(\.voice)) == [.kick])
    }

    @Test("the tempo is the feel's argument: the same chop, further apart")
    func tempoStretchesThePerformance() throws {
        let (lane, _) = lane()
        lane.tempo = 90
        let fast = try lane.regroove()
        lane.tempo = 70
        let slow = try lane.regroove()
        #expect(slow.placements.count == fast.placements.count)
        #expect(slow.duration > fast.duration)
    }

    @Test("stretch-to-fit adds pads rather than letting slices ring")
    func overlapModeAddsVariants() throws {
        let (lane, _) = lane()
        lane.overlap = .ring
        let ringing = try lane.regroove()
        lane.overlap = .stretchToFit
        let fitted = try lane.regroove()
        #expect(fitted.map.mappings.count >= ringing.map.mappings.count)
        // Whatever it added, the map it hands back is still renderable — which is the map a caller
        // must render, not the one that went in.
        let kit = try fitted.map.render(source: lane.source.planar)
        #expect(kit.manifest.zones.count == fitted.map.mappings.count)
    }

    @Test("playing the re-groove loads its own kit and fires its own hits")
    func playRegrooveGoesThroughTheHost() throws {
        let (lane, host) = lane()
        lane.playRegroove()
        #expect(lane.lastError == nil)
        let kit = try #require(host.lastKit)
        #expect(kit.manifest.zones.count >= lane.sliceCount)
        #expect(host.lastHits.count > lane.sliceCount)
        // The host is now holding the re-groove's kit, so the pad map has to go back before a pad
        // is touched again.
        #expect(lane.needsAuditionRefresh)
        lane.audition(slice: 0)
        #expect(host.preparedKits.count == 2)
    }

    @Test("no feel, no re-groove")
    func noFeelIsAnError() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        lane.feelName = nil
        #expect(throws: ChopLaneError.noFeel) { try lane.regroove() }
    }

    // MARK: Versions

    @Test("an edit produces a new part version, and the lane rebinds to it")
    func commitProducesAVersion() throws {
        let (lane, host) = lane()
        #expect(lane.bound.isEmpty)

        lane.override(slice: 0, as: .snare)
        let version = try lane.commitChop(note: "first cut")

        #expect(host.madeVersions.count == 1)
        #expect(version.partID == lane.partID)
        #expect(version.operation == SongGraph.Operation.chop)
        #expect(version.author == .user)
        #expect(lane.bound == [version.id])
        #expect(lane.title == lane.headline)
        #expect(!lane.handEdited)

        guard case .sample(let sample) = version.kind else {
            Issue.record("expected a sample part")
            return
        }
        #expect(sample.media == lane.source.media)
        #expect(sample.slices.count == lane.sliceCount)
        #expect(sample.detectedTempo == ChopLaneFixtures.bpm)
        // Markers are in the record's own time.
        #expect(sample.slices.map(\.position) == lane.chop.slices.map {
            lane.chop.sourceOffset + $0.startSeconds
        })

        // A second commit derives from the first, on the same part.
        let next = try lane.commitChop()
        #expect(next.parents == [version.id])
        #expect(next.partID == version.partID)
        #expect(lane.bound == [next.id])
    }

    @Test("a refused version is not pretended to have been kept")
    func refusedVersion() throws {
        let (lane, host) = lane()
        host.refuseVersions = true
        #expect(throws: ChopLaneError.versionRefused) { try lane.commitChop() }
        #expect(lane.bound.isEmpty)
        #expect(host.madeVersions.isEmpty)
    }

    @Test("the committed markers carry the class, so an override survives the version")
    func markersCarryTheClass() throws {
        let (lane, _) = lane()
        lane.override(slice: 1, as: .kick)
        let markers = lane.sliceMarkers
        #expect(markers.count == lane.sliceCount)

        let recovered = ChopLaneSurface.overrides(from: markers)
        #expect(recovered[1] == .kick)
        #expect(recovered.count == lane.sliceCount)
        #expect(recovered[0] == .kick)   // the bar's own first kick, not an override
        #expect(recovered[2] == .snare)

        // A marker with no class, or a label from some other writer, is simply not a class.
        #expect(ChopLaneSurface.overrides(from: [SliceMarker(position: 0)]).isEmpty)
        #expect(ChopLaneSurface.overrides(from: [SliceMarker(position: 0, label: "onset")]).isEmpty)
        #expect(ChopLaneSurface.overrides(
            from: [SliceMarker(position: 0, label: "onset tambourine")]).isEmpty)
    }

    @Test("the re-groove commits as a groove derived from the chop")
    func commitRegroove() throws {
        let (lane, host) = lane()
        let chop = try lane.commitChop()
        let groove = try lane.commitRegroove()
        #expect(groove.operation == SongGraph.Operation.regroove)
        #expect(groove.parents == [chop.id])
        // A groove is a new part, not a later draft of the chopped bar.
        #expect(groove.partID != chop.partID)
        #expect(host.madeVersions.count == 2)
        guard case .groove(let payload) = groove.kind else {
            Issue.record("expected a groove part")
            return
        }
        #expect(payload == lane.feel?.groove)
        #expect(groove.note?.contains(Self.feelName) == true)
    }

    @Test("with no host there is nothing to commit to")
    func commitNeedsAHost() {
        let lane = ChopLaneSurface(source: ChopLaneFixtures.source(ChopLaneFixtures.cleanBar(),
                                                                   label: "Bar"))
        #expect(throws: ChopLaneError.noHost) { try lane.commitChop() }
        // And a hostless lane simply makes no sound rather than trapping.
        lane.audition(slice: 0)
        lane.auditionBar()
        lane.stop()
    }

    @Test("a malformed source is refused rather than half-chopped")
    func malformedSourceIsRefused() {
        let empty = ChopLaneSource(media: ChopLaneFixtures.media, mono: [],
                                   sampleRate: ChopLaneFixtures.sampleRate)
        #expect(!empty.isWellFormed)
        let lane = ChopLaneSurface(source: empty)
        #expect(lane.sliceCount == 0)
        #expect(lane.lastError == ChopLaneError.malformedSource.description)
    }

    @Test("a lane is a Surface the bench can hold")
    func laneIsASurface() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        #expect(ChopLaneSurface.kind == .chopLane)
        #expect(SurfaceKind.gateA.contains(.chopLane))
        let bench = Bench()
        bench.open(BenchItem(id: lane.id, kind: ChopLaneSurface.kind, title: lane.title))
        #expect(bench.items.count == 1)
        #expect(bench.items.first?.id == lane.id)
    }
}
