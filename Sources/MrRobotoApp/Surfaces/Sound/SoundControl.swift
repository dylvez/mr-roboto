import Foundation
import Instrument

/// One control on the Sound surface: its machine name, what it is really wired to when the name
/// would mislead, its position, and — quietly — what it is doing in a unit you can check against a
/// real machine by ear.
///
/// A control only exists here if turning it changes the sound of *this* voice. That is the whole
/// selection rule, and it is why an 808 kick has four and a 909 kick has five.
public struct SoundControl: Identifiable, Hashable, Sendable {

    /// Which parameter this control moves.
    public enum Parameter: Hashable, Sendable {
        case machine(MachineControl)
        case chain(ChainControl)
    }

    /// The six machine knobs, by the names on the front panel.
    public enum MachineControl: String, Hashable, Sendable, CaseIterable {
        case tune, decay, tone, snappy, attack, level
        public var panelName: String { rawValue.uppercased() }
    }

    /// The chain's parameters. Nine, matching the stages in `CDegrade.h`; `wow` and `flutter` carry
    /// their rate in the readout rather than as a control of their own, because a deck's rates are
    /// a property of the transport and its depth is the thing you reach for.
    public enum ChainControl: String, Hashable, Sendable, CaseIterable {
        case bitDepth, sampleRate, drive, wow, flutter, noise, crackle, highCut, mix

        public var panelName: String {
            switch self {
            case .bitDepth: "BIT DEPTH"
            case .sampleRate: "RATE"
            case .drive: "DRIVE"
            case .wow: "WOW"
            case .flutter: "FLUTTER"
            case .noise: "NOISE"
            case .crackle: "CRACKLE"
            case .highCut: "HIGH CUT"
            case .mix: "MIX"
            }
        }
    }

    public var parameter: Parameter
    /// What the machine calls it: `"TUNE"`, `"BIT DEPTH"`.
    public var name: String
    /// What it is really wired to, when the name alone would lie. `nil` when the name is honest.
    public var honestly: String?
    public var value: Double
    /// The range the surface drives it over. Machine knobs are 0…1 knob positions; chain parameters
    /// are in their own units, because that is what they mean.
    public var range: ClosedRange<Double>
    /// The value in a unit you can measure: `"49 Hz"`, `"900 ms"`, `"12.0 bits"`.
    public var readout: String
    /// At most two of these per panel — the M1 spec's rule, asserted in the tests.
    public var isProminent: Bool

    public var id: Parameter { parameter }

    init(_ parameter: Parameter, name: String, honestly: String? = nil,
         value: Double, range: ClosedRange<Double>, readout: String, isProminent: Bool = false) {
        self.parameter = parameter
        self.name = name
        self.honestly = honestly
        self.value = value
        self.range = range
        self.readout = readout
        self.isProminent = isProminent
    }
}

// MARK: - The voice's controls

public extension SoundControl {

    /// The controls this voice actually has.
    ///
    /// Each rule is a fact about `DrumSynthesizer`, not a taste:
    ///
    /// * **TUNE** exists when the knob moves either the pitch (`tuneSemitones > 0`) or the
    ///   pitch-envelope's length (`pitchEnvelopeShortestSeconds`/`LongestSeconds`). The TR-909's
    ///   bass drum is the second kind — VR2 sets how long the drop takes, not where the drum ends
    ///   up — so it is labelled as what it is rather than as "pitch".
    /// * **DECAY** exists when the voice's decay triple actually spans a range.
    /// * **TONE** exists when it is wired to something: the output low-pass with two different
    ///   corners, the balance of the two rings (808 snare), or the noise's length (909 snare).
    /// * **SNAPPY** exists only on `dualToneNoise` voices with noise, because that is the only
    ///   engine that reads `controls.snappy` — on a snare it raises the noise without cutting the
    ///   tone, exactly as Roland describes VR9.
    /// * **ATTACK** exists only where the click is a separate circuit summed *after* the voice's
    ///   filter (`click.postFilter`), which is the TR-909 bass drum and nothing else. The 808's
    ///   trigger leaks through the bridged-T and out through TONE; it has no ATTACK knob, so there
    ///   is no ATTACK control here.
    /// * **LEVEL** is the channel fader and is always there.
    ///
    /// Prominence: DECAY always — it is the one knob that changes what the drum *is* — plus one
    /// more, the most characterful the voice has: ATTACK on a 909 kick, SNAPPY on a snare, TUNE on
    /// anything tuned, TONE otherwise.
    static func voiceControls(for spec: SynthVoiceSpec) -> [SoundControl] {
        let c = spec.controls
        let hasTonePath = spec.tone.level > 0 && spec.engine != .burstNoise && spec.engine != .filteredNoise
        var controls: [SoundControl] = []

        let movesPitch = hasTonePath && spec.tone.tuneSemitones > 0
        let movesSweep = spec.tone.pitchEnvelopeShortestSeconds > 0
            && spec.tone.pitchEnvelopeLongestSeconds > 0
        if movesPitch || movesSweep {
            controls.append(SoundControl(
                .machine(.tune),
                name: MachineControl.tune.panelName,
                honestly: movesPitch ? nil : "sets the pitch sweep's length, not the pitch",
                value: c.tune, range: 0...1,
                readout: movesPitch
                    ? SoundUnit.hertz(spec.tone.frequency(tune: c.tune))
                    : "\(SoundUnit.time(spec.tone.pitchEnvelope(tune: c.tune))) sweep"))
        }

        let toneSpans = spec.tone.decayShortestSeconds != spec.tone.decayLongestSeconds
        let noiseSpans = spec.noise.decayShortestSeconds != spec.noise.decayLongestSeconds
        if (hasTonePath && toneSpans) || (spec.noise.level > 0 && noiseSpans) {
            controls.append(SoundControl(
                .machine(.decay),
                name: MachineControl.decay.panelName,
                value: c.decay, range: 0...1,
                readout: SoundUnit.time(hasTonePath
                    ? spec.tone.decaySeconds(decay: c.decay)
                    : spec.noise.decaySeconds(decay: c.decay))))
        }

        if let tone = toneControl(for: spec) { controls.append(tone) }

        if spec.engine == .dualToneNoise, spec.noise.level > 0 {
            // `addNoise` scales the noise channel by `noise.level * 2 * snappy`, so the detent is
            // the preset's own noise level and the knob reads as dB against it.
            controls.append(SoundControl(
                .machine(.snappy),
                name: MachineControl.snappy.panelName,
                honestly: "raises the noise; it does not cut the tone",
                value: c.snappy, range: 0...1,
                readout: "noise \(SoundUnit.decibels(2 * max(c.snappy, 0), signed: true))"))
        }

        if spec.click.level > 0, spec.click.postFilter {
            controls.append(SoundControl(
                .machine(.attack),
                name: MachineControl.attack.panelName,
                honestly: "level of a separate click circuit, not a VCA attack time",
                value: c.attack, range: 0...1,
                readout: "click \(SoundUnit.decibels(max(c.attack, 0), signed: true))"))
        }

        controls.append(SoundControl(
            .machine(.level),
            name: MachineControl.level.panelName,
            value: c.level, range: 0...1.5,
            readout: SoundUnit.decibels(c.level, signed: true)))

        return promoting(preferred(for: spec), in: controls)
    }

    private static func toneControl(for spec: SynthVoiceSpec) -> SoundControl? {
        let tone = spec.controls.tone
        switch spec.toneControl {
        case .outputLowPass:
            guard spec.output.toneDarkHz != spec.output.toneBrightHz else { return nil }
            return SoundControl(
                .machine(.tone), name: MachineControl.tone.panelName,
                value: tone, range: 0...1,
                readout: SoundUnit.hertz(spec.output.toneHz(tone)) + " low-pass")
        case .oscillatorBalance:
            return SoundControl(
                .machine(.tone), name: MachineControl.tone.panelName,
                honestly: "balances the two rings against each other",
                value: tone, range: 0...1,
                readout: "\(SoundUnit.percent(tone, decimals: 0)) upper ring")
        case .noiseDecay:
            // `render` stretches the noise envelope by 0.35…2.0 across the knob.
            let length = spec.noise.decaySeconds(decay: spec.controls.decay)
                * (0.35 + 1.65 * min(max(tone, 0), 1))
            return SoundControl(
                .machine(.tone), name: MachineControl.tone.panelName,
                honestly: "sets the noise's length; it is not a filter",
                value: tone, range: 0...1,
                readout: "\(SoundUnit.time(length)) noise")
        }
    }

    /// The second prominent lever, after DECAY.
    private static func preferred(for spec: SynthVoiceSpec) -> [MachineControl] {
        var order: [MachineControl] = [.decay]
        if spec.click.level > 0, spec.click.postFilter { order.append(.attack) }
        else if spec.engine == .dualToneNoise, spec.noise.level > 0 { order.append(.snappy) }
        else { order.append(contentsOf: [.tune, .tone]) }
        return order
    }

    private static func promoting(_ order: [MachineControl],
                                  in controls: [SoundControl]) -> [SoundControl] {
        var controls = controls
        var promoted = 0
        for wanted in order where promoted < 2 {
            guard let i = controls.firstIndex(where: { $0.parameter == .machine(wanted) }) else { continue }
            controls[i].isProminent = true
            promoted += 1
        }
        return controls
    }
}

// MARK: - The chain's controls

public extension SoundControl {

    /// The degradation chain, in signal order: converter, saturation, transport, medium, output.
    ///
    /// Prominence: MIX, which is how much of any of this you are getting, plus whichever stage this
    /// chain is actually built out of — the quantiser on an SP-1200 or MPC60, the drive on a radio,
    /// the wow on a cassette or a record. A chain with nothing turned on promotes the high cut, so
    /// there is always somewhere to start.
    static func chainControls(for settings: DegradeSettings) -> [SoundControl] {
        let quantising = settings.bitDepth < DegradeSettings.bitDepthOff
        var controls: [SoundControl] = [
            SoundControl(
                .chain(.bitDepth), name: ChainControl.bitDepth.panelName,
                honestly: settings.companding > 0 ? "companded: the noise floor follows the signal" : nil,
                value: settings.bitDepth, range: 4...DegradeSettings.bitDepthOff,
                readout: quantising ? String(format: "%.1f bits", settings.bitDepth) : "off"),
            SoundControl(
                .chain(.sampleRate), name: ChainControl.sampleRate.panelName,
                honestly: settings.targetSampleRate > 0 && settings.antiAliasing == .none
                    ? "unfiltered: everything above Nyquist folds back in" : nil,
                value: settings.targetSampleRate, range: 4_000...48_000,
                readout: settings.targetSampleRate > 0
                    ? SoundUnit.hertz(settings.targetSampleRate) : "off"),
            SoundControl(
                .chain(.drive), name: ChainControl.drive.panelName,
                honestly: "normalised at the origin, so it compresses and never adds level",
                value: settings.drive, range: 1...4,
                // Deliberately not in dB: `drive` is the gain *into* the curve, and the curve is
                // normalised at the origin, so the output never rises with it. A dB readout here
                // would say the opposite of what the stage does.
                readout: "\(SoundUnit.times(settings.drive)) into \(settings.saturation.rawValue)"),
            SoundControl(
                .chain(.wow), name: ChainControl.wow.panelName,
                value: settings.wowDepth, range: 0...0.01,
                readout: settings.wowDepth > 0
                    ? "\(SoundUnit.percent(settings.wowDepth, decimals: 2)) at \(SoundUnit.rate(settings.wowRate))"
                    : "off"),
            SoundControl(
                .chain(.flutter), name: ChainControl.flutter.panelName,
                value: settings.flutterDepth, range: 0...0.005,
                readout: settings.flutterDepth > 0
                    ? "\(SoundUnit.percent(settings.flutterDepth, decimals: 3)) at \(SoundUnit.rate(settings.flutterRate))"
                    : "off"),
            SoundControl(
                .chain(.noise), name: ChainControl.noise.panelName,
                value: settings.noiseLevel, range: 0...0.01,
                readout: settings.noiseLevel > 0
                    ? "\(SoundUnit.decibels(settings.noiseLevel, signed: true))FS" : "off"),
            SoundControl(
                .chain(.crackle), name: ChainControl.crackle.panelName,
                value: settings.crackleDensity, range: 0...40,
                readout: settings.crackleDensity > 0
                    ? String(format: "%.0f ticks/s", settings.crackleDensity) : "off"),
            SoundControl(
                .chain(.highCut), name: ChainControl.highCut.panelName,
                value: settings.highCut, range: 0...20_000,
                readout: settings.highCut > 0 ? SoundUnit.hertz(settings.highCut) : "off"),
            SoundControl(
                .chain(.mix), name: ChainControl.mix.panelName,
                value: settings.mix, range: 0...1,
                readout: "\(SoundUnit.percent(settings.mix, decimals: 0)) wet"),
        ]

        let second: ChainControl = quantising ? .bitDepth
            : settings.drive > 1 ? .drive
            : settings.wowDepth > 0 ? .wow
            : .highCut
        for wanted in [ChainControl.mix, second] {
            if let i = controls.firstIndex(where: { $0.parameter == .chain(wanted) }) {
                controls[i].isProminent = true
            }
        }
        return controls
    }
}

// MARK: - Real units

/// The quiet readouts. Every one of these is a unit you can check against a real machine by ear or
/// with a tuner, which is the point: the knob positions are ours, the numbers are the hardware's.
enum SoundUnit {

    /// `"49.4 Hz"`, `"890 Hz"`, `"12 kHz"`, `"26.04 kHz"`.
    ///
    /// Trailing zeros are trimmed rather than padded, because the figures that matter here are
    /// quoted the way the machine's own spec quotes them: the SP-1200's rate is 26.04 kHz and
    /// rounding it to 26.0 loses the thing you would be checking.
    static func hertz(_ hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return "0 Hz" }
        if hz < 1_000 { return String(format: hz < 100 ? "%.1f Hz" : "%.0f Hz", hz) }
        return "\(trimmed(hz / 1_000, decimals: 2)) kHz"
    }

    /// `12.00` → `"12"`, `26.04` → `"26.04"`, `4.50` → `"4.5"`.
    private static func trimmed(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `"6.0 ms"`, `"900 ms"`, `"1.60 s"`.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 ms" }
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        let ms = seconds * 1_000
        return String(format: ms < 10 ? "%.1f ms" : "%.0f ms", ms)
    }

    /// A linear gain as dB, where 1.0 is the preset's own level. `"+6.0 dB"`, `"-1.6 dB"`.
    static func decibels(_ gain: Double, signed: Bool) -> String {
        guard gain > 0, gain.isFinite else { return "off" }
        let dB = 20 * log10(gain)
        if abs(dB) < 0.05 { return "0.0 dB" }
        return String(format: signed ? "%+.1f dB" : "%.1f dB", dB)
    }

    /// A fraction as a percentage: `"0.12 %"`, `"100 %"`.
    static func percent(_ fraction: Double, decimals: Int) -> String {
        String(format: "%.\(max(0, decimals))f %%", fraction * 100)
    }

    /// A multiplier: `"1.4x"`, `"3x"`.
    static func times(_ value: Double) -> String {
        "\(trimmed(value, decimals: 2))x"
    }

    /// An oscillator rate: `"0.90 Hz"`, `"7.5 Hz"`.
    static func rate(_ hz: Double) -> String {
        String(format: hz < 1 ? "%.2f Hz" : "%.1f Hz", hz)
    }
}
