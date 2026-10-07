import Foundation
import SongGraph
import Testing
@testable import Instrument

/// Every kit carries the hand percussion, it sounds like what it is named, it never sets the kit's
/// level, and the old catch-all `perc` voice plays on the shaker.
@Suite("Hand percussion")
struct HandPercussionTests {
    static let sr: Double = 48_000

    @Test("every machine has all the hand-percussion voices, after its drums")
    func everyMachineHasThem() {
        for machine in SynthMachine.all {
            let kinds = machine.voices.map(\.kind)
            #expect(Array(kinds.suffix(SynthVoiceKind.handPercussion.count)) == SynthVoiceKind.handPercussion, "\(machine.name): \(kinds)")
            #expect(Set(kinds).count == kinds.count, "\(machine.name) lists a voice twice")
        }
    }

    @Test("the percussion sits under the kick, so it never decides how loud a kit is")
    func quieterThanTheKick() throws {
        for machine in SynthMachine.all {
            let kick = try #require(machine.spec(for: .kick))
            let kickPeak = SynthMeasure.peak(DrumSynthesizer.render(kick, velocity: 127, sampleRate: Self.sr))
            for kind in SynthVoiceKind.handPercussion {
                let spec = try #require(machine.spec(for: kind))
                let peak = SynthMeasure.peak(DrumSynthesizer.render(spec, velocity: 127, sampleRate: Self.sr))
                #expect(peak < kickPeak, "\(machine.name) \(kind) peaks at \(peak) over the kick's \(kickPeak)")
            }
        }
    }

    @Test("the drums sit low, the shaker and tambourine high, and the congas under the bongos")
    func spectralPlaces() throws {
        let studio = SynthMachine.studio
        func centroid(_ kind: SynthVoiceKind) throws -> Double {
            let spec = try #require(studio.spec(for: kind))
            // The first 40 ms, where each one is loudest and most itself.
            return SynthMeasure.spectralCentroid(DrumSynthesizer.render(spec, velocity: 100, sampleRate: Self.sr),
                                                 in: 0..<Int(0.04 * Self.sr), sampleRate: Self.sr)
        }
        let lowConga = try centroid(.lowConga), highConga = try centroid(.highConga)
        let highBongo = try centroid(.highBongo)
        #expect(lowConga < highConga && highConga < highBongo, "\(lowConga) \(highConga) \(highBongo)")
        #expect(try centroid(.shaker) > 4_000)
        #expect(try centroid(.tambourine) > 4_000)
        #expect(try centroid(.claves) > 1_500)
    }

    @Test("the low stroke of a cajón or a darbuka sits under its high one, and the metal and the beads sit high")
    func worldPlaces() throws {
        let studio = SynthMachine.studio
        func centroid(_ kind: SynthVoiceKind) throws -> Double {
            let spec = try #require(studio.spec(for: kind))
            return SynthMeasure.spectralCentroid(DrumSynthesizer.render(spec, velocity: 100, sampleRate: Self.sr),
                                                 in: 0..<Int(0.04 * Self.sr), sampleRate: Self.sr)
        }
        #expect(try centroid(.cajon) < centroid(.cajonSlap))
        #expect(try centroid(.darbuka) < centroid(.darbukaTek))
        #expect(try centroid(.frameDrum) < centroid(.darbukaTek))
        #expect(try centroid(.lowAgogo) < centroid(.highAgogo))
        for kind in [SynthVoiceKind.cabasa, .guiro, .guiroLong, .openTriangle, .muteTriangle] {
            #expect(try centroid(kind) > 2_000, "\(kind)")
        }
        // A held triangle is a tick; an open one rings.
        let open = try #require(studio.spec(for: .openTriangle)), held = try #require(studio.spec(for: .muteTriangle))
        #expect(open.tone.decaySeconds(decay: 0.5) > 4 * held.tone.decaySeconds(decay: 0.5))
    }

    @Test("VCSL plays every hand-percussion voice, each from one place")
    func vcslCoversThem() {
        let kinds = RecordedPercussion.vcsl.map(\.kind)
        #expect(Set(kinds).count == kinds.count)
        #expect(Set(kinds) == Set(SynthVoiceKind.handPercussion))
    }

    @Test("the played skins bend down as they settle; the electronic ones carry no skin noise")
    func playedAndElectronic() throws {
        let played = try #require(SynthMachine.studio.spec(for: .highConga))
        let electronic = try #require(SynthMachine.tr808.spec(for: .highConga))
        #expect(played.tone.pitchPeakHz > played.tone.frequencyHz)
        #expect(played.noise.level > 0 && electronic.noise.level == 0)
        // A converter kit puts its percussion through the converter too.
        #expect(SynthMachine.linn.spec(for: .shaker)?.sampled != nil)
        #expect(SynthMachine.sp1200.spec(for: .claves)?.sampled != nil)
    }

    @Test("a built kit maps every hand-percussion voice to its General MIDI note, and perc to the shaker")
    func builtKitMaps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hand-perc-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kit = try SynthesizedKit.build(.tr808, in: folder, sampleRate: 24_000, layerCount: 2)
        for kind in SynthVoiceKind.handPercussion {
            #expect(kit.manifest.note(for: kind.drumVoice) == kind.generalMIDINote)
            #expect(kit.manifest.zone(for: kind.drumVoice, velocity: 100) != nil, "\(kind) has no zone")
        }
        #expect(kit.manifest.note(for: .perc) == SynthVoiceKind.shaker.generalMIDINote)
        #expect(kit.manifest.validate(resolvingSamplesAgainst: folder).isPlayable)
    }
}
