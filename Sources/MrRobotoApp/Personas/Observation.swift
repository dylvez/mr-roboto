import Analysis
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// What a persona is actually handed.
//
// A persona does not read audio and it does not read prose. It reads a small value made of numbers
// the engines already produce, which is what keeps the whole cast testable without a model and
// without an audio device: `GrooveObservation(of: feel)` is arithmetic, and so is every rule that
// fires off it.
//
// Both observation types are built by *reading* engine values, never by asking the engine to do
// anything. Nothing here renders, plays, decodes or allocates a buffer.

// MARK: - Groove

/// Everything the Beatmaker measures about a groove, in the units its rules are written in.
///
/// Milliseconds rather than fractions of a step, deliberately. `VoiceFeel.timingOffset` is stored as
/// a fraction so a feel keeps its character across tempos — that is right for the engine and wrong
/// for a rule, because the ear's tolerance for a displaced snare does not scale with tempo either.
/// The conversion happens exactly once, here.
public struct GrooveObservation: Hashable, Sendable {

    /// What it was measured from, for a finding that has to name it.
    public var label: String
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var stepsPerBar: Int
    public var bars: Int

    /// MPC percent: 50 straight, 66.67 triplet, 75 the machines' maximum.
    public var swingPercent: Double
    /// Per-voice swing overrides, in percent. A voice absent from here rides the groove's own.
    public var voiceSwingPercent: [DrumVoice: Double]
    /// Per-voice constant displacement in milliseconds, positive = late.
    public var voiceLagMS: [DrumVoice: Double]
    /// Seeded timing jitter at its widest, in milliseconds, off the beat.
    public var humanizeTimingMS: Double
    /// Velocity jitter at its widest, in MIDI units.
    public var humanizeVelocity: Double

    public var velocities: VelocityMap
    /// Sounding steps at the ghost tier over all sounding steps, 0…1.
    public var ghostRatio: Double
    /// Sounding steps per voice, by tier.
    public var hits: [DrumVoice: [VelocityTier: Int]]

    /// Voices that sound at all.
    public var voices: [DrumVoice]

    // MARK: Derived

    /// Steps per beat: 4 for sixteenths in 4/4, 8 for thirty-seconds.
    public var subdivision: Double {
        Double(stepsPerBar) / Double(max(1, timeSignature.beatsPerBar))
    }

    /// One step in milliseconds at this tempo and subdivision.
    public var stepMS: Double {
        guard tempo > 0 else { return 0 }
        return 60_000 / tempo / max(1, subdivision)
    }

    /// How far apart the earliest and the latest voice sit, in milliseconds. This number *is* the
    /// drunk feel: one voice moving is a late snare; three voices moving by different amounts is a
    /// bar that leans.
    public var pocketSpreadMS: Double {
        let lags = voices.map { voiceLagMS[$0] ?? 0 }
        guard let low = lags.min(), let high = lags.max() else { return 0 }
        return high - low
    }

    public func lagMS(_ voice: DrumVoice) -> Double { voiceLagMS[voice] ?? 0 }

    /// Swing this voice actually plays, in percent.
    public func swingPercent(_ voice: DrumVoice) -> Double {
        voiceSwingPercent[voice] ?? swingPercent
    }

    /// How far the ghost tier sits under the normal tier, in dB. The ear reads velocity as level,
    /// so dB is the honest unit for "how quiet is a ghost note".
    public var ghostDepthDB: Double {
        let ghost = Double(max(1, velocities.ghost))
        let normal = Double(max(1, velocities.normal))
        return 20 * log10(normal / ghost)
    }

    /// Sounding steps on beats 2 and 4, across the voices that carry a backbeat.
    public var backbeatCount: Int { backbeats }
    private var backbeats: Int = 0

    /// A reading of one feature, in the unit the bible's thresholds use.
    public func value(of feature: Feature) -> Double? {
        switch feature {
        case .swingPercent: return swingPercent
        case .snareLagMS: return lagMS(.snare)
        case .hatLagMS: return lagMS(.closedHat)
        case .kickLagMS: return lagMS(.kick)
        case .pocketSpreadMS: return pocketSpreadMS
        case .ghostRatio: return ghostRatio
        case .ghostDepthDB: return ghostDepthDB
        case .humanizeTimingMS: return humanizeTimingMS
        case .tempoBPM: return tempo
        case .subdivision: return subdivision
        case .backbeatCount: return Double(backbeatCount)
        default: return nil
        }
    }

    // MARK: Construction

    /// Read a groove and its render options. Nothing is rendered: every number below comes out of
    /// the values themselves.
    public init(label: String, groove: Groove, options: GrooveRenderOptions,
                tempo: Double, timeSignature: TimeSignature = .fourFour) {
        self.label = label
        self.tempo = tempo
        self.timeSignature = timeSignature
        stepsPerBar = max(1, groove.stepsPerBar)
        bars = max(1, groove.bars)
        swingPercent = (options.swing ?? Swing(factor: groove.swing)).percent
        velocities = options.velocities

        let beats = max(1, timeSignature.beatsPerBar)
        let perBeat = Double(stepsPerBar) / Double(beats)
        let step = tempo > 0 ? 60_000 / tempo / max(1, perBeat) : 0

        var swings: [DrumVoice: Double] = [:]
        var lags: [DrumVoice: Double] = [:]
        for (voice, feel) in options.voices {
            if let voiceSwing = feel.swing { swings[voice] = voiceSwing.percent }
            if feel.timingOffset != 0 { lags[voice] = feel.timingOffset * step }
        }
        voiceSwingPercent = swings
        voiceLagMS = lags

        humanizeTimingMS = options.humanize.timing * step
        humanizeVelocity = options.humanize.velocity * 127

        var tally: [DrumVoice: [VelocityTier: Int]] = [:]
        var sounding = 0
        var ghosts = 0
        var backbeatHits = 0
        // Beats 2 and 4 of each bar, as step indices. A backbeat is a *position*, so this is the
        // same arithmetic whatever subdivision the groove is written on.
        let barCount = bars
        let perBar = stepsPerBar
        var backbeatSteps: Set<Int> = []
        if beats >= 4 {
            for bar in 0..<barCount {
                for beat in [1, 3] {
                    backbeatSteps.insert(bar * perBar + Int((Double(beat) * perBeat).rounded()))
                }
            }
        }
        let backbeatVoices: Set<DrumVoice> = [.snare, .clap, .rim]

        for pattern in groove.patterns {
            var perTier: [VelocityTier: Int] = [:]
            for (index, tier) in pattern.steps.enumerated() where tier != .rest {
                perTier[tier, default: 0] += 1
                sounding += 1
                if tier == .ghost { ghosts += 1 }
                if backbeatVoices.contains(pattern.voice), backbeatSteps.contains(index),
                   tier != .ghost {
                    backbeatHits += 1
                }
            }
            if !perTier.isEmpty { tally[pattern.voice] = perTier }
        }
        hits = tally
        voices = groove.patterns.filter { tally[$0.voice] != nil }.map(\.voice)
        ghostRatio = sounding > 0 ? Double(ghosts) / Double(sounding) : 0
        backbeats = backbeatHits
    }

    /// Read a feel: its groove, its own options, its own suggested tempo.
    public init(_ feel: Feel, tempo: Double? = nil) {
        self.init(label: feel.name, groove: feel.groove, options: .feel(feel),
                  tempo: tempo ?? feel.suggestedTempo, timeSignature: feel.timeSignature)
    }
}

// MARK: - Source

/// Everything the Sampler measures about a chopped source and the chain over it.
///
/// Built from a `Chop`, its classifications, and — for the two spectral features — a measurement
/// the caller made with `SourceMeasurement`. Nothing here holds audio: an observation is a handful
/// of doubles that survives being put in a finding, a version note or a test expectation.
public struct SourceObservation: Equatable, Sendable {

    public var label: String
    public var sampleRate: Double
    /// Source length in seconds.
    public var duration: Double
    /// The tempo the chop was cut at, when the caller knew it.
    public var tempo: Double?
    public var sliceCount: Int

    /// Peak level of each slice in dBFS, by slice index. `-infinity` for silence.
    public var slicePeakDB: [Int: Double]
    /// What each slice was called.
    public var sliceClass: [Int: SliceClass]
    /// Spectral centroid of each slice's attack, in Hz.
    public var sliceCentroid: [Int: Double]
    /// Slice start times in seconds from frame 0 of the source.
    public var sliceStart: [Int: Double]
    /// How far each start moved when it snapped; positive means it moved *later*, which is the
    /// direction that shaves an attack.
    public var sliceSnapOffset: [Int: Double]
    public var sliceOrigin: [Int: SliceOrigin]

    /// Frequency below which 95% of the source's energy sits, in Hz. Nil when nobody measured it.
    public var bandwidthHz: Double?
    /// The source's own noise floor in dBFS, when measured.
    public var noiseFloorDB: Double?

    /// The chain currently over the source, if any.
    public var degrade: DegradeSettings?
    /// Chains the source has *already* been through — an import from a 12-bit sampler, a stem
    /// bounced through the tape preset. What makes "leave it alone" a checkable rule.
    public var priorDegrades: [String]

    public init(label: String, sampleRate: Double, duration: Double, tempo: Double? = nil,
                sliceCount: Int, slicePeakDB: [Int: Double] = [:],
                sliceClass: [Int: SliceClass] = [:], sliceCentroid: [Int: Double] = [:],
                sliceStart: [Int: Double] = [:], sliceSnapOffset: [Int: Double] = [:],
                sliceOrigin: [Int: SliceOrigin] = [:],
                bandwidthHz: Double? = nil, noiseFloorDB: Double? = nil,
                degrade: DegradeSettings? = nil, priorDegrades: [String] = []) {
        self.label = label
        self.sampleRate = sampleRate
        self.duration = duration
        self.tempo = tempo
        self.sliceCount = sliceCount
        self.slicePeakDB = slicePeakDB
        self.sliceClass = sliceClass
        self.sliceCentroid = sliceCentroid
        self.sliceStart = sliceStart
        self.sliceSnapOffset = sliceSnapOffset
        self.sliceOrigin = sliceOrigin
        self.bandwidthHz = bandwidthHz
        self.noiseFloorDB = noiseFloorDB
        self.degrade = degrade
        self.priorDegrades = priorDegrades
    }

    /// Read a chop and its classifications.
    public init(label: String, chop: Chop, classifications: [SliceClassification] = [],
                bandwidthHz: Double? = nil, noiseFloorDB: Double? = nil,
                degrade: DegradeSettings? = nil, priorDegrades: [String] = []) {
        var peaks: [Int: Double] = [:]
        var starts: [Int: Double] = [:]
        var snaps: [Int: Double] = [:]
        var origins: [Int: SliceOrigin] = [:]
        for slice in chop.slices {
            peaks[slice.index] = slice.peakDB
            starts[slice.index] = slice.startSeconds
            snaps[slice.index] = slice.snapOffset
            origins[slice.index] = slice.origin
        }
        var kinds: [Int: SliceClass] = [:]
        var centroids: [Int: Double] = [:]
        for classification in classifications {
            kinds[classification.sliceIndex] = classification.kind
            centroids[classification.sliceIndex] = classification.centroid
        }
        self.init(label: label, sampleRate: chop.sampleRate, duration: chop.duration,
                  tempo: chop.detectedTempo, sliceCount: chop.count,
                  slicePeakDB: peaks, sliceClass: kinds, sliceCentroid: centroids,
                  sliceStart: starts, sliceSnapOffset: snaps, sliceOrigin: origins,
                  bandwidthHz: bandwidthHz, noiseFloorDB: noiseFloorDB,
                  degrade: degrade, priorDegrades: priorDegrades)
    }

    // MARK: Derived

    /// Slices per bar, when the tempo is known. Four beats to the bar.
    public var slicesPerBar: Double? {
        guard let tempo, tempo > 0, duration > 0 else { return nil }
        let bars = duration / (4 * 60 / tempo)
        return bars > 0 ? Double(sliceCount) / bars : nil
    }

    /// The worst attack-shave in the chop, in milliseconds: how far the latest-moved cut sits
    /// after the transient it was taken from.
    public var attackShaveMS: Double {
        (sliceSnapOffset.values.filter { $0 > 0 }.max() ?? 0) * 1000
    }

    /// How far, on average, a snapped start moved — the chop's overall obedience to the grid.
    public var gridDeviationMS: Double {
        let moved = sliceSnapOffset.values.filter { $0 != 0 }
        guard !moved.isEmpty else { return 0 }
        return moved.reduce(0) { $0 + abs($1) } / Double(moved.count) * 1000
    }

    /// Peak level of the quietest sounding slice, in dBFS.
    public var sliceFloorDB: Double {
        slicePeakDB.values.filter { $0.isFinite }.min() ?? 0
    }

    /// Loudest minus quietest, in dB, within one class. The number that decides whether a rotating
    /// policy will produce a groove or a groove that ducks every other bar.
    public func spreadDB(of kind: SliceClass) -> Double {
        let levels = sliceClass.filter { $0.value == kind }
            .compactMap { slicePeakDB[$0.key] }
            .filter { $0.isFinite }
        guard let low = levels.min(), let high = levels.max() else { return 0 }
        return high - low
    }

    /// The widest spread across all three classes.
    public var sliceSpreadDB: Double {
        SliceClass.allCases.map(spreadDB(of:)).max() ?? 0
    }

    public func value(of feature: Feature) -> Double? {
        switch feature {
        case .sliceDensity: return slicesPerBar
        case .attackShaveMS: return attackShaveMS
        case .gridDeviationMS: return gridDeviationMS
        case .bitDepth: return degrade?.bitDepth
        case .holdRateHz: return degrade?.targetSampleRate
        case .bandwidthHz: return bandwidthHz
        case .sliceFloorDB: return sliceFloorDB
        case .sliceSpreadDB: return sliceSpreadDB
        case .wowPercent: return degrade.map { $0.wowDepth * 100 }
        case .crackleDensity: return degrade?.crackleDensity
        case .drive: return degrade?.drive
        case .tempoBPM: return tempo
        default: return nil
        }
    }
}

// MARK: - Measuring a source

/// The two spectral numbers a `SourceObservation` cannot derive from a `Chop` alone.
///
/// Separate from the observation because they are the only part of the Sampler's reading that costs
/// a transform, and because a caller that already has them (from `Analysis`, from a cached import)
/// should not pay again. Both are built on the same `STFT` the `SliceClassifier` uses, so a centroid
/// and a rolloff measured on the same buffer agree about what the spectrum is.
public enum SourceMeasurement {

    /// Frequency below which `fraction` of the magnitude sits, in Hz — the spectral rolloff.
    ///
    /// This is the number that decides whether a degradation preset has anything left to remove. A
    /// source whose 95% rolloff is already at 9 kHz will not be made darker by a 14 kHz corner; all
    /// that corner can add is the preset's own noise bed, which is the Sampler's "leave it alone"
    /// rule in one measurement.
    public static func rolloff(_ signal: [Float], sampleRate: Double, fraction: Double = 0.95,
                               nFFT: Int = 2048, hop: Int = 512) -> Double {
        guard sampleRate > 0, !signal.isEmpty else { return 0 }
        var window = signal
        if window.count <= nFFT {
            window += [Float](repeating: 0, count: nFFT + 1 - window.count)
        }
        let magnitude = STFT(nFFT: nFFT, hop: hop).forward(window).magnitude()
        let bins = magnitude.binCount
        guard bins > 1, magnitude.frameCount > 0 else { return 0 }
        var perBin = [Double](repeating: 0, count: bins)
        var total = 0.0
        for frame in 0..<magnitude.frameCount {
            for bin in 0..<bins {
                let m = Double(magnitude[frame, bin])
                perBin[bin] += m
                total += m
            }
        }
        guard total > 0 else { return 0 }
        let target = total * min(1, max(0, fraction))
        var running = 0.0
        let binHz = sampleRate / Double(nFFT)
        for bin in 0..<bins {
            running += perBin[bin]
            if running >= target { return Double(bin) * binHz }
        }
        return Double(bins - 1) * binHz
    }

    /// The signal's own noise floor in dBFS: the 10th percentile of block RMS, which on real
    /// material is the quietest thing that is still the recording rather than the quietest thing
    /// that is a gap between drums.
    public static func noiseFloorDB(_ signal: [Float], sampleRate: Double,
                                    block: Double = 0.02, percentile: Double = 0.1) -> Double {
        guard sampleRate > 0, !signal.isEmpty else { return -.infinity }
        let frames = max(1, Int((block * sampleRate).rounded()))
        var levels: [Double] = []
        var i = 0
        while i < signal.count {
            let end = min(i + frames, signal.count)
            var sum = 0.0
            for j in i..<end { sum += Double(signal[j]) * Double(signal[j]) }
            levels.append((sum / Double(end - i)).squareRoot())
            i = end
        }
        levels.sort()
        guard !levels.isEmpty else { return -.infinity }
        let index = min(levels.count - 1, max(0, Int(Double(levels.count - 1) * percentile)))
        let rms = levels[index]
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }
}
