import Foundation
import Instrument
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The Dust menu on the Chop lane, and the A/B beside it: what the model does when a machine is
// chosen, offline, through the lane's stub host. The Grid's menu is held in `DustTests`, against a
// real song; the popover behind both in `SoundShapingTests`.

@Suite("The Chop lane's Dust menu") @MainActor
struct ChopLaneDustTests {

    @Test("choosing a machine keeps the chop through it, the pads play through it, and Dry is the bar as cut")
    func menuKeepsAndPlays() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        #expect(lane.dustPasses.isEmpty, "a fresh cut is clean")
        // The pads' kit, as cut: rendered on the first touch, so here by hand.
        lane.refreshAudition()
        let before = host.preparedKits.count

        // The cut is kept first — the lane has no version yet — then the dusty version of it.
        lane.setDust(.sp1200)
        #expect(lane.lastError == nil)
        #expect(host.madeVersions.count == 2, "\(host.madeVersions.map(\.operation))")
        let cut = host.madeVersions[0], dusty = host.madeVersions[1]
        #expect(cut.operation == Operation.chop && cut.kind.degradation.isEmpty)
        #expect(dusty.operation == Operation.degrade && dusty.parents == [cut.id] && dusty.partID == cut.partID)
        #expect(dusty.kind.degradation == [DegradeSettings(preset: .sp1200).degradation(from: .sp1200)])
        #expect(lane.versions == [dusty.id], "the lane follows its chop to the dusty version")
        #expect(lane.dustPasses.map(\.preset) == ["sp1200"])
        #expect(Dust.chip(lane.dustPasses) == "SP-1200")

        // The kit the pads play was rendered again, through the chain: not the bar as cut.
        #expect(host.preparedKits.count == before + 1)
        let wet = try #require(host.lastKit)
        let dry = try #require(host.preparedKits.dropLast().last)
        #expect(wet.audio != dry.audio, "the pads still play the bar dry")
        #expect(wet.frameCount == dry.frameCount)

        // Dry is a true bypass: the kit rendered from the bar as cut, bit for bit.
        lane.hearsDry = true
        #expect(host.lastKit?.audio == dry.audio)
        lane.hearsDry = false
        #expect(host.lastKit?.audio == wet.audio)

        // The same machine again is not a version; another replaces it; Clean takes it off.
        lane.setDust(.sp1200)
        #expect(host.madeVersions.count == 2)
        lane.setDust(.cassette)
        #expect(host.madeVersions.count == 3 && lane.dustPasses.map(\.preset) == ["cassette"])
        #expect(host.madeVersions[2].parents == [dusty.id])
        lane.setDust(.clean)
        #expect(host.madeVersions.count == 4 && lane.dustPasses.isEmpty)
        #expect(host.lastKit?.audio == dry.audio, "clean plays the bar as cut")

        // A marker moved afterwards keeps the chain the chop plays through.
        lane.setDust(.vinyl)
        lane.hearsDry = false
        let moved = try lane.commitChop(note: "moved")
        #expect(moved.kind.degradation.map(\.preset) == ["vinyl"], "re-cutting is not a request to clean it")
    }

    @Test("a refused version says so, and a chain kept from the popover comes back to the lane")
    func refusedAndAdopted() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        host.refuseVersions = true
        lane.setDust(.mpc60)
        #expect(lane.lastError != nil && lane.dustPasses.isEmpty)

        host.refuseVersions = false
        #expect(lane.keepNow())
        let cut = try #require(host.madeVersions.last)
        let dusty = try #require(Dust.version(choosing: .radio, on: cut, by: .user))
        #expect(host.record(dusty))
        let kits = host.preparedKits.count
        lane.adopt(dusty)
        #expect(lane.versions == [dusty.id] && lane.dustPasses.map(\.preset) == ["radio"])
        #expect(host.preparedKits.count == kits + 1, "the pads play through what the popover kept")
    }

    @Test("the menu's words: the chip names the machine on top, its mix once moved, and what it is over")
    func chipWords() {
        let sp = DegradeSettings(preset: .sp1200).degradation(from: .sp1200)
        var moved = DegradeSettings(preset: .vinyl)
        moved.mix = 0.6
        let vinyl = moved.degradation(from: .vinyl)
        #expect(Dust.chip([]) == "Clean")
        #expect(Dust.chip([sp]) == "SP-1200")
        #expect(Dust.chip([vinyl]) == "Vinyl at 60%")
        #expect(Dust.chip([sp, vinyl]) == "Vinyl at 60% over SP-1200")
        #expect(Dust.preset(on: [sp]) == .sp1200)
        #expect(Dust.preset(on: [vinyl]) == nil, "a moved chain is not the preset it left")
        #expect(Dust.preset(on: []) == nil)
    }
}
