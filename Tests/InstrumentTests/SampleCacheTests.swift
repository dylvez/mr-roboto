import AVFoundation
import Foundation
import Testing
@testable import Instrument

/// Counts how many times the cache actually ran a decode.
final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    /// A decoder that counts, then defers to the real one.
    func decoder() -> SampleCache.Decode {
        { [self] url, rate in
            increment()
            return try SampleCache.decodeFile(url, rate)
        }
    }
}

@Test func cacheDecodesOnceAndSharesTheBuffer() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let wav = try AudioFixtures.writeWAV(at: temp.file("kick.wav"), sampleRate: 44_100, channels: 2, frames: 1_000)

    let counter = DecodeCounter()
    let cache = SampleCache(decode: counter.decoder())
    let first = try cache.buffer(for: wav, sampleRate: 44_100)
    let second = try cache.buffer(for: wav, sampleRate: 44_100)

    #expect(counter.count == 1)
    #expect(cache.decodeCount == 1)
    #expect(first === second)
    #expect(cache.count == 1)
    #expect(first.frameCount == 1_000)
    #expect(first.channelCount == 2)
    #expect(first.sampleRate == 44_100)
    #expect(abs(first.duration - 1_000 / 44_100) < 1e-9)
    // A different target rate is a different entry.
    _ = try cache.buffer(for: wav, sampleRate: 48_000)
    #expect(counter.count == 2)
    #expect(cache.count == 2)
}

@Test func cacheConvertsToTheTargetSampleRate() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let wav = try AudioFixtures.writeWAV(at: temp.file("tone.wav"), sampleRate: 48_000, channels: 1, frames: 4_800)
    let cache = SampleCache()
    let buffer = try cache.buffer(for: wav, sampleRate: 44_100)
    #expect(buffer.sampleRate == 44_100)
    // 0.1 s at 44.1 kHz, within the converter's transient.
    #expect(abs(buffer.frameCount - 4_410) < 128)
    #expect(buffer.channelCount == 1)

    let native = try cache.buffer(for: wav, sampleRate: 48_000)
    #expect(native.frameCount == 4_800)
}

@Test func cacheDecodesTheSamplesValues() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let wav = try AudioFixtures.writeWAV(at: temp.file("ramp.wav"), sampleRate: 44_100, channels: 2, frames: 16) { channel, frame in
        channel == 0 ? Float(frame) / 100 : -Float(frame) / 100
    }
    let buffer = try SampleCache().buffer(for: wav, sampleRate: 44_100)
    #expect(abs(buffer.sample(channel: 0, frame: 5) - 0.05) < 1e-5)
    #expect(abs(buffer.sample(channel: 1, frame: 5) + 0.05) < 1e-5)
    buffer.withUnsafeChannelPointers { pointers, channels, frames in
        #expect(channels == 2)
        #expect(frames == 16)
        #expect(abs(pointers[0]![7] - 0.07) < 1e-5)
        #expect(abs(pointers[1]![7] + 0.07) < 1e-5)
    }
}

@Test func cacheAccountsForResidentBytes() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let mono = try AudioFixtures.writeWAV(at: temp.file("a.wav"), channels: 1, frames: 1_000)
    let stereo = try AudioFixtures.writeWAV(at: temp.file("b.wav"), channels: 2, frames: 1_000)
    let cache = SampleCache()
    #expect(cache.residentByteCount == 0)
    let first = try cache.buffer(for: mono, sampleRate: 44_100)
    #expect(cache.residentByteCount == 1_000 * 4)
    let second = try cache.buffer(for: stereo, sampleRate: 44_100)
    #expect(second.byteCount == 2 * 1_000 * 4)
    #expect(cache.residentByteCount == first.byteCount + second.byteCount)
    // Asking again does not double count.
    _ = try cache.buffer(for: mono, sampleRate: 44_100)
    #expect(cache.residentByteCount == first.byteCount + second.byteCount)
}

@Test func bufferPointersStayValidAsTheCacheGrows() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let wav = try AudioFixtures.writeWAV(at: temp.file("first.wav"), channels: 1, frames: 256) { _, frame in
        Float(frame) / 256
    }
    let cache = SampleCache()
    let buffer = try cache.buffer(for: wav, sampleRate: 44_100)

    // What a C voice would store at setup time.
    let pointers = buffer.channelPointers
    let channel0 = try #require(pointers[0])
    let sampleBefore = channel0[100]

    for index in 0..<24 {
        let url = try AudioFixtures.writeWAV(at: temp.file("grow-\(index).wav"), channels: 1, frames: 512)
        _ = try cache.buffer(for: url, sampleRate: 44_100)
    }
    #expect(cache.count == 25)

    // The dictionary grew and rehashed; the allocation behind the pointer did not move.
    #expect(cache.cached(url: wav, sampleRate: 44_100) === buffer)
    #expect(buffer.channelPointers == pointers)
    #expect(pointers[0] == channel0)
    #expect(channel0[100] == sampleBefore)
    #expect(abs(channel0[100] - 100.0 / 256) < 1e-5)
}

@Test func cacheEvictsByKit() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("Kit", isDirectory: true)
    let manifest = KitManifest(name: "Evictable", zones: [
        .drum(id: "kick", sample: "samples/kick.wav", note: 36),
        .drum(id: "snare", sample: "samples/snare.wav", note: 38),
        // A second zone on the same file: decoded once, evicted once.
        .drum(id: "snare_rim", sample: "samples/snare.wav", note: 40),
    ])
    try KitStore.save(manifest, to: folder)
    try AudioFixtures.writeWAV(at: KitPath.resolve("samples/kick.wav", in: folder), frames: 128)
    try AudioFixtures.writeWAV(at: KitPath.resolve("samples/snare.wav", in: folder), frames: 128)
    let kit = try KitStore.load(from: folder)

    let counter = DecodeCounter()
    let cache = SampleCache(decode: counter.decoder())
    let buffers = try cache.preload(kit, sampleRate: 44_100)
    #expect(buffers.count == 3)
    #expect(buffers[ZoneID("snare")] === buffers[ZoneID("snare_rim")])
    #expect(counter.count == 2)
    #expect(cache.count == 2)

    // Another kit sharing one of the files keeps it resident.
    let otherKit = KitID("other")
    _ = try cache.buffer(for: KitPath.resolve("samples/kick.wav", in: folder), sampleRate: 44_100, kit: otherKit)
    #expect(cache.evict(kit: kit.id) == 1)
    #expect(cache.count == 1)
    #expect(cache.evict(kit: otherKit) == 1)
    #expect(cache.count == 0)
    #expect(cache.residentByteCount == 0)
}

@Test func preloadNamesTheZoneWhoseSampleIsMissing() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("Broken", isDirectory: true)
    let manifest = KitManifest(name: "Broken", zones: [.drum(id: "ghost", sample: "ghost.wav", note: 36)])
    try KitStore.save(manifest, to: folder)
    let kit = try KitStore.load(from: folder, checkingSamples: false)
    #expect(throws: KitError.missingSample(zone: "ghost", path: "ghost.wav", folder: folder.path)) {
        try SampleCache().preload(kit, sampleRate: 44_100)
    }
    #expect(throws: KitError.self) {
        try SampleCache().buffer(for: folder.appendingPathComponent("nope.wav"), sampleRate: 44_100)
    }
}

// MARK: - The end of the file

// 102,720 frames is 100 blocks of 1024 plus 320. `AVAudioFile.read(into:frameCount:)` hands back
// whole internal blocks and stops without throwing, so one call for the whole file returns 102,400
// — up to 1023 frames missing from the end of every decode. Inaudible on a one-shot whose tail has
// already decayed; audible on a chopped bar, whose last zone ends exactly at the end of the file.
// It bites on the mono files the synthesizer and the chopper write, where the read deinterleaves;
// a stereo file whose processing format is the file's own reads straight through and does not
// short-read, which is why both are here.
// `Tests/PerformanceTests/ChopKitTests.swift` has the same pair from the chop's side.

@Test func cacheDecodesTheLastPartialBlock() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let frames = 102_720

    for channels in [1, 2] as [AVAudioChannelCount] {
        let wav = try AudioFixtures.writeWAV(at: temp.file("long-\(channels).wav"), sampleRate: 44_100,
                                             channels: channels, frames: frames) { channel, frame in
            let ramp = Float(frame) / Float(frames)
            return channel == 0 ? ramp : -ramp
        }
        let buffer = try SampleCache().buffer(for: wav, sampleRate: 44_100)
        #expect(buffer.frameCount == frames, "\(channels) ch decoded \(buffer.frameCount) of \(frames)")
        // Not just the count: the tail has to hold the samples that were written there.
        for frame in (frames - 4)..<frames {
            let expected = Float(frame) / Float(frames)
            #expect(abs(buffer.sample(channel: 0, frame: frame) - expected) < 1e-5)
            if channels == 2 {
                #expect(abs(buffer.sample(channel: 1, frame: frame) + expected) < 1e-5)
            }
        }
        // The resampling path runs the same read, so it must not lose the block either.
        let resampled = try SampleCache().buffer(for: wav, sampleRate: 48_000)
        #expect(abs(resampled.frameCount - Int((Double(frames) * 48_000 / 44_100).rounded())) < 128)
    }
}

@Test func synthesizedWAVsAreReadableAsSoonAsTheyAreWritten() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let frames = 102_720
    let samples = (0..<frames).map { Float($0) / Float(frames) }
    let url = temp.file("synth/tom.wav")

    // Read back in the same scope as the write: without an explicit `close()` the header is not
    // finalised yet and the file reads as empty.
    try SynthesizedKit.writeWAV(samples, to: url, sampleRate: 48_000)
    let buffer = try SampleCache().buffer(for: url, sampleRate: 48_000)
    #expect(buffer.channelCount == 1)
    #expect(buffer.frameCount == frames)
    for frame in (frames - 4)..<frames {
        #expect(abs(buffer.sample(channel: 0, frame: frame) - Float(frame) / Float(frames)) < 1e-5)
    }
}

@Suite("A cache shared between engines")
struct SharedSampleCacheTests {

    @Test("two engines' caches hold one decode of a recording between them, and each its own rendered kit")
    func sharedBetweenTwo() throws {
        let temp = TempDirectory()
        defer { temp.remove() }
        let piano = try AudioFixtures.writeWAV(at: temp.file("library/piano.wav"), sampleRate: 48_000, channels: 2, frames: 2_000)
        let rendered = try AudioFixtures.writeWAV(at: temp.file("kits/tr808/kick.wav"), sampleRate: 48_000, channels: 1, frames: 500)
        let counter = DecodeCounter()
        let shared = SampleCache(decode: counter.decoder(), checksFiles: true)
        let kits = temp.url.appendingPathComponent("kits").standardizedFileURL.path + "/"
        func engine() -> SampleCache {
            SampleCache(decode: counter.decoder(), backing: shared, sharing: { !$0.standardizedFileURL.path.hasPrefix(kits) })
        }
        // A bounce's cache and the transport's: the second does not read the piano again.
        let live = engine(), bounce = engine()
        let first = try live.buffer(for: piano, sampleRate: 48_000)
        let second = try bounce.buffer(for: piano, sampleRate: 48_000)
        #expect(first === second && counter.count == 1)
        #expect(shared.count == 1 && live.count == 0 && bounce.count == 0)
        #expect(bounce.cached(url: piano, sampleRate: 48_000) === first)
        // What an engine rendered is its own.
        let mine = try live.buffer(for: rendered, sampleRate: 48_000)
        let theirs = try bounce.buffer(for: rendered, sampleRate: 48_000)
        #expect(mine !== theirs && counter.count == 3)
        #expect(shared.count == 1 && live.count == 1)
        // A bounce is thrown away, and the recording is still held for the next one.
        #expect(try engine().buffer(for: piano, sampleRate: 48_000) === first)
        #expect(counter.count == 3)
    }

    @Test("a recording written again is decoded again; one left alone is not")
    func checksTheFile() throws {
        let temp = TempDirectory()
        defer { temp.remove() }
        let url = temp.file("cello.wav")
        try AudioFixtures.writeWAV(at: url, sampleRate: 48_000, channels: 1, frames: 1_000)
        let counter = DecodeCounter()
        let cache = SampleCache(decode: counter.decoder(), checksFiles: true)
        let before = try cache.buffer(for: url, sampleRate: 48_000)
        #expect(try cache.buffer(for: url, sampleRate: 48_000) === before)
        #expect(counter.count == 1)
        // Imported again over itself: another recording at the same path.
        try FileManager.default.removeItem(at: url)
        try AudioFixtures.writeWAV(at: url, sampleRate: 48_000, channels: 1, frames: 1_500)
        let after = try cache.buffer(for: url, sampleRate: 48_000)
        #expect(after !== before && after.frameCount == 1_500 && counter.count == 2)
        #expect(before.frameCount == 1_000, "whoever held the old one still has it whole")
        #expect(cache.count == 1)
        // A cache that does not check is the cache it always was.
        let trusting = SampleCache(decode: counter.decoder())
        let held = try trusting.buffer(for: url, sampleRate: 48_000)
        try FileManager.default.removeItem(at: url)
        try AudioFixtures.writeWAV(at: url, sampleRate: 48_000, channels: 1, frames: 700)
        #expect(try trusting.buffer(for: url, sampleRate: 48_000) === held)
    }

    @Test("past its limit a cache lets go of what was used longest ago, never of the newest")
    func bounded() throws {
        let temp = TempDirectory()
        defer { temp.remove() }
        let files = try (0..<4).map { try AudioFixtures.writeWAV(at: temp.file("s\($0).wav"), sampleRate: 48_000, channels: 1, frames: 1_000) }
        let one = 1_000 * MemoryLayout<Float>.size
        let cache = SampleCache(byteLimit: 2 * one + one / 2)
        let first = try cache.buffer(for: files[0], sampleRate: 48_000)
        _ = try cache.buffer(for: files[1], sampleRate: 48_000)
        // The first is asked for again, so the second is the oldest when a third comes in.
        _ = try cache.buffer(for: files[0], sampleRate: 48_000)
        _ = try cache.buffer(for: files[2], sampleRate: 48_000)
        #expect(cache.count == 2 && cache.residentByteCount == 2 * one)
        #expect(cache.cached(url: files[0], sampleRate: 48_000) === first)
        #expect(cache.cached(url: files[1], sampleRate: 48_000) == nil)
        #expect(cache.cached(url: files[2], sampleRate: 48_000) != nil)
        // One bigger than the limit is still held: it is what is about to be played.
        let small = SampleCache(byteLimit: one / 2)
        _ = try small.buffer(for: files[3], sampleRate: 48_000)
        #expect(small.count == 1)
        // And what was let go is whole for whoever still holds it.
        #expect(first.frameCount == 1_000)
    }

    @Test("the engine's cache shares what is outside its kits and the recorded pieces inside them")
    func whatAnEngineShares() throws {
        let temp = TempDirectory()
        defer { temp.remove() }
        let kits = temp.url.appendingPathComponent("audition \(UUID().uuidString)", isDirectory: true)
        let piano = try AudioFixtures.writeWAV(at: temp.file("Instruments/piano/samples/c4.wav"), sampleRate: 48_000, channels: 1, frames: 300)
        let synthesized = try AudioFixtures.writeWAV(at: kits.appendingPathComponent("tr808-0123/samples/kick_v1_63.wav"), sampleRate: 48_000, channels: 1, frames: 300)
        let recorded = try AudioFixtures.writeWAV(at: kits.appendingPathComponent("kit-room-0123/samples/recorded/room/kick.wav"), sampleRate: 48_000, channels: 1, frames: 300)
        defer { for url in [piano, recorded] { SampleCache.recordings.remove(url: url, sampleRate: 48_000) } }
        let cache = SampleCache.sharingRecordings(besides: kits)
        _ = try cache.buffer(for: piano, sampleRate: 48_000)
        _ = try cache.buffer(for: synthesized, sampleRate: 48_000)
        _ = try cache.buffer(for: recorded, sampleRate: 48_000)
        #expect(cache.count == 1, "the synthesized kick is the engine's own")
        #expect(SampleCache.recordings.cached(url: piano, sampleRate: 48_000) != nil)
        #expect(SampleCache.recordings.cached(url: recorded, sampleRate: 48_000) != nil)
        #expect(SampleCache.recordings.cached(url: synthesized, sampleRate: 48_000) == nil)
    }
}

@Suite("readAll bounds")
struct SampleCacheReadAllBoundsTests {

    /// Reading into a buffer smaller than the file must fill it and stop, not overrun it. This
    /// aborted the process before the destination was part of the bound.
    @Test("a destination smaller than the file is filled, not overrun")
    func destinationBound() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let url = try AudioFixtures.writeSamples(
            AudioFixtures.sine(frequency: 440, seconds: 2.0, sampleRate: 44_100),
            to: temp.url.appendingPathComponent("long.wav"), sampleRate: 44_100)

        let file = try AVAudioFile(forReading: url)
        let wanted = AVAudioFrameCount(4_096)
        #expect(AVAudioFramePosition(wanted) < file.length, "the fixture must be longer than the buffer")
        let small = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: wanted))
        try SampleCache.readAll(file, into: small)
        #expect(small.frameLength == wanted)
        #expect(small.frameLength <= small.frameCapacity)
    }

    /// One bar out of a longer record: seek partway in, then read into a buffer sized to the bar
    /// rather than to the rest of the file. The frames that come back have to be the ones starting
    /// at the seek — a buffer that is merely the right *length* would pass the bound check above
    /// while holding the wrong audio.
    @Test("a read from partway through the file lands the frames at that offset")
    func readsFromFramePosition() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let total = 12_000
        let channels: AVAudioChannelCount = 2
        // Each frame carries its own index, so a misplaced read is off by a readable amount rather
        // than by a phase a sine would hide. The channels differ so a copy cannot cross them.
        func expected(_ channel: Int, _ frame: Int) -> Float {
            Float(frame) / Float(total) * (channel == 0 ? 1 : -1)
        }
        let url = try AudioFixtures.writeWAV(at: temp.url.appendingPathComponent("record.wav"),
                                             sampleRate: 44_100, channels: channels,
                                             frames: total, generator: expected)

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition(total))
        let offset = 5_000
        let bar = AVAudioFrameCount(3_000)
        #expect(AVAudioFramePosition(offset) + AVAudioFramePosition(bar) < file.length,
                "the buffer must be smaller than what is left in the file after the seek")

        file.framePosition = AVAudioFramePosition(offset)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bar))
        try SampleCache.readAll(file, into: buffer)

        #expect(buffer.frameLength == bar)
        let data = try #require(buffer.floatChannelData)
        let stride = buffer.stride
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                let got = data[channel][frame * stride]
                #expect(abs(got - expected(channel, offset + frame)) < 1e-5,
                        "channel \(channel) frame \(frame): got \(got)")
            }
        }
    }
}
