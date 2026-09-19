import AudioEngine
import Foundation
import SongGraph

// M5 R4: comping. Takes of one part chosen bar by bar and rendered into one, with the seams
// crossfaded and snapped to the quietest moment nearby so a breath is not cut in half.

public enum Comp {

    /// One take's audio, placed in the song.
    public struct TakeAudio: Sendable {
        public var planar: [[Float]]
        public var sampleRate: Double
        /// Song seconds at which frame 0 sits.
        public var alignmentSeconds: Double

        public init(planar: [[Float]], sampleRate: Double, alignmentSeconds: Double) {
            self.planar = planar
            self.sampleRate = sampleRate
            self.alignmentSeconds = alignmentSeconds
        }
    }

    public struct Rendered: Sendable {
        public var planar: [[Float]]
        public var sampleRate: Double
        /// Song seconds at which frame 0 sits: the first span's bar.
        public var alignmentSeconds: Double
        /// Where every seam landed after snapping, song seconds.
        public var seams: [Double]
    }

    public enum Failure: Error, CustomStringConvertible {
        case emptyPlan
        case missingTake(VersionID)
        case mixedRates
        public var description: String {
            switch self {
            case .emptyPlan: return "The comp names no bars."
            case .missingTake(let id): return "The comp names a take this song does not hold: \(id.description.prefix(8))."
            case .mixedRates: return "The takes are at different sample rates."
            }
        }
    }

    /// Renders a plan. Seams are snapped to the quietest 5 ms of the outgoing take within
    /// `snapWindow` seconds of the bar line, then crossfaded equal-power over `plan.crossfade`.
    public static func render(_ plan: CompPlan, takes: [VersionID: TakeAudio], clock: TransportClock,
                              snapWindow: Double = 0.04) throws -> Rendered {
        guard let first = plan.spans.first, let last = plan.spans.last else { throw Failure.emptyPlan }
        for span in plan.spans where takes[span.take] == nil { throw Failure.missingTake(span.take) }
        let rates = Set(takes.values.map(\.sampleRate))
        guard rates.count == 1, let rate = rates.first else { throw Failure.mixedRates }
        let channels = takes.values.map { $0.planar.count }.max() ?? 1

        let start = clock.seconds(forBar: first.startBar)
        let end = clock.seconds(forBar: last.endBar)
        let frames = Int(((end - start) * rate).rounded())

        // Seams: one per span boundary, snapped in the outgoing take.
        var seams: [Double] = []
        for (index, span) in plan.spans.enumerated().dropLast() {
            let line = clock.seconds(forBar: span.endBar)
            let next = plan.spans[index + 1]
            // Only a seam where the take changes; the same take across a bar line is no seam.
            guard next.take != span.take, let outgoing = takes[span.take] else { seams.append(line); continue }
            seams.append(quietest(in: outgoing, around: line, window: snapWindow))
        }

        func sample(_ take: TakeAudio, channel: Int, at seconds: Double) -> Float {
            let lane = take.planar[min(channel, take.planar.count - 1)]
            let frame = Int(((seconds - take.alignmentSeconds) * rate).rounded())
            guard frame >= 0, frame < lane.count else { return 0 }
            return lane[frame]
        }

        let half = max(0, plan.crossfade) / 2
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        for frame in 0..<frames {
            let t = start + Double(frame) / rate
            // Which span, by seams: the i-th span runs from seam[i-1] to seam[i].
            var index = 0
            while index < seams.count, t >= seams[index] { index += 1 }
            let span = plan.spans[index]
            let take = takes[span.take]!
            // Near a seam: blend outgoing and incoming.
            var blend: (from: TakeAudio, to: TakeAudio, gainFrom: Float, gainTo: Float)?
            if index < seams.count, seams[index] - t < half, half > 0, plan.spans[index + 1].take != span.take {
                let x = (t - (seams[index] - half)) / (2 * half)   // 0 → 0.5 up to the seam
                let toTake = takes[plan.spans[index + 1].take]!
                blend = (take, toTake, Float(cos(x * .pi / 2)), Float(sin(x * .pi / 2)))
            } else if index > 0, t - seams[index - 1] < half, half > 0, plan.spans[index - 1].take != span.take {
                let x = (t - (seams[index - 1] - half)) / (2 * half)   // 0.5 → 1 after the seam
                let fromTake = takes[plan.spans[index - 1].take]!
                blend = (fromTake, take, Float(cos(x * .pi / 2)), Float(sin(x * .pi / 2)))
            }
            for channel in 0..<channels {
                if let blend {
                    out[channel][frame] = blend.gainFrom * sample(blend.from, channel: channel, at: t)
                        + blend.gainTo * sample(blend.to, channel: channel, at: t)
                } else {
                    out[channel][frame] = sample(take, channel: channel, at: t)
                }
            }
        }
        return Rendered(planar: out, sampleRate: rate, alignmentSeconds: start, seams: seams)
    }

    /// The centre of the quietest 5 ms in a take within ±window of a moment, song seconds.
    static func quietest(in take: TakeAudio, around seconds: Double, window: Double) -> Double {
        let rate = take.sampleRate
        let lane = take.planar[0]
        let block = max(1, Int(0.005 * rate))
        let centre = Int(((seconds - take.alignmentSeconds) * rate).rounded())
        let reach = Int(window * rate)
        var best = centre
        var bestEnergy = Double.infinity
        var at = centre - reach
        while at + block <= centre + reach {
            var energy = 0.0
            for i in at..<(at + block) where i >= 0 && i < lane.count { energy += Double(lane[i] * lane[i]) }
            // Outside the take counts as silence, but a seam outside the audio is no use: skip it.
            if at >= 0, at + block <= lane.count, energy < bestEnergy { bestEnergy = energy; best = at + block / 2 }
            at += block / 2
        }
        return take.alignmentSeconds + Double(best) / rate
    }
}
