import AVFoundation
import Foundation
import SongGraph
import Testing
@testable import Instrument

/// The point of A3's architecture: a synthesized kit is an ordinary kit. It has to load through
/// `KitStore`, validate clean, and play through `VoiceSampler` with no special case anywhere.
@Suite("Synthesized kit")
struct SynthesizedKitTests {
    static let sr: Double = 48_000

    @Test("a generated 808 kit loads through KitStore and validates clean")
    func generatedKitLoadsAndValidates() throws {
        let dir = TempDirectory("tr808-kit")
        defer { dir.remove() }

        let built = try SynthesizedKit.build(.tr808, in: dir.url, sampleRate: Self.sr)
        #expect(built.manifest.kind == .synthesized)

        // Through the real loader, from disk, checking every sample file exists.
        let loaded = try KitStore.load(from: dir.url)
        let validation = loaded.validate()
        #expect(validation.isClean, "findings: \(validation.findings.map(\.description))")

        // Every voice the machine defines is addressable by name and by note.
        for spec in SynthMachine.tr808.voices {
            let note = try #require(loaded.manifest.note(for: spec.kind.drumVoice),
                                    "no note mapped for \(spec.kind.rawValue)")
            #expect(note == spec.kind.generalMIDINote)
            for velocity in [1, 40, 90, 127] {
                #expect(loaded.manifest.zone(note: note, velocity: velocity) != nil,
                        "\(spec.kind.rawValue) has no zone at velocity \(velocity)")
            }
        }

        // And the specs travelled with it, so the kit can be re-rendered after an edit.
        let synthesis = try #require(loaded.manifest.synthesis)
        #expect(synthesis.machine == "tr808")
        #expect(synthesis.sampleRate == Self.sr)
        #expect(synthesis.voices.count == SynthMachine.tr808.voices.count)
        #expect(synthesis.voices == SynthMachine.tr808.voices, "specs did not survive kit.json")
    }

    @Test("the manifest still reports format version 1 — the synthesis block needed no bump")
    func synthesisDidNotBumpTheFormatVersion() throws {
        let dir = TempDirectory("format-version")
        defer { dir.remove() }
        try SynthesizedKit.build(.tr909, in: dir.url, sampleRate: Self.sr, layerCount: 2)
        let json = try Data(contentsOf: dir.url.appendingPathComponent(KitManifest.fileName))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 1)
        #expect(object["synthesis"] != nil)
        #expect(object["kind"] as? String == "synthesized")
    }

    @Test("a pre-A3 kit.json with no synthesis block still decodes")
    func oldManifestsStillDecode() throws {
        let json = Data("""
        {"formatVersion":1,"name":"Old Kit","kind":"sampled",
         "zones":[{"id":"kick","sample":"kick.wav","note":36}]}
        """.utf8)
        let manifest = try KitCodec.makeDecoder().decode(KitManifest.self, from: json)
        #expect(manifest.synthesis == nil)
        #expect(manifest.zones.count == 1)
    }

    @Test("the hi-hat pair chokes both ways; nothing else is in a choke group")
    func hatChokeRelationship() throws {
        let dir = TempDirectory("choke")
        defer { dir.remove() }
        let kit = try SynthesizedKit.build(.tr808, in: dir.url, sampleRate: Self.sr)

        let hatNotes: Set<Int> = [SynthVoiceKind.closedHat.generalMIDINote,
                                  SynthVoiceKind.openHat.generalMIDINote]
        for zone in kit.manifest.zones {
            let note = zone.key.noteRange.lowerBound
            if hatNotes.contains(note) {
                #expect(zone.group == SynthesizedKit.hatChokeGroup, "\(zone.id) is not in the hat group")
                #expect(zone.offBy == SynthesizedKit.hatChokeGroup, "\(zone.id) is not choked by the hat group")
            } else {
                #expect(zone.group == nil && zone.offBy == nil, "\(zone.id) is unexpectedly in a choke group")
            }
        }
    }

    @Test("velocity layers cover 1…127 with no gap and no overlap")
    func layersTile() {
        for count in [2, 3] {
            let layers = SynthVelocityLayer.split(count)
            #expect(layers.count == count)
            #expect(layers.first?.range.lowerBound == 1)
            #expect(layers.last?.range.upperBound == 127)
            for (a, b) in zip(layers, layers.dropFirst()) {
                #expect(a.range.upperBound + 1 == b.range.lowerBound,
                        "gap or overlap between \(a.range) and \(b.range)")
            }
            for layer in layers {
                #expect(layer.range.contains(layer.velocity))
            }
        }
    }

    @Test("nothing written to disk clips")
    func writtenSamplesHaveHeadroom() throws {
        let dir = TempDirectory("headroom")
        defer { dir.remove() }
        let kit = try SynthesizedKit.build(.tr808, in: dir.url, sampleRate: Self.sr)
        let cache = SampleCache()
        var loudest: Float = 0
        for url in kit.sampleURLs {
            let buffer = try cache.buffer(for: url, sampleRate: Self.sr)
            let channel = Array(buffer.channel(0))
            let finite = channel.allSatisfy(\.isFinite)
            #expect(finite)
            loudest = max(loudest, SynthMeasure.peak(channel))
        }
        #expect(loudest <= 1.0, "a written sample peaks at \(loudest)")
        // The kit is scaled to -1 dBFS as a whole, so something in it must actually reach it.
        #expect(loudest > 0.8, "the loudest sample in the kit only reaches \(loudest)")
    }

    @Test("re-rendering after a parameter change produces different audio, same layout")
    func rerenderAfterAParameterChange() throws {
        let dir = TempDirectory("rerender")
        defer { dir.remove() }
        let original = try SynthesizedKit.build(.tr808, in: dir.url, sampleRate: Self.sr)
        let kickURL = try #require(original.manifest.zones
            .first { $0.sample.contains("kick") }
            .map { original.folder.appendingPathComponent($0.sample) })
        let before = try Data(contentsOf: kickURL)

        var edited = original
        var synthesis = try #require(edited.manifest.synthesis)
        var kick = try #require(synthesis.spec(for: .kick))
        kick.controls.decay = 1.0                // DECAY fully clockwise
        kick.controls.tune = 0.9                 // and tuned up
        synthesis.setSpec(kick)
        edited.manifest.synthesis = synthesis

        let rerendered = try SynthesizedKit.rerender(edited)
        #expect(rerendered.manifest.zones.map(\.id) == original.manifest.zones.map(\.id),
                "re-rendering changed the zone layout")
        let after = try Data(contentsOf: kickURL)
        #expect(after != before, "re-rendering did not change the kick's audio")

        // Still a valid kit afterwards.
        let reloaded = try KitStore.load(from: dir.url)
        #expect(reloaded.validate().isClean)
        #expect(reloaded.manifest.synthesis?.spec(for: .kick)?.controls.decay == 1.0)
    }

    @Test("building the same machine twice produces byte-identical WAVs")
    func kitBuildIsReproducible() throws {
        let a = TempDirectory("repro-a"), b = TempDirectory("repro-b")
        defer { a.remove(); b.remove() }
        let kitA = try SynthesizedKit.build(.tr909, in: a.url, sampleRate: Self.sr)
        try SynthesizedKit.build(.tr909, in: b.url, sampleRate: Self.sr)
        for path in kitA.manifest.samplePaths {
            let dataA = try Data(contentsOf: KitPath.resolve(path, in: a.url))
            let dataB = try Data(contentsOf: KitPath.resolve(path, in: b.url))
            #expect(dataA == dataB, "\(path) differs between two builds")
        }
    }

    // MARK: Playback

    @Test("a generated 808 kit plays through VoiceSampler, closed hat choking open hat")
    func playsThroughVoiceSampler() throws {
        let dir = TempDirectory("tr808-play")
        defer { dir.remove() }
        let kit = try SynthesizedKit.build(.tr808, in: dir.url, sampleRate: Self.sr)

        let cache = SampleCache()
        let sampler = VoiceSampler(cache: cache)
        try sampler.prepare(kit, sampleRate: Self.sr, channels: 1)
        let host = try OfflineHost(sampler: sampler, sampleRate: Self.sr, channels: 1)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        let chokeSeconds = 0.5
        sampler.enqueue([
            .init(.kick, velocity: 120, at: 0.0),
            .init(.openHat, velocity: 110, at: 0.1),
            .init(.closedHat, velocity: 110, at: chokeSeconds),
        ])
        let x = Signal.samples(try host.render(seconds: 1.5))
        #expect(sampler.droppedEventCount == 0)
        let finite = x.allSatisfy(\.isFinite)
        #expect(finite)
        #expect(Signal.maxAbs(x) > 0.05, "the kit rendered silence")
        #expect(Signal.maxAbs(x) <= 1.0, "the mix clipped at \(Signal.maxAbs(x))")

        // The open hat is ringing before the choke...
        let chokeFrame = Int(chokeSeconds * Self.sr)
        let beforeChoke = Signal.maxAbs(x[(chokeFrame - 2_000)..<chokeFrame])
        #expect(beforeChoke > 0.01, "the open hat was not still ringing at the choke (\(beforeChoke))")

        // ...and by the time the closed hat itself has decayed, the open hat is not still there.
        // The closed hat's own decay is a few tens of ms; sample well past it but well inside where
        // the un-choked open hat would still be audible.
        let closed = try #require(SynthMachine.tr808.spec(for: .closedHat))
        let openHatTail = chokeFrame + Int(0.25 * Self.sr)
        let afterChoke = Signal.maxAbs(x[openHatTail..<min(x.count, openHatTail + 4_000)])
        #expect(afterChoke < beforeChoke * 0.25,
                "open hat still at \(afterChoke) after the closed hat (\(closed.tone.decayLongestSeconds) s) choked it")
    }

    @Test("two offline renders of a generated kit are byte-identical")
    func offlinePlaybackIsDeterministic() throws {
        let dir = TempDirectory("tr909-determinism")
        defer { dir.remove() }
        let kit = try SynthesizedKit.build(.tr909, in: dir.url, sampleRate: Self.sr, layerCount: 2)

        func renderOnce() throws -> [Float] {
            let sampler = VoiceSampler(cache: SampleCache())
            try sampler.prepare(kit, sampleRate: Self.sr, channels: 1)
            let host = try OfflineHost(sampler: sampler, sampleRate: Self.sr, channels: 1)
            defer { host.stop(); sampler.unprepare() }
            host.startTransport()
            sampler.enqueue([
                .init(.kick, velocity: 120, at: 0.0),
                .init(.snare, velocity: 96, at: 0.25),
                .init(.closedHat, velocity: 70, at: 0.375),
                .init(.kick, velocity: 100, at: 0.5),
            ])
            return Signal.samples(try host.render(seconds: 1.0))
        }

        let first = try renderOnce()
        let second = try renderOnce()
        #expect(first == second)
    }

    @Test("a machine's kit folder changes when its voices do, so a retuned machine is rendered again")
    func machineFolderFingerprint() {
        let names = SynthMachine.all.map(SynthesizedKit.folderName(for:))
        #expect(Set(names).count == SynthMachine.all.count)
        #expect(zip(names, SynthMachine.all).allSatisfy { $0.hasPrefix("\($1.id)-") })
        var retuned = SynthMachine.dmx
        retuned.voices[0].tone.frequencyHz += 1
        #expect(SynthesizedKit.folderName(for: retuned) != SynthesizedKit.folderName(for: .dmx))
        #expect(KitFingerprint.isStale("dmx", prefix: "dmx", current: SynthesizedKit.folderName(for: .dmx)),
                "the unfingerprinted folder from before is cleared")
    }

    @Test("every machine builds, loads and validates")
    func allMachinesBuild() throws {
        for machine in SynthMachine.all {
            let dir = TempDirectory("machine-\(machine.id)")
            defer { dir.remove() }
            try SynthesizedKit.build(machine, in: dir.url, sampleRate: Self.sr, layerCount: 2)
            let loaded = try KitStore.load(from: dir.url)
            let validation = loaded.validate()
            #expect(validation.isClean, "\(machine.id): \(validation.findings.map(\.description))")
            #expect(loaded.manifest.synthesis?.machine == machine.id)
        }
    }
}
