import CStripFX
import Foundation
import SongGraph

/// The song as the strips' time-keeping effects read it: where each section starts and ends in
/// the transport's beats, and where the kick falls in it.
///
/// A filter that opens across a build and a pump that ducks on the kick both need to know where
/// the song is to the sample, live and in a bounce alike. The section the playhead is in reaches
/// the strips late — the frame notices it on a timer — so instead each strip is given the whole
/// form once, with the render sample time of the transport's zero, and works out where it is from
/// its own render timestamps.
public struct MixTimeline: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        /// The section, or nil for an unarranged song's one long stretch.
        public var section: SectionID?
        public var startBeat: Double
        public var lengthBeats: Double
        /// Where the kick hits, in beats into a pattern `patternBeats` long that repeats from the
        /// section's first beat. Empty when no groove plays here.
        public var kicks: [Double]
        public var patternBeats: Double

        public init(section: SectionID?, startBeat: Double, lengthBeats: Double, kicks: [Double] = [], patternBeats: Double = 4) {
            self.section = section
            self.startBeat = startBeat
            self.lengthBeats = lengthBeats
            self.kicks = kicks
            self.patternBeats = patternBeats
        }
    }

    public var sections: [Section]
    /// The form comes round every this many beats when the song loops; nil is no loop.
    public var cycleBeats: Double?

    public init(sections: [Section], cycleBeats: Double? = nil) {
        self.sections = sections
        self.cycleBeats = cycleBeats
    }

    /// Writes the timeline one strip plays by: `part`'s filter moves and pump depth from `mix`,
    /// section by section, on the clock given.
    func write(into timeline: UnsafeMutablePointer<sfx_timeline_t>, part: PartID, mix: Mix,
               originSampleTime: Double, samplesPerBeat: Double) {
        timeline.pointee.valid = 1
        timeline.pointee.origin = originSampleTime
        timeline.pointee.samplesPerBeat = samplesPerBeat
        timeline.pointee.cycleBeats = cycleBeats ?? 0
        let strip = mix.strip(for: part)
        let everyBeat = strip?.pump?.trigger == .beat
        let used = min(sections.count, Int(SFX_SEGMENTS))
        timeline.pointee.count = Int32(used)
        withUnsafeMutableBytes(of: &timeline.pointee.segments) { raw in
            let segments = raw.bindMemory(to: sfx_segment_t.self)
            for (index, section) in sections.prefix(used).enumerated() {
                var segment = sfx_segment_t()
                segment.startBeat = Float(section.startBeat)
                segment.lengthBeats = Float(section.lengthBeats)
                let effect = mix.sectionEffect(for: part, in: section.section)
                if let from = effect?.filterFromHz {
                    segment.filterFrom = Float(from)
                    segment.filterTo = Float(effect?.filterToHz ?? from)
                }
                segment.pumpDB = Float(effect?.pumpDB ?? -1)
                let kicks = everyBeat ? [0] : section.kicks
                segment.patternBeats = Float(everyBeat ? 1 : section.patternBeats)
                let count = min(kicks.count, Int(SFX_TRIGGERS))
                segment.count = Int32(count)
                withUnsafeMutableBytes(of: &segment.at) { at in
                    let slots = at.bindMemory(to: Float.self)
                    for (k, beat) in kicks.prefix(count).enumerated() { slots[k] = Float(beat) }
                }
                segments[index] = segment
            }
        }
    }
}

extension Groove {
    /// Where the kick hits in one pass, in beats from the groove's first: each step the kick lane
    /// sounds on, the odd steps moved by the swing as the player moves them.
    public func kickBeats(beatsPerBar: Int) -> [Double] {
        guard stepsPerBar > 0, let lane = patterns.first(where: { $0.voice == .kick }) else { return [] }
        let stepBeats = Double(max(1, beatsPerBar)) / Double(stepsPerBar)
        return lane.steps.prefix(stepCount).enumerated().compactMap { step, tier in
            guard tier != .rest else { return nil }
            let swung = step % 2 != 0 ? swing * 0.5 * stepBeats : 0
            return Double(step) * stepBeats + swung
        }
    }
}
