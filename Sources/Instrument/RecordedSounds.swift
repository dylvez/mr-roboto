import Foundation

/// The recordings that play what a built-in sound stands for.
///
/// The built-in instruments are synthesized, and for anything acoustic — a piano, strings, a
/// trumpet — a recording of the instrument is what a record sounds like. The genre profiles name
/// their sounds by built-in id, because that is what every library has; this is where a library
/// that holds recordings says which of them each id means. A sound with no recording in the
/// library stays the synthesized one, and a sound that is a synth (a pad, a lead, a stab) has no
/// recording to stand in for it.
public enum RecordedSounds {

    /// Built-in id to the recordings that play it, by name, the one to reach for first. Sections
    /// by id (`Ensembles`).
    ///
    /// Two are what the genres mean rather than what the preset is: "horns" — a French horn
    /// among the presets — is named by soul, funk, reggae, salsa and the rest for their horn
    /// section; "brass" likewise. Names follow what the instrument packs call their recordings.
    public static let candidates: [String: [String]] = [
        "grand-piano": ["Steinway Grand", "Salamander Grand Piano (Light)", "Kawai Grand", "Splendid Grand Piano",
                        "Headroom Piano", "Osiris Piano"],
        "felt-piano": ["Intimate Piano", "Upright Piano", "Knight Upright", "Upright Piano No. 1"],
        "rhodes": ["Rhodes"],
        "wurlitzer": ["Wurlitzer"],
        "fm-piano": ["FM Piano"],
        "harpsichord": ["Harpsichord", "Harpsichord, French", "Harpsichord, Italian"],
        "pipe-organ": ["Pipe Organ", "Pipe Organ, Quiet"],
        "marimba": ["Marimba"],
        "vibraphone": ["Vibraphone"],
        "xylophone": ["Xylophone"],
        "glockenspiel": ["Glockenspiel"],
        "kalimba": ["Kalimba", "Kalimba, Kenya", "Mbira"],
        "steel-drum": ["Steel Drum"],
        "tubular-bells": ["Tubular Bells"],
        "clean-electric": [Treatment.cleanAmp.id, "Electric Guitar", "Gretsch Guitar", "Hofner Guitar", "Archtop Guitar, Pickup"],
        "overdrive-guitar": [Treatment.crunch.id],
        "distorted-guitar": [Treatment.lead.id],
        "muted-guitar": ["Gretsch Guitar Staccato", "Hofner Guitar Staccato"],
        "nylon-guitar": ["Nylon Guitar"],
        "harp": ["Harp", "Concert Harp", "Folk Harp"],
        "koto": ["Dan Tranh"],
        "banjo": ["Ganjo"],
        "pizzicato": ["Violin Section Pizzicato", "Cello Section Pizzicato", "Viola Section Pizzicato"],
        "strings": [Ensemble.stringSection.id, "Violin Section"],
        "slow-strings": [Ensemble.stringSection.id, "Violin Section"],
        "violin": ["Solo Violin"],
        "cello": ["Solo Cello", "Cello Section"],
        "flute": ["Flute", "Concert Flute"],
        "clarinet": ["Clarinet"],
        "oboe": ["Oboe"],
        "tenor-sax": ["Tenor Saxophone, Vibrato", "Tenor Saxophone, Studio", "Tenor Saxophone, Non-Vibrato"],
        "alto-sax": ["Alto Saxophone", "Alto Saxophone, Close"],
        "trumpet": ["Trumpet"],
        "horns": [Ensemble.hornSection.id, Ensemble.hornTrio.id, "French Horn"],
        // A choir of one vowel for the choir, and for the oohs nearer than a synthesized voice.
        "choir": ["Choir"],
        "oohs": ["Choir"],
        "combo-organ": [Treatment.combo.id, "Transistor Organ"],
        "brass": [Ensemble.hornSection.id, Ensemble.hornTrio.id],
    ]

    /// Built-in bass sound to the recordings that play it, by name. The synth basses — the sub,
    /// the 808, the acid line — are synths, and have none; nor have slap and fretless yet, which
    /// no pack in the library records.
    public static let basses: [String: [String]] = [
        "finger": ["Jazz Bass", "Roundwound Bass", "Black Bass", "Blue Bass"],
        "picked": ["Bass VI, Picked", "Roundwound Bass"],
        "muted": ["Flatwound Bass", "Jazz Bass Staccato", "Black Bass Staccato"],
        "upright": ["Double Bass Pizzicato", "Double Bass, Late Night", "Contrabass Pizzicato"],
    ]

    /// Built-in drum machine to the recorded kits that play it, by name: the machines that stand
    /// for a kit somebody hits with sticks. The drum machines themselves — the 808, the 909, the
    /// Linn — are what they are.
    public static let kits: [String: [String]] = [
        "studio": ["Naked Drums", "Virtuosity Drums", "Muldjord Kit"],
        "rock": ["Big Rusty Drums", "Muldjord Kit", "Naked Drums"],
        "funk": ["Naked Drums", "Virtuosity Drums"],
        "vintage": ["Gogodze Phu", "Naked Drums"],
        "jazz": ["Swirly Brushes"],
        "lofi": ["Gogodze Phu"],
    ]

    /// The recording in the library that plays the built-in bass sound `id`.
    public static func bass(for id: String, among specs: [InstrumentVoiceSpec] = ImportedInstruments.all) -> InstrumentVoiceSpec? {
        guard let names = basses[id] else { return nil }
        let recorded = specs.filter { $0.engine == .sampled && !$0.isMadeFromRecordings }
        for name in names {
            if let found = recorded.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
        }
        return nil
    }

    /// The recorded kit in the library that plays the built-in machine `id`.
    public static func kit(for id: String, among kits: [SynthMachine] = RecordedKits.machines) -> SynthMachine? {
        guard let names = self.kits[id] else { return nil }
        for name in names {
            if let found = kits.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
        }
        return nil
    }

    /// The recording in `specs` that plays the built-in `id`, the first of its candidates there.
    /// Nil when the library has none, or the sound is one only a synthesizer makes.
    public static func recording(for id: String, among specs: [InstrumentVoiceSpec]) -> InstrumentVoiceSpec? {
        guard let names = candidates[id] else { return nil }
        let recorded = specs.filter { $0.engine == .sampled }
        for name in names {
            if let found = recorded.first(where: { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return found
            }
        }
        return nil
    }

    /// The same, among what is imported now.
    public static func recording(for id: String) -> InstrumentVoiceSpec? {
        recording(for: id, among: ImportedInstruments.all)
    }

    /// Whether a built-in sound is acoustic, so that a recording of it is what it should be heard
    /// on: everything `candidates` names, whether or not the library has the recording.
    public static func hasRecordedCounterpart(_ id: String) -> Bool { candidates[id] != nil || basses[id] != nil || kits[id] != nil }
}
