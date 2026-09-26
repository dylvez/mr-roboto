import Foundation
import Instrument
import SongGraph
import Testing
@testable import MrRobotoApp

/// What the Sound surface promises: every control it shows changes the sound, the same control
/// value always makes the same sound, the machine's own knobs are the ones on screen, a named
/// degradation preset means what the C says it means, the A/B's dry side is untouched, and an edit
/// is a new version rather than a change to an old one.
///
/// All of it is the model. The view is not tested here and does not need to be: it reads
/// `controls`, draws them and calls back in.
@Suite("Sound surface")
@MainActor
struct SoundSurfaceTests {

    // MARK: Audible, and the same every time

    @Test("moving a control changes the rendered voice")
    func movingAControlChangesTheRender() {
        let (surface, _) = SoundFixture.surface("tr808", .kick)
        let before = surface.rendered(.dry)
        surface.setValue(0.8, for: .machine(.tune))
        let after = surface.rendered(.dry)
        #expect(before != after, "TUNE did not change the 808 kick")
    }

    @Test("the same control value renders identically, dry and through the chain")
    func rendersAreDeterministic() {
        let (surface, _) = SoundFixture.surface("tr808", .kick)
        let first = surface.rendered(.dry)
        surface.setValue(0.8, for: .machine(.tune))
        surface.setValue(0.5, for: .machine(.tune))
        #expect(surface.rendered(.dry) == first, "returning TUNE to 0.5 did not return the sound")

        surface.apply(.vinyl)
        let wet = surface.rendered(.chain)
        #expect(surface.rendered(.chain) == wet, "the chain is not deterministic at a fixed seed")
        #expect(wet != surface.rendered(.dry), "vinyl did not change anything")
    }

    @Test("every control the surface shows changes the sound of the voice it is shown for")
    func everyControlIsAudible() {
        // At the sampler's own rate, not a cheaper one: the 909's metal voices sit between 9 and
        // 18 kHz and a 24 kHz render puts their TONE corners at or above Nyquist, where the knob
        // genuinely does nothing. The rate a control is judged at has to be the rate it runs at.
        for machine in SynthMachine.all {
            for voice in machine.voices.map(\.kind) {
                let (surface, _) = SoundFixture.surface(machine.id, voice)
                for control in surface.controls(for: .voice) {
                    let low = control.range.lowerBound
                    let span = control.range.upperBound - low
                    surface.setValue(low + 0.25 * span, for: control.parameter)
                    let quarter = surface.rendered(.dry)
                    surface.setValue(low + 0.75 * span, for: control.parameter)
                    #expect(quarter != surface.rendered(.dry),
                            "\(machine.id) \(voice.rawValue): \(control.name) does nothing")
                    surface.reset(control.parameter)
                }
            }
        }
    }

    @Test("a change plays immediately, through the host")
    func changesPlayOnTouch() {
        let (surface, host) = SoundFixture.surface("tr808", .kick)
        #expect(host.auditions.isEmpty)
        surface.setValue(0.7, for: .machine(.decay))
        #expect(host.auditions.count == 1)
        #expect(host.auditions[0].label == "TR-808 kick")
        #expect(host.auditions[0].isDry, "a clean chain is a bypass, so this audition is dry")
        // A value that does not move is not a new sound and must not retrigger.
        surface.setValue(0.7, for: .machine(.decay))
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

    @Test("no voice shows more than six controls and no panel more than two prominent ones")
    func theSurfaceStaysSmall() {
        for machine in SynthMachine.all {
            for voice in machine.voices.map(\.kind) {
                let (surface, _) = SoundFixture.surface(machine.id, voice)
                for panel in SoundPanel.allCases {
                    let controls = surface.controls(for: panel)
                    let prominent = controls.filter(\.isProminent)
                    #expect(prominent.count <= 2,
                            "\(machine.id) \(voice.rawValue) \(panel.rawValue): \(prominent.count) prominent")
                    if panel == .voice {
                        #expect(controls.count <= 6,
                                "\(machine.id) \(voice.rawValue): \(controls.count) controls")
                        #expect(!controls.isEmpty)
                    }
                }
            }
        }
    }

    @Test("DECAY is always one of the two prominent levers on a voice")
    func decayIsAlwaysProminent() {
        for machine in SynthMachine.all {
            for voice in machine.voices.map(\.kind) {
                let (surface, _) = SoundFixture.surface(machine.id, voice)
                let controls = surface.controls(for: .voice)
                guard controls.contains(where: { $0.parameter == .machine(.decay) }) else { continue }
                #expect(controls.first { $0.parameter == .machine(.decay) }?.isProminent == true,
                        "\(machine.id) \(voice.rawValue): DECAY is not prominent")
            }
        }
    }

    // MARK: Degradation presets

    @Test("sp1200 applies its documented parameter values")
    func sp1200IsTheDocumentedMachine() {
        let (surface, _) = SoundFixture.surface()
        surface.apply(.sp1200)
        let chain = surface.draft.degrade
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

        // and the panel says so, in the machine's units
        let readouts = Dictionary(uniqueKeysWithValues:
            surface.controls(for: .chain).map { ($0.parameter, $0.readout) })
        #expect(readouts[.chain(.bitDepth)] == "12.0 bits")
        #expect(readouts[.chain(.sampleRate)] == "26.04 kHz")
        #expect(readouts[.chain(.highCut)] == "12 kHz")
        #expect(readouts[.chain(.wow)] == "off")
    }

    @Test("mpc60 and cassette differ from sp1200 where the research says they do")
    func theOtherPresetsAreThemselves() {
        let (surface, _) = SoundFixture.surface()

        surface.apply(.mpc60)
        var chain = surface.draft.degrade
        // Same 12 bits, but companded and at 40 kHz: the Akai keeps its top end and its noise
        // floor follows the signal.
        #expect(chain.bitDepth == 12)
        #expect(chain.companding > 0)
        #expect(chain.targetSampleRate == 40_000)
        #expect(chain.antiAliasing == .filtered)
        #expect(chain.highCut == 17_000)

        surface.apply(.cassette)
        chain = surface.draft.degrade
        // No converter at all: transport and magnetics.
        #expect(chain.bitDepth == DegradeSettings.bitDepthOff)
        #expect(chain.targetSampleRate == 0)
        #expect(chain.saturation == .tape)
        #expect(abs(chain.wowDepth - 0.0012) < 1e-7)
        #expect(abs(chain.wowRate - 0.90) < 1e-6)
        #expect(abs(chain.flutterRate - 7.5) < 1e-6)
        #expect(chain.highCut == 14_000)

        let wow = surface.controls(for: .chain).first { $0.parameter == .chain(.wow) }
        #expect(wow?.readout == "0.12 % at 0.90 Hz")

        surface.apply(.vinyl)
        // 33 1/3 rpm is 0.5556 revolutions a second, and an off-centre spindle hole wobbles once
        // per revolution.
        #expect(abs(surface.draft.degrade.wowRate - 0.5556) < 1e-5)
        #expect(surface.draft.degrade.crackleDensity == 12)
    }

    @Test("a preset is reachable and identifiable again afterwards")
    func aPresetNamesItself() {
        let (surface, _) = SoundFixture.surface()
        surface.apply(.vinyl)
        #expect(surface.draft.degrade.matchingPreset == .vinyl)
        #expect(surface.title.hasSuffix("vinyl"))
        surface.setValue(0.5, for: .chain(.mix))
        #expect(surface.draft.degrade.matchingPreset == nil, "a moved knob is no longer the preset")
        #expect(surface.draft.chainBase == .vinyl, "but it still knows where it came from")
    }

    // MARK: The A/B

    @Test("true bypass is bit-transparent through the model")
    func bypassIsBitTransparent() {
        let (surface, _) = SoundFixture.surface("tr909", .kick)
        surface.apply(.vinyl)
        let direct = DrumSynthesizer.render(surface.draft.spec, velocity: surface.auditionVelocity,
                                            sampleRate: surface.sampleRate)
        #expect(surface.rendered(.dry) == direct, "the dry side of the A/B is not the raw voice")
        #expect(surface.rendered(.chain) != direct, "vinyl did nothing")

        // And a clean chain is a bypass too, not merely a quiet setting.
        surface.apply(.clean)
        #expect(surface.draft.degrade.isBypass)
        #expect(surface.rendered(.chain) == direct)
    }

    @Test("switching the A/B re-auditions the same hit on the other side")
    func theABPlaysBothSides() {
        let (surface, host) = SoundFixture.surface("tr808", .snare)
        surface.apply(.sp1200)
        #expect(host.auditions.count == 1)
        #expect(host.auditions[0].isDry == false)

        surface.monitor = .dry
        #expect(host.auditions.count == 2)
        #expect(host.auditions[1].isDry)
        #expect(host.auditions[1].samples == surface.rendered(.dry))
        // Same hit, same length: an A/B that changed the hit would not be one.
        #expect(host.auditions[1].samples.count == host.auditions[0].samples.count)

        surface.monitor = .dry  // no change, no retrigger
        #expect(host.auditions.count == 2)
    }

    @Test("the chain never comes back louder than the dry signal")
    func theChainOnlyCompresses() {
        // The saturation curves are normalised by their slope at the origin, so |y| <= |x| at any
        // drive. A drive control on a chain with no curve would be a plain gain and would break
        // that, which is why the surface gives it a curve to drive into.
        let (surface, _) = SoundFixture.surface("tr808", .kick)
        surface.setValue(3.0, for: .chain(.drive))
        #expect(surface.draft.degrade.saturation == .soft)
        let dry = SoundFixture.peak(surface.rendered(.dry))
        let wet = SoundFixture.peak(surface.rendered(.chain))
        #expect(wet <= dry, "drive 3 made it louder: \(wet) against \(dry)")

        // Backing off restores the base preset's own curve, so clean is clean again.
        surface.setValue(1.0, for: .chain(.drive))
        #expect(surface.draft.degrade.saturation == .none)
        #expect(surface.draft.degrade.isBypass)
    }

    // MARK: Versions

    @Test("an edit is written as a new part version, not a change to the old one")
    func editsProduceNewVersions() throws {
        let original = SoundFixture.state("tr808", .kick)
        let parent = SoundFixture.version(original)
        let host = SoundHostStub(selectedPart: parent)
        let surface = SoundSurface(host: host, sampleRate: SoundFixture.sampleRate)

        #expect(!surface.isDirty)
        surface.setValue(0.75, for: .machine(.decay))
        #expect(surface.isDirty)
        #expect(host.recorded.isEmpty, "a knob turn is not yet a version")

        let written = try #require(surface.commit(note: "longer kick"))
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

        // The new version carries the edit, and the surface is now bound to it.
        let newState = try #require(SoundState(written))
        #expect(newState.controls.decay == 0.75)
        #expect(!surface.isDirty)

        // A second commit with nothing moved writes nothing.
        #expect(surface.commit() == nil)
        #expect(host.recorded.count == 1)

        // And a further edit derives from the version just written, not from the original.
        surface.setValue(0.3, for: .machine(.tone))
        let second = try #require(surface.commit())
        #expect(second.parents == [written.id])
        #expect(host.recorded.count == 2)
    }

    @Test("a chain edit is a version too, and round-trips through the part payload")
    func chainEditsRoundTrip() throws {
        let (surface, host) = SoundFixture.surface("tr909", .snare)
        surface.apply(.cassette)
        surface.setValue(0.6, for: .chain(.mix))
        surface.setValue(0.55, for: .machine(.snappy))
        let written = try #require(surface.commit())

        let reread = try #require(SoundState(written))
        #expect(reread == surface.draft, "a Sound part did not survive the round trip")
        #expect(reread.machine == "tr909")
        #expect(reread.voice == .snare)
        #expect(reread.chainBase == .cassette)
        #expect(reread.degrade.mix == 0.6)
        #expect(reread.degrade.saturation == .tape)
        // The seed is a UInt64 and `Sound.parameters` is `[String: Double]`, so it travels by the
        // preset name instead. It has to survive, or the bounce is not reproducible.
        #expect(reread.degrade.seed == DegradeSettings(preset: .cassette).seed)
        #expect(reread.degrade.seed != 0)

        // And the re-read state renders the same samples the surface was auditioning.
        let host2 = SoundHostStub(selectedPart: written)
        let reopened = SoundSurface(host: host2, sampleRate: SoundFixture.sampleRate)
        #expect(reopened.rendered(.chain) == surface.rendered(.chain))
        #expect(host.recorded.count == 2, "picking the cassette is a version of its own; the knobs after it are the second")
    }

    @Test("a refused version leaves the edit as a draft rather than pretending it was kept")
    func aRefusedVersionStaysADraft() {
        let (surface, host) = SoundFixture.surface()
        host.accepts = false
        surface.setValue(0.2, for: .machine(.tone))
        #expect(surface.commit() == nil)
        #expect(surface.isDirty, "the edit was dropped on the floor")
        #expect(host.recorded.isEmpty)
    }

    @Test("a knob let go of says what it became: the version kept, counted, and a refusal owned up to")
    func theFooterKnowsWhatWasKept() throws {
        let (surface, host) = SoundFixture.surface()
        #expect(surface.lastKept == nil && surface.keptCount == 0 && !surface.lastCommitWasRefused)

        surface.setValue(0.7, for: .machine(.decay))
        let first = try #require(surface.commit())
        #expect(surface.lastKept?.id == first.id && surface.keptCount == 1)

        // A refusal leaves the draft on the knobs and says so; it is not counted as kept.
        host.accepts = false
        surface.setValue(0.2, for: .machine(.tone))
        #expect(surface.commit() == nil)
        #expect(surface.lastCommitWasRefused && surface.isDirty)
        #expect(surface.lastKept?.id == first.id && surface.keptCount == 1)

        // Trying again with the host back lands the same draft, and the refusal is over.
        host.accepts = true
        let second = try #require(surface.commit())
        #expect(!surface.lastCommitWasRefused && surface.lastKept?.id == second.id && surface.keptCount == 2)
    }

    @Test("a control knows whether it sits on the preset, so the way back is offered only when there is one")
    func atPreset() throws {
        let (surface, _) = SoundFixture.surface("tr808", .kick)
        let decay = try #require(surface.controls(for: .voice).first { $0.parameter == .machine(.decay) })
        #expect(surface.isAtPreset(.machine(.decay)))
        surface.setValue(decay.value == decay.range.upperBound ? decay.range.lowerBound : decay.range.upperBound, for: .machine(.decay))
        #expect(!surface.isAtPreset(.machine(.decay)))
        surface.reset(.machine(.decay))
        #expect(surface.isAtPreset(.machine(.decay)))

        // A chain control's preset is the chain's base preset, whichever was applied last.
        surface.apply(.vinyl)
        #expect(surface.isAtPreset(.chain(.mix)))
        surface.setValue(0.5, for: .chain(.mix))
        #expect(!surface.isAtPreset(.chain(.mix)))
        surface.reset(.chain(.mix))
        #expect(surface.isAtPreset(.chain(.mix)))
        #expect(surface.draft.degrade.matchingPreset == .vinyl, "back to the preset means back to vinyl, not to clean")
    }


    @Test("with nothing selected the surface starts a part instead of editing one")
    func withNothingSelectedItStartsAPart() throws {
        let host = SoundHostStub(selectedPart: nil)
        let surface = SoundSurface(host: host, sampleRate: SoundFixture.sampleRate)
        #expect(surface.draft.machine == "tr808")
        surface.setValue(0.7, for: .machine(.tune))
        let written = try #require(surface.commit())
        #expect(written.parents.isEmpty)
        #expect(written.operation == Operation.written)
    }

    @Test("reverting throws the draft away and reload follows the host's selection")
    func revertAndReload() throws {
        let original = SoundFixture.state("tr808", .kick)
        let host = SoundHostStub(selectedPart: SoundFixture.version(original))
        let surface = SoundSurface(host: host, sampleRate: SoundFixture.sampleRate)
        surface.setValue(0.9, for: .machine(.decay))
        surface.revert()
        #expect(!surface.isDirty)
        #expect(surface.draft == original)

        let other = SoundFixture.state("tr909", .snare)
        host.selectedPart = SoundFixture.version(other)
        surface.reload()
        #expect(surface.draft == other)
        #expect(surface.draft.voice == .snare)
    }

    @Test("switching voice keeps the chain and takes the new voice's own knob positions")
    func switchingVoiceKeepsTheChain() {
        let (surface, _) = SoundFixture.surface("tr808", .kick)
        surface.apply(.vinyl)
        surface.select(.snare)
        #expect(surface.draft.voice == .snare)
        #expect(surface.draft.degrade.matchingPreset == .vinyl, "the chain is not part of the voice")
        #expect(surface.draft.controls == SynthMachine.tr808.spec(for: .snare)?.controls)
    }

    // MARK: Helpers

    private func names(_ machine: String, _ voice: SynthVoiceKind) -> [String] {
        let (surface, _) = SoundFixture.surface(machine, voice)
        return surface.controls(for: .voice).map(\.name)
    }

    private func control(_ machine: String, _ voice: SynthVoiceKind,
                         _ parameter: SoundControl.Parameter) -> SoundControl? {
        let (surface, _) = SoundFixture.surface(machine, voice)
        return surface.controls(for: .voice).first { $0.parameter == parameter }
    }
}
