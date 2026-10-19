import Accelerate
import Analysis
import Foundation

/// A bounce read stretch by stretch: each section of a whole-song bounce — or of a record, by the
/// sections its analysis heard — in the numbers the whole is read in, off the one buffer.
///
/// Each stretch has its integrated loudness (BS.1770, as `MixMeter` measures the whole, its
/// filters carrying on from the bars before it rather than starting cold at its first sample), its
/// crest, how far its 3-second loudness moves, and its energy in five bands against the whole
/// buffer's. The bands are read against the whole and not against the stretch, so every row is on
/// one scale: a chorus that is fuller stands taller in the bands it fills, a verse with no bass is
/// short in the first, and the whole buffer's own row is its balance — "2–6 kHz 15 dB under the
/// whole mix".
///
/// One K-weighting pass and one STFT over the whole buffer, sliced: nothing is filtered or
/// transformed twice, and nothing is rendered at all — this reads what was already bounced.
public enum SectionMeter {

    /// A stretch of the spectrum, Hz: from `low` up to, not including, `high`.
    public struct Band: Hashable, Sendable {
        public var name: String
        public var low: Double
        public var high: Double
    }

    /// The five bands a balance is read in: the sub and the kick, the body, the middle, the
    /// presence, the air.
    public static let bands: [Band] = [
        Band(name: "20–120", low: 20, high: 120), Band(name: "120–500", low: 120, high: 500),
        Band(name: "500–2k", low: 500, high: 2_000), Band(name: "2k–6k", low: 2_000, high: 6_000),
        Band(name: "6k–16k", low: 6_000, high: 16_000),
    ]

    /// A band with nothing in it reads this, not minus infinity: a number every reader can print.
    public static let floorDB = -90.0

    /// One named stretch of a buffer, in frames.
    public struct Span: Hashable, Sendable {
        public var name: String
        public var frames: Range<Int>

        public init(name: String, frames: Range<Int>) {
            self.name = name
            self.frames = frames
        }
    }

    /// One stretch, read.
    public struct Reading: Hashable, Sendable {
        public var name: String
        public var startSeconds: Double
        public var seconds: Double
        /// Integrated loudness, LUFS, gated as BS.1770 gates it. Nil for silence.
        public var integratedLUFS: Double?
        /// The sample peak over every channel, dBFS. Nil for silence.
        public var peakDBFS: Double?
        /// Sample peak over RMS, dB. Nil for silence.
        public var crestDB: Double?
        /// How far its 3-second loudness moves, LU (`MixMeter.loudnessSpread`). Nil for a stretch
        /// too short to hold two windows, or silent.
        public var spreadLU: Double?
        /// Energy in each of `SectionMeter.bands`, dB against the whole buffer's energy, a second
        /// for a second. Never under `floorDB`.
        public var bandsDB: [Double]
        /// All of its energy against the whole buffer's, dB: 0 for the whole, under 0 for a quiet
        /// stretch. What its bands less this are its own balance.
        public var energyDB: Double

        public init(name: String, startSeconds: Double, seconds: Double, integratedLUFS: Double?, peakDBFS: Double? = nil, crestDB: Double?,
                    spreadLU: Double?, bandsDB: [Double], energyDB: Double) {
            self.name = name
            self.startSeconds = startSeconds
            self.seconds = seconds
            self.integratedLUFS = integratedLUFS
            self.peakDBFS = peakDBFS
            self.crestDB = crestDB
            self.spreadLU = spreadLU
            self.bandsDB = bandsDB
            self.energyDB = energyDB
        }

        /// The stretch's bands against its own energy rather than the whole buffer's: its tone,
        /// whatever its level.
        public var balanceDB: [Double] { bandsDB.map { max(SectionMeter.floorDB, $0 - energyDB) } }
    }

    /// A buffer read whole and stretch by stretch.
    public struct Sheet: Hashable, Sendable {
        public var whole: Reading
        public var sections: [Reading]
        /// Mean power per bin over the whole buffer: `MixMeter.powerSpectrum`'s, from the same STFT,
        /// so the tilt, the top end and the drawn spectrum need not take another.
        public var spectrum: [Double]

        public init(whole: Reading, sections: [Reading], spectrum: [Double]) {
            self.whole = whole
            self.sections = sections
            self.spectrum = spectrum
        }
    }

    /// Reads `planar` whole and in `spans`. Spans are clamped to the buffer; one that falls
    /// outside it entirely is read as empty, not dropped, so the rows stay one for one with the
    /// spans asked for.
    public static func read(_ planar: [[Float]], sampleRate: Double, spans: [Span], name: String = "Whole") -> Sheet {
        let frames = planar.first?.count ?? 0
        let running = MixMeter.weightedRunningSums(planar, sampleRate: sampleRate)
        let power = MixMeter.powerFrames(planar)
        let spectrum = power.map { MixMeter.meanPower($0, frames: 0..<$0.frameCount) } ?? []
        let wholeTotal = spectrum.reduce(0, +)
        func reading(_ name: String, _ range: Range<Int>, spectrum mean: [Double]?) -> Reading {
            let range = range.clamped(to: 0..<frames)
            let lufs = range.isEmpty ? -.infinity : MixMeter.integratedLoudness(running: running, frames: range, sampleRate: sampleRate)
            let spread = MixMeter.loudnessSpread(MixMeter.shortTermLoudness(running: running, frames: range, sampleRate: sampleRate))
            let (bands, energy) = bandLevels(mean, against: wholeTotal, sampleRate: sampleRate)
            let (peak, crest) = peakAndCrest(planar, frames: range)
            return Reading(name: name, startSeconds: sampleRate > 0 ? Double(range.lowerBound) / sampleRate : 0,
                           seconds: sampleRate > 0 ? Double(range.count) / sampleRate : 0,
                           integratedLUFS: lufs.isFinite ? lufs : nil, peakDBFS: peak, crestDB: crest,
                           spreadLU: spread, bandsDB: bands, energyDB: energy)
        }
        let rows = spans.map { span -> Reading in
            let mean = power.flatMap { power in centred(span.frames.clamped(to: 0..<frames)).map { MixMeter.meanPower(power, frames: $0) } }
            return reading(span.name, span.frames, spectrum: mean)
        }
        return Sheet(whole: reading(name, 0..<frames, spectrum: spectrum), sections: rows, spectrum: spectrum)
    }

    /// The STFT frames that belong to a stretch. Frame t's window runs from t × hop less half a
    /// window to t × hop plus half: the frames whose whole window lies inside the stretch, so
    /// nothing of the section either side bleeds into its bands — or, for a stretch shorter than a
    /// window, the frames centred in it. Nil when none is.
    static func centred(_ frames: Range<Int>) -> Range<Int>? {
        let hop = MixMeter.spectrumHop, half = MixMeter.spectrumFFT / 2
        guard !frames.isEmpty else { return nil }
        if frames.upperBound - half >= 0 {
            let first = (frames.lowerBound + half + hop - 1) / hop, last = (frames.upperBound - half) / hop
            if first <= last { return first..<(last + 1) }
        }
        let first = (frames.lowerBound + hop - 1) / hop, last = (frames.upperBound - 1) / hop
        return first <= last ? first..<(last + 1) : nil
    }

    /// Each band's share of a mean power spectrum, and all of it, in dB against `total` — the whole
    /// buffer's mean power summed over every bin.
    static func bandLevels(_ mean: [Double]?, against total: Double, sampleRate: Double) -> ([Double], Double) {
        guard let mean, mean.count > 1, total > 0, sampleRate > 0 else { return ([Double](repeating: floorDB, count: bands.count), floorDB) }
        let binHz = sampleRate / Double(2 * (mean.count - 1))
        func dB(_ x: Double) -> Double { x > 0 ? max(floorDB, 10 * log10(x / total)) : floorDB }
        let levels = bands.map { band -> Double in
            var sum = 0.0
            for (bin, p) in mean.enumerated() {
                let hz = Double(bin) * binHz
                if hz >= band.low && hz < band.high { sum += p }
            }
            return dB(sum)
        }
        return (levels, dB(mean.reduce(0, +)))
    }

    /// The sample peak across every channel, dBFS, and the peak over the RMS, dB, for the frames
    /// `frames`. Nil and nil for silence.
    static func peakAndCrest(_ planar: [[Float]], frames: Range<Int>) -> (peakDBFS: Double?, crestDB: Double?) {
        var peak: Float = 0
        var squares = 0.0
        var count = 0
        for lane in planar {
            let range = frames.clamped(to: 0..<lane.count)
            guard !range.isEmpty else { continue }
            lane.withUnsafeBufferPointer { buffer in
                let base = buffer.baseAddress! + range.lowerBound
                var lanePeak: Float = 0
                vDSP_maxmgv(base, 1, &lanePeak, vDSP_Length(range.count))
                var sum: Float = 0
                vDSP_svesq(base, 1, &sum, vDSP_Length(range.count))
                peak = max(peak, lanePeak)
                squares += Double(sum)
            }
            count += range.count
        }
        guard count > 0, peak > 0, squares > 0 else { return (nil, nil) }
        let peakDB = 20 * log10(Double(peak))
        return (peakDB, peakDB - 10 * log10(squares / Double(count)))
    }
}
