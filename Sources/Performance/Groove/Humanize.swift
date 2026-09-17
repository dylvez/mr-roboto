import Foundation

// MARK: - Deterministic noise

/// SplitMix64 — the mixing function behind `Xoshiro`'s seeding, used here on its own.
///
/// Two properties matter and neither is "good randomness":
///
/// 1. **It is ours.** `SystemRandomNumberGenerator`, `Double.random`, `Hasher` and `String.hashValue`
///    are all seeded per process. A bounce made with any of them would differ from the render the
///    user approved. Every random number in the groove engine comes from here.
/// 2. **It is addressable.** `value(seed:_:)` mixes a coordinate into the seed rather than drawing
///    from a stream, so a hit's jitter depends only on *which* hit it is — not on how many hits
///    were rendered before it, nor on the order the patterns happen to sit in. Adding a voice to a
///    groove does not change any other voice's feel, and rendering a groove in one pass gives the
///    same result as rendering it bar by bar.
public struct SeededRandom: RandomNumberGenerator, Hashable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return SeededRandom.mix(state)
    }

    /// One SplitMix64 finalizer round.
    public static func mix(_ z0: UInt64) -> UInt64 {
        var z = z0
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value addressed by coordinates rather than drawn from a stream.
    public static func value(seed: UInt64, _ coordinates: UInt64...) -> UInt64 {
        var z = seed
        for c in coordinates { z = mix(z &+ (c &* 0x9E37_79B9_7F4A_7C15)) }
        return mix(z)
    }

    /// A `Double` in `-1...1`, addressed by coordinates.
    public static func signed(seed: UInt64, _ coordinates: UInt64...) -> Double {
        var z = seed
        for c in coordinates { z = mix(z &+ (c &* 0x9E37_79B9_7F4A_7C15)) }
        return unitSigned(mix(z))
    }

    /// 53 bits of `x` as a `Double` in `-1...1`.
    public static func unitSigned(_ x: UInt64) -> Double {
        Double(x >> 11) * (2.0 / 9_007_199_254_740_992.0) - 1.0
    }

    /// FNV-1a over UTF-8. `Hasher` is seeded per process, so voice names cannot be hashed with it
    /// and still give the same bounce twice.
    public static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Humanize

/// Seeded jitter on velocity and timing — the difference between a programmed pattern and a played
/// one, applied reproducibly.
///
/// The velocity behaviour is ported from `groove-theory/src/store/useSequencerStore.ts`:
///
/// ```js
/// humanizePattern: (amount = 0.18) => …
///   const onBeat = i % 4 === 0;
///   const jitter = (Math.random() - 0.5) * 2 * amount;
///   return clamp(base + jitter * (onBeat ? 0.3 : 1), 0.2, 1);
/// ```
///
/// — that is, a symmetric ±`amount` on a 0…1 velocity scale, with steps that land on a beat getting
/// **0.3×** the jitter because a drummer's downbeats are the steady ones. `amount = 0.18` on a
/// 0…1 scale is ±23 MIDI, which is the figure that sounded right in the web app and is kept here.
///
/// The web app's `Math.max(s, 0.9)` floor on downbeats is *not* the default: it makes humanizing
/// also accent, which would silently overrule a groove's velocity tiers. It is available as
/// `downbeatFloor` for callers who want the original behaviour exactly.
///
/// Timing jitter has no ancestor in the web app (Tone.js scheduled on the grid) and is expressed as
/// a fraction of a step rather than in milliseconds, so a feel keeps its character when the tempo
/// moves. At 90 BPM one sixteenth is 166.7 ms, so `timing = 0.06` is ±10 ms — the range hip-hop
/// producers describe as micro-timing rather than sloppiness.
public struct Humanize: Hashable, Sendable, Codable {
    /// Velocity jitter as a fraction of the full 0…127 scale, applied symmetrically (±).
    public var velocity: Double
    /// Timing jitter as a fraction of one step, applied symmetrically (±).
    public var timing: Double
    /// Multiplier on both jitters for steps that land on a beat. `groove-theory` uses 0.3.
    public var onBeatScale: Double
    /// Optional floor applied to on-beat velocities, as a fraction of the scale — the web app's
    /// `max(s, 0.9)`. `nil` (the default) leaves the groove's tiers alone.
    public var downbeatFloor: Double?
    /// The seed. Two renders with the same seed are identical, sample for sample.
    public var seed: UInt64

    public init(velocity: Double = 0, timing: Double = 0, onBeatScale: Double = 0.3,
                downbeatFloor: Double? = nil, seed: UInt64 = Humanize.defaultSeed) {
        self.velocity = max(0, velocity)
        self.timing = max(0, timing)
        self.onBeatScale = max(0, onBeatScale)
        self.downbeatFloor = downbeatFloor
        self.seed = seed
    }

    /// An arbitrary but fixed seed, so a groove rendered without a stated seed is still reproducible.
    public static let defaultSeed: UInt64 = 0x4D52_524F_424F_544F  // "MRROBOTO"

    public var isActive: Bool { velocity > 0 || timing > 0 || downbeatFloor != nil }

    /// No jitter: the grid, exactly.
    public static let none = Humanize()
    /// `groove-theory`'s velocity amount with a little timing: a played, not programmed, feel.
    public static let subtle = Humanize(velocity: 0.18, timing: 0.04)
    /// Wider on both axes — the "drunk", off-grid character lo-fi hip-hop is after.
    public static let drunk = Humanize(velocity: 0.22, timing: 0.12)
    /// `groove-theory`'s `humanizePattern` exactly, floor and all.
    public static let grooveTheory = Humanize(velocity: 0.18, timing: 0, downbeatFloor: 0.9)

    /// The same settings with another seed — the way to audition variations of one feel.
    public func seeded(_ seed: UInt64) -> Humanize {
        var copy = self
        copy.seed = seed
        return copy
    }

    // MARK: Application

    /// Velocity jitter in MIDI units for one addressed step.
    func velocityJitter(voice: UInt64, step: UInt64, onBeat: Bool) -> Double {
        guard velocity > 0 else { return 0 }
        let scale = onBeat ? onBeatScale : 1
        return SeededRandom.signed(seed: seed, voice, step, 0x11) * velocity * scale * 127
    }

    /// Timing jitter as a fraction of one step for the same addressed step.
    func timingJitter(voice: UInt64, step: UInt64, onBeat: Bool) -> Double {
        guard timing > 0 else { return 0 }
        let scale = onBeat ? onBeatScale : 1
        return SeededRandom.signed(seed: seed, voice, step, 0x22) * timing * scale
    }
}
