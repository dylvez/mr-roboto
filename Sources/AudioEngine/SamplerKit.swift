import AVFAudio
import AudioToolbox
import Foundation

/// Loads one drum/sample kit into the engine's `AVAudioUnitSampler` and schedules MIDI
/// notes on it at transport times.
///
/// Files are mapped to MIDI notes by transcoding each one to a temporary AIFF carrying an
/// `INST` chunk (root/low/high key = the target note); `AVAudioUnitSampler.loadAudioFiles(at:)`
/// honours that chunk, so each file plays only on its own note and at its original pitch.
/// Note events go through the sampler's `AUAudioUnit.scheduleMIDIEventBlock` in render
/// sample time, resolved from the transport (`Transport.auSampleTime(atSeconds:)`).
@AudioActor
public final class SamplerKit: ScheduledSource {
    public struct Event: Hashable, Sendable {
        public let time: Double
        public let bytes: [UInt8]
    }

    public let sampler: AVAudioUnitSampler
    /// MIDI channel (0-15) used by `noteOn` / `noteOff`.
    public var channel: UInt8 = 0
    /// note -> the original file loaded for it.
    public private(set) var mapping: [UInt8: URL] = [:]
    /// Directory holding the transcoded AIFFs for the current kit.
    public private(set) var kitDirectory: URL?
    public var pendingEventCount: Int { pending.count }
    public private(set) var scheduledEventCount = 0

    private var pending: [Event] = []
    private var transport: Transport?
    private let scheduleBlock: AUScheduleMIDIEventBlock?

    public init(engine: Engine) {
        self.sampler = engine.sampler
        self.scheduleBlock = engine.sampler.withAUAudioUnit { $0.scheduleMIDIEventBlock }
    }

    // MARK: loading

    /// Load every `.wav` / `.aif` / `.aiff` in `folder`. A leading integer in a file name
    /// (`36 kick.wav`, `38-snare.aif`) is its MIDI note; other files are assigned
    /// consecutive notes from `baseNote` in name order, skipping taken notes.
    @discardableResult
    public func load(folder: URL, baseNote: UInt8 = 36) throws -> [UInt8: URL] {
        let exts: Set<String> = ["wav", "aif", "aiff", "aifc"]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !urls.isEmpty else { throw EngineError.noAudioFiles(folder) }

        var files: [UInt8: URL] = [:]
        var unnamed: [URL] = []
        for url in urls {
            if let note = SamplerKit.noteNumber(inFileName: url.lastPathComponent), files[note] == nil {
                files[note] = url
            } else {
                unnamed.append(url)
            }
        }
        var next = Int(baseNote)
        for url in unnamed {
            while files[UInt8(clamping: next)] != nil && next < 128 { next += 1 }
            guard next < 128 else { break }
            files[UInt8(next)] = url
            next += 1
        }
        try load(files: files)
        return files
    }

    /// Load an explicit note -> file mapping.
    public func load(files: [UInt8: URL]) throws {
        guard !files.isEmpty else { throw EngineError.noAudioFiles(URL(fileURLWithPath: "/")) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioEngine-SamplerKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var aiffs: [URL] = []
        for (note, source) in files.sorted(by: { $0.key < $1.key }) {
            let out = dir.appendingPathComponent(String(format: "%03d.aif", Int(note)))
            try SamplerKit.writeInstrumentAIFF(from: source, note: note, to: out)
            aiffs.append(out)
        }
        try sampler.loadAudioFiles(at: aiffs)
        mapping = files
        kitDirectory = dir
    }

    /// The MIDI note encoded by a leading integer in a file name, if any.
    nonisolated public static func noteNumber(inFileName name: String) -> UInt8? {
        let stem = (name as NSString).deletingPathExtension
        let digits = stem.prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits), (0...127).contains(value) else { return nil }
        return UInt8(value)
    }

    // MARK: notes

    /// Queue a note-on at transport time `seconds`; nil sends it immediately.
    public func noteOn(_ note: UInt8, velocity: UInt8 = 100, at seconds: Double? = nil) {
        send([0x90 | (channel & 0x0f), note & 0x7f, velocity & 0x7f], at: seconds)
    }

    /// Queue a note-off at transport time `seconds`; nil sends it immediately.
    public func noteOff(_ note: UInt8, at seconds: Double? = nil) {
        send([0x80 | (channel & 0x0f), note & 0x7f, 0], at: seconds)
    }

    /// Queue a note-on at `seconds` and a note-off `duration` later.
    public func play(_ note: UInt8, velocity: UInt8 = 100, at seconds: Double, duration: Double) {
        noteOn(note, velocity: velocity, at: seconds)
        noteOff(note, at: seconds + duration)
    }

    /// Queue an arbitrary MIDI 1.0 message (1-3 bytes). Nil time = immediately.
    public func send(_ bytes: [UInt8], at seconds: Double?) {
        guard let seconds else {
            dispatch(bytes, at: AUEventSampleTimeImmediate)
            return
        }
        let event = Event(time: seconds, bytes: bytes)
        let index = pending.firstIndex { $0.time > seconds } ?? pending.count
        pending.insert(event, at: index)
        if let transport, seconds < scheduledThroughTime {
            // Already past the scheduling horizon: send now so it is not lost.
            pending.remove(at: index)
            dispatch(bytes, at: transport.auSampleTime(atSeconds: seconds))
            scheduledEventCount += 1
        }
    }

    public func allNotesOff() {
        for channel in UInt8(0)..<16 {
            dispatch([0xB0 | channel, 123, 0], at: AUEventSampleTimeImmediate)
        }
    }

    // MARK: ScheduledSource

    private var scheduledThroughTime: Double = -.infinity

    public func transportDidStart(_ transport: Transport) {
        self.transport = transport
        scheduledThroughTime = -.infinity
        scheduledEventCount = 0
    }

    public func schedule(through seconds: Double) {
        guard let transport else { return }
        scheduledThroughTime = seconds
        var count = 0
        for event in pending {
            guard event.time < seconds else { break }
            dispatch(event.bytes, at: transport.auSampleTime(atSeconds: event.time))
            count += 1
        }
        if count > 0 {
            pending.removeFirst(count)
            scheduledEventCount += count
        }
    }

    public func transportWillStop() {
        transport = nil
        scheduledThroughTime = -.infinity
    }

    private func dispatch(_ bytes: [UInt8], at sampleTime: AUEventSampleTime) {
        guard let scheduleBlock, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { ptr in
            scheduleBlock(sampleTime, 0, ptr.count, ptr.baseAddress!)
        }
    }

    // MARK: AIFF transcoding

    /// Write `source` as a 16-bit AIFF with an `INST` chunk whose root, low and high keys
    /// are all `note`, so `AVAudioUnitSampler.loadAudioFiles(at:)` maps it to exactly that key.
    nonisolated public static func writeInstrumentAIFF(from source: URL, note: UInt8, to destination: URL) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: true)
        let frames = AVAudioFrameCount(file.length)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else {
            throw EngineError.renderFailed("could not allocate buffer for \(source.lastPathComponent)")
        }
        if frames > 0 { try file.read(into: buffer, frameCount: frames) }
        try writeInstrumentAIFF(buffer: buffer, note: note, to: destination)
    }

    /// Same as above from an in-memory float32 buffer.
    nonisolated public static func writeInstrumentAIFF(buffer: AVAudioPCMBuffer, note: UInt8, to destination: URL) throws {
        guard let channels = buffer.floatChannelData else {
            throw EngineError.formatMismatch("AIFF writer needs a float32 buffer")
        }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let frameStride = buffer.stride
        var data = Data()
        data.reserveCapacity(frames * channelCount * 2 + 128)

        func be32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.bigEndian) { Array($0) }) }

        var ssnd = Data(count: 8)  // offset + block size
        ssnd.reserveCapacity(8 + frames * channelCount * 2)
        for i in 0..<frames {
            for c in 0..<channelCount {
                let x = max(-1, min(1, channels[c][i * frameStride]))
                let v = Int16((x * 32767).rounded())
                let u = UInt16(bitPattern: v)
                ssnd.append(UInt8(u >> 8)); ssnd.append(UInt8(u & 0xff))
            }
        }
        var comm = Data()
        comm.append(contentsOf: [UInt8(channelCount >> 8), UInt8(channelCount & 0xff)])
        comm.append(contentsOf: withUnsafeBytes(of: UInt32(frames).bigEndian) { Array($0) })
        comm.append(contentsOf: [0, 16])
        comm.append(contentsOf: extended80(buffer.format.sampleRate))

        var inst = Data([note, 0, note, note, 1, 127, 0, 0])  // base, detune, low, high, lowVel, highVel, gain
        inst.append(contentsOf: [UInt8](repeating: 0, count: 12))  // sustain + release loops

        let bodyLength = 4 + (8 + comm.count) + (8 + inst.count) + (8 + ssnd.count)
        data.append(contentsOf: Array("FORM".utf8)); be32(UInt32(bodyLength))
        data.append(contentsOf: Array("AIFF".utf8))
        data.append(contentsOf: Array("COMM".utf8)); be32(UInt32(comm.count)); data.append(comm)
        data.append(contentsOf: Array("INST".utf8)); be32(UInt32(inst.count)); data.append(inst)
        data.append(contentsOf: Array("SSND".utf8)); be32(UInt32(ssnd.count)); data.append(ssnd)
        if ssnd.count % 2 == 1 { data.append(0) }
        try data.write(to: destination)
    }

    /// 80-bit IEEE extended, big endian (the AIFF sample-rate encoding).
    nonisolated static func extended80(_ value: Double) -> [UInt8] {
        guard value > 0 else { return [UInt8](repeating: 0, count: 10) }
        var exponent = Int(floor(log2(value)))
        var mantissa = value / pow(2.0, Double(exponent))  // [1, 2)
        exponent += 16383
        var bits: UInt64 = 0
        for _ in 0..<64 {
            bits <<= 1
            if mantissa >= 1 { bits |= 1; mantissa -= 1 }
            mantissa *= 2
        }
        var out = [UInt8(exponent >> 8), UInt8(exponent & 0xff)]
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        return out
    }
}
