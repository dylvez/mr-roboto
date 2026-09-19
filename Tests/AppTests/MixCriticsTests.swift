import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M6 X7: masking pairs, the ceiling, the target — each a flag with two moves, both mix versions.

@Suite("Mix critics: a band and a gap, the ceiling, the target")
struct MixCriticsTests {
    private let kick = PartID(), bass = PartID(), hats = PartID()

    private func observation(gap: Double = 2, lufs: Double = -22, truePeak: Double = -0.2) -> MixObservation {
        var o = MixObservation(label: "Verse", integratedLUFS: lufs, peakDBFS: truePeak - 0.3, crestDB: 14, tiltDB: -18, bandwidthHz: 9_000)
        o.truePeakDBTP = truePeak
        o.strips = [
            .init(part: kick, label: "Boom-bap pocket", bandsDB: [30, 15, 10, 5, 0]),
            .init(part: bass, label: "Palladino line", bandsDB: [30 - gap, 25, -2, -20, -30]),
            .init(part: hats, label: "Hats", bandsDB: [-70, -40, -20, 12, 15]),
        ]
        o.masking = MixObservation.masking(o.strips)
        return o
    }

    @Test("the masking pairs: the kick and the bass share 60–120 by 2 dB; the hats share nothing")
    func pairs() {
        let o = observation()
        #expect(o.masking.count == 1, "\(o.masking)")
        let pair = o.masking[0]
        #expect(pair.band == 0 && pair.bandName == "60–120" && abs(pair.gapDB - 2) < 1e-9)
        #expect(pair.louder == kick && pair.quieter == bass && pair.quieterLabel == "Palladino line")
        #expect(abs(pair.centreHz - sqrt(60 * 120)) < 1e-6)
        #expect(MixObservation.masking(observation(gap: 8).strips).isEmpty, "8 dB apart is owned")
    }

    @Test("three flags, each with two mix moves, and none when the mix is right")
    func flags() throws {
        let master = Master(gainDB: 0, ceilingDBTP: -1, targetLUFS: -14)
        let findings = CriticBoard.standard.review(MixReview(observation: observation(), master: master))
        #expect(findings.map(\.critic) == [.masking, .overCeiling, .hotMaster], "\(findings.map(\.headline))")
        let masking = findings[0]
        #expect(masking.headline == "Boom-bap pocket and Palladino line within 2 dB at 60–120 Hz")
        #expect(masking.persona == .engineer && masking.severity == .warn)
        #expect(masking.fixes[0].title == "Cut Palladino line 4 dB at 85 Hz", "\(masking.fixes[0].title)")
        if case .mixStrip(let part, let gain, let hz, let db) = masking.fixes[0].change { #expect(part == bass && gain == nil && hz == 85 && db == -4) } else { Issue.record("no cut") }
        if case .mixStrip(let part, _, _, _) = masking.fixes[1].change { #expect(part == kick) } else { Issue.record("no other cut") }
        let ceiling = findings[1]
        #expect(ceiling.headline == "True peak -0.2 dBTP, 0.8 over the ceiling")
        if case .mixMaster(let g, let c) = ceiling.fixes[0].change { #expect(abs((g ?? 0) + 0.8) < 1e-9 && c == nil) } else { Issue.record("no master move") }
        let hot = findings[2]
        #expect(hot.headline == "-22.0 LUFS, 8 LU under the target" && hot.severity == .warn)
        if case .mixMaster(let g, _) = hot.fixes[0].change { #expect(g == 8) } else { Issue.record("no gain move") }
        if case .accept = hot.fixes[1].change {} else { Issue.record("the second is to leave it") }
        let fine = CriticBoard.standard.review(MixReview(observation: observation(gap: 9, lufs: -14.5, truePeak: -1.4), master: master))
        #expect(fine.isEmpty, "\(fine.map(\.headline))")
    }
}
