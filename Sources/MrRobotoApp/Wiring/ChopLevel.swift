import Foundation
import Instrument
import SongGraph

/// The level a chop is played at.
///
/// Every recorded instrument in the app is levelled when it comes in, so a piano from one pack
/// and a snare from another sit together. A chop was not: it played at whatever level its bar of
/// the media had. A bar of a mastered record is loud enough. A bar of a stem that the separator
/// left nearly empty is not — the other stem of a vocal record sat 20 dB under the record — and
/// the song then bounced 19 LU under its target, with the master raised 18.8 dB to make it up and
/// every drum machine added afterwards that much too loud.
///
/// A quiet bar is brought up when it is cut. The gain is the chop's own (`Sample.gainDB`), and
/// it is applied where the bar is read, so the lane, the loop and a groove on the slices agree.
/// A bar that is loud enough is left exactly as it was.
enum ChopLevel {
    /// Where a chop's loudest tenth of a second is brought to: where an instrument's is.
    static let targetDBFS = KitLevel.instrumentDBFS
    /// No sample of a levelled chop goes over this.
    static let ceilingDBFS = KitLevel.ceilingDBFS
    /// A bar within this of the target is left as recorded.
    static let leastDB = 6.0
    /// The most a bar is brought up. Past this it is the recording's floor that is heard.
    static let mostDB = 24.0
    /// The share of a bar's samples that may reach past its measured peak: a click, not the music.
    static let clicks = 0.001

    /// A bar, measured: its loudest tenth of a second summed to mono, and how far its samples
    /// reach on any one channel, but for the one in a thousand that reaches furthest.
    ///
    /// Not the largest sample. The bar this was written for came off a 78: forty samples of
    /// crackle stood 17 dB over everything else in it, and held under the ceiling by those the
    /// bar came up 7 dB where it needed 18. What is over the ceiling once it is levelled is held
    /// there (`AudioRegion.Span.levelled`), and that is a click a little shorter.
    struct Reading: Equatable, Sendable {
        var loudnessDBFS: Double
        var peakDBFS: Double

        /// The gain that brings the bar to the target, as far as the ceiling lets its peak go, or
        /// nil when it is loud enough as recorded.
        var gainDB: Double? {
            let gain = min(ChopLevel.targetDBFS - loudnessDBFS, ChopLevel.ceilingDBFS - peakDBFS, ChopLevel.mostDB)
            return gain >= ChopLevel.leastDB ? (gain * 10).rounded() / 10 : nil
        }
    }

    /// Reads a bar. Nil when it holds nothing at all: silence has no level to bring up.
    static func read(_ planar: [[Float]], sampleRate: Double) -> Reading? {
        guard let frames = planar.first?.count, frames > 0, sampleRate > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        var reach: [Float] = []
        reach.reserveCapacity(frames * planar.count)
        for channel in planar {
            for index in 0..<min(frames, channel.count) {
                mono[index] += channel[index] / Float(planar.count)
                reach.append(abs(channel[index]))
            }
        }
        reach.sort()
        let peak = reach[min(reach.count - 1, Int((Double(reach.count) * (1 - clicks)).rounded(.down)))]
        let window = max(1, min(frames, Int(0.1 * sampleRate))), hop = max(1, window / 4)
        var loudest = 0.0, start = 0
        while start + window <= frames {
            var sum = 0.0
            for index in start..<(start + window) { sum += Double(mono[index]) * Double(mono[index]) }
            loudest = max(loudest, (sum / Double(window)).squareRoot())
            start += hop
        }
        guard loudest > 1e-6, peak > 0 else { return nil }
        return Reading(loudnessDBFS: 20 * log10(loudest), peakDBFS: 20 * log10(Double(peak)))
    }

    /// The reading of a chop's bar as its media holds it, before any level of its own.
    static func read(_ sample: Sample, in song: Song?, mediaURL: (MediaRef) -> URL?) -> Reading? {
        guard let url = mediaURL(sample.media) else { return nil }
        let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: song)?.bars ?? [],
                                            tempo: sample.detectedTempo ?? song?.tempo)
        guard let span = try? AudioRegion.read(url, from: region.start, to: region.end) else { return nil }
        return read(span.planar, sampleRate: span.sampleRate)
    }

    /// The chops a plan plays that are quiet at their source and have no level of their own:
    /// each chop's loop, and the chop under every groove on its slices, once.
    static func quiet(in plan: SongPlayback) -> [QuietChop] {
        var seen = Set<VersionID>()
        var found: [QuietChop] = []
        let voices = plan.segments.flatMap(\.voices) + plan.voices
        for track in voices.compactMap({ $0.chop ?? $0.kit }) where track.gainDB == nil && seen.insert(track.version).inserted {
            guard let part = track.part,
                  let span = try? AudioRegion.read(track.url, from: track.region.start, to: track.region.end),
                  let reading = read(span.planar, sampleRate: span.sampleRate), let gain = reading.gainDB else { continue }
            found.append(QuietChop(part: part, label: track.name, loudnessDBFS: reading.loudnessDBFS, gainDB: gain))
        }
        return found
    }

    /// "+16.0 dB", for a line a person reads.
    static func spoken(_ gainDB: Double) -> String { String(format: "%+.1f dB", gainDB) }
}

extension AudioRegion.Span {
    /// The span at a chop's level. Every reader of a chop's bar goes through this, so the bar is
    /// one loudness wherever it is heard.
    func levelled(by gainDB: Double?) -> AudioRegion.Span {
        guard let gainDB, gainDB != 0 else { return self }
        let gain = Float(pow(10, gainDB / 20)), ceiling = Float(pow(10, ChopLevel.ceilingDBFS / 20))
        // Brought up, and whatever that puts over the ceiling held at it: the few samples the
        // measure left out (`ChopLevel.Reading`).
        return AudioRegion.Span(planar: planar.map { channel in channel.map { max(-ceiling, min(ceiling, $0 * gain)) } },
                                sampleRate: sampleRate)
    }
}
