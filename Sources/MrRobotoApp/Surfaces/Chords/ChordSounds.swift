import Foundation
import Instrument
import Performance
import SongGraph

// A sound the chords are played with, kept by name across songs: the instrument, how it is played,
// and what its strip does to it. The Orchid saves a sound with its performance mode and its
// effects, so a sound found once is a press away in the next song; before this the instrument, the
// rhythm, the voicing and the effects were four picks to make again every time.

/// What a strip does to a part's sound, as against how loud it is or where it sits: what it plays
/// through, the pedal and the modulation, its filter, and its sends to the room and the echo. The
/// level, the pan, the EQ and the compressor are the mix's, and a sound carried to another song
/// leaves them where that song has them.
public struct StripSound: Hashable, Codable, Sendable {
    public var insert: StripInsert?
    public var pedal: StripPedal?
    public var modulation: StripModulation?
    public var filter: StripFilter?
    public var sendDB: Double?
    public var echoDB: Double?

    public init(insert: StripInsert? = nil, pedal: StripPedal? = nil, modulation: StripModulation? = nil,
                filter: StripFilter? = nil, sendDB: Double? = nil, echoDB: Double? = nil) {
        self.insert = insert
        self.pedal = pedal
        self.modulation = modulation
        self.filter = filter
        self.sendDB = sendDB
        self.echoDB = echoDB
    }

    /// What a strip does now; nothing for a part the mix has not touched.
    public init(_ strip: Strip?) {
        self.init(insert: strip?.insert, pedal: strip?.pedal, modulation: strip?.modulation,
                  filter: strip?.filter, sendDB: strip?.sendDB, echoDB: strip?.echoDB)
    }

    /// Puts it on a strip, in place of what the strip did.
    public func apply(to strip: inout Strip) {
        strip.insert = insert
        strip.pedal = pedal
        strip.modulation = modulation
        strip.filter = filter
        strip.sendDB = sendDB
        strip.echoDB = echoDB
    }

    public var isNothing: Bool { self == StripSound() }

    /// "chorus, the room at −14 dB": what it does, for a menu's line.
    public var words: String {
        var said: [String] = []
        if let insert, insert != .off { said.append(insert.id ?? "an insert") }
        if pedal != nil { said.append("a pedal") }
        if let modulation, modulation != .off { said.append(modulation.id ?? "modulation") }
        if filter != nil { said.append("a filter") }
        if let sendDB { said.append(String(format: "the room at %.0f dB", sendDB)) }
        if let echoDB { said.append(String(format: "the echo at %.0f dB", echoDB)) }
        return said.isEmpty ? "dry" : said.joined(separator: ", ")
    }
}

/// A sound for the chords, by name: the instrument, the way it is played, and the strip.
public struct ChordSound: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var instrument: String
    /// The pattern, voicing, roll and slop; the seed is the song's, chosen afresh where it is used.
    public var playing: ChordPlaying
    public var strip: StripSound

    public var id: String { name }

    public init(name: String, instrument: String, playing: ChordPlaying, strip: StripSound = StripSound()) {
        self.name = name
        self.instrument = instrument
        var playing = playing
        playing.seed = 0
        self.playing = playing
        self.strip = strip
    }

    /// "Rhodes · pushes, voice-led, loose · chorus, the room at −14 dB".
    public var summary: String {
        let instrument = InstrumentVoiceSpec.preset(id: instrument)?.name ?? instrument
        return "\(instrument) · \(playing.sentence.lowercased()) · \(strip.words)"
    }

    /// The sounds the app comes with, one for each way of letting a chord go: kept out of the list
    /// when their instrument is not here, so none of them is a sound that cannot play.
    public static let starters: [ChordSound] = [
        ChordSound(name: "Late-night Rhodes", instrument: "rhodes",
                   playing: ChordPlaying(.pushes, .led, slop: true), strip: StripSound(modulation: .chorus, sendDB: -14)),
        ChordSound(name: "Nylon strum", instrument: "nylon-guitar",
                   playing: ChordPlaying(.eighths, .spread, roll: .strum, slop: true), strip: StripSound(sendDB: -16)),
        ChordSound(name: "Harp bed", instrument: "harp",
                   playing: ChordPlaying(.held, .spread, roll: .harp), strip: StripSound(sendDB: -10, echoDB: -18)),
        ChordSound(name: "Rolling saws", instrument: "juno",
                   playing: ChordPlaying(.rolling, .led), strip: StripSound(modulation: .chorusWide, echoDB: -14)),
        ChordSound(name: "Organ skank", instrument: "rock-organ",
                   playing: ChordPlaying(.offbeats, .close), strip: StripSound(insert: .rotarySlow, sendDB: -20)),
    ].filter { InstrumentVoiceSpec.preset(id: $0.instrument) != nil }
}

/// The sounds kept: the starters, then the ones saved, in `UserDefaults` as JSON so they are there
/// in every song.
public struct ChordSoundShelf {
    private let defaults: UserDefaults
    static let key = "chords.sounds"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The ones saved, in the order they were first saved.
    public var saved: [ChordSound] {
        guard let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([ChordSound].self, from: data) else { return [] }
        return stored
    }

    /// The starters and the saved, a saved sound taking the place of a starter of the same name.
    public var sounds: [ChordSound] {
        let saved = self.saved
        return ChordSound.starters.filter { starter in !saved.contains { $0.name == starter.name } } + saved
    }

    /// Keeps a sound, in place of one already kept under its name.
    public func save(_ sound: ChordSound) {
        var stored = saved
        if let index = stored.firstIndex(where: { $0.name == sound.name }) { stored[index] = sound } else { stored.append(sound) }
        write(stored)
    }

    /// Forgets a saved sound. A starter is not forgotten: it is the app's.
    public func remove(named name: String) {
        write(saved.filter { $0.name != name })
    }

    private func write(_ sounds: [ChordSound]) {
        if let data = try? JSONEncoder().encode(sounds) { defaults.set(data, forKey: Self.key) }
    }
}
