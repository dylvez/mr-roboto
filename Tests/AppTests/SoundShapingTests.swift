import Foundation
import Instrument
import SongGraph
import Testing
@testable import MrRobotoApp

/// What the Shape popover's model promises: every control it shows changes the sound, the same
/// control value always makes the same sound, the machine's own knobs are the ones on screen, a
/// named degradation preset means what the C says it means, the A/B's dry side is untouched, and
/// an edit is a new version rather than a change to an old one.
///
/// All of it is the model. The view is not tested here and does not need to be: it reads
/// `voiceControls` and `chainControls`, draws them and calls back in.
@Suite("Sound shaping")
@MainActor
struct SoundShapingTests {

    // MARK: Audible, and the same every time

    @Test("moving a control changes the rendered voice")
    func movingAControlChangesTheRender() {
        let (shaping, _) = SoundFixture.shaping("tr808", .kick)
        let before = shaping.rendered(.dry)
        shaping.setValue(0.8, for: .machine(.tune))
        let after = shaping.rendered(.dry)
        #expect(before != after, "TUNE did not change the 808 kick")
    }

    @Test("the same control value renders identically, dry and through the chain")
    func rendersAreDeterministic() {
        let (shaping, _) = SoundFixture.shaping("tr808", .kick)
        let first = shaping.rendered(.dry)
        shaping.setValue(0.8, for: .machine(.tune))
        shaping.setValue(0.5, for: .machine(.tune))
        #expect(shaping.rendered(.dry) == first, "returning TUNE to 0.5 did not return the sound")

        shaping.apply(.vinyl)
        let wet = shaping.rendered(.chain)
        #expect(shaping.rendered(.chain) == wet, "the chain is not deterministic at a fixed seed")
        #expect(wet != shaping.rendered(.dry), "vinyl did not change anything")
    }

    @Test("every control the popover shows changes the sound of the voice it is shown for")
    func everyControlIsAudible() {
        // At the sampler's own rate, not a cheaper one: the 909's metal voices sit between 9 and
        // 18 kHz and a 24 kHz render puts their TONE corners at or above Nyquist, where the knob
        // genuinely does nothing. The rate a control is judged at has to be the rate it runs at.
        for machine in SynthMachine.all {
            for voice in machine.voices.map(\.kind) {
                let (shaping, _) = SoundFixture.shaping(machine.id, voice)
                for control in shaping.voiceControls {
                    let low = control.range.lowerBound
                    let span = control.range.upperBound - low
                    shaping.setValue(low + 0.25 * span, for: control.parameter)
                    let quarter = shaping.rendered(.dry)
                    shaping.setValue(low + 0.75 * span, for: control.parameter)
                    #expect(quarter != shaping.rendered(.dry),
                            "\(machine.id) \(voice.rawValue): \(control.name) does nothing")
                    shaping.reset(control.parameter)
                }
            }
        }
    }

    @Test("a change plays immediately, through the host")
    func changesPlayOnTouch() {
        let (shaping, host) = SoundFixture.shaping("tr808", .kick)
        #expect(host.auditions.isEmpty)
        shaping.setValue(0.7, for: .machine(.decay))
        #expect(host.auditions.count == 1)
        #expect(host.auditions[0].label == "TR-808 kick")
        #expect(host.auditions[0].isDry, "a clean chain is a bypass, so this audition is dry")
        // A value that does not move is not a new sound and must not retrigger.
        shaping.setValue(0.7, for: .machine(.decay))
        #expect(host.auditions.count == 1)
    }

    // MARK: The control set is the machine's

    @Test("an 808 kick, a 909 kick and a snare do not have the same knobs")
    func controlSetsFollowTheHardware() {
        #expect(names("tr808", .kick) == ["TUNE", "DECAY", "TONE", "LEVEL"])
        #expect(names("tr909", .kick) == ["TUNE", "DECAY", "TONE", "ATTACK", "LEVEL"])
        #expect(names("tr808", .snare) == ["TUNE", "DECAY", "TONE", "SNAPPY", "LEVEL"])

        // ATTACK is the 909 bass drum's separate click circuit and nothing else's. The 808's kick
        // has a click too, but it goes out through TONE and has no knob of its own.
        #expect(!names("tr808", .kick).contains("ATTACK"))
        // SNAPPY only exists where the synthesizer reads it: a two-oscillator-plus-noise voice.
        #expect(!names("tr909", .kick).contains("SNAPPY"))
        #expect(names("tr909", .snare).contains("SNAPPY"))
    }

    @Test("a 909 kick's TUNE is labelled as the pitch-envelope control it is")
    func the909TuneIsLabelledHonestly() throws {
        let tune909 = try #require(control("tr909", .kick, .machine(.tune)))
        #expect(tune909.honestly != nil, "a 909's TUNE is not a pitch control and must say so")
        #expect(tune909.readout.hasSuffix("sweep"))
        // 30…120 ms is the documented range; the detent sits inside it.
        #expect(tune909.readout.hasPrefix("5") || tune909.readout.hasPrefix("6"),
                "expected tens of milliseconds, got \(tune909.readout)")

        let tune808 = try #require(control("tr808", .kick, .machine(.tune)))
        #expect(tune808.honestly == nil)
        #expect(tune808.readout.hasSuffix("Hz"), "an 808 kick's TUNE is a pitch: \(tune808.readout)")
    }

    @Test("a snare's TONE says what it is really wired to, machine by machine")
    func toneIsLabelledPerMachine() throws {
        let tone808 = try #require(control("tr808", .snare, .machine(.tone)))
        #expect(tone808.honestly?.contains("rings") == true)
        let tone909 = try #require(control("tr909", .snare, .machine(.tone)))
        #expect(tone909.honestly?.contains("noise") == true)
        #expect(tone909.readout.hasSuffix("noise"))
    }

    @Test("the readouts are in units you can check against a machine")
    func readoutsAreInRealUnits() throws {
        let decay = try #require(control("tr808", .kick, .machine(.decay)))
        // The 808 service notes' 300 ms is T20; the preset's detent is the 900 ms T60.
        #expect(decay.readout == "900 ms")
        let tone = try #require(control("tr808", .kick, .machine(.tone)))
        #expect(tone.readout.hasSuffix("low-pass"))
    }

    // MARK: Small, with at most two prominent levers

    @Test("no voice shows more than six knobs, and neither set more than two prominent ones")
    func theControlsStaySmall() {
        for machine in SynthMachine.all {
            for voice in machine.voices.map(\.kind) {
                let (shaping, _) = SoundFixture.shaping(machine.id, voice)
                let knobs = shaping.voiceControls
                #expect(knobs.filter(\.isProminent).count <= 2,
                        "\(machine.id) \(voice.rawValue): \(knobs.filter(\.isProminent).count) prominent")
                #expect(knobs.count <= 6, "\(machine.id) \(voice.rawValue): \(knobs.count) controls")
                #expect(!knobs.isEmpty)
                let chain = shaping.chainControls
                #expect(chain.count == SoundControl.ChainControl.allCases.count, "the chain is its nine stages")
                #expect(chain.filter(\.isProminent).count <= 2)
            }
        }
    }

    @Test("DECAY is always one of the two prominent levers on a voice")
    func decayIsAlwaysProminent() {
        for machine in SynthMachine.all {
            for voice in machine.voices.map(\.kind) {
                let (shaping, _) = SoundFixture.shaping(machine.id, voice)
                let controls = shaping.voiceControls
                guard controls.contains(where: { $0.parameter == .machine(.decay) }) else { continue }
                #expect(controls.first { $0.parameter == .machine(.decay) }?.isProminent == true,
                        "\(machine.id) \(voice.rawValue): DECAY is not prominent")
            }
        }
    }

    // MARK: Degradation presets

    @Test("sp1200 applies its documented parameter values")
    func sp1200IsTheDocumentedMachine() {
        let (shaping, _) = SoundFixture.shaping()
        shaping.apply(.sp1200)
        let chain = shaping.draft.degrade
        // 12 linear bits and 26.04 kHz, off Rossum's own spec, with the decimator unfiltered
        // because the SP-1200's artifacts are what an unfiltered drop-sample path makes.
        #expect(chain.bitDepth == 12)
        #expect(chain.companding == 0)
        #expect(chain.targetSampleRate == 26_040)
        #expect(chain.antiAliasing == .none)
        #expect(chain.saturation == .soft)
        #expect(abs(chain.drive - 1.40) < 1e-6)
        #expect(chain.highCut == 12_000)
        #expect(chain.mix == 1)
        #expect(chain.wowDepth == 0 && chain.flutterDepth == 0 && chain.crackleDensity == 0)

        // and the popover says so, in the machine's units
        let readouts = Dictionary(uniqueKeysWithValues:
            shaping.chainControls.map { ($0.parameter, $0.readout) })
        #expect(readouts[.chain(.bitDepth)] == "12.0 bits")
        #expect(readouts[.chain(.sampleRate)] == "26.04 kHz")
        #expect(readouts[.chain(.highCut)] == "12 kHz")
        #expect(readouts[.chain(.wow)] == "off")
    }

    @Test("mpc60 and cassette differ from sp1200 where the research says they do")
    func theOtherPresetsAreThemselves() {
        let (shaping, _) = SoundFixture.shaping()

        shaping.apply(.mpc60)
        var chain = shaping.draft.degrade
        // Same 12 bits, but companded and at 40 kHz: the Akai keeps its top end and its noise
        // floor follows the signal.
        #expect(chain.bitDepth == 12)
        #expect(chain.companding > 0)
        #expect(chain.targetSampleRate == 40_000)
        #expect(chain.antiAliasing == .filtered)
        #expect(chain.highCut == 17_000)

        shaping.apply(.cassette)
        chain = shaping.draft.degrade
        // No converter at all: transport and magnetics.
        #expect(chain.bitDepth == DegradeSettings.bitDepthOff)
        #expect(chain.targetSampleRate == 0)
        #expect(chain.saturation == .tape)
        #expect(abs(chain.wowDepth - 0.0012) < 1e-7)
        #expect(abs(chain.wowRate - 0.90) < 1e-6)
        #expect(abs(chain.flutterRate - 7.5) < 1e-6)
        #expect(chain.highCut == 14_000)

        let wow = shaping.chainControls.first { $0.parameter == .chain(.wow) }
        #expect(wow?.readout == "0.12 % at 0.90 Hz")

        shaping.apply(.vinyl)
        // 33 1/3 rpm is 0.5556 revolutions a second, and an off-centre spindle hole wobbles once
        // per revolution.
        #expect(abs(shaping.draft.degrade.wowRate - 0.5556) < 1e-5)
        #expect(shaping.draft.degrade.crackleDensity == 12)
    }

    @Test("a preset is reachable and identifiable again afterwards")
    func aPresetNamesItself() {
        let (shaping, _) = SoundFixture.shaping()
        shaping.apply(.vinyl)
        #expect(shaping.draft.degrade.matchingPreset == .vinyl)
        #expect(shaping.title.hasSuffix("vinyl"))
        #expect(shaping.provenance == "TR-808 · Vinyl")
        shaping.setValue(0.5, for: .chain(.mix))
        #expect(shaping.draft.degrade.matchingPreset == nil, "a moved knob is no longer the preset")
        #expect(shaping.draft.chainBase == .vinyl, "but it still knows where it came from")
    }

    // MARK: The A/B

    @Test("true bypass is bit-transparent through the model")
    func bypassIsBitTransparent() {
        let (shaping, _) = SoundFixture.shaping("tr909", .kick)
        shaping.apply(.vinyl)
        let direct = DrumSynthesizer.render(shaping.draft.spec, velocity: shaping.auditionVelocity,
                                            sampleRate: shaping.sampleRate)
        #expect(shaping.rendered(.dry) == direct, "the dry side of the A/B is not the raw voice")
        #expect(shaping.rendered(.chain) != direct, "vinyl did nothing")

        // And a clean chain is a bypass too, not merely a quiet setting.
        shaping.apply(.clean)
        #expect(shaping.draft.degrade.isBypass)
        #expect(shaping.rendered(.chain) == direct)
    }

    @Test("switching the A/B re-auditions the same hit on the other side")
    func theABPlaysBothSides() {
        let (shaping, host) = SoundFixture.shaping("tr808", .snare)
        shaping.apply(.sp1200)
        #expect(host.auditions.count == 1)
        #expect(host.auditions[0].isDry == false)

        shaping.monitor = .dry
        #expect(host.auditions.count == 2)
        #expect(host.auditions[1].isDry)
        #expect(host.auditions[1].samples == shaping.rendered(.dry))
        // Same hit, same length: an A/B that changed the hit would not be one.
        #expect(host.auditions[1].samples.count == host.auditions[0].samples.count)

        shaping.monitor = .dry  // no change, no retrigger
        #expect(host.auditions.count == 2)
    }

    @Test("the chain never comes back louder than the dry signal")
    func theChainOnlyCompresses() {
        // The saturation curves are normalised by their slope at the origin, so |y| <= |x| at any
        // drive. A drive control on a chain with no curve would be a plain gain and would break
        // that, which is why the model gives it a curve to drive into.
        let (shaping, _) = SoundFixture.shaping("tr808", .kick)
        shaping.setValue(3.0, for: .chain(.drive))
        #expect(shaping.draft.degrade.saturation == .soft)
        let dry = SoundFixture.peak(shaping.rendered(.dry))
        let wet = SoundFixture.peak(shaping.rendered(.chain))
        #expect(wet <= dry, "drive 3 made it louder: \(wet) against \(dry)")

        // Backing off restores the base preset's own curve, so clean is clean again.
        shaping.setValue(1.0, for: .chain(.drive))
        #expect(shaping.draft.degrade.saturation == .none)
        #expect(shaping.draft.degrade.isBypass)
    }

    // MARK: Versions

    @Test("an edit is written as a new part version, not a change to the old one")
    func editsProduceNewVersions() throws {
        let original = SoundFixture.state("tr808", .kick)
        let parent = SoundFixture.version(original)
        let host = SoundShapingStub(kept: [parent])
        let shaping = SoundShaping(host: host, voice: .kick, machine: "tr808", sampleRate: SoundFixture.sampleRate)

        #expect(!shaping.isDirty)
        #expect(shaping.boundVersion?.id == parent.id, "a voice opens at the song's newest edit of it")
        shaping.setValue(0.75, for: .machine(.decay))
        #expect(shaping.isDirty)
        #expect(host.recorded.isEmpty, "a knob turn is not yet a version")

        let written = try #require(shaping.commit(note: "longer kick"))
        #expect(host.recorded.count == 1)
        #expect(host.recorded[0].id == written.id)
        #expect(written.id != parent.id)
        #expect(written.partID == parent.partID, "an edit stays the same part")
        #expect(written.parents == [parent.id])
        #expect(written.operation == Operation.edit)
        #expect(written.author == .user)

        // The version it opened against is untouched.
        let parentState = try #require(SoundState(parent))
        #expect(parentState == original)
        #expect(parentState.controls.decay == original.controls.decay)

        // The new version carries the edit, and the shaping is now bound to it.
        let newState = try #require(SoundState(written))
        #expect(newState.controls.decay == 0.75)
        #expect(!shaping.isDirty)

        // A second commit with nothing moved writes nothing.
        #expect(shaping.commit() == nil)
        #expect(host.recorded.count == 1)

        // And a further edit derives from the version just written, not from the original.
        shaping.setValue(0.3, for: .machine(.tone))
        let second = try #require(shaping.commit())
        #expect(second.parents == [written.id])
        #expect(host.recorded.count == 2)
    }

    @Test("a chain edit is a version too, and round-trips through the part payload")
    func chainEditsRoundTrip() throws {
        let (shaping, host) = SoundFixture.shaping("tr909", .snare)
        shaping.apply(.cassette)
        shaping.setValue(0.6, for: .chain(.mix))
        shaping.setValue(0.55, for: .machine(.snappy))
        let written = try #require(shaping.commit())

        let reread = try #require(SoundState(written))
        #expect(reread == shaping.draft, "a Sound part did not survive the round trip")
        #expect(reread.machine == "tr909")
        #expect(reread.voice == .snare)
        #expect(reread.chainBase == .cassette)
        #expect(reread.degrade.mix == 0.6)
        #expect(reread.degrade.saturation == .tape)
        // The seed is a UInt64 and `Sound.parameters` is `[String: Double]`, so it travels by the
        // preset name instead. It has to survive, or the bounce is not reproducible.
        #expect(reread.degrade.seed == DegradeSettings(preset: .cassette).seed)
        #expect(reread.degrade.seed != 0)

        // And the re-read state renders the same samples the popover was auditioning.
        let host2 = SoundShapingStub(kept: [written])
        let reopened = SoundShaping(host: host2, voice: .snare, machine: "tr909", sampleRate: SoundFixture.sampleRate)
        #expect(reopened.rendered(.chain) == shaping.rendered(.chain))
        #expect(host.recorded.count == 2, "picking the cassette is a version of its own; the knobs after it are the second")
    }

    @Test("a refused version leaves the edit as a draft rather than pretending it was kept")
    func aRefusedVersionStaysADraft() {
        let (shaping, host) = SoundFixture.shaping()
        host.accepts = false
        shaping.setValue(0.2, for: .machine(.tone))
        #expect(shaping.commit() == nil)
        #expect(shaping.isDirty, "the edit was dropped on the floor")
        #expect(host.recorded.isEmpty)
    }

    @Test("a knob let go of says what it became: the version kept, counted, and a refusal owned up to")
    func theFooterKnowsWhatWasKept() throws {
        let (shaping, host) = SoundFixture.shaping()
        #expect(shaping.lastKept == nil && shaping.keptCount == 0 && !shaping.lastCommitWasRefused)
        var told: [PartVersion] = []
        shaping.kept = { told.append($0) }

        shaping.setValue(0.7, for: .machine(.decay))
        let first = try #require(shaping.commit())
        #expect(shaping.lastKept?.id == first.id && shaping.keptCount == 1)
        #expect(told.map(\.id) == [first.id], "the surface the popover opened from is told")

        // A refusal leaves the draft on the knobs and says so; it is not counted as kept.
        host.accepts = false
        shaping.setValue(0.2, for: .machine(.tone))
        #expect(shaping.commit() == nil)
        #expect(shaping.lastCommitWasRefused && shaping.isDirty)
        #expect(shaping.lastKept?.id == first.id && shaping.keptCount == 1)

        // Trying again with the host back lands the same draft, and the refusal is over.
        host.accepts = true
        let second = try #require(shaping.commit())
        #expect(!shaping.lastCommitWasRefused && shaping.lastKept?.id == second.id && shaping.keptCount == 2)
        #expect(told.count == 2)
    }

    @Test("a control knows whether it sits on the preset, so the way back is offered only when there is one")
    func atPreset() throws {
        let (shaping, _) = SoundFixture.shaping("tr808", .kick)
        let decay = try #require(shaping.voiceControls.first { $0.parameter == .machine(.decay) })
        #expect(shaping.isAtPreset(.machine(.decay)))
        shaping.setValue(decay.value == decay.range.upperBound ? decay.range.lowerBound : decay.range.upperBound, for: .machine(.decay))
        #expect(!shaping.isAtPreset(.machine(.decay)))
        shaping.reset(.machine(.decay))
        #expect(shaping.isAtPreset(.machine(.decay)))

        // A chain control's preset is the chain's base preset, whichever was applied last.
        shaping.apply(.vinyl)
        #expect(shaping.isAtPreset(.chain(.mix)))
        shaping.setValue(0.5, for: .chain(.mix))
        #expect(!shaping.isAtPreset(.chain(.mix)))
        shaping.reset(.chain(.mix))
        #expect(shaping.isAtPreset(.chain(.mix)))
        #expect(shaping.draft.degrade.matchingPreset == .vinyl, "back to the preset means back to vinyl, not to clean")
    }

    @Test("a voice nobody has kept starts a part of its own, on the machine the song plays")
    func withNothingKeptItStartsAPart() throws {
        let host = SoundShapingStub()
        host.songMachine = "linn"
        let shaping = SoundShaping(host: host, voice: .snare, sampleRate: SoundFixture.sampleRate)
        #expect(shaping.draft.machine == "linn" && shaping.draft.voice == .snare)
        #expect(shaping.boundVersion == nil && shaping.editing == nil)
        shaping.setValue(0.7, for: .machine(.tune))
        let written = try #require(shaping.commit())
        #expect(written.parents.isEmpty)
        #expect(written.operation == Operation.written)
        #expect(SoundState(written)?.machine == "linn")
        #expect(shaping.editing?.id == written.id)

        // With no song at all, the 808, on a voice it has.
        let bare = SoundShaping(host: SoundShapingStub(), voice: .cajon, sampleRate: SoundFixture.sampleRate)
        #expect(bare.draft.machine == "tr808" && SynthMachine.tr808.voices.contains { $0.kind == bare.draft.voice })
    }

    @Test("a chop or a groove is only its chain: no voice knobs, and nothing to shape on a tune")
    func aPartIsOnlyItsChain() {
        let host = SoundShapingStub()
        let groove = WiringFixture.groove()
        let shaping = SoundShaping(host: host, part: groove, sampleRate: SoundFixture.sampleRate)
        #expect(shaping.subject == .part(.groove))
        #expect(shaping.voiceControls.isEmpty)
        #expect(shaping.chainControls.count == 9)
        #expect(shaping.subjectName == PartLabel.title(of: groove))
        #expect(shaping.provenance == "dry · chain off")

        let tune = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [])), author: .user, operation: Operation.written)
        let none = SoundShaping(host: host, part: tune, sampleRate: SoundFixture.sampleRate)
        #expect(none.subject == .voice && none.boundVersion == nil, "a tune carries no chain")
    }

    // MARK: Helpers

    private func names(_ machine: String, _ voice: SynthVoiceKind) -> [String] {
        let (shaping, _) = SoundFixture.shaping(machine, voice)
        return shaping.voiceControls.map(\.name)
    }

    private func control(_ machine: String, _ voice: SynthVoiceKind,
                         _ parameter: SoundControl.Parameter) -> SoundControl? {
        let (shaping, _) = SoundFixture.shaping(machine, voice)
        return shaping.voiceControls.first { $0.parameter == parameter }
    }
}
