import AudioEngine
import Instrument
import SongGraph

// What the strips' own effects need from a plan: the modulation an instrument brings, and the
// song as the filters and pumps keep time by.

extension SongPlayback {
    /// What each pitched part's instrument brings to its strip as its modulation when the mix sets
    /// none: a combo organ its vibrato. The first sound a part plays on decides, as for the insert.
    public var instrumentModulations: [PartID: StripModulation] {
        var out: [PartID: StripModulation] = [:]
        for voice in voices + segments.flatMap(\.voices) where voice.isPitched {
            guard let part = voice.part, out[part] == nil,
                  let modulation = InstrumentVoiceSpec.preset(id: voice.sound)?.modulation else { continue }
            out[part] = modulation
        }
        return out
    }

    /// The song in the transport's beats, each section with where its grooves' kick falls: what a
    /// strip's filter moves and its pump are timed by. An unarranged song is one long stretch
    /// from where its loops begin.
    public var mixTimeline: MixTimeline {
        let beatsPerBar = Double(max(1, timeSignature.beatsPerBar))
        func kicks(_ voices: [Voice]) -> (beats: [Double], pattern: Double) {
            let grooves = voices.compactMap(\.groove)
            guard let longest = grooves.map({ Double(max(1, $0.bars)) * beatsPerBar }).max() else { return ([], beatsPerBar) }
            // Grooves of different lengths together: each tiled to the longest, their kicks as one.
            var all = Set<Double>()
            for groove in grooves {
                let length = Double(max(1, groove.bars)) * beatsPerBar
                let passes = max(1, Int((longest / length).rounded()))
                for pass in 0..<passes {
                    for beat in groove.kickBeats(beatsPerBar: Int(beatsPerBar)) { all.insert(beat + Double(pass) * length) }
                }
            }
            return Self.folded(all.sorted(), over: longest, beatsPerBar: beatsPerBar)
        }
        if isArranged {
            let sections = segments.sorted { $0.startBar < $1.startBar }.map { segment in
                let found = kicks(segment.voices)
                return MixTimeline.Section(section: segment.section, startBeat: Double(segment.startBar) * beatsPerBar,
                                           lengthBeats: Double(segment.lengthInBars) * beatsPerBar,
                                           kicks: found.beats, patternBeats: found.pattern)
            }
            return MixTimeline(sections: sections, cycleBeats: loops ? lengthInBars.map { Double($0) * beatsPerBar } : nil)
        }
        let found = kicks(voices)
        return MixTimeline(sections: [MixTimeline.Section(section: nil, startBeat: voicesStartAt * tempo / 60, lengthBeats: 10_000_000,
                                                          kicks: found.beats, patternBeats: found.pattern)])
    }

    /// A kick pattern at the shortest whole number of bars it repeats in. A section's groove is
    /// written out to the section's length, and a strip holds sixty-four triggers: thirty-two bars
    /// of four on the floor would have stopped pumping halfway.
    static func folded(_ kicks: [Double], over beats: Double, beatsPerBar: Double) -> (beats: [Double], pattern: Double) {
        let bars = max(1, Int((beats / beatsPerBar).rounded()))
        for period in 1...bars where bars % period == 0 {
            let length = Double(period) * beatsPerBar
            let first = kicks.filter { $0 < length - 1e-9 }
            let repeats = (0..<(bars / period)).flatMap { pass in first.map { $0 + Double(pass) * length } }
            if repeats.count == kicks.count, zip(repeats, kicks).allSatisfy({ abs($0 - $1) < 1e-6 }) { return (first, length) }
        }
        return (kicks, beats)
    }
}
