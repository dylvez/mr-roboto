import Foundation
import Testing
@testable import Performance

@Suite("Slice stretch")
struct SliceStretchTests {
    static let sr: Double = 48_000

    static func slice() -> [[Float]] {
        [ChopFixtures.snare(sr)]
    }

    @Test("the same slice at the same ratio is stretched once")
    func repeatedRatioHitsTheCache() throws {
        let calls = Counter()
        let cache = SliceStretch(stretch: { planar, _, ratio in
            calls.increment()
            return planar.map { channel in
                [Float](repeating: 0, count: Int((Double(channel.count) * ratio).rounded()))
            }
        })
        let audio = Self.slice()

        _ = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.25)
        _ = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.25)
        _ = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.25)

        #expect(calls.value == 1)
        #expect(cache.stretchCount == 1)
        #expect(cache.hitCount == 2)
        #expect(cache.count == 1)
    }

    @Test("float noise in the ratio is not a different ratio")
    func nearIdenticalRatiosShareAnEntry() throws {
        let calls = Counter()
        let cache = SliceStretch(stretch: { planar, _, _ in calls.increment(); return planar })

        _ = try cache.stretched(slice: 0, planar: Self.slice(), sampleRate: Self.sr, ratio: 1.25)
        _ = try cache.stretched(slice: 0, planar: Self.slice(), sampleRate: Self.sr,
                                ratio: 1.25 + 1e-9)
        #expect(calls.value == 1)
    }

    @Test("a different slice, ratio or direction is a different entry")
    func keysAreDistinct() throws {
        let calls = Counter()
        let cache = SliceStretch(stretch: { planar, _, _ in calls.increment(); return planar })
        let audio = Self.slice()

        _ = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.25)
        _ = try cache.stretched(slice: 1, planar: audio, sampleRate: Self.sr, ratio: 1.25)
        _ = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 0.8)
        _ = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.25,
                                reversed: true)
        #expect(calls.value == 4)
        #expect(cache.count == 4)
    }

    @Test("a unity ratio does not go through the stretcher at all")
    func unityRatioIsFree() throws {
        let calls = Counter()
        let cache = SliceStretch(stretch: { planar, _, _ in calls.increment(); return planar })
        let audio = Self.slice()

        let out = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1)
        #expect(calls.value == 0)
        #expect(out[0] == audio[0])
    }

    @Test("stretching is deterministic: two runs are bit identical")
    func deterministic() throws {
        let audio = Self.slice()
        let a = try SliceStretch().stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.3)
        let b = try SliceStretch().stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.3)

        #expect(a.count == b.count)
        #expect(a[0] == b[0], "the same slice at the same ratio gave two different results")
    }

    @Test("a cached result is the same as a recomputed one")
    func cachedEqualsRecomputed() throws {
        let audio = Self.slice()
        let cache = SliceStretch()
        let first = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 0.75)
        let second = try cache.stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 0.75)
        let fresh = try SliceStretch().stretched(slice: 0, planar: audio, sampleRate: Self.sr,
                                                 ratio: 0.75)

        #expect(first[0] == second[0])
        #expect(first[0] == fresh[0])
        #expect(cache.stretchCount == 1)
    }

    @Test("the output is the requested length")
    func outputLength() throws {
        let audio = Self.slice()
        let out = try SliceStretch().stretched(slice: 0, planar: audio, sampleRate: Self.sr, ratio: 1.5)
        #expect(out[0].count == Int((Double(audio[0].count) * 1.5).rounded()))
    }

    /// A call counter the `@Sendable` stretch closure can touch.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
