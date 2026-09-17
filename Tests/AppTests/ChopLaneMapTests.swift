import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

/// The pad map: what the surface actually hands to `Performance`, and what the per-slice controls
/// do to it.
@MainActor
@Suite("Chop lane map")
struct ChopLaneMapTests {

    @Test("the map is one pad per slice from C1 up, and Performance renders it")
    func mapIsValid() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let map = lane.chopMap

        #expect(map.mappings.count == lane.sliceCount)
        #expect(map.mappings.map(\.sliceIndex) == Array(0..<lane.sliceCount))
        #expect(map.mappings.map(\.note) == (0..<lane.sliceCount).map { ChopMap.firstPadNote + $0 })
        #expect(Set(map.mappings.map(\.note)).count == map.mappings.count)
        // Every mapping points at a slice that exists — `render` throws `sliceOutOfRange` if not.
        #expect(map.mappings.allSatisfy { map.chop.slices.indices.contains($0.sliceIndex) })

        // A `Groove` addresses a chop by voice, so the map names one per class it found.
        #expect(map.voices[DrumVoice.kick.rawValue] != nil)
        #expect(map.voices[DrumVoice.snare.rawValue] != nil)
        #expect(map.voices[DrumVoice.closedHat.rawValue] != nil)

        let kit = try map.render(source: lane.source.planar)
        #expect(kit.manifest.zones.count == map.mappings.count)
        #expect(kit.channelCount == 1)
        // Nothing is reversed or stretched, so nothing was appended: every pad is a window into
        // the one buffer the bar already is.
        #expect(kit.frameCount == lane.source.frameCount)
        for (zone, slice) in zip(kit.manifest.zones, map.chop.slices) {
            #expect(zone.sampleStart == slice.start)
            #expect(zone.sampleEnd == slice.end)
        }
    }

    @Test("the slices cover the bar with no gap and no overlap")
    func slicesCoverTheBar() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let slices = lane.chop.slices
        #expect(slices.first?.start == 0)
        #expect(slices.last?.end == lane.source.frameCount)
        for (a, b) in zip(slices, slices.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test("pitch in cents lands on the pad's zone")
    func pitchChangesTheZone() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        lane.setTune(-1200, slice: 1)
        #expect(lane.edit(forSlice: 1).tuneCents == -1200)

        let kit = try lane.chopMap.render(source: lane.source.planar)
        #expect(kit.manifest.zones[1].tuneCents == -1200)
        // And only that pad.
        #expect(kit.manifest.zones[0].tuneCents == 0)
        #expect(kit.manifest.zones[2].tuneCents == 0)
        // A tuned pad still plays straight out of the source; nothing is rendered for it.
        #expect(kit.frameCount == lane.source.frameCount)

        lane.setTune(9_000, slice: 1)
        #expect(lane.edit(forSlice: 1).tuneCents == ChopLaneSurface.tuneRange.upperBound)
    }

    @Test("reverse renders the slice backwards into the same buffer")
    func reverseChangesTheZone() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let slice = lane.chop.slices[2]
        lane.setReverse(true, slice: 2)
        #expect(lane.edit(forSlice: 2).reverse)

        let kit = try lane.chopMap.render(source: lane.source.planar)
        let zone = kit.manifest.zones[2]
        let end = try #require(zone.sampleEnd)
        // A reversed pad cannot be a window into the original audio, so it is appended to the tail
        // of the same buffer — one file, one buffer, a longer one.
        #expect(zone.sampleStart >= lane.source.frameCount)
        #expect(end - zone.sampleStart == slice.frameCount)
        #expect(kit.frameCount > lane.source.frameCount)

        let rendered = Array(kit.audio[0][zone.sampleStart..<end])
        let expected = Array(lane.source.mono[slice.start..<slice.end].reversed())
        #expect(rendered == expected)

        // The pads either side are untouched windows into the source.
        #expect(kit.manifest.zones[1].sampleStart == lane.chop.slices[1].start)
        #expect(kit.manifest.zones[3].sampleStart == lane.chop.slices[3].start)
    }

    @Test("gain and stretch land too, and are clamped to what Performance accepts")
    func gainAndStretch() throws {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        lane.setGain(-6, slice: 3)
        lane.setStretch(1.5, slice: 3)
        #expect(lane.edit(forSlice: 3).gainDB == -6)
        #expect(lane.edit(forSlice: 3).stretchRatio == 1.5)

        lane.setStretch(99, slice: 4)
        #expect(lane.edit(forSlice: 4).stretchRatio == ChopLaneSurface.stretchRange.upperBound)
        lane.setGain(-100, slice: 4)
        #expect(lane.edit(forSlice: 4).gainDB == ChopLaneSurface.gainRange.lowerBound)

        let kit = try lane.chopMap.render(source: lane.source.planar)
        #expect(kit.manifest.zones[3].gainDB == -6)

        // Reset takes a pad back to being a plain window.
        lane.resetSlice(3)
        lane.resetSlice(4)
        #expect(lane.edits.isEmpty)
        let plain = try lane.chopMap.render(source: lane.source.planar)
        #expect(plain.frameCount == lane.source.frameCount)
    }

    // MARK: Playing on touch

    @Test("a pad plays on touch, and the touch does no work")
    func padsPlayOnTouch() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        #expect(lane.needsAuditionRefresh)

        lane.audition(slice: 0)
        #expect(host.preparedKits.count == 1)
        #expect(!lane.needsAuditionRefresh)
        #expect(host.lastHits.count == 1)
        #expect(host.lastHits.first?.note == ChopMap.firstPadNote)
        #expect(host.lastHits.first?.time == 0)
        #expect(lane.selectedSlice == 0)

        // The whole point: touching more pads posts more hits and renders nothing further. If this
        // ever fails, the surface has grown a round trip on the audition path.
        for index in 1..<lane.sliceCount { lane.audition(slice: index) }
        #expect(host.preparedKits.count == 1)
        #expect(host.auditionedHits.count == lane.sliceCount)
        #expect(host.lastHits.first?.note == ChopMap.firstPadNote + lane.sliceCount - 1)
    }

    @Test("an edit makes the held kit stale and the next touch re-sends it")
    func editsRefreshTheKit() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.audition(slice: 0)
        #expect(host.preparedKits.count == 1)

        lane.setReverse(true, slice: 0)
        #expect(lane.needsAuditionRefresh)
        lane.audition(slice: 0)
        #expect(host.preparedKits.count == 2)
    }

    @Test("the bar plays back as it was cut")
    func barPlaysBackInOrder() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.auditionBar()
        let hits = host.lastHits
        #expect(hits.count == lane.sliceCount)
        #expect(hits.map(\.time) == lane.chop.slices.map(\.startSeconds))
        #expect(hits.map(\.note) == (0..<lane.sliceCount).map { ChopMap.firstPadNote + $0 })

        lane.stop()
        #expect(host.stopCount == 1)
    }

    @Test("a host that cannot prepare is reported, not thrown")
    func prepareFailureIsReported() {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        host.prepareFailure = ChopError.emptySource
        lane.audition(slice: 0)
        #expect(lane.lastError != nil)
        #expect(host.auditionedHits.isEmpty == false)  // the hit is still posted
    }

    // MARK: Gate B's seam

    @Test("the lane carries critic marks and never writes one")
    func marksAreASeam() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        #expect(lane.marks.isEmpty)
        lane.sensitivity = 0.3
        lane.override(slice: 0, as: .snare)
        lane.setReverse(true, slice: 0)
        _ = lane.chopMap
        #expect(lane.marks.isEmpty, "Gate A must not produce a finding of its own")

        // And a mark handed in from outside survives, which is all the seam has to do.
        lane.marks = [ChopLaneMark(sliceIndex: 0, start: 0, end: 0.1, summary: "clicks")]
        #expect(lane.marks.count == 1)
    }

    @Test("the catalog's rule: at most two prominent levers")
    func atMostTwoProminentLevers() {
        #expect(ChopLaneSurface.prominentLevers.count <= 2)
        #expect(Set(ChopLaneSurface.prominentLevers).count
                == ChopLaneSurface.prominentLevers.count)
    }

    // MARK: The waveform's arithmetic

    @Test("the waveform envelope is normalised and reversible")
    func waveformEnvelope() {
        let mono = ChopLaneFixtures.cleanBar()
        let columns = ChopLaneWaveform.envelope(mono, buckets: 200)
        #expect(columns.count == 200)
        #expect(columns.allSatisfy { $0.maximum <= 1.0001 && $0.minimum >= -1.0001 })
        #expect(columns.contains { $0.maximum > 0.9 })
        #expect(ChopLaneWaveform.envelope([], buckets: 100).isEmpty)
        #expect(ChopLaneWaveform.envelope([Float](repeating: 0, count: 64), buckets: 8).count == 8)

        let t = ChopLaneWaveform.time(atX: 120, width: 240, duration: 2)
        #expect(abs(t - 1) < 1e-9)
        #expect(abs(ChopLaneWaveform.x(atTime: t, width: 240, duration: 2) - 120) < 1e-9)
        // Off the ends, it clamps rather than running off the plate.
        #expect(ChopLaneWaveform.time(atX: -50, width: 240, duration: 2) == 0)
        #expect(ChopLaneWaveform.x(atTime: 99, width: 240, duration: 2) == 240)
    }
}
