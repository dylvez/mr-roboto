import Foundation
import Testing

@testable import Performance

// M6 X10/X11: a Standard MIDI File written and read back to the tick.

@Suite("MIDI file: written and read to the tick")
struct MIDIFileTests {

    @Test("notes, names, tempo, time signature and markers round-trip")
    func roundTrip() throws {
        let drums = MIDIFile.Track(name: "Boom-bap pocket", notes: [
            .init(channel: 9, pitch: 36, velocity: 90, start: 0, length: 120),
            .init(channel: 9, pitch: 38, velocity: 120, start: 480, length: 120),
            .init(channel: 9, pitch: 42, velocity: 40, start: 240, length: 60),
        ], markers: [.init(tick: 0, text: "Verse"), .init(tick: 1920 * 4, text: "Hook")])
        let bass = MIDIFile.Track(name: "Palladino line", notes: [
            .init(channel: 0, pitch: 38, velocity: 100, start: 0, length: 480),
            .init(channel: 0, pitch: 45, velocity: 100, start: 960, length: 240),
            .init(channel: 0, pitch: 38, velocity: 100, start: 960, length: 240),   // a chord: two notes at one tick
        ], program: 33)
        let file = MIDIFile(ticksPerBeat: 480, tempo: 92, beatsPerBar: 4, beatUnit: 4, tracks: [drums, bass])
        let data = file.data()
        #expect(data.prefix(4) == Data("MThd".utf8))
        let back = try MIDIFile(data: data)
        #expect(back.ticksPerBeat == 480 && abs(back.tempo - 92) < 0.01 && back.beatsPerBar == 4 && back.beatUnit == 4)
        #expect(back.tracks.count == 2)
        #expect(back.tracks[0].name == "Boom-bap pocket" && back.tracks[0].isDrums)
        #expect(back.tracks[0].notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) } == drums.notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) })
        #expect(back.tracks[0].markers == drums.markers)
        #expect(back.tracks[1].name == "Palladino line" && back.tracks[1].program == 33 && !back.tracks[1].isDrums)
        #expect(back.tracks[1].notes == bass.notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) })
        #expect(file.ticks(beats: 1.5) == 720 && file.beats(ticks: 720) == 1.5)
    }

    @Test("not a MIDI file is said as such")
    func notMIDI() {
        #expect(throws: MIDIFile.ReadError.self) { try MIDIFile(data: Data("RIFF....WAVE".utf8)) }
    }
}
