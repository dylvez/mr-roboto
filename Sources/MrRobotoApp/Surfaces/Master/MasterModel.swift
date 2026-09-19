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
        /// The first reading that does not hold: what to change first.
        public var firstToChange: PersonaReading? { readings.first { !$0.holds } }
    }

    public let surfaceID: SurfaceID
    public private(set) var mix: Mix
    public private(set) var base: PartVersion?
    public let targets: Master
    public private(set) var reading: Reading?
    public private(set) var isReading = false
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

    /// Bounces the song (or its first section) through the mix and reads it.
    public func read() async {
        isReading = true
        defer { isReading = false }
        do {
            let section = host.song?.sections.first?.id
            let (planar, rate) = try await host.bounce(mix: mix, section: section)
            let observation = MixObservation.measure(label: host.song?.title ?? "Song", mix: planar, sampleRate: rate)
            let truePeak = MixMeter.truePeakDB(planar, sampleRate: rate)
            let spectrum = Self.logSpectrum(MixMeter.powerSpectrum(planar, sampleRate: rate), sampleRate: rate)
            reading = Reading(observation: observation, truePeakDBTP: truePeak, spectrumDB: spectrum, readings: Engineer().read(observation))
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

    public func setTarget(_ lufs: Double) { mix.master.targetLUFS = max(-30, min(-6, lufs)); host.preview(mix) }
    public func setCeiling(_ dBTP: Double) { mix.master.ceilingDBTP = max(-12, min(0, dBTP)); host.preview(mix) }
    public func setGain(_ dB: Double) { mix.master.gainDB = max(-24, min(24, dB)); host.preview(mix) }

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
