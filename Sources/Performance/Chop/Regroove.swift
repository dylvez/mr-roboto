import Foundation
import Instrument
import MusicTheory
import SongGraph

/// Where one slice lands in the target feel, and why.
public struct SlicePlacement: Hashable, Sendable {
    public var sliceIndex: Int
    /// The feel's voice this step belonged to.
    public var voice: DrumVoice
    /// The class that chose the slice.
    public var kind: SliceClass
    /// Bar of the target grid.
    public var bar: Int
    /// Step within that bar.
    public var step: Int
    /// Transport seconds.
    public var time: Double
    public var velocity: Int
    /// Length of the step, in seconds.
    public var stepDuration: Double
    /// Seconds until the next hit on this voice — how long the slice has to speak before the feel
    /// asks for that voice again.
    public var available: Double
    /// The slice's own length, in seconds.
    public var naturalDuration: Double
    /// Set when the slice was stretched to fit; output duration over input duration.
    public var stretchRatio: Double?
    /// The MIDI note that plays it, filled in once the map has a pad for it.
    public var note: Int?

    /// True when the slice is longer than the room the feel gives it.
    public var overruns: Bool { naturalDuration > available + 1e-9 }
}

/// A chop played in someone else's rhythm: the placements, the hits, and the map that plays them.
public struct RegroovePerformance: Sendable {
    public var placements: [SlicePlacement]
    /// Ready for `VoiceSampler.enqueue`. Transport seconds.
    public var hits: [VoiceSampler.Hit]
    /// The map, extended with pads for any stretched variants the placements needed. **Render this
    /// one**, not the one you passed in, or the stretched pads will be missing.
    public var map: ChopMap
    public var classifications: [SliceClassification]
    /// Steps of the feel that asked for a voice no slice could serve.
    public var unplacedSteps: Int
    /// Classes the chop had none of, which were filled with the closest slices instead. Worth
    /// surfacing: "there is no hat in this break" is something a user wants to know.
    public var substitutedClasses: Set<SliceClass>
    /// Seconds from the first step to the end of the last bar placed.
    public var duration: Double
}

/// The payoff: take a chop and a target feel, and play the slices in the feel's rhythm.
///
/// ## How a slice finds a step
///
/// Each slice is classified (`SliceClassifier`) as kick-, snare- or hat-like. The feel is written
/// in drum voices, so each voice is looked up in `Policy.voices` to find the class that serves it,
/// and the slices of that class are handed out in rotation — a break with two different snares
/// alternates them across the backbeats, which is most of what makes a re-grooved chop sound like
/// a performance rather than a loop of one hit.
///
/// The whole policy is data, and `Policy.overrides` forces any slice to any class, so a UI or a
/// persona that hears the third slice as a rim rather than a snare says so and everything
/// downstream follows. Nothing here is hard-coded to the classifier's opinion.
///
/// ## When a slice is too long for its step
///
/// Selectable, because both answers are musical. `.ring` lets it play through the next step, which
/// is what an MPC does and is why chopped breaks sound thick. `.stretchToFit` squeezes it into the
/// room it has (through `SliceStretch`, so a ratio used twice is computed once), which is what you
/// want when the target tempo is much slower and the ringing would turn to mud.
public struct Regroove: Sendable {
    /// What to do with a slice whose natural length exceeds the room the feel gives it.
    public enum Overlap: String, Hashable, Sendable, Codable, CaseIterable {
        /// Let it ring into the following steps.
        case ring
        /// Time-stretch it so it ends where the next hit on its voice begins.
        case stretchToFit
    }

    /// Everything about slice-to-voice assignment, as data a UI can edit.
    public struct Policy: Sendable {
        /// Which of the feel's voices each class of slice serves.
        public var voices: [SliceClass: [DrumVoice]]
        /// Forced classes by slice index — a hand or a persona overruling the classifier.
        public var overrides: [Int: SliceClass]
        /// Class used for a voice that `voices` does not mention. `nil` skips those steps.
        public var fallback: SliceClass?
        /// When a class has no slices at all — a break with no hat in it, asked to play a feel
        /// full of hats — use the slices that scored closest to that class rather than leaving
        /// the steps silent. This is what a person does with a pad bank: something gets assigned.
        public var substitute: Bool
        /// How many substitutes are allowed into the rotation for an empty class.
        public var substituteCount: Int
        public var overlap: Overlap
        /// Hand the slices of a class out in rotation. Off plays the loudest one every time.
        public var rotate: Bool
        /// Stretch ratios are clamped here; outside it the slice rings instead. A ratio below a
        /// quarter turns a drum into a click, and above four it turns into a drone.
        public var stretchLimits: ClosedRange<Double>
        /// Scales every velocity the feel asks for.
        public var velocityScale: Double

        public init(voices: [SliceClass: [DrumVoice]] = Policy.defaultVoices,
                    overrides: [Int: SliceClass] = [:],
                    fallback: SliceClass? = .snare,
                    substitute: Bool = true,
                    substituteCount: Int = 2,
                    overlap: Overlap = .ring,
                    rotate: Bool = true,
                    stretchLimits: ClosedRange<Double> = 0.25...4,
                    velocityScale: Double = 1) {
            self.voices = voices
            self.overrides = overrides
            self.fallback = fallback
            self.substitute = substitute
            self.substituteCount = max(1, substituteCount)
            self.overlap = overlap
            self.rotate = rotate
            self.stretchLimits = stretchLimits
            self.velocityScale = velocityScale
        }

        /// The usual kit, folded onto three classes: anything low is the kick's job, anything that
        /// answers on the backbeat is the snare's, anything metallic keeps time.
        public static let defaultVoices: [SliceClass: [DrumVoice]] = [
            .kick: [.kick, .lowTom, .cajon, .darbuka, .frameDrum],
            .snare: [.snare, .clap, .rim, .midTom, .highTom, .highConga, .lowConga, .highBongo, .lowBongo,
                     .claves, .woodblock, .cowbell, .cajonSlap, .darbukaTek, .slitDrum, .highAgogo, .lowAgogo],
            .hat: [.closedHat, .openHat, .ride, .crash, .shaker, .tambourine, .perc, .cabasa, .guiro, .guiroLong,
                   .openTriangle, .muteTriangle, .vibraslap],
        ]

        /// The class serving `voice`, or `fallback`.
        public func kind(for voice: DrumVoice) -> SliceClass? {
            for kind in SliceClass.allCases where voices[kind]?.contains(voice) == true { return kind }
            return fallback
        }
    }

    public var policy: Policy

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    // MARK: Performing

    /// Play `map`'s slices in `groove`'s rhythm, on `grid`'s timing.
    ///
    /// - Parameters:
    ///   - classifications: from `SliceClassifier`. Pass an edited set to override the machine.
    ///   - startBar: the grid bar the groove's first bar lands on.
    ///   - repeats: how many times the whole groove is laid down, back to back.
    ///   - zeroAtStart: shift the times so the first step is at transport 0. Off keeps grid time.
    public func perform(_ map: ChopMap, classifications: [SliceClassification],
                        groove: Groove, grid: BeatGrid, startBar: Int = 0, repeats: Int = 1,
                        zeroAtStart: Bool = true) throws -> RegroovePerformance {
        var labelled = classifications
        if !policy.overrides.isEmpty {
            labelled = labelled.map { policy.overrides[$0.sliceIndex].map($0.overridden(as:)) ?? $0 }
        }
        // Slices of each class, loudest first so a non-rotating policy picks the strongest hit and
        // a rotating one starts there.
        var byClass: [SliceClass: [Int]] = [:]
        var substituted: Set<SliceClass> = []
        for kind in SliceClass.allCases {
            let own = labelled.filter { $0.kind == kind }
                .sorted { ($0.peak, -Double($0.sliceIndex)) > ($1.peak, -Double($1.sliceIndex)) }
                .map(\.sliceIndex)
            if !own.isEmpty || !policy.substitute {
                byClass[kind] = own
                continue
            }
            // Nothing in the chop reads as this class. Take whatever came closest instead of
            // dropping the feel's steps on the floor.
            byClass[kind] = labelled.sorted { $0.scores[kind] > $1.scores[kind] }
                .prefix(policy.substituteCount).map(\.sliceIndex)
            if !(byClass[kind] ?? []).isEmpty { substituted.insert(kind) }
        }
        let kindOf = Dictionary(uniqueKeysWithValues: labelled.map { ($0.sliceIndex, $0.kind) })

        let timeline = StepTimeline(grid: grid, stepsPerBar: groove.stepsPerBar, swing: groove.swing)
        let grooveBars = max(1, groove.bars)
        let origin = zeroAtStart ? timeline.time(bar: startBar, step: 0) : 0

        var placements: [SlicePlacement] = []
        var counters: [SliceClass: Int] = [:]
        var unplaced = 0

        for pattern in groove.patterns.sorted(by: { $0.voice.rawValue < $1.voice.rawValue }) {
            guard let kind = policy.kind(for: pattern.voice) else {
                // No class serves this voice and there is no fallback: the steps are counted, not
                // quietly dropped, so a caller can see that the feel asked for something the chop
                // cannot give it.
                unplaced += (0..<(max(1, repeats) * groove.stepCount)).reduce(0) { total, absolute in
                    let step = absolute % groove.stepCount
                    let tier = step < pattern.steps.count ? pattern.steps[step] : VelocityTier.rest
                    return total + (tier == .rest ? 0 : 1)
                }
                continue
            }
            let candidates = byClass[kind] ?? []
            // Step times for this voice, so "how long until this voice is asked for again" is
            // answerable without looking at the whole groove.
            var voiceSteps: [(bar: Int, step: Int, time: Double, tier: VelocityTier)] = []
            for repeatIndex in 0..<max(1, repeats) {
                for absolute in 0..<groove.stepCount {
                    let tier = absolute < pattern.steps.count ? pattern.steps[absolute] : .rest
                    guard tier != .rest else { continue }
                    let bar = startBar + repeatIndex * grooveBars + absolute / groove.stepsPerBar
                    let step = absolute % groove.stepsPerBar
                    voiceSteps.append((bar, step, timeline.time(bar: bar, step: step) - origin, tier))
                }
            }
            guard !candidates.isEmpty else { unplaced += voiceSteps.count; continue }

            for (i, entry) in voiceSteps.enumerated() {
                let counter = counters[kind, default: 0]
                let sliceIndex = policy.rotate
                    ? candidates[counter % candidates.count]
                    : candidates[0]
                counters[kind] = counter + 1
                guard map.chop.slices.indices.contains(sliceIndex) else { unplaced += 1; continue }
                let slice = map.chop.slices[sliceIndex]
                let stepDuration = timeline.duration(bar: entry.bar, step: entry.step)
                let nextOnVoice = i + 1 < voiceSteps.count ? voiceSteps[i + 1].time : entry.time + stepDuration
                let available = max(0, nextOnVoice - entry.time)

                var placement = SlicePlacement(
                    sliceIndex: sliceIndex,
                    voice: pattern.voice,
                    kind: kindOf[sliceIndex] ?? kind,
                    bar: entry.bar,
                    step: entry.step,
                    time: entry.time,
                    velocity: Self.velocity(entry.tier, scale: policy.velocityScale),
                    stepDuration: stepDuration,
                    available: available,
                    naturalDuration: slice.duration
                )
                if policy.overlap == .stretchToFit, placement.overruns, available > 0, slice.duration > 0 {
                    let ratio = SliceStretch.rounded(available / slice.duration)
                    if policy.stretchLimits.contains(ratio) { placement.stretchRatio = ratio }
                }
                placements.append(placement)
            }
        }
        placements.sort { ($0.time, $0.voice.rawValue) < ($1.time, $1.voice.rawValue) }

        // Pads for the stretched variants, one per distinct (slice, ratio) so the stretch cache
        // has something to hit and the kit does not grow a zone per hit.
        var extended = map
        var variantNotes: [SliceStretch.Key: Int] = [:]
        for index in placements.indices {
            guard let ratio = placements[index].stretchRatio else {
                placements[index].note = extended.note(forSlice: placements[index].sliceIndex)
                continue
            }
            let key = SliceStretch.Key(slice: placements[index].sliceIndex, reversed: false, ratio: ratio)
            if let note = variantNotes[key] {
                placements[index].note = note
            } else {
                let note = extended.addPad(sliceIndex: placements[index].sliceIndex,
                                           stretchRatio: ratio,
                                           label: String(format: "slice %d × %.3f",
                                                         placements[index].sliceIndex, ratio))
                variantNotes[key] = note
                placements[index].note = note
            }
        }

        var hits: [VoiceSampler.Hit] = []
        hits.reserveCapacity(placements.count)
        for placement in placements {
            guard let note = placement.note else { unplaced += 1; continue }
            hits.append(VoiceSampler.Hit(note: note, velocity: placement.velocity, at: placement.time))
        }

        let lastBar = startBar + max(1, repeats) * grooveBars
        let end = timeline.time(bar: lastBar, step: 0) - origin
        return RegroovePerformance(placements: placements, hits: hits, map: extended,
                                   classifications: labelled, unplacedSteps: unplaced,
                                   substitutedClasses: substituted, duration: max(0, end))
    }

    static func velocity(_ tier: VelocityTier, scale: Double) -> Int {
        min(127, max(1, Int((Double(tier.velocity) * scale).rounded())))
    }
}
