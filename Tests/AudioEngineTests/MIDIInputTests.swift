import CoreMIDI
import Foundation
import Testing

@testable import AudioEngine

// Inputs I4: packets parse to events with their times; a client comes up with a port.

@Suite("MIDI in: packets to events")
struct MIDIInputTests {

    @Test("UMP words: note on, note off, control change, a zero-velocity note-on as off, other types skipped by size")
    func ump() {
        let words: [UInt32] = [
            0x2090_3C64, // note on ch 0, 60, 100
            0x4090_3C00, 0x8000_0000, // a MIDI 2.0 voice message: two words, skipped
            0x2080_3C40, // note off ch 0, 60
            0x20B0_0E7F, // CC 14 = 127 on ch 0
            0x2999_2400, // note on ch 9, 36, velocity 0 → off
            0x1000_0000, // system message, one word, skipped
        ]
        let events = MIDIParse.events(words: words, hostTime: 42, source: "Pad")
        #expect(events.count == 4)
        #expect(events[0].kind == .noteOn(note: 60, velocity: 100) && events[0].channel == 0 && events[0].hostTime == 42 && events[0].source == "Pad")
        #expect(events[1].kind == .noteOff(note: 60))
        #expect(events[2].kind == .controlChange(controller: 14, value: 127))
        #expect(events[3].kind == .noteOff(note: 36) && events[3].channel == 9)
    }

    @Test("a MIDI 1.0 byte stream with running status and a sysex in the middle")
    func bytes() {
        let stream: [UInt8] = [0x99, 36, 100, 38, 90, 0xF0, 0x7E, 0x01, 0xF7, 0x89, 36, 0, 0xB0, 22, 64, 0xC0, 5]
        let events = MIDIParse.events(bytes: stream, hostTime: 7, source: "Keys")
        #expect(events.map(\.kind) == [.noteOn(note: 36, velocity: 100), .noteOn(note: 38, velocity: 90), .noteOff(note: 36), .controlChange(controller: 22, value: 64)])
        #expect(events.allSatisfy { $0.hostTime == 7 })
        #expect(events[0].channel == 9 && events[3].channel == 0)
    }

    @Test("a client comes up, lists whatever sources are here, and can be asked again")
    func client() throws {
        let input = try MIDIInput(name: "Mr. Roboto test", handler: { _ in })
        let sources = input.sources
        #expect(sources.allSatisfy { !$0.name.isEmpty })
        input.refresh()
        #expect(input.sources == sources)
    }
}
