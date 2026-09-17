import Analysis
import Foundation

/// What a slice sounds like it is, in the only three categories a feel actually needs.
///
/// Three, not twelve, because a feel is written in kick/snare/hat and a chop has to be mapped onto
/// it. A tom, a rim and a clap are all "the backbeat one" as far as placing them on a groove goes;
/// the pad map keeps the real sound, this only decides where it lands.
public enum SliceClass: String, Hashable, Sendable, Codable, CaseIterable {
    case kick, snare, hat
}

/// How well a slice matched each class. Exposed so a UI can show *why* a slice was called a hat,
/// and so a persona can reason about a marginal one instead of being handed a bare label.
public struct ClassScores: Hashable, Sendable, Codable {
    public var kick: Double
    public var snare: Double
    public var hat: Double

    public init(kick: Double, snare: Double, hat: Double) {
        self.kick = kick
        self.snare = snare
        self.hat = hat
    }

    public subscript(_ kind: SliceClass) -> Double {
        switch kind {
        case .kick: return kick
        case .snare: return snare
        case .hat: return hat
        }
    }

    public var ranked: [(kind: SliceClass, score: Double)] {
        SliceClass.allCases.map { (kind: $0, score: self[$0]) }.sorted { $0.score > $1.score }
    }
}

/// One slice's classification, with the measurements it was based on.
public struct SliceClassification: Hashable, Sendable, Codable, Identifiable {
    public var sliceIndex: Int
    public var kind: SliceClass
    /// Spectral centroid of the slice's attack, in Hz.
    public var centroid: Double
    /// The slice's length in seconds — the gap to the next slice, which depends on how finely the
    /// bar was chopped, not on how long the drum rings.
    public var duration: Double
    /// How long the slice actually sounds: from its start to where its envelope falls 30 dB below
    /// its own peak. This is the length the hat rule uses, because a closed hat cut on an eighth
    /// grid is a 30 ms sound in a 330 ms slice and must not be called a ride for it.
    public var effectiveDuration: Double
    public var peak: Float
    public var rms: Float
    public var scores: ClassScores
    /// Margin between the winner and the runner-up, 0…1. Low means the slice is genuinely between
    /// two categories and is a good candidate to show a user for an override.
    public var confidence: Double
    /// True when a caller forced this label rather than the measurements choosing it.
    public var isOverride: Bool

    public var id: Int { sliceIndex }

    public init(sliceIndex: Int, kind: SliceClass, centroid: Double, duration: Double,
                effectiveDuration: Double? = nil, peak: Float = 0, rms: Float = 0,
                scores: ClassScores = ClassScores(kick: 0, snare: 0, hat: 0),
                confidence: Double = 0, isOverride: Bool = false) {
        self.sliceIndex = sliceIndex
        self.kind = kind
        self.centroid = centroid
        self.duration = duration
        self.effectiveDuration = effectiveDuration ?? duration
        self.peak = peak
        self.rms = rms
        self.scores = scores
        self.confidence = confidence
        self.isOverride = isOverride
    }

    /// The same classification relabelled by hand, keeping the measurements it was based on.
    public func overridden(as kind: SliceClass) -> SliceClassification {
        var copy = self
        copy.kind = kind
        copy.isOverride = true
        copy.confidence = 1
        return copy
    }
}

/// Decides whether a slice is kick-like, snare-like or hat-like from its spectral centroid and
/// its length.
///
/// The centroid of the **attack** is what separates drums, so only the first `analysisWindow`
/// seconds are measured: a kick's tail and a hat's tail are both mostly nothing, and including
/// them just drags every centroid towards whatever the room noise is.
///
/// Scores are distance in octaves from each class's reference centroid, negated — so 0 is a
/// perfect match and every score is ≤ 0. Length enters only where it has to: a bright slice that
/// rings for half a second is a crash or a ride, not a closed hat, so the hat score is penalised
/// past `hatMaxDuration`. That is the "a bright *short* one is a hat" rule, written down.
public struct SliceClassifier: Sendable {
    /// Reference centroid for a kick, in Hz.
    public var kickCentroid: Double
    /// Reference centroid for a snare.
    public var snareCentroid: Double
    /// Reference centroid for a hat.
    public var hatCentroid: Double
    /// Past this *effective* length a bright slice stops being hat-like (it is a ride, a crash, a
    /// cymbal wash).
    public var hatMaxDuration: Double
    /// How far below a slice's own peak its envelope must fall to count as finished, in dB.
    public var decayFloorDB: Double = 30
    /// Block length of the envelope follower, in seconds.
    public var envelopeBlock: Double = 0.005
    /// Octaves of penalty applied to the hat score when a slice runs past `hatMaxDuration`.
    public var hatLengthPenalty: Double
    /// Seconds of the slice's attack that are measured.
    public var analysisWindow: Double
    public var nFFT: Int
    public var hop: Int
    /// Slices quieter than this (peak) are classified but flagged with zero confidence.
    public var silenceFloor: Float

    public init(kickCentroid: Double = 150, snareCentroid: Double = 3000, hatCentroid: Double = 9000,
                hatMaxDuration: Double = 0.2, hatLengthPenalty: Double = 2,
                analysisWindow: Double = 0.08, nFFT: Int = 1024, hop: Int = 256,
                silenceFloor: Float = 1e-4) {
        self.kickCentroid = kickCentroid
        self.snareCentroid = snareCentroid
        self.hatCentroid = hatCentroid
        self.hatMaxDuration = hatMaxDuration
        self.hatLengthPenalty = hatLengthPenalty
        self.analysisWindow = analysisWindow
        self.nFFT = nFFT
        self.hop = hop
        self.silenceFloor = silenceFloor
    }

    /// Classify every slice of a chop against the mono signal it was cut from.
    ///
    /// - Parameter overrides: slice index to forced class, for a UI or a persona that disagrees.
    ///   An override keeps the measured centroid and duration, so the disagreement stays visible.
    public func classify(_ chop: Chop, in signal: [Float],
                         overrides: [Int: SliceClass] = [:]) -> [SliceClassification] {
        chop.slices.map { slice in
            var result = classify(slice, in: signal)
            if let forced = overrides[slice.index] { result = result.overridden(as: forced) }
            return result
        }
    }

    /// Classify one slice.
    public func classify(_ slice: Slice, in signal: [Float]) -> SliceClassification {
        let sampleRate = slice.sampleRate
        let centroid = Self.spectralCentroid(signal, range: attackRange(of: slice, in: signal),
                                             sampleRate: sampleRate, nFFT: nFFT, hop: hop)
        let sounding = Self.effectiveDuration(signal, range: bodyRange(of: slice, in: signal),
                                              sampleRate: sampleRate, floorDB: decayFloorDB,
                                              block: envelopeBlock)
        // On a dense break the envelope never reaches the floor before the next hit arrives, so
        // the measurement is censored: the slice's length is all we learned, and it says more
        // about how the bar was cut than about the drum. Penalising the hat score on a censored
        // measurement turns every hat in a busy bar into a snare, so a censored slice is scored as
        // if it were short — the length rule only fires on a decay we actually saw finish.
        let censored = sounding >= slice.duration - envelopeBlock
        let scores = score(centroid: centroid, duration: censored ? min(sounding, hatMaxDuration) : sounding)
        let ranked = scores.ranked
        let best = ranked[0]
        let runnerUp = ranked.count > 1 ? ranked[1].score : best.score
        // Scores are negative octave distances; the gap between the top two, soft-clipped to 0…1.
        var confidence = min(1, max(0, (best.score - runnerUp) / 2))
        if slice.peak < silenceFloor { confidence = 0 }
        return SliceClassification(sliceIndex: slice.index, kind: best.kind, centroid: centroid,
                                   duration: slice.duration, effectiveDuration: sounding,
                                   peak: slice.peak, rms: slice.rms,
                                   scores: scores, confidence: confidence)
    }

    /// The scores a centroid and a length earn, without any audio — the rule itself, testable and
    /// tunable on its own.
    public func score(centroid: Double, duration: Double) -> ClassScores {
        func distance(_ reference: Double) -> Double {
            guard centroid > 0, reference > 0 else { return -8 }
            return -abs(log2(centroid / reference))
        }
        var hat = distance(hatCentroid)
        if duration > hatMaxDuration { hat -= hatLengthPenalty }
        return ClassScores(kick: distance(kickCentroid), snare: distance(snareCentroid), hat: hat)
    }

    // MARK: Measurement

    private func bodyRange(of slice: Slice, in signal: [Float]) -> Range<Int> {
        let lo = max(0, min(slice.start, signal.count))
        let hi = max(lo, min(slice.end, signal.count))
        return lo..<hi
    }

    /// Seconds from the start of `range` to the last block whose RMS is within `floorDB` of the
    /// loudest block. A drum's own length, independent of how the bar was cut.
    public static func effectiveDuration(_ signal: [Float], range: Range<Int>, sampleRate: Double,
                                         floorDB: Double = 30, block: Double = 0.005) -> Double {
        guard sampleRate > 0, range.lowerBound < range.upperBound else { return 0 }
        let blockFrames = max(1, Int((block * sampleRate).rounded()))
        var levels: [Double] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let end = min(i + blockFrames, range.upperBound)
            var sum = 0.0
            for j in i..<end { sum += Double(signal[j]) * Double(signal[j]) }
            levels.append((sum / Double(end - i)).squareRoot())
            i = end
        }
        guard let loudest = levels.max(), loudest > 0 else { return 0 }
        let floor = loudest * pow(10, -floorDB / 20)
        let last = levels.lastIndex { $0 >= floor } ?? 0
        return Double((last + 1) * blockFrames) / sampleRate
    }

    private func attackRange(of slice: Slice, in signal: [Float]) -> Range<Int> {
        let lo = max(0, min(slice.start, signal.count))
        let windowFrames = Int((analysisWindow * slice.sampleRate).rounded())
        let hi = max(lo, min(min(slice.end, lo + windowFrames), signal.count))
        return lo..<hi
    }

    /// Magnitude-weighted mean frequency over `range`, in Hz.
    ///
    /// Zero-padded to the transform length when the region is shorter, so a 15 ms hat measures the
    /// same way a 300 ms kick does.
    public static func spectralCentroid(_ signal: [Float], range: Range<Int>, sampleRate: Double,
                                        nFFT: Int = 1024, hop: Int = 256) -> Double {
        guard sampleRate > 0, range.lowerBound < range.upperBound else { return 0 }
        var window = Array(signal[range])
        if window.count <= nFFT { window += [Float](repeating: 0, count: nFFT + 1 - window.count) }
        let magnitude = STFT(nFFT: nFFT, hop: hop).forward(window).magnitude()
        let bins = magnitude.binCount
        let binHz = sampleRate / Double(nFFT)
        var weighted = 0.0
        var total = 0.0
        for t in 0..<magnitude.frameCount {
            for k in 0..<bins {
                let m = Double(magnitude[t, k])
                weighted += m * Double(k) * binHz
                total += m
            }
        }
        return total > 0 ? weighted / total : 0
    }
}
