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
}
