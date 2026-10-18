import Foundation
import SongGraph

// Recorded instruments heard the way their records hear them.
//
// The library's electric guitars were recorded direct — straight from the pickups into the desk,
// as sample libraries are, so that whoever plays them chooses the amp. Played that way they are
// thin and plinky, and an overdriven guitar, which every rock, blues, cumbia and ska profile
// names, was a synthesized string through the strip's amp, because no recording of one existed.
// A treatment is one recording and what it is played through, offered as an instrument of its
// own: the Emily guitar through the amp at crunch is the overdriven guitar. It plays the
// recording's own kit — nothing is copied or rendered — and brings its insert to its strip the way
// an organ brings its speaker, so the Mixer can still change it or take it off.

public struct Treatment: Sendable, Hashable {
    public var id: String
    public var name: String
    public var family: String
    public var summary: String
    /// The recordings it can be made from, the one to reach for first, by name.
    public var recordings: [String]
    public var insert: StripInsert?
    public var modulation: StripModulation?

    public static let cleanAmp = Treatment(
        id: "treated-electric-clean", name: "Electric Guitar, Clean Amp", family: "guitar",
        summary: "The recorded electric through a clean amp and its cabinet: round and warm, the clean guitar of soul, reggae and funk.",
        recordings: ["Electric Guitar", "Gretsch Guitar", "Hofner Guitar"], insert: .ampClean)
    public static let crunch = Treatment(
        id: "treated-electric-crunch", name: "Electric Guitar, Crunch", family: "guitar",
        summary: "The recorded electric through an amp pushed until chords break up: blues, rock, cumbia and ska.",
        recordings: ["Electric Guitar", "Gretsch Guitar", "Hofner Guitar"], insert: .ampCrunch)
    public static let lead = Treatment(
        id: "treated-electric-lead", name: "Electric Guitar, Lead", family: "guitar",
        summary: "The recorded electric through an amp at a lead's gain: sustain and saturation for riffs, power chords and solos.",
        recordings: ["Electric Guitar", "Gretsch Guitar", "Hofner Guitar"], insert: .ampLead)

    /// The Unitra B-11's stops together through the combo organ's vibrato and a small amp: a
    /// recorded transistor organ heard as the sixties combo organ was.
    public static let combo = Treatment(
        id: "treated-transistor-combo", name: "Transistor Organ, Combo", family: "organ",
        summary: "A recorded sixties transistor organ, every stop out, with a vibrato and a small amp: the combo organ of ska, garage and sixties pop.",
        recordings: ["Transistor Organ"], insert: .ampClean, modulation: .vibrato)

    public static let all: [Treatment] = [cleanAmp, crunch, lead, combo]

    /// The treatments the library can make, as instruments: each on the first of its recordings
    /// that is here.
    public static func available(among specs: [InstrumentVoiceSpec]) -> [InstrumentVoiceSpec] {
        let recorded = specs.filter { $0.engine == .sampled && $0.sampledKit != nil && !$0.isMadeFromRecordings }
        return all.compactMap { treatment in
            guard let base = treatment.recordings.lazy.compactMap({ name in
                recorded.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }).first else { return nil }
            var spec = base
            spec.id = treatment.id
            spec.name = treatment.name
            spec.family = treatment.family
            spec.summary = treatment.summary
            spec.insert = treatment.insert
            spec.modulation = treatment.modulation
            spec.basedOn = base.id
            return spec
        }
    }
}
