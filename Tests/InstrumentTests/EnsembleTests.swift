import Foundation
import SongGraph
import Testing
@testable import Instrument

/// Recorded instruments played as players play them: a short note on the short recording, a
/// chord dealt out to a section.
@Suite("Ensembles and articulations")
struct EnsembleTests {

    // MARK: Articulations

    static func recorded(_ name: String, folder: String? = nil) -> InstrumentVoiceSpec {
        var spec = InstrumentVoiceSpec(id: "sfz-\(ImportedInstruments.slug(of: name))", name: name, family: "brass", engine: .sampled)
        spec.sampledKit = "/library/Instruments/\(folder ?? ImportedInstruments.slug(of: name))"
        return spec
    }

    @Test("A short recording is paired with the held one it is the short notes of, by name")
    func partners() {
        let specs = [
            "Trumpet", "Trumpet Staccato", "Trumpet, Harmon Mute",
            "Tenor Saxophone, Vibrato", "Tenor Saxophone, Non-Vibrato", "Tenor Saxophone, Studio", "Tenor Saxophone Staccato",
            "Baritone Saxophone, 1926", "Baritone Saxophone, 1926 Growl", "Baritone Saxophone, 1926 Staccato",
            "Erhu", "Erhu Short", "Violin Section", "Violin Section Spiccato", "Flute",
        ].map { Self.recorded($0) }
        let pairs = Articulations.partners(among: specs)
        func short(of name: String) -> String? { pairs[Self.recorded(name).id]?.name }
        #expect(short(of: "Trumpet") == "Trumpet Staccato")
        #expect(short(of: "Trumpet, Harmon Mute") == nil)
        #expect(short(of: "Tenor Saxophone, Vibrato") == "Tenor Saxophone Staccato")
        #expect(short(of: "Tenor Saxophone, Non-Vibrato") == "Tenor Saxophone Staccato")
        // Another tenor altogether, from another pack: not this one's staccato.
        #expect(short(of: "Tenor Saxophone, Studio") == nil)
        #expect(short(of: "Baritone Saxophone, 1926") == "Baritone Saxophone, 1926 Staccato")
        #expect(short(of: "Baritone Saxophone, 1926 Growl") == nil)
        #expect(short(of: "Erhu") == "Erhu Short")
        #expect(short(of: "Violin Section") == "Violin Section Spiccato")
        #expect(short(of: "Flute") == nil)
        // A short recording is nobody's held one.
        #expect(short(of: "Trumpet Staccato") == nil)
    }

    // MARK: Choosing a zone

    static let articulated = KitManifest(name: "Articulated", zones: [
        Zone(id: "held", sample: "held.wav", key: .range(48...84, rootNote: 60)),
        Zone(id: "short", sample: "short.wav", key: .range(48...84, rootNote: 60), longest: 0.25),
        Zone(id: "short-top", sample: "short-top.wav", key: .range(85...90, rootNote: 86), longest: 0.25),
    ])

    @Test("A note no longer than a short recording's longest plays on it; any other on the held one")
    func byLength() {
        let kit = Self.articulated
        #expect(kit.zone(note: 60, velocity: 100, length: 0.2)?.id == "short")
        #expect(kit.zone(note: 60, velocity: 100, length: 0.25)?.id == "short")
        #expect(kit.zone(note: 60, velocity: 100, length: 0.6)?.id == "held")
        // A key held on a controller: no length, so the held recording.
        #expect(kit.zone(note: 60, velocity: 100)?.id == "held")
        // Where only the short recording reaches, it plays whatever the length.
        #expect(kit.zone(note: 86, velocity: 100, length: 2)?.id == "short-top")
        // A kit with no short recordings is not asked about length.
        let plain = KitManifest(name: "Plain", zones: [Zone(id: "only", sample: "x.wav", key: .range(0...127, rootNote: 60))])
        #expect(plain.zone(note: 60, velocity: 100, length: 0.1)?.id == "only")
    }

    @Test("A section's note is played by the player it was dealt to")
    func byLayer() {
        let kit = KitManifest(name: "Section", zones: [
            Zone(id: "top", sample: "a.wav", key: .range(55...84, rootNote: 70), layer: 0),
            Zone(id: "bottom", sample: "b.wav", key: .range(40...72, rootNote: 55), layer: 1),
        ])
        #expect(kit.zone(note: 60, velocity: 100, layer: 0)?.id == "top")
        #expect(kit.zone(note: 60, velocity: 100, layer: 1)?.id == "bottom")
        // For no player, the top one's.
        #expect(kit.zone(note: 60, velocity: 100)?.id == "top")
        // A player with nothing on the note gives way to one that has.
        #expect(kit.zone(note: 80, velocity: 100, layer: 1)?.id == "top")
    }

    // MARK: Dealing

    /// The Horn Section's players with reaches like the recordings': trumpet, alto, tenor, trombone.
    static let horns = KitEnsemble(players: [
        .init(name: "trumpet", range: 52...84, centre: 72),
        .init(name: "alto saxophone", range: 49...80, centre: 67),
        .init(name: "tenor saxophone", range: 44...75, centre: 62),
        .init(name: "trombone", range: 40...72, centre: 55),
    ], lead: 74, rootBelow: false)

    static let strings = KitEnsemble(players: [
        .init(name: "first violins", range: 55...96, centre: 74),
        .init(name: "second violins", range: 55...96, centre: 67),
        .init(name: "violas", range: 48...84, centre: 60),
        .init(name: "cellos", range: 36...72, centre: 48),
    ], lead: 72, rootBelow: true)

    static func chord(_ notes: [Int], at time: Double = 1, duration: Double = 0.2, velocity: Int = 90) -> [VoiceSampler.Hit] {
        notes.map { VoiceSampler.Hit(note: $0, velocity: velocity, at: time, duration: duration) }
    }

    @Test("A chord struck on the horns is voiced close under the trumpet, a note to each player")
    func hornChord() throws {
        // Dm7 as the keys player voices it, round C3.
        let dealt = Self.horns.dealt(Self.chord([50, 53, 57, 60], velocity: 84))
        #expect(dealt.count == 4)
        #expect(Set(dealt.compactMap(\.layer)) == [0, 1, 2, 3])
        let byPlayer = dealt.sorted { ($0.layer ?? 0) < ($1.layer ?? 0) }.compactMap(\.note)
        // Top to bottom, every player in its own reach, the top near the lead.
        #expect(byPlayer == byPlayer.sorted(by: >))
        for (index, note) in byPlayer.enumerated() { #expect(Self.horns.players[index].range.contains(note)) }
        #expect(abs(byPlayer[0] - 74) <= 2)
        // Close: inside an octave and a bit, with all four tones of the chord and no rub.
        #expect(byPlayer[0] - byPlayer[3] <= 14)
        #expect(Set(byPlayer.map { $0 % 12 }) == [2, 5, 9, 0])
        #expect(KitEnsemble.rubs(in: byPlayer) == 0)
        // Each struck once, as hard and as long as the chord.
        #expect(dealt.allSatisfy { $0.velocity == 84 && $0.duration == 0.2 && $0.time == 1 })
    }

    @Test("A triad on four horns doubles its top an octave down")
    func triadDoubled() {
        let notes = Self.horns.dealt(Self.chord([48, 52, 55])).sorted { ($0.layer ?? 0) < ($1.layer ?? 0) }.compactMap(\.note)
        #expect(notes.count == 4)
        #expect(notes[3] == notes[0] - 12)
        #expect(Set(notes.map { $0 % 12 }) == [0, 4, 7])
    }

    @Test("Three horns keep the third and the seventh of a seventh chord, and drop the fifth first")
    func threeHorns() {
        let trio = KitEnsemble(players: Array(Self.horns.players.prefix(2)) + [Self.horns.players[3]], lead: 74, rootBelow: false)
        let classes = Set(trio.dealt(Self.chord([43, 47, 50, 53])).compactMap(\.note).map { $0 % 12 })  // G7
        #expect(classes == [11, 5, 7])  // B, F and G; the D goes
    }

    @Test("A line on the horns is played in unison and octaves, never a player over the one above")
    func hornLine() {
        let high = Self.horns.dealt([VoiceSampler.Hit(note: 72, velocity: 100, at: 0, duration: 0.5)])
            .sorted { ($0.layer ?? 0) < ($1.layer ?? 0) }.compactMap(\.note)
        #expect(high == [72, 72, 60, 60])
        let low = Self.horns.dealt([VoiceSampler.Hit(note: 60, velocity: 100, at: 0, duration: 0.5)])
            .sorted { ($0.layer ?? 0) < ($1.layer ?? 0) }.compactMap(\.note)
        #expect(low == [60, 60, 60, 60])
        // Struck in octaves is still a line.
        let octaves = Self.horns.dealt(Self.chord([60, 72]))
        #expect(octaves.count == 4)
    }

    @Test("A key held on a controller is played as it is, by the player whose register it is in")
    func heldKey() {
        let high = Self.horns.dealt([VoiceSampler.Hit(note: 74, velocity: 100, at: 0)])
        #expect(high.map(\.note) == [74] && high.map(\.layer) == [0])
        let low = Self.horns.dealt([VoiceSampler.Hit(note: 50, velocity: 100, at: 0)])
        #expect(low.map(\.note) == [50] && low.map(\.layer) == [3])
        // Out of everyone's reach: nothing to play it.
        #expect(Self.horns.dealt([VoiceSampler.Hit(note: 100, velocity: 100, at: 0)]).isEmpty)
    }

    @Test("The strings put the cellos on the chord's bass, under the others")
    func stringsRootBelow() {
        let dealt = Self.strings.dealt(Self.chord([45, 48, 52, 55]))  // Am7
        let cellos = dealt.first { $0.layer == 3 }?.note
        #expect(cellos.map { $0 % 12 } == 9)
        let upper = dealt.filter { $0.layer != 3 }.compactMap(\.note)
        #expect(upper.count == 3)
        #expect(cellos.map { cello in upper.allSatisfy { $0 > cello } } == true)
    }

    @Test("A drum hit, or a note already dealt, passes a section by; chords apart are dealt apart")
    func passesThrough() {
        let drum = VoiceSampler.Hit(.kick, velocity: 100, at: 0)
        let dealt = VoiceSampler.Hit(note: 60, velocity: 100, at: 0, layer: 2)
        #expect(Self.horns.dealt([drum, dealt]) == [drum, dealt])
        let two = Self.horns.dealt(Self.chord([48, 52, 55], at: 0) + Self.chord([53, 57, 60], at: 1))
        #expect(two.filter { $0.time == 0 }.count == 4)
        #expect(two.filter { $0.time == 1 }.count == 4)
    }

    // MARK: Seating

    @Test("A section is offered only when the library has every chair's recording")
    func available() {
        let horns = ["Trumpet", "Alto Saxophone", "Tenor Saxophone, Vibrato", "Trombone"].map { Self.recorded($0) }
        let offered = Ensemble.available(among: horns)
        #expect(offered.map(\.id).contains(Ensemble.hornSection.id))
        #expect(offered.map(\.id).contains(Ensemble.hornTrio.id))
        #expect(!offered.map(\.id).contains(Ensemble.stringSection.id))
        let section = offered.first { $0.id == Ensemble.hornSection.id }
        #expect(section?.members == horns.map(\.id))
        #expect(section?.isEnsemble == true && section?.playsShortNotes == true)
        #expect(Ensemble.available(among: Array(horns.dropLast())).isEmpty)
    }

    // MARK: Kits

    /// Instruments as the library keeps them, each a folder with a kit, in one directory.
    static func library(_ names: [String], in directory: URL) throws -> [InstrumentVoiceSpec] {
        try names.map { name in
            let slug = ImportedInstruments.slug(of: name)
            let folder = directory.appendingPathComponent(slug, isDirectory: true)
            let samples = (0..<4_800).map { i in Float(0.5 * sin(Double(i) * 2 * .pi * 220 / 48_000)) }
            try SynthesizedKit.writeWAV(samples, to: folder.appendingPathComponent("samples/a.wav"), sampleRate: 48_000)
            _ = try KitStore.save(KitManifest(name: name, zones: [
                Zone(id: "a", sample: "samples/a.wav", key: .range(40...84, rootNote: 57)),
            ]), to: folder)
            var spec = InstrumentVoiceSpec(id: "sfz-\(slug)", name: name, family: "brass", engine: .sampled)
            spec.sampledKit = folder.path
            return spec
        }
    }

    @Test("An instrument with a short recording plays from both, its own folder first")
    func articulatedKit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ensembles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let specs = try Self.library(["Trumpet", "Trumpet Staccato"], in: directory)
        var trumpet = specs[0]
        trumpet.shortKit = specs[1].sampledKit
        let kit = try #require(try PlayedKits.kit(for: trumpet))
        #expect(kit.folder.standardizedFileURL.path == URL(fileURLWithPath: specs[0].sampledKit!).standardizedFileURL.path)
        #expect(kit.manifest.zones.count == 2)
        #expect(kit.manifest.zones.filter { $0.longest == Articulations.shortNote }.count == 1)
        #expect(kit.manifest.ensemble == nil)
        // Every recording is reachable from the kit, and the short one is its neighbour's file.
        for url in kit.sampleURLs { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(kit.sampleURLs.map(\.standardizedFileURL.path).contains { $0.contains("/trumpet-staccato/samples/") })
        // One recording and nothing else is its own kit.
        #expect(try PlayedKits.kit(for: specs[1]) == nil)
    }

    @Test("A section's kit holds every player's recordings on its own layer, set out across the stereo picture")
    func sectionKit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ensembles-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            for spec in ImportedInstruments.all where spec.sampledKit?.hasPrefix(directory.path) == true || spec.isEnsemble {
                ImportedInstruments.unregister(id: spec.id)
            }
        }
        let specs = try Self.library(["Trumpet", "Trumpet Staccato", "Tenor Saxophone, Vibrato", "Trombone"], in: directory)
        let played = ImportedInstruments.played(specs)
        let trio = try #require(played.first { $0.id == Ensemble.hornTrio.id })
        let kit = try #require(try PlayedKits.kit(for: trio))
        let ensemble = try #require(kit.manifest.ensemble)
        #expect(ensemble.players.map(\.name) == Ensemble.hornTrio.seats.map(\.name))
        #expect(Set(kit.manifest.zones.compactMap(\.layer)) == [0, 1, 2])
        // The trumpet's staccato comes with it.
        #expect(kit.manifest.zones.contains { $0.layer == 0 && $0.longest != nil })
        #expect(Set(kit.manifest.zones.map(\.pan)).count == 3)
        for url in kit.sampleURLs { #expect(FileManager.default.fileExists(atPath: url.path)) }
        // A section has no folder of its own to remove.
        try ImportedInstruments.remove(id: trio.id)
        for spec in specs { #expect(FileManager.default.fileExists(atPath: spec.sampledKit!)) }
        // Its reach is its players'.
        #expect(ImportedInstruments.range(of: trio) == 40...84)
    }

    // MARK: Recordings for the built-in sounds

    @Test("A built-in sound is played on the first of its recordings the library has")
    func recordedSounds() {
        let library = ["Kawai Grand", "Steinway Grand", "Violin Section", "Rhodes", "Nylon Guitar"].map { Self.recorded($0) }
        #expect(RecordedSounds.recording(for: "grand-piano", among: library)?.name == "Steinway Grand")
        #expect(RecordedSounds.recording(for: "strings", among: library)?.name == "Violin Section")
        #expect(RecordedSounds.recording(for: "rhodes", among: library)?.name == "Rhodes")
        #expect(RecordedSounds.recording(for: "nylon-guitar", among: library)?.name == "Nylon Guitar")
        #expect(RecordedSounds.recording(for: "organ", among: library) == nil)
        #expect(RecordedSounds.recording(for: "pad", among: library) == nil)
        #expect(RecordedSounds.hasRecordedCounterpart("trumpet"))
        #expect(!RecordedSounds.hasRecordedCounterpart("saw-lead"))
        // The genres' "horns" are a section when the library seats one.
        var section = InstrumentVoiceSpec(id: Ensemble.hornSection.id, name: "Horn Section", family: "brass", engine: .sampled)
        section.members = ["a"]
        #expect(RecordedSounds.recording(for: "horns", among: library + [section])?.id == Ensemble.hornSection.id)
        // Every id it names is a built-in sound.
        let builtIn = Set(InstrumentVoiceSpec.all.map(\.id))
        for id in RecordedSounds.candidates.keys { #expect(builtIn.contains(id), "\(id)") }
    }
}
