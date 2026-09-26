import Foundation

// M6 X10/X11: a Standard MIDI File, type 1, written and read. Enough of the format for a song's
// written parts to leave and come back to the tick: notes, tempo, time signature, track names,
// markers. Nothing else is read; nothing else is written.

public struct MIDIFile: Hashable, Sendable {
    public struct Note: Hashable, Sendable {
        public var channel: Int
        public var pitch: Int
        public var velocity: Int
        /// Ticks from the start of the track.
        public var start: Int
        public var length: Int
        public init(channel: Int, pitch: Int, velocity: Int, start: Int, length: Int) {
            self.channel = channel
            self.pitch = pitch
            self.velocity = velocity
            self.start = start
            self.length = length
        }
    }

    public struct Marker: Hashable, Sendable {
        public var tick: Int
        public var text: String
        public init(tick: Int, text: String) { self.tick = tick; self.text = text }
    }

    public struct Track: Hashable, Sendable {
        public var name: String
        public var notes: [Note]
        public var markers: [Marker]
        /// General MIDI program, when the track sets one.
        public var program: Int?
        public init(name: String, notes: [Note], markers: [Marker] = [], program: Int? = nil) {
            self.name = name
            self.notes = notes
            self.markers = markers
            self.program = program
        }
        public var isDrums: Bool { notes.contains { $0.channel == 9 } }
    }

    public var ticksPerBeat: Int
    public var tempo: Double
    public var beatsPerBar: Int
    public var beatUnit: Int
    public var tracks: [Track]

    public init(ticksPerBeat: Int = 480, tempo: Double, beatsPerBar: Int = 4, beatUnit: Int = 4, tracks: [Track]) {
        self.ticksPerBeat = ticksPerBeat
        self.tempo = tempo
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
        self.tracks = tracks
    }

    public func ticks(beats: Double) -> Int { Int((beats * Double(ticksPerBeat)).rounded()) }
    public func beats(ticks: Int) -> Double { Double(ticks) / Double(ticksPerBeat) }

    // MARK: Writing

    public func data() -> Data {
        var out = Data()
        out.append(contentsOf: Array("MThd".utf8))
        // `ticksPerBeat` and `tempo` count the meter's own beat — an eighth in 6/8 — and a file counts
        // quarter notes, in its division and its tempo alike. Written as they were, a 6/8 song
        // put every bar line, marker and note at half the place a DAW read them at.
        let quarter = Double(max(1, beatUnit)) / 4
        out.append(be32(6)); out.append(be16(1)); out.append(be16(UInt16(tracks.count + 1)))
        out.append(be16(UInt16(max(1, Int((Double(ticksPerBeat) * quarter).rounded())))))
        // Track 0: the tempo and the time signature.
        var conductor = Data()
        let microseconds = UInt32((60_000_000 / max(1, tempo) * quarter).rounded())
        conductor.append(vlq(0)); conductor.append(contentsOf: [0xFF, 0x51, 0x03, UInt8((microseconds >> 16) & 0xFF), UInt8((microseconds >> 8) & 0xFF), UInt8(microseconds & 0xFF)])
        let denominator = UInt8(log2(Double(max(1, beatUnit))))
        conductor.append(vlq(0)); conductor.append(contentsOf: [0xFF, 0x58, 0x04, UInt8(beatsPerBar), denominator, 24, 8])
        conductor.append(vlq(0)); conductor.append(contentsOf: [0xFF, 0x2F, 0x00])
        out.append(chunk("MTrk", conductor))
        for track in tracks {
            var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
            let name = Array(track.name.utf8)
            events.append((0, 0, [0xFF, 0x03] + vlqBytes(name.count) + name))
            if let program = track.program { events.append((0, 1, [0xC0 | UInt8(track.notes.first?.channel ?? 0), UInt8(max(0, min(127, program)))])) }
            for marker in track.markers {
                let text = Array(marker.text.utf8)
                events.append((marker.tick, 2, [0xFF, 0x06] + vlqBytes(text.count) + text))
            }
            for note in track.notes {
                let channel = UInt8(max(0, min(15, note.channel)))
                events.append((note.start, 4, [0x90 | channel, UInt8(max(0, min(127, note.pitch))), UInt8(max(1, min(127, note.velocity)))]))
                events.append((note.start + max(1, note.length), 3, [0x80 | channel, UInt8(max(0, min(127, note.pitch))), 0]))
            }
            events.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
            var body = Data()
            var last = 0
            for event in events {
                body.append(vlq(event.tick - last)); body.append(contentsOf: event.bytes)
                last = event.tick
            }
            body.append(vlq(0)); body.append(contentsOf: [0xFF, 0x2F, 0x00])
            out.append(chunk("MTrk", body))
        }
        return out
    }

    public func write(to url: URL) throws { try data().write(to: url) }

    // MARK: Reading

    public enum ReadError: Error, CustomStringConvertible {
        case notMIDI, truncated, unsupportedFormat(Int)
        public var description: String {
            switch self {
            case .notMIDI: return "Not a Standard MIDI File."
            case .truncated: return "The MIDI file ends early."
            case .unsupportedFormat(let f): return "MIDI format \(f) is not read; 0 and 1 are."
            }
        }
    }

    public init(contentsOf url: URL) throws { try self.init(data: try Data(contentsOf: url)) }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, String(bytes: bytes[0..<4], encoding: .ascii) == "MThd" else { throw ReadError.notMIDI }
        let format = Int(bytes[8]) << 8 | Int(bytes[9])
        guard format == 0 || format == 1 else { throw ReadError.unsupportedFormat(format) }
        let trackCount = Int(bytes[10]) << 8 | Int(bytes[11])
        let division = Int(bytes[12]) << 8 | Int(bytes[13])
        ticksPerBeat = division & 0x8000 == 0 ? max(1, division) : 480
        tempo = 120
        beatsPerBar = 4
        beatUnit = 4
        var tracks: [Track] = []
        var offset = 8 + Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        offset = 8 + (Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7]))
        for _ in 0..<trackCount {
            guard offset + 8 <= bytes.count, String(bytes: bytes[offset..<offset + 4], encoding: .ascii) == "MTrk" else { break }
            let length = Int(bytes[offset + 4]) << 24 | Int(bytes[offset + 5]) << 16 | Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
            let start = offset + 8, end = min(bytes.count, start + length)
            var p = start
            var tick = 0
            var running: UInt8 = 0
            var name = "Track \(tracks.count + 1)"
            var notes: [Note] = []
            var markers: [Marker] = []
            var program: Int?
            var open: [Int: (start: Int, velocity: Int)] = [:]   // key: channel << 8 | pitch
            func readVLQ() -> Int {
                var value = 0
                while p < end {
                    let b = bytes[p]; p += 1
                    value = (value << 7) | Int(b & 0x7F)
                    if b & 0x80 == 0 { break }
                }
                return value
            }
            while p < end {
                tick += readVLQ()
                guard p < end else { break }
                var status = bytes[p]
                if status & 0x80 != 0 { p += 1 } else { status = running }
                if status == 0xFF {
                    guard p < end else { break }
                    let type = bytes[p]; p += 1
                    let length = readVLQ()
                    let payload = Array(bytes[p..<min(end, p + length)]); p += length
                    switch type {
                    case 0x03: name = String(bytes: payload, encoding: .utf8) ?? name
                    case 0x06: markers.append(Marker(tick: tick, text: String(bytes: payload, encoding: .utf8) ?? ""))
                    case 0x51 where payload.count == 3:
                        let micro = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                        if micro > 0 { tempo = 60_000_000 / Double(micro) }
                    case 0x58 where payload.count >= 2:
                        beatsPerBar = Int(payload[0]); beatUnit = 1 << Int(payload[1])
                    case 0x2F: p = end
                    default: break
                    }
                    continue
                }
                if status == 0xF0 || status == 0xF7 { let length = readVLQ(); p += length; continue }
                running = status
                let kind = status & 0xF0, channel = Int(status & 0x0F)
                switch kind {
                case 0x90, 0x80:
                    guard p + 1 < end + 1, p + 1 <= end - 0 else { p = end; continue }
                    let pitch = Int(bytes[p]), velocity = Int(bytes[p + 1]); p += 2
                    let key = channel << 8 | pitch
                    if kind == 0x90, velocity > 0 {
                        open[key] = (tick, velocity)
                    } else if let began = open.removeValue(forKey: key) {
                        notes.append(Note(channel: channel, pitch: pitch, velocity: began.velocity, start: began.start, length: max(1, tick - began.start)))
                    }
                case 0xA0, 0xB0, 0xE0: p += 2
                case 0xC0: program = Int(bytes[p]); p += 1
                case 0xD0: p += 1
                default: p = end
                }
            }
            for (key, began) in open {
                notes.append(Note(channel: key >> 8, pitch: key & 0xFF, velocity: began.velocity, start: began.start, length: max(1, tick - began.start)))
            }
            notes.sort { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
            tracks.append(Track(name: name, notes: notes, markers: markers, program: program))
            offset = start + length
        }
        // Track 0 of a type 1 file is the conductor: no notes, and not a part.
        self.tracks = tracks.filter { !$0.notes.isEmpty || !$0.markers.isEmpty }
        // The file counted quarter notes; this counts the meter's beat, as it was written from.
        if beatUnit != 4, beatUnit > 0 {
            ticksPerBeat = max(1, Int((Double(ticksPerBeat) * 4 / Double(beatUnit)).rounded()))
            tempo = tempo * Double(beatUnit) / 4
        }
    }

    // MARK: Bytes

    private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    private func chunk(_ tag: String, _ body: Data) -> Data {
        var out = Data(tag.utf8); out.append(be32(UInt32(body.count))); out.append(body); return out
    }
    private func vlq(_ value: Int) -> Data { Data(vlqBytes(value)) }
    private func vlqBytes(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return bytes
    }
}
