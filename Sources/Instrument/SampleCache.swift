import AVFoundation
import Foundation

// MARK: - SampleBuffer

/// Decoded audio owned by a stable, manually managed allocation.
///
/// ## The pointer-lifetime contract (read this before writing a render callback)
///
/// The voice sampler runs on the audio thread, where it may not retain, release, allocate, free,
/// lock, or touch anything that could. It therefore reads sample data through a **raw pointer that
/// never moves**:
///
/// * The sample data is one `UnsafeMutableBufferPointer<Float>` allocated once in `init` and freed
///   exactly once in `deinit`. It is deinterleaved: channel `c` occupies
///   `[c * frameCount ..< (c + 1) * frameCount]`. Nothing ever reallocates or resizes it, so an
///   address handed out at setup time stays valid and stays put for the life of this object.
/// * `channelPointers` is an array of `channelCount` `UnsafePointer<Float>?`, also allocated once,
///   pointing into that block. It is what a C render callback stores, exactly like
///   `AudioBufferList`-style planar data.
/// * The data is immutable after `init`. Any number of threads may read it concurrently; nothing
///   ever writes it. That is why the type is `@unchecked Sendable`.
///
/// **Who keeps it alive:** the `SampleCache` holds the only strong reference a render thread may
/// rely on. A `SampleBuffer` is deallocated when — and only when — it is evicted from the cache
/// (`evict(kit:)`, `remove(...)`, `removeAll()`) or the cache itself goes away. So:
///
/// 1. The setup path resolves every zone's buffer through the cache **before** the voice can be
///    triggered, and stores `channelPointers` in the C voice state.
/// 2. The cache must outlive the render graph, and a kit must not be evicted while any voice that
///    points into it can still be rendering. Evicting a playing kit is a use-after-free. Stop the
///    voices (or swap the kit and let its voices finish) first, then evict.
/// 3. The render thread must never call `buffer(for:...)`, never copy a `SampleBuffer` reference,
///    and never do anything that retains or releases one. It only dereferences the raw pointers.
///
/// `withUnsafeChannelPointers` is the safe form for non-realtime code (analysis, tests, offline
/// render): the reference is kept alive for the duration of the closure.
public final class SampleBuffer: @unchecked Sendable, Identifiable {
    /// The file this was decoded from.
    public let url: URL
    /// The rate the data is at — the cache's target rate, not necessarily the file's.
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int

    /// The one allocation: `channelCount * frameCount` floats, planar.
    private let storage: UnsafeMutableBufferPointer<Float>
    /// `channelCount` pointers into `storage`, allocated once so their address is stable too.
    private let pointers: UnsafeMutableBufferPointer<UnsafePointer<Float>?>

    /// Takes ownership of `planar`, which must hold `channelCount` arrays of `frameCount` floats.
    public init(url: URL, sampleRate: Double, planar: [[Float]]) {
        let channels = max(1, planar.count)
        let frames = planar.first?.count ?? 0
        let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, channels * frames))
        storage.initialize(repeating: 0)
        let pointers = UnsafeMutableBufferPointer<UnsafePointer<Float>?>.allocate(capacity: channels)
        pointers.initialize(repeating: nil)
        if let base = storage.baseAddress {
            for channel in 0..<planar.count {
                let count = min(planar[channel].count, frames)
                guard count > 0 else { continue }
                planar[channel].withUnsafeBufferPointer { source in
                    (base + channel * frames).update(from: source.baseAddress!, count: count)
                }
            }
            for channel in 0..<channels {
                pointers[channel] = UnsafePointer(base + channel * frames)
            }
        }
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channels
        self.frameCount = frames
        self.storage = storage
        self.pointers = pointers
    }

    deinit {
        pointers.deallocate()
        storage.deallocate()
    }

    /// Bytes of sample data this buffer holds resident.
    public var byteCount: Int { channelCount * frameCount * MemoryLayout<Float>.size }

    /// Seconds of audio.
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// The stable channel-pointer array for the render thread. Valid for as long as the cache holds
    /// this buffer; see the contract above. Never call this from the audio thread — read it once
    /// during setup and store the result.
    public var channelPointers: UnsafePointer<UnsafePointer<Float>?> {
        UnsafePointer(pointers.baseAddress!)
    }

    /// Scoped access for non-realtime callers: the buffer is kept alive for the call.
    public func withUnsafeChannelPointers<R>(
        _ body: (UnsafePointer<UnsafePointer<Float>?>, Int, Int) throws -> R
    ) rethrows -> R {
        defer { withExtendedLifetime(self) {} }
        return try body(channelPointers, channelCount, frameCount)
    }

    /// One channel as a buffer pointer, for non-realtime use.
    public func channel(_ index: Int) -> UnsafeBufferPointer<Float> {
        precondition(index >= 0 && index < channelCount, "channel \(index) out of range")
        return UnsafeBufferPointer(start: storage.baseAddress! + index * frameCount, count: frameCount)
    }

    /// One sample, for tests and offline code.
    public func sample(channel: Int, frame: Int) -> Float {
        precondition(channel >= 0 && channel < channelCount && frame >= 0 && frame < frameCount)
        return storage[channel * frameCount + frame]
    }
}

// MARK: - SampleCache

/// Decodes audio files once and shares the result.
///
/// Keyed by (file URL, target sample rate): two kits pointing at the same WAV at the same rate get
/// the same `SampleBuffer` and the bytes are resident once.
///
/// Deliberately **not** an actor. Loading happens from synchronous setup paths (kit load, voice
/// preparation, offline render) that cannot `await`, and the audio thread must never suspend. A
/// plain lock around a dictionary is the right shape: the lock is held only while looking up or
/// inserting a reference, never while decoding, and never by the render thread — which does not
/// touch the cache at all, only the raw pointers it handed out earlier.
public final class SampleCache: @unchecked Sendable {
    /// What identifies a cached decode.
    public struct Key: Hashable, Sendable {
        public var path: String
        public var sampleRate: Double

        public init(url: URL, sampleRate: Double) {
            self.path = url.standardizedFileURL.path
            self.sampleRate = sampleRate
        }
    }

    /// Decodes a file to planar Float32 at a target rate. Injectable so tests can count decodes and
    /// feed synthetic audio.
    public typealias Decode = @Sendable (URL, Double) throws -> DecodedAudio

    /// The result of a decode: planar Float32 at `sampleRate`.
    public struct DecodedAudio: Sendable {
        public var sampleRate: Double
        public var channels: [[Float]]

        public init(sampleRate: Double, channels: [[Float]]) {
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    private let lock = NSLock()
    private let decode: Decode
    private var entries: [Key: SampleBuffer] = [:]
    /// Which kit asked for which keys, so a kit's samples can be evicted as a set.
    private var owners: [KitID: Set<Key>] = [:]
    private var decodes = 0

    public init(decode: @escaping Decode = SampleCache.decodeFile) {
        self.decode = decode
    }

    // MARK: Loading

    /// The decoded buffer for `url` at `sampleRate`, decoding it only the first time.
    ///
    /// - Parameter kit: records the buffer as belonging to that kit so `evict(kit:)` can drop it.
    ///   A buffer used by two kits is kept until both are evicted.
    @discardableResult
    public func buffer(for url: URL, sampleRate: Double, kit: KitID? = nil) throws -> SampleBuffer {
        let key = Key(url: url, sampleRate: sampleRate)
        lock.lock()
        if let existing = entries[key] {
            if let kit { owners[kit, default: []].insert(key) }
            lock.unlock()
            return existing
        }
        lock.unlock()

        // Decoding happens outside the lock: it is slow, and two threads racing on the same file
        // only costs one redundant decode, which the insert below discards.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KitError.sampleFileMissing(path: url.path)
        }
        let decoded = try decode(url, sampleRate)
        let buffer = SampleBuffer(url: url, sampleRate: sampleRate, planar: decoded.channels)

        lock.lock()
        defer { lock.unlock() }
        decodes += 1
        if let kit { owners[kit, default: []].insert(key) }
        if let winner = entries[key] { return winner }
        entries[key] = buffer
        return buffer
    }

    /// Decodes every sample a loaded kit references. Throws `KitError.missingSample` naming the zone
    /// whose file is absent — the failure the `AVAudioUnitSampler` path used to swallow.
    @discardableResult
    public func preload(_ kit: LoadedKit, sampleRate: Double) throws -> [ZoneID: SampleBuffer] {
        var result: [ZoneID: SampleBuffer] = [:]
        var byPath: [String: SampleBuffer] = [:]
        for zone in kit.manifest.zones {
            if let cached = byPath[zone.sample] {
                result[zone.id] = cached
                continue
            }
            let url = kit.url(for: zone)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KitError.missingSample(zone: zone.id, path: zone.sample, folder: kit.folder.path)
            }
            let buffer = try self.buffer(for: url, sampleRate: sampleRate, kit: kit.id)
            byPath[zone.sample] = buffer
            result[zone.id] = buffer
        }
        return result
    }

    /// The buffer already cached for `url` at `sampleRate`, without decoding.
    public func cached(url: URL, sampleRate: Double) -> SampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(url: url, sampleRate: sampleRate)]
    }

    // MARK: Accounting

    /// How many decodes actually ran. A second request for the same file and rate must not raise it.
    public var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodes
    }

    /// Buffers resident.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Total sample bytes held. Counts each buffer once, however many kits reference it.
    public var residentByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: Eviction

    /// Drops the buffers that only this kit uses. **Never call this while a voice reading those
    /// buffers can still render** — see the contract on `SampleBuffer`.
    ///
    /// - Returns: the number of buffers freed.
    @discardableResult
    public func evict(kit: KitID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let keys = owners.removeValue(forKey: kit) else { return 0 }
        let stillUsed = Set(owners.values.flatMap { $0 })
        var freed = 0
        for key in keys where !stillUsed.contains(key) {
            if entries.removeValue(forKey: key) != nil { freed += 1 }
        }
        return freed
    }

    /// Drops one buffer regardless of owners.
    @discardableResult
    public func remove(url: URL, sampleRate: Double) -> Bool {
        let key = Key(url: url, sampleRate: sampleRate)
        lock.lock()
        defer { lock.unlock() }
        for kit in owners.keys { owners[kit]?.remove(key) }
        return entries.removeValue(forKey: key) != nil
    }

    /// Empties the cache. Same warning as `evict(kit:)`.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        owners.removeAll()
    }

    // MARK: Default decoder

    /// Reads any format `AVAudioFile` can open and returns planar Float32 at `targetSampleRate`,
    /// keeping the file's channel count (unlike `Analysis.Resampler`, which downmixes to mono —
    /// a sampler needs the stereo image the sample was recorded with).
    public static let decodeFile: Decode = { url, targetSampleRate in
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw KitError.decodeFailed(path: url.path, reason: "\(error)")
        }
        let sourceFormat = file.processingFormat
        let channels = Int(sourceFormat.channelCount)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else {
            return DecodedAudio(sampleRate: targetSampleRate, channels: Array(repeating: [], count: max(1, channels)))
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else {
            throw KitError.decodeFailed(path: url.path, reason: "could not allocate a \(frames)-frame buffer")
        }
        do {
            try file.read(into: input, frameCount: frames)
        } catch {
            throw KitError.decodeFailed(path: url.path, reason: "\(error)")
        }
        let converted = try convert(input, to: targetSampleRate, path: url.path)
        return DecodedAudio(sampleRate: targetSampleRate, channels: converted)
    }

    /// Converts a buffer to deinterleaved Float32 at `targetRate`, one array per channel.
    static func convert(_ input: AVAudioPCMBuffer, to targetRate: Double, path: String) throws -> [[Float]] {
        let source = input.format
        let channels = source.channelCount
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                         channels: channels, interleaved: false) else {
            throw KitError.decodeFailed(path: path, reason: "unsupported format \(source)")
        }
        if source.commonFormat == .pcmFormatFloat32, !source.isInterleaved, source.sampleRate == targetRate {
            return planar(input)
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw KitError.decodeFailed(path: path, reason: "no converter from \(source) to \(target)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let ratio = targetRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw KitError.decodeFailed(path: path, reason: "could not allocate the output buffer")
        }
        var supplied = false
        let block: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        var accumulated = [[Float]](repeating: [], count: Int(channels))
        loop: while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: block)
            if let error { throw KitError.decodeFailed(path: path, reason: error.localizedDescription) }
            let produced = Int(output.frameLength)
            if produced > 0 {
                let chunk = planar(output)
                for c in 0..<Int(channels) { accumulated[c].append(contentsOf: chunk[c]) }
            }
            switch status {
            case .haveData where produced > 0: continue
            default: break loop
            }
        }
        return accumulated
    }

    /// A deinterleaved Float32 buffer as arrays.
    static func planar(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return Array(repeating: [], count: channels) }
        let stride = buffer.stride
        return (0..<channels).map { channel in
            let source = data[channel]
            if stride == 1 { return Array(UnsafeBufferPointer(start: source, count: frames)) }
            return (0..<frames).map { source[$0 * stride] }
        }
    }
}
