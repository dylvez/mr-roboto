import CoreMIDI
import Foundation

// Inputs I4: a CoreMIDI client with a port on every source, and the events it delivers.

/// One thing a controller said, with the host time it said it.
public struct MIDIEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case noteOn(note: Int, velocity: Int)
        case noteOff(note: Int)
        case controlChange(controller: Int, value: Int)
    }

    public var kind: Kind
    /// 0-based channel.
    public var channel: Int
    public var hostTime: UInt64
    /// The source's display name, "Launchkey Mini MK3".
    public var source: String

    public init(kind: Kind, channel: Int, hostTime: UInt64, source: String) {
        self.kind = kind
        self.channel = channel
        self.hostTime = hostTime
        self.source = source
    }

    public var note: Int? {
        switch kind {
        case .noteOn(let note, _), .noteOff(let note): return note
        case .controlChange: return nil
        }
    }
}

/// Universal MIDI Packets and MIDI 1.0 byte streams, read into events. Pure, so a test can feed it.
public enum MIDIParse {

    /// UMP words (what a MIDI 1.0-protocol input port delivers): message type 2 is a MIDI 1.0
    /// channel-voice message in one word. Other types (utility, system, sysex, MIDI 2.0 voice) are
    /// skipped by their word count. A note-on at velocity 0 is a note-off, as on the wire.
    public static func events(words: [UInt32], hostTime: UInt64, source: String) -> [MIDIEvent] {
        var out: [MIDIEvent] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let type = Int(word >> 28)
            switch type {
            case 0x2:
                let status = Int((word >> 16) & 0xFF), data1 = Int((word >> 8) & 0x7F), data2 = Int(word & 0x7F)
                if let kind = kind(status: status, data1: data1, data2: data2) {
                    out.append(MIDIEvent(kind: kind, channel: status & 0x0F, hostTime: hostTime, source: source))
                }
                index += 1
            case 0x0, 0x1, 0x6, 0x7: index += 1
            case 0x3, 0x4, 0x8, 0x9, 0xA: index += 2
            case 0xB, 0xC: index += 3
            default: index += 4
            }
        }
        return out
    }

    /// A MIDI 1.0 byte stream with running status, as a legacy packet carries it.
    public static func events(bytes: [UInt8], hostTime: UInt64, source: String) -> [MIDIEvent] {
        var out: [MIDIEvent] = []
        var status = 0
        var index = 0
        func dataLength(_ status: Int) -> Int {
            switch status & 0xF0 {
            case 0xC0, 0xD0: return 1
            case 0xF0: return status == 0xF2 ? 2 : (status == 0xF1 || status == 0xF3 ? 1 : 0)
            default: return 2
            }
        }
        while index < bytes.count {
            let byte = Int(bytes[index])
            if byte & 0x80 != 0 {
                status = byte
                index += 1
                if status == 0xF0 { // sysex: skip to the end
                    while index < bytes.count, bytes[index] != 0xF7 { index += 1 }
                    index += 1
                    status = 0
                }
                continue
            }
            guard status != 0 else { index += 1; continue }
            let length = dataLength(status)
            guard length > 0 else { index += 1; continue }
            let data1 = byte
            let data2 = length == 2 && index + 1 < bytes.count ? Int(bytes[index + 1]) : 0
            if let kind = kind(status: status, data1: data1, data2: data2) {
                out.append(MIDIEvent(kind: kind, channel: status & 0x0F, hostTime: hostTime, source: source))
            }
            index += length
        }
        return out
    }

    static func kind(status: Int, data1: Int, data2: Int) -> MIDIEvent.Kind? {
        switch status & 0xF0 {
        case 0x90: return data2 == 0 ? .noteOff(note: data1) : .noteOn(note: data1, velocity: data2)
        case 0x80: return .noteOff(note: data1)
        case 0xB0: return .controlChange(controller: data1, value: data2)
        default: return nil
        }
    }
}

/// The client: a port on every source here now and every one that turns up later. Events reach
/// the handler on CoreMIDI's thread; the app hops to the main actor itself.
public final class MIDIInput: @unchecked Sendable {

    public struct Source: Hashable, Sendable, Identifiable {
        public var id: MIDIEndpointRef
        public var name: String
    }

    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef: String] = [:]
    private let handler: @Sendable (MIDIEvent) -> Void
    private let sourcesChanged: @Sendable ([Source]) -> Void

    /// The sources with a port on them, by name.
    public var sources: [Source] {
        lock.withLock { connected.map { Source(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name } }
    }

    /// - Parameters:
    ///   - name: the client's name, as Audio MIDI Setup shows it.
    ///   - handler: every event, on CoreMIDI's thread.
    ///   - sourcesChanged: the sources after a controller is plugged in or pulled.
    public init(name: String = "Mr. Roboto", handler: @escaping @Sendable (MIDIEvent) -> Void,
                sourcesChanged: @escaping @Sendable ([Source]) -> Void = { _ in }) throws {
        self.handler = handler
        self.sourcesChanged = sourcesChanged
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged { self?.refresh() }
        }
        guard status == noErr else { throw MIDIInputError.client(status) }
        self.client = client
        var port = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(client, "\(name) In" as CFString, ._1_0, &port) { [weak self] list, refCon in
            self?.receive(list, refCon: refCon)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            throw MIDIInputError.port(portStatus)
        }
        self.port = port
        refresh()
    }

    deinit {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Connects every source not yet connected and forgets the ones gone.
    public func refresh() {
        let count = MIDIGetNumberOfSources()
        var present: [MIDIEndpointRef: String] = [:]
        for index in 0..<count {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            present[endpoint] = Self.name(of: endpoint)
        }
        let before = lock.withLock { connected }
        for (endpoint, name) in present where before[endpoint] == nil {
            let status = MIDIPortConnectSource(port, endpoint, UnsafeMutableRawPointer(bitPattern: UInt(endpoint)))
            if status == noErr { lock.withLock { connected[endpoint] = name } }
        }
        for endpoint in before.keys where present[endpoint] == nil {
            MIDIPortDisconnectSource(port, endpoint)
            lock.withLock { connected[endpoint] = nil }
        }
        if before != lock.withLock({ connected }) { sourcesChanged(sources) }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, refCon: UnsafeMutableRawPointer?) {
        let endpoint = refCon.map { MIDIEndpointRef(UInt(bitPattern: $0)) } ?? 0
        let source = lock.withLock { connected[endpoint] } ?? "MIDI"
        for packet in list.unsafeSequence() {
            var copy = packet.pointee
            let count = Int(copy.wordCount)
            let words = withUnsafePointer(to: &copy.words) { tuple in
                tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { Array(UnsafeBufferPointer(start: $0, count: min(64, count))) }
            }
            for event in MIDIParse.events(words: words, hostTime: copy.timeStamp, source: source) { handler(event) }
        }
    }

    static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr, let cf = value?.takeRetainedValue() {
            return cf as String
        }
        return "MIDI source \(endpoint)"
    }
}

public enum MIDIInputError: Error, CustomStringConvertible {
    case client(OSStatus)
    case port(OSStatus)
    public var description: String {
        switch self {
        case .client(let status): return "CoreMIDI would not make a client (\(status))"
        case .port(let status): return "CoreMIDI would not make an input port (\(status))"
        }
    }
}
