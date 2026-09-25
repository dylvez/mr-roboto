import Foundation
import Performance
import SongGraph

/// The Master: the last bounce read against the target, and the levers that set the target,
/// the ceiling and the gain before the limiter.
@MainActor
@Observable
public final class MasterModel {

    public struct Reading: Sendable {
        public var observation: MixObservation
        public var truePeakDBTP: Double
        /// The spectrum in dB, 48 log-spaced bars from 40 Hz to 16 kHz.
        public var spectrumDB: [Double]
        public var readings: [PersonaReading]
        /// What was actually bounced and measured — see `Scope`. The numbers are the same kind
        /// either way; what they are the numbers *of* is not, and the surface says which.
        public var scope: Scope
        /// The first reading that does not hold: what to change first.
        public var firstToChange: PersonaReading? { readings.first { !$0.holds } }
    }

    /// How much of the song a reading covers.
    ///
    /// An arranged song is bounced one section at a time, and the Master reads the first — a
    /// whole-song bounce on every lever move is not something to wait for. An unarranged song has
    /// no sections to pick from and bounces whole. A reading of the first section is not the song's
    /// integrated loudness, and calling it that would be the one lie a mastering surface must not
    /// tell, so the scope travels with the reading.
    public enum Scope: Equatable, Sendable {
        case wholeSong
        case firstSection(name: String)

        /// The label beside the numbers: "Whole song" or "First section · Verse".
        public var label: String {
            switch self {
            case .wholeSong: return "Whole song"
            case .firstSection(let name): return "First section · \(name)"
            }
        }
    }

    public let surfaceID: SurfaceID
    public private(set) var mix: Mix
    public private(set) var base: PartVersion?
    public let targets: Master
    public private(set) var reading: Reading?
    public private(set) var isReading = false
    /// True once a lever that changes the bounce has moved since the reading was taken. The
    /// numbers are still shown, dimmed: they were true of a mix that is no longer the one on the
    /// strips.
    public private(set) var isStale = false
    public private(set) var lastError: String?
    public private(set) var lastNote: String?

    private let host: any MixHosting
    private var committed: Mix

    public init(host: any MixHosting, base: PartVersion? = nil, surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.base = base
        let targets = host.targets
        self.targets = targets
        let starting: Mix
        if let base, case .mix(let stored) = base.kind {
            starting = stored
        } else if let planned = host.playback.mix {
            starting = planned
        } else {
            var unity = Mix.unity
            unity.master = Master(gainDB: 0, ceilingDBTP: targets.ceilingDBTP, targetLUFS: targets.targetLUFS)
            starting = unity
        }
        mix = starting
        committed = starting
    }

    public var song: Song? { host.song }

    /// What the next reading will cover. The host bounces a section only when the plan is arranged
    /// (`SongPlayback.isArranged`); otherwise it bounces the whole song whatever it is asked.
    public var scope: Scope {
        guard host.playback.isArranged, let first = host.song?.sections.first else { return .wholeSong }
        return .firstSection(name: first.name)
    }

    /// Bounces the song (or its first section) through the mix and reads it.
    public func read() async {
        isReading = true
        defer { isReading = false }
        do {
            let scope = self.scope
            let section = host.song?.sections.first?.id
            let (planar, rate) = try await host.bounce(mix: mix, section: section)
            let observation = MixObservation.measure(label: host.song?.title ?? "Song", mix: planar, sampleRate: rate)
            let truePeak = MixMeter.truePeakDB(planar, sampleRate: rate)
            let spectrum = Self.logSpectrum(MixMeter.powerSpectrum(planar, sampleRate: rate), sampleRate: rate)
            reading = Reading(observation: observation, truePeakDBTP: truePeak, spectrumDB: spectrum,
                              readings: Engineer().read(observation), scope: scope)
            isStale = false
            lastError = nil
        } catch {
            lastError = "The bounce could not be read: \(error)"
        }
    }

    /// 48 log-spaced bars from 40 Hz to 16 kHz, in dB relative to the loudest bar.
    static func logSpectrum(_ power: [Double], sampleRate: Double, bars: Int = 48) -> [Double] {
        guard power.count > 1 else { return [] }
        let binHz = sampleRate / 2 / Double(power.count - 1)
        var out: [Double] = []
        for i in 0..<bars {
            let low = 40 * pow(16_000 / 40, Double(i) / Double(bars))
            let high = 40 * pow(16_000 / 40, Double(i + 1) / Double(bars))
            var sum = 0.0, n = 0
            var bin = max(1, Int(low / binHz))
            while Double(bin) * binHz < high, bin < power.count { sum += power[bin]; n += 1; bin += 1 }
            out.append(n > 0 ? 10 * log10(sum / Double(n) + 1e-20) : -120)
        }
        let top = out.max() ?? 0
        return out.map { $0 - top }
    }

    /// The gain that would put the last reading on the target.
    public var suggestedGainDB: Double? {
        guard let reading, reading.observation.integratedLUFS.isFinite else { return nil }
        return mix.master.targetLUFS - reading.observation.integratedLUFS + mix.master.gainDB
    }

    // MARK: Levers

    /// The target is what the reading is judged against, not something in the bounce, so moving
    /// it leaves the reading current. The ceiling and the gain change the audio, so they stale it.
    public func setTarget(_ lufs: Double) { mix.master.targetLUFS = max(-30, min(-6, lufs)); host.preview(mix) }
    public func setCeiling(_ dBTP: Double) { move { $0.master.ceilingDBTP = max(-12, min(0, dBTP)) } }
    public func setGain(_ dB: Double) { move { $0.master.gainDB = max(-24, min(24, dB)) } }

    private func move(_ change: (inout Mix) -> Void) {
        let before = mix
        change(&mix)
        if mix != before, reading != nil { isStale = true }
        host.preview(mix)
    }

    /// Applies the suggested gain and keeps it.
    public func hitTheTarget() {
        guard let gain = suggestedGainDB else { return }
        setGain(gain)
        endGesture()
    }

    @discardableResult
    public func endGesture() -> PartVersion? {
        guard mix != committed else { return nil }
        let note = MixerModel.describe(from: committed, to: mix, labels: [:])
        guard let version = host.commit(mix, base: base, note: note) else {
            lastError = "The move could not be kept."
            return nil
        }
        base = version
        committed = mix
        lastNote = note
        return version
    }
}
