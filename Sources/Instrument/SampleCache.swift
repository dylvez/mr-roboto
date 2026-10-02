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
///
/// ## Sharing
///
/// A cache can stand in front of another (`backing`): files `sharing` says yes to are looked up
/// and kept there instead of here. That is how every engine in the process — the one the transport
/// plays through and the offline one each bounce builds and throws away — holds one decode of a
/// recorded piano between them (`SampleCache.recordings`). Before it, each bounce had a cache of
/// its own and read the piano from disk again: twelve to seventeen seconds a section, and a
/// reading of a whole mix was mostly that.
///
/// A shared cache outlives what it was filled for, so it does two things a private one need not:
/// it **checks the file** (`checksFiles`), so an instrument imported again over itself is decoded
/// again rather than heard as it was; and it is **bounded** (`byteLimit`), letting go of what was
/// used longest ago. Letting go is safe: a sampler holds its own reference to every buffer it
/// plays (`VoiceSampler`), so a buffer the cache drops lives until the sampler is done with it.
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

    /// The cache shared files are kept in, and which files those are (all of them when nil).
    private let backing: SampleCache?
    private let sharing: (@Sendable (URL) -> Bool)?
    /// The most sample bytes held, past which the buffers used longest ago are let go. Nil holds
    /// everything until it is evicted.
    private let byteLimit: Int?
    private let checksFiles: Bool
    /// A file as it was when it was decoded: its size and when it was last written.
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date?
    }
    private var stamps: [Key: Stamp] = [:]
    /// When each buffer was last asked for, on a counter.
    private var used: [Key: UInt64] = [:]
    private var tick: UInt64 = 0

    /// - Parameters:
    ///   - backing: a cache to keep shared files in instead of this one.
    ///   - sharing: which files go to `backing`; every file when nil.
    ///   - byteLimit: the most sample bytes to hold. The newest buffer is always kept.
    ///   - checksFiles: decode a file again when its size or date has changed since it was cached.
    public init(decode: @escaping Decode = SampleCache.decodeFile, backing: SampleCache? = nil,
                sharing: (@Sendable (URL) -> Bool)? = nil, byteLimit: Int? = nil, checksFiles: Bool = false) {
        self.decode = decode
        self.backing = backing
        self.sharing = sharing
        self.byteLimit = byteLimit
        self.checksFiles = checksFiles
    }

    /// The recordings the process has decoded — imported instruments, the pieces of a recorded
    /// kit — shared by every engine, live or offline. Bounded to a quarter of the machine's
    /// memory, and never under a gigabyte: one grand piano at three layers is half of that.
    public static let recordings = SampleCache(
        byteLimit: max(1 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory / 4)), checksFiles: true)

    /// A cache for one engine whose kits are built in `kitsDirectory`: what is rendered there is
    /// its own, and recordings — files anywhere else, and the copies a kit keeps of its recorded
    /// pieces — are `recordings`'.
    public static func sharingRecordings(besides kitsDirectory: URL) -> SampleCache {
        let own = kitsDirectory.standardizedFileURL.path + "/"
        return SampleCache(backing: .recordings, sharing: { url in
            let path = url.standardizedFileURL.path
            return !path.hasPrefix(own) || path.contains("/samples/recorded/")
        })
    }

    private func shares(_ url: URL) -> SampleCache? {
        guard let backing, sharing?(url) ?? true else { return nil }
        return backing
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modified: attributes[.modificationDate] as? Date)
    }

    /// Lets go of the buffers used longest ago until what is held fits. Called with the lock held.
    private func trim(keeping key: Key) {
        guard let byteLimit else { return }
        var held = entries.values.reduce(0) { $0 + $1.byteCount }
        while held > byteLimit, entries.count > 1,
              let oldest = entries.keys.filter({ $0 != key }).min(by: { used[$0, default: 0] < used[$1, default: 0] }) {
            held -= entries[oldest]?.byteCount ?? 0
            forget(oldest)
        }
    }

    /// Called with the lock held.
    private func forget(_ key: Key) {
        entries[key] = nil
        stamps[key] = nil
        used[key] = nil
        for kit in owners.keys { owners[kit]?.remove(key) }
    }

    // MARK: Loading

    /// The decoded buffer for `url` at `sampleRate`, decoding it only the first time.
    ///
    /// - Parameter kit: records the buffer as belonging to that kit so `evict(kit:)` can drop it.
    ///   A buffer used by two kits is kept until both are evicted.
    @discardableResult
    public func buffer(for url: URL, sampleRate: Double, kit: KitID? = nil) throws -> SampleBuffer {
        if let shared = shares(url) { return try shared.buffer(for: url, sampleRate: sampleRate, kit: kit) }
        let key = Key(url: url, sampleRate: sampleRate)
        let stamp = checksFiles ? Self.stamp(of: url) : nil
        lock.lock()
        if let existing = entries[key] {
            if !checksFiles || stamps[key] == stamp {
                if let kit { owners[kit, default: []].insert(key) }
                tick += 1
                used[key] = tick
                lock.unlock()
                return existing
            }
            // Written again since it was decoded: what is cached is the file as it was.
            forget(key)
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
        tick += 1
        used[key] = tick
        if let winner = entries[key] { return winner }
        entries[key] = buffer
        stamps[key] = stamp
        trim(keeping: key)
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
        if let shared = shares(url) { return shared.cached(url: url, sampleRate: sampleRate) }
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
            stamps[key] = nil
            used[key] = nil
        }
        return freed
    }

    /// Drops one buffer regardless of owners.
    @discardableResult
    public func remove(url: URL, sampleRate: Double) -> Bool {
        if let shared = shares(url) { return shared.remove(url: url, sampleRate: sampleRate) }
        let key = Key(url: url, sampleRate: sampleRate)
        lock.lock()
        defer { lock.unlock() }
        let held = entries[key] != nil
        forget(key)
        return held
    }

    /// Empties the cache. Same warning as `evict(kit:)`.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        owners.removeAll()
        stamps.removeAll()
        used.removeAll()
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
            try readAll(file, into: input)
        } catch {
            throw KitError.decodeFailed(path: url.path, reason: "\(error)")
        }
        let converted = try convert(input, to: targetSampleRate, path: url.path)
        return DecodedAudio(sampleRate: targetSampleRate, channels: converted)
    }

    /// Fills `buffer` with the whole of `file`, looping until `file.length` frames have been read.
    ///
    /// **One `read(into:frameCount:)` call is a short read.** On this toolchain it hands back whole
    /// internal blocks and stops, without throwing: asking for all 102,720 frames of a
    /// 102,720-frame file returns 102,400. Up to a block goes missing from the end of every
    /// decode — inaudible on a one-shot whose tail has already decayed, and audible on a chopped
    /// bar, whose last zone ends exactly at the end of the file. So nothing here reads a file in
    /// one call.
    public static func readAll(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer) throws {
        let wanted = AVAudioFrameCount(max(0, file.length - file.framePosition))
        guard wanted > 0, let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                         frameCapacity: min(wanted, 1 << 16)) else {
            buffer.frameLength = 0
            return
        }
        var filled: AVAudioFrameCount = 0
        let limit = min(wanted, buffer.frameCapacity)
        while filled < limit {
            scratch.frameLength = 0
            // Bounded by the destination too, not just the file and the scratch buffer. Reading a
            // region into a smaller buffer otherwise overruns it and aborts the process — latent
            // while every caller sizes the buffer to the whole file, and immediate the first time
            // one does not.
            try file.read(into: scratch, frameCount: min(limit - filled, scratch.frameCapacity))
            let produced = scratch.frameLength
            if produced == 0 { break }
            let written = copy(scratch, into: buffer, at: filled)
            filled += written
            if written < produced { break }
        }
        buffer.frameLength = filled
    }

    /// Appends `source`'s frames to `destination` starting at frame `offset`, and returns how many
    /// frames it actually wrote.
    ///
    /// That is all of them, as long as the caller bounds its reads by the destination's capacity.
    /// It is returned rather than assumed so that a caller which *stops* bounding them reports a
    /// short buffer instead of a `frameLength` counting frames nobody wrote: dropping the copy
    /// silently and letting the count run on is the one outcome worse than the overrun it guards.
    private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer,
                             at offset: AVAudioFrameCount) -> AVAudioFrameCount {
        guard let src = source.floatChannelData, let dst = destination.floatChannelData else { return 0 }
        let room = Int(destination.frameCapacity) - Int(offset)
        let n = min(Int(source.frameLength), max(0, room))
        assert(n == Int(source.frameLength),
               "copy dropped \(Int(source.frameLength) - n) frames: \(source.frameLength) read into \(room) frames of room")
        let channels = min(Int(source.format.channelCount), Int(destination.format.channelCount))
        for c in 0..<channels {
            for i in 0..<n {
                dst[c][(Int(offset) + i) * destination.stride] = src[c][i * source.stride]
            }
        }
        return AVAudioFrameCount(n)
    }

    /// Planar Float32 at one rate, at another: the same converter a kit's samples go through.
    public static func resample(_ planar: [[Float]], from sourceRate: Double, to targetRate: Double) throws -> [[Float]] {
        guard sourceRate != targetRate, let first = planar.first, !first.isEmpty else { return planar }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                         channels: AVAudioChannelCount(planar.count), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(first.count)),
              let data = buffer.floatChannelData else {
            throw KitError.decodeFailed(path: "resample", reason: "could not hold \(planar.count) channels at \(sourceRate) Hz")
        }
        buffer.frameLength = AVAudioFrameCount(first.count)
        for (channel, samples) in planar.enumerated() {
            samples.withUnsafeBufferPointer { data[channel].update(from: $0.baseAddress!, count: min(samples.count, first.count)) }
        }
        return try convert(buffer, to: targetRate, path: "resample")
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
