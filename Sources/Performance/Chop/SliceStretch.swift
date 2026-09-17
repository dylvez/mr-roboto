import Analysis
import Foundation

/// Per-slice time stretching with a cache, for re-grooving a chop at a tempo other than its own.
///
/// Stretching a slice is the expensive part of a regroove: a sixteen-slice bar placed on a feel
/// that needs three different ratios is forty-eight STFT passes if nothing is remembered, and a
/// UI that lets someone drag the tempo asks for the same ratios over and over. So the result is
/// keyed by (slice, reversed, ratio) and computed once.
///
/// **Deterministic**, and that is not incidental: `SignalsmithTimeStretcher` takes a seed and runs
/// its `exact` sequence per call, so the same slice at the same ratio gives bit-identical output
/// on every run and on every machine. A cache that returned something different from a recompute
/// would make a render depend on how warm the cache was; `SliceStretchTests` asserts it does not.
///
/// The stretch function is injectable so tests can count calls and so a caller can swap in a
/// different engine without this type learning about it.
public final class SliceStretch: @unchecked Sendable {
    /// Planar channels in, planar channels out. `ratio` is output duration over input duration.
    public typealias Stretch = @Sendable (_ planar: [[Float]], _ sampleRate: Double, _ ratio: Double) throws -> [[Float]]

    /// What identifies a cached stretch.
    public struct Key: Hashable, Sendable {
        /// The slice's index in its chop.
        public var slice: Int
        public var reversed: Bool
        /// The ratio quantised to a millionth, so two ratios that differ by float noise are one key.
        public var ratioMicros: Int

        public init(slice: Int, reversed: Bool, ratio: Double) {
            self.slice = slice
            self.reversed = reversed
            self.ratioMicros = SliceStretch.quantise(ratio)
        }
    }

    private let stretch: Stretch
    private let lock = NSLock()
    private var entries: [Key: [[Float]]] = [:]
    private var stretches = 0
    private var hits = 0

    public init(stretch: @escaping Stretch = SliceStretch.signalsmith()) {
        self.stretch = stretch
    }

    /// The default engine: Signalsmith at the `percussive` preset, which keeps drum attacks sharp
    /// (40 ms blocks, 10 ms hops), with a fixed seed so runs are reproducible.
    public static func signalsmith(preset: SignalsmithTimeStretcher.Preset = .percussive,
                                   seed: Int = 1) -> Stretch {
        let stretcher = SignalsmithTimeStretcher(preset: preset, seed: seed)
        return { planar, sampleRate, ratio in
            try stretcher.stretch(planar: planar, sampleRate: sampleRate, ratio: ratio)
        }
    }

    /// Ratio quantised the way `Key` does, exposed so callers can collapse near-identical ratios
    /// onto one cache entry before they ask for them.
    public static func quantise(_ ratio: Double) -> Int {
        guard ratio.isFinite else { return 0 }
        return Int((ratio * 1_000_000).rounded())
    }

    /// `ratio` snapped to the cache's own resolution, so a caller can build a `ChopMap` whose
    /// stored ratio is exactly the one the cache will key on.
    public static func rounded(_ ratio: Double) -> Double { Double(quantise(ratio)) / 1_000_000 }

    // MARK: Stretching

    /// The slice's audio at `ratio`, stretching it only the first time it is asked for.
    ///
    /// A ratio of 1 is returned untouched and is not counted as a stretch: running a unity stretch
    /// through an STFT would smear the attack for no reason.
    public func stretched(slice: Int, planar: [[Float]], sampleRate: Double, ratio: Double,
                          reversed: Bool = false) throws -> [[Float]] {
        guard ratio.isFinite, ratio > 0 else { return planar }
        if Self.quantise(ratio) == Self.quantise(1) { return planar }
        let key = Key(slice: slice, reversed: reversed, ratio: ratio)
        lock.lock()
        if let cached = entries[key] {
            hits += 1
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Stretching happens outside the lock: it is slow, and two callers racing on the same key
        // only costs one redundant stretch, which the insert below discards. The result is
        // deterministic, so the discarded one was identical anyway.
        let result = try stretch(planar, sampleRate, Self.rounded(ratio))

        lock.lock()
        defer { lock.unlock() }
        if let winner = entries[key] {
            hits += 1
            return winner
        }
        stretches += 1
        entries[key] = result
        return result
    }

    // MARK: Accounting

    /// How many times the stretch engine actually ran. A repeated (slice, ratio) must not raise it.
    public var stretchCount: Int { lock.lock(); defer { lock.unlock() }; return stretches }
    /// How many requests were served from the cache.
    public var hitCount: Int { lock.lock(); defer { lock.unlock() }; return hits }
    /// Entries resident.
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
