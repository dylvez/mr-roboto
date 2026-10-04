import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

/// A loop of four parts — drums, bass, chords, a tune — in a new song's starting form.
@MainActor
enum DevelopFixture {
    static func row(_ voice: DrumVoice, _ text: String) -> GroovePattern {
        GroovePattern(voice: voice, steps: text.map { $0 == "X" ? .accent : $0 == "x" ? .normal : $0 == "g" ? .ghost : .rest })
    }

    static let groove = Groove(stepsPerBar: 16, bars: 1, patterns: [
        row(.kick, "X...X...X...X..."), row(.clap, "....X.......X..."),
        row(.closedHat, "x.gxx.gxx.gxx.gx"), row(.shaker, "gxgxgxgxgxgxgxgx"),
    ])

    static func n(_ midi: Int, _ start: Double, _ duration: Double, _ velocity: Int = 100) -> NoteEvent {
        NoteEvent(pitch: Pitch(midi: midi), start: start, duration: duration, velocity: velocity)
    }

    struct Loop {
        var song: Song
        var drums: PartVersion
        var bass: PartVersion
        var chords: PartVersion
        var tune: PartVersion
    }

    /// Every part in every section, as `AppState.record` would have put them.
    static func loop(title: String = "Afterglow", genre: String? = nil, sections: [(String, Int)]? = nil) throws -> Loop {
        let key = Key(parsing: "A minor")!
        var song = Song.new(title: title, key: key, tempo: 120)
        song.genre = genre
        let drums = PartVersion(partID: PartID(), kind: .groove(groove), author: .user, operation: Operation.written, note: "House loop")
        let bass = PartVersion(partID: PartID(), kind: .bassline(Bassline(
            notes: (0..<16).map { i in n(i < 8 ? 45 : 41, Double(i) * 0.5, 0.4, i % 2 == 0 ? 100 : 80) },
            sound: "analogue", key: key, lengthInBars: 2, hands: "octave")), author: .user, operation: Operation.written, note: "Octaves")
        let chords = PartVersion(partID: PartID(), kind: .progression(Progression(key: key, bars: [
            ProgressionBar(Chord(parsing: "Am7")!, beats: 4), ProgressionBar(Chord(parsing: "Fmaj7")!, beats: 4),
        ])), author: .user, operation: Operation.written, note: "Am7 Fmaj7")
        let tune = PartVersion(partID: PartID(), kind: .melody(Melody(
            notes: [n(72, 0, 1), n(74, 1, 1), n(76, 2, 2), n(79, 4, 1), n(76, 5, 1), n(72, 6, 1.5)], lengthInBars: 2)),
            author: .user, operation: Operation.written, note: "The hook")
        try song.append(contentsOf: [drums, bass, chords, tune])
        if let sections {
            song.sections = sections.map { Section(name: $0.0, stitch: [], lengthInBars: $0.1) }
        }
        for index in song.sections.indices { song.sections[index].stitch = [drums, bass, chords, tune].lanes }
        return Loop(song: song, drums: drums, bass: bass, chords: chords, tune: tune)
    }

    /// The song with a development kept in it, as the app keeps one.
    static func developed(_ song: Song, _ development: Development) throws -> Song {
        var out = song
        try out.append(contentsOf: development.versions)
        out.sections = development.sections
        if let mix = development.mix {
            try out.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix, note: "Mix"))
        }
        return out
    }
}

@Suite("Develop: the loop, arranged") @MainActor
struct DevelopTests {
    private let resolver = TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))

    private func plays(_ development: Development, _ name: String) throws -> Development.Plays {
        try #require(development.plays.first { $0.name == name })
    }

    /// The name of the variation a section's lane of this kind plays, or "" for the part itself.
    private func variation(_ type: PartType, in section: Section, of song: Song) -> String? {
        for lane in section.stitch {
            guard let version = song.latestVersion(of: lane.part), version.type == type else { continue }
            return song.variation(of: lane.part)?.name ?? ""
        }
        return nil
    }

    // MARK: The form

    @Test("a new song's starting form is not an arrangement: a song with no genre gets a verse-and-hook form")
    func standardForm() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        #expect(development.form == .standard)
        #expect(development.sections.map(\.name) == ["Intro", "Verse", "Hook", "Verse", "Hook", "Bridge", "Hook", "Outro"])
        #expect(development.bars == 72)
        // The sections the song had keep their ids: a level or a stanza set on the Verse is still the Verse's.
        #expect(development.sections[0].id == loop.song.sections[0].id)
        #expect(development.sections[1].id == loop.song.sections[1].id)
        #expect(development.sections[2].id == loop.song.sections[2].id)
        #expect(Set(development.sections.map(\.id)).count == 8)
    }

    @Test("a form somebody made is kept however short it is, and only a genre somebody set arranges a song")
    func shortAndGuessed() throws {
        // Four sections and twenty-six bars, one of them a bridge: not long, and not the app's to replace.
        let short = try DevelopFixture.loop(sections: [("Intro", 4), ("Verse", 8), ("Hook", 8), ("Bridge", 6)])
        #expect(Develop.hasOwnForm(short.song))
        let development = try #require(Develop.plan(for: short.song, genre: GenreBook.standard.profile(named: "folk")))
        #expect(development.form == .kept)
        #expect(development.sections.map(\.name) == ["Intro", "Verse", "Hook", "Bridge"])
        #expect(development.sections.map(\.lengthInBars) == [4, 8, 8, 6])
        #expect(!Develop.hasOwnForm(try DevelopFixture.loop().song), "a new song's Intro, Verse and Hook is where it starts")

        // In the app: a genre guessed from the feel a groove was written in says whether the
        // drums are dance music's, and nothing about the form or how loud the master is.
        let (app, directory, _) = CompletenessFixture.app("develop-guess")
        defer { try? FileManager.default.removeItem(at: directory) }
        var loop = try DevelopFixture.loop()
        guard case .groove(var groove) = loop.drums.kind else { return }
        groove.feel = GrooveFeel(name: "Classic House", seed: 3)
        let drums = PartVersion(partID: PartID(), kind: .groove(groove), author: .user, operation: Operation.written, note: "House loop")
        var song = Song.new(title: "Guessed", key: loop.song.key, tempo: 124)
        try song.append(contentsOf: [drums, loop.bass, loop.chords, loop.tune])
        for index in song.sections.indices { song.sections[index].stitch = [drums, loop.bass, loop.chords, loop.tune].lanes }
        loop.song = song
        app.open(song)
        #expect(app.genre?.source != .set && app.genre?.profile.family == "electronic", "\(String(describing: app.genre?.description))")
        let guessed = try #require(app.development())
        #expect(guessed.form == .standard && guessed.genre == nil)
        #expect(guessed.targetLUFS == -14)
        #expect(guessed.written.contains("Lifted drums"))
        let hook = try #require(guessed.versions.first { $0.variation?.name == "lift" })
        guard case .groove(let lifted) = hook.kind else { return }
        #expect(lifted.patterns.contains { $0.voice == .openHat }, "dance music lifts with an open hat")

        #expect(app.setGenre("house"))
        let set = try #require(app.development())
        #expect(set.form == .genre("House") && set.genre == "House")
        #expect(set.targetLUFS == Develop.loudness(for: GenreBook.standard.profile(named: "house")))
    }

    @Test("a song arranged by hand keeps its form, and a form asked for is the form")
    func keptAndGiven() throws {
        let own = try DevelopFixture.loop(sections: [("Intro", 8), ("Groove", 16), ("Breakdown", 8), ("Groove", 16), ("Outro", 8)])
        let kept = try #require(Develop.plan(for: own.song))
        #expect(kept.form == .kept)
        #expect(kept.sections.map(\.id) == own.song.sections.map(\.id))
        #expect(kept.sections.map(\.lengthInBars) == [8, 16, 8, 16, 8])

        let given = try #require(Develop.plan(for: own.song, form: [("Intro", 4), ("Hook", 8), ("Outro", 4)]))
        #expect(given.form == .given)
        #expect(given.sections.map(\.name) == ["Intro", "Hook", "Outro"])
        #expect(given.sections[0].id == own.song.sections[0].id)
        #expect(given.sections[0].lengthInBars == 4)
    }

    @Test("a song in a genre is arranged the way the genre is, a long way in and out each in two")
    func genreForm() throws {
        let loop = try DevelopFixture.loop(genre: "house")
        let house = try #require(GenreBook.standard.profile(named: "house"))
        let development = try #require(Develop.plan(for: loop.song, genre: house))
        #expect(development.form == .genre("House"))
        #expect(development.sections.map(\.name) == ["Intro", "Intro 2", "Groove", "Breakdown", "Drop", "Breakdown", "Drop", "Outro", "Outro 2"])
        #expect(development.bars == house.form?.bars)
        // The way in: the drums alone, then the chords and a lighter bass with them.
        #expect(try plays(development, "Intro").parts == ["drums, thinned"])
        #expect(try plays(development, "Intro 2").parts == ["drums, thinned", "bass, lighter", "chords"])
        #expect(try plays(development, "Outro 2").parts == ["drums, thinned"])
        #expect(development.targetLUFS == Develop.loudness(for: house))
        #expect(development.mix?.master.targetLUFS == development.targetLUFS)
        #expect(development.mix?.master.fadeOutBars == 8)
    }

    // MARK: What each section plays

    @Test("each kind of section plays the loop its own way")
    func sections() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)

        #expect(try plays(development, "Intro").parts == ["drums, thinned", "chords"])
        // Nobody sings, so the verse gets the tune's first phrase.
        #expect(development.plays[1].parts == ["drums", "bass", "chords", "tune, first phrase only"])
        #expect(development.plays[2].parts == ["drums, lifted", "bass", "chords", "tune"])
        #expect(try plays(development, "Bridge").parts == ["drums, on the ride", "bass, on the bridge's chords",
                                                           "chords, its own: Fmaj7 | G7 | Dm7 | E7"])
        // The last hook is eight bars and the tune is two: room to say it, then say it an octave up.
        #expect(development.plays[6].parts == ["drums, lifted", "bass", "chords", "tune, then an octave up"])
        #expect(try plays(development, "Outro").parts == ["drums, thinned", "bass, lighter", "chords"])

        #expect(variation(.groove, in: song.sections[0], of: song) == "thin")
        #expect(variation(.groove, in: song.sections[1], of: song) == "")
        #expect(variation(.groove, in: song.sections[2], of: song) == "lift")
        #expect(variation(.bassline, in: song.sections[0], of: song) == nil)
        #expect(variation(.melody, in: song.sections[6], of: song) == "lift")
    }

    @Test("a variation is written once and played wherever it is wanted")
    func writtenOnce() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        // Thinned drums (intro and outro), lifted drums (three hooks), on the ride; a lighter bass
        // (bridge and outro); the tune's first phrase (two verses) and its lift.
        #expect(development.written == ["Thinned drums", "First phrase of The hook", "Lifted drums", "Drums on the ride",
                                        "Bridge bass", "Bridge chords", "Lift of The hook", "Lighter bass"])
        #expect(development.versions.allSatisfy { $0.operation == Operation.developed })
        #expect(development.versions.allSatisfy { $0.author == Develop.author })
        #expect(development.sections[0].stitch.first?.part == development.sections[7].stitch.first?.part)
        // Each is a variation of the part it came from, with that part's version as its parent.
        let thin = try #require(development.versions.first)
        #expect(thin.variation == Variation(of: loop.drums.partID, name: "thin"))
        #expect(thin.parents == [loop.drums.id])
    }

    @Test("a breakdown has no kick and holds the roots; a build rolls into the drop and nothing fills over it")
    func breakdownAndBuild() throws {
        let loop = try DevelopFixture.loop(genre: "breakbeat")
        let breakbeat = try #require(GenreBook.standard.profile(named: "breakbeat"))
        let development = try #require(Develop.plan(for: loop.song, genre: breakbeat))
        let song = try DevelopFixture.developed(loop.song, development)
        #expect(try plays(development, "Breakdown").parts == ["drums, no kick", "bass, held roots", "chords", "tune, first phrase only"])
        #expect(try plays(development, "Build").parts == ["drums, build", "bass, pulse", "chords"])
        #expect(try plays(development, "Drop").parts == ["drums, lifted", "bass", "chords", "tune, then an octave up"])

        let build = try #require(development.sections.first { $0.name == "Build" })
        #expect(build.transitionOut?.kind == .riser)
        let plan = SongPlayback.plan(for: song, mediaURL: resolver)
        let segment = try #require(plan.segments.first { $0.section == build.id })
        let played = try #require(segment.groove)
        #expect(played.patterns.first { $0.voice == .lowTom } == nil, "no fill down the toms over the roll")
        #expect(played.patterns.first { $0.voice == .clap }?.steps.suffix(16).allSatisfy { $0 == .accent } == true)
        // The drop still opens on its crash.
        let drop = try #require(plan.segments.first { $0.name == "Drop" }?.groove)
        #expect(drop.patterns.first { $0.voice == .crash }?.steps.first == .accent)
    }

    // MARK: The chords

    private func progression(_ version: PartVersion?) -> Progression? {
        if case .progression(let sheet)? = version?.kind { return sheet }
        return nil
    }

    private func bassline(_ version: PartVersion?) -> Bassline? {
        if case .bassline(let line)? = version?.kind { return line }
        return nil
    }

    @Test("a bridge goes somewhere else: chords that start away from home and lead back, and the bass written to them")
    func bridge() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        let section = try #require(song.sections.first { $0.name == "Bridge" })
        let played = song.versions(playing: section)
        let chords = try #require(progression(played.first { $0.type == .progression }))
        #expect(chords.symbols() == "Fmaj7 | G7 | Dm7 | E7")
        #expect(chords.key == Key(parsing: "A minor"))
        #expect(chords.bars.allSatisfy { $0.beats == 4 })
        // It is a variation of the song's chords: their strip, their instrument.
        let part = try #require(played.first { $0.type == .progression }).partID
        #expect(song.variation(of: part) == Variation(of: loop.chords.partID, name: "bridge"))

        // The bass is in the hands that wrote the loop's, on the bridge's chords: whatever it
        // plays on the first beat of a bar is a note of that bar's chord.
        let line = try #require(bassline(played.first { $0.type == .bassline }))
        #expect(line.hands == "octave" && line.sound == "analogue")
        #expect(line.lengthInBars == 4)
        for (bar, chord) in chords.chords.enumerated() {
            let first = try #require(line.notes.first { $0.start >= Double(bar * 4) - 0.25 && $0.start < Double(bar * 4) + 1 }, "bar \(bar + 1) has no bass on its one")
            #expect(chord.pitchClasses.contains(first.pitch.pitchClass), "bar \(bar + 1): \(first.pitch) under \(chord)")
        }
        #expect(!played.contains { $0.type == .melody }, "the tune waits for the hook")
        // Everywhere else the song's own chords play.
        for other in song.sections where other.name != "Bridge" {
            let sheet = progression(song.versions(playing: other).first { $0.type == .progression })
            #expect(sheet == nil || sheet?.symbols() == "Am7 | Fmaj7", "\(other.name)")
        }
    }

    @Test("in a major key the bridge is IV, V, vi, V; and from somewhere else when the song starts there")
    func bridgeInMajor() throws {
        func sheet(_ line: String, _ key: String) -> Progression { try! Progression.parse(line, key: Key(parsing: key)!).get() }
        #expect(Develop.bridge(from: sheet("C | G | Am | F", "C major"))?.symbols() == "F | G | Am | G")
        #expect(Develop.bridge(from: sheet("Cmaj7 | Am7 | Dm7 | G7", "C major"))?.symbols() == "Fmaj7 | G7 | Am7 | G7")
        // Eight bars of chords: two bars a chord.
        let eight = try #require(Develop.bridge(from: sheet("C | C | F | F | G | G | C | C", "C major")))
        #expect(eight.symbols() == "F | F | G | G | Am | Am | G | G")
        // A song that starts on IV goes to vi.
        #expect(Develop.bridge(from: sheet("F | G | C | Am", "C major"))?.symbols() == "Am | F | Dm | G")
        #expect(Develop.bridge(from: sheet("Fmaj7 | G7 | Dm7 | E7", "A minor"))?.symbols() == "Dm7 | G7 | Fmaj7 | E7")
        // Sixteen bars of chords and a bridge of eight: eight bars, so the one that leads back is reached.
        let sixteen = sheet("Cm7 | Cm7 | Fm7 | Fm7 | Cm7 | Cm7 | Abmaj7 | G7 | Cm7 | Cm7 | Fm7 | Bb7 | Ebmaj7 | Abmaj7 | G7 | Cm7", "C minor")
        #expect(Develop.bridge(from: sixteen)?.bars.count == 16)
        #expect(Develop.bridge(from: sixteen, bars: 8)?.symbols() == "Abmaj7 | Abmaj7 | Bb7 | Bb7 | Fm7 | Fm7 | G7 | G7")
        // Four bars of chords go twice into eight, and stay four.
        #expect(Develop.bridge(from: sheet("C | G | Am | F", "C major"), bars: 8)?.symbols() == "F | G | Am | G")
        #expect(Develop.bridge(from: sheet("C | C | F | F | G | G | C | C", "C major"), bars: 16)?.symbols() == eight.symbols())
        // Six bars: a chord a bar, ending on the one that leads back.
        #expect(Develop.bridge(from: sheet("C | G | Am | F", "C major"), bars: 6)?.symbols() == "F | G | Am | G | F | G")
        #expect(Develop.bridge(from: sheet("C | G | Am | F", "C major"), bars: 5)?.symbols() == "F | G | Am | G | G")
        // Played the way the song's chords are.
        var stabbed = sheet("Am7 | Fmaj7", "A minor")
        stabbed.playing = ChordPlaying(.stabs, .led, seed: 9)
        #expect(Develop.bridge(from: stabbed)?.playing == stabbed.playing)
    }

    @Test("a bridge with a tune of its own, or a chop, keeps the chords they were written to")
    func bridgeStays() throws {
        var loop = try DevelopFixture.loop(sections: [("Intro", 4), ("Verse", 16), ("Hook", 8), ("Bridge", 8), ("Hook", 8), ("Outro", 4)])
        let figure = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [DevelopFixture.n(69, 0, 2), DevelopFixture.n(72, 2, 2)], lengthInBars: 1)),
                                 author: .user, operation: Operation.written, note: "The bridge's own line")
        try loop.song.append(figure)
        loop.song.sections[3].stitch = [loop.drums, loop.bass, loop.chords].lanes + [Lane(part: figure.partID)]
        let development = try #require(Develop.plan(for: loop.song))
        #expect(development.plays[3].parts == ["drums, on the ride", "bass, lighter", "chords", "tune"])
        #expect(!development.written.contains("Bridge chords"))
    }

    @Test("chords with a rhythm are held where the song stands still")
    func chordsHeld() throws {
        var loop = try DevelopFixture.loop(genre: "breakbeat")
        guard case .progression(var sheet) = loop.chords.kind else { return }
        sheet.playing = ChordPlaying(.stabs, .led, seed: 5)
        let stabbed = loop.chords.deriving(.progression(sheet), by: .user, operation: Operation.edit, note: "Am7 Fmaj7: stabs")
        try loop.song.append(stabbed)
        let development = try #require(Develop.plan(for: loop.song, genre: GenreBook.standard.profile(named: "breakbeat")))
        let song = try DevelopFixture.developed(loop.song, development)
        #expect(try plays(development, "Intro 2").parts == ["drums, thinned", "bass, lighter", "chords, held"])
        #expect(try plays(development, "Breakdown").parts == ["drums, no kick", "bass, held roots", "chords, held", "tune, first phrase only"])
        #expect(try plays(development, "Drop").parts == ["drums, lifted", "bass", "chords", "tune, then an octave up"])
        let breakdown = try #require(song.sections.first { $0.name == "Breakdown" })
        let held = try #require(progression(song.versions(playing: breakdown).first { $0.type == .progression }))
        #expect(held.playing == ChordPlaying(.held, .led), "held, and voiced as they were")
        #expect(held.symbols() == sheet.symbols())
        #expect(development.written.filter { $0 == "Held chords" }.count == 1, "written once, played in four sections")
    }

    @Test("held chords are given the genre's rhythm where the song arrives, on an instrument that can play one")
    func chordsLifted() throws {
        var loop = try DevelopFixture.loop(genre: "house")
        try loop.song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "grand-piano", forPart: loop.chords.partID)),
                                         author: .user, operation: Operation.written, note: "Grand Piano"))
        let house = try #require(GenreBook.standard.profile(named: "house"))
        let onPiano = try #require(Develop.plan(for: loop.song, genre: house))
        let drop = try plays(onPiano, "Drop").parts
        #expect(drop == ["drums, lifted", "bass", "chords, stabs", "tune"], "\(drop)")
        #expect(try plays(onPiano, "Groove").parts.contains("chords"))
        let stabs = try #require(progression(onPiano.versions.first { $0.variation?.name == "played-stabs" }))
        #expect(stabs.playing?.keysPattern == .stabs)
        #expect(Voicing.notes(for: stabs).allSatisfy { $0.duration <= 0.35 })

        // On a pad, which swells into a note, they stay held.
        try loop.song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "air-pad", forPart: loop.chords.partID)),
                                         author: .user, operation: Operation.written, note: "Air Pad"))
        let onPad = try #require(Develop.plan(for: loop.song, genre: house))
        #expect(try plays(onPad, "Drop").parts.contains("chords"))
        // And with no genre set nobody knows what rhythm to give them.
        loop.song.genre = nil
        #expect(try #require(Develop.plan(for: loop.song)).written.allSatisfy { !$0.contains("chords") || $0 == "Bridge chords" })
    }

    @Test("with words to sing, the verses leave the tune out")
    func sung() throws {
        var loop = try DevelopFixture.loop()
        try loop.song.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "[Verse]\nI put the coffee on at six")),
                                         author: .user, operation: Operation.written, note: "Lyric"))
        let development = try #require(Develop.plan(for: loop.song))
        #expect(development.plays[1].parts == ["drums", "bass", "chords"])
    }

    @Test("a tune written for one section is played there as it was written, and nowhere else")
    func aTuneOfItsOwnSection() throws {
        var loop = try DevelopFixture.loop(sections: [("Intro", 8), ("Groove", 8), ("Main", 16), ("Break", 12), ("Drop", 16), ("Outro", 12)])
        let figure = PartVersion(partID: PartID(), kind: .melody(Melody(notes: (0..<8).map { DevelopFixture.n(64 + $0 % 3, Double($0) * 0.5, 0.5) }, lengthInBars: 1)),
                                 author: .persona("Melodist"), operation: Operation.written, note: "Main: a two-bar figure")
        try loop.song.append(figure)
        loop.song.sections[2].stitch.append(Lane(part: figure.partID))
        let development = try #require(Develop.plan(for: loop.song))
        // The loop's tune is saved for the drop and thinned to its first phrase on the way;
        // the figure written for Main is in Main, whole.
        #expect(development.plays[2].parts == ["drums", "bass", "chords", "tune, first phrase only", "tune"])
        #expect(development.sections[2].stitch.contains(part: figure.partID))
        #expect(development.sections.count { $0.stitch.contains(part: figure.partID) } == 1)
        #expect(!development.versions.contains { $0.variation?.of == figure.partID })
    }

    @Test("a groove written for one section stays that section's")
    func aPartOfItsOwnSection() throws {
        var loop = try DevelopFixture.loop(sections: [("Intro", 4), ("Verse", 16), ("Hook", 8), ("Bridge", 8), ("Outro", 4)])
        let waltz = PartVersion(partID: PartID(), kind: .groove(Groove(stepsPerBar: 12, bars: 1, patterns: [
            DevelopFixture.row(.kick, "X....x......"), DevelopFixture.row(.rim, "......x....."), DevelopFixture.row(.ride, "x..x..x..x.."),
        ])), author: .user, operation: Operation.written, note: "Bridge beat")
        try loop.song.append(waltz)
        loop.song.sections[3].stitch = [waltz, loop.bass, loop.chords].lanes
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        #expect(development.form == .kept)
        let bridge = development.sections[3]
        #expect(bridge.stitch.contains(part: waltz.partID), "its own beat, which has a ride already and is left as written")
        #expect(!bridge.stitch.contains { song.strip(of: $0.part) == loop.drums.partID })
        #expect(!development.sections[1].stitch.contains(part: waltz.partID))
        // Two grooves in the song: a variation says which it is a variation of.
        #expect(development.written.contains("Thinned drums (House loop)"))
    }

    @Test("a song in which nothing plays has nothing to develop")
    func nothing() {
        #expect(Develop.plan(for: Song.new(title: "Empty")) == nil)
    }

    // MARK: How a variation sounds

    @Test("a variation plays on the strip, the machine and the instrument of the part it varies")
    func oneStrip() throws {
        var loop = try DevelopFixture.loop()
        try loop.song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "tr909", forPart: loop.drums.partID)),
                                         author: .user, operation: Operation.written, note: "TR-909"))
        try loop.song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "bell-pluck", forPart: loop.tune.partID)),
                                         author: .user, operation: Operation.written, note: "Bell Pluck"))
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        let plan = SongPlayback.plan(for: song, mediaURL: resolver)
        #expect(plan.segments.count == 8)
        #expect(Set(plan.parts) == [loop.drums.partID, loop.bass.partID, loop.chords.partID, loop.tune.partID])
        for segment in plan.segments {
            #expect(segment.groovePart == loop.drums.partID)
            #expect(segment.voices.first { $0.groove != nil }?.sound == "tr909")
            if let tune = segment.voices.first(where: { $0.melody != nil }) {
                #expect(tune.part == loop.tune.partID)
                #expect(tune.sound == "bell-pluck")
            }
        }
        // And what it plays is the variation's own steps.
        let intro = try #require(plan.segments.first?.groove)
        #expect(intro.patterns.first { $0.voice == .clap } == nil)
        #expect(MixerModel.rows(of: plan, song: song, mix: plan.mix ?? .unity).map(\.part)
                    == [loop.drums.partID, loop.chords.partID, loop.bass.partID, loop.tune.partID])
    }

    @Test("each section's level is set against the part's own, on the part's strip")
    func levels() throws {
        var loop = try DevelopFixture.loop()
        var mix = Mix.unity
        mix.set(Strip(part: loop.drums.partID, label: "Drums", gainDB: -3))
        mix.sectionGains = [SectionGain(section: loop.song.sections[2].id, part: loop.tune.partID, gainDB: 4)]
        try loop.song.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix, note: "Mix"))
        let development = try #require(Develop.plan(for: loop.song))
        let developed = try #require(development.mix)
        let intro = development.sections[0].id, hook = development.sections[2].id, verse = development.sections[1].id
        #expect(developed.gainDB(for: loop.drums.partID, in: intro) == -5)
        #expect(developed.gainDB(for: loop.drums.partID, in: hook) == -2.5)
        #expect(developed.gainDB(for: loop.drums.partID, in: verse) == -3)
        #expect(developed.gainDB(for: loop.tune.partID, in: hook) == 4, "a level you set stands")
        #expect(developed.strips == mix.strips)
        #expect(developed.master.fadeOutBars == 4)
    }

    @Test("the newest groove is still the loop, and a variation is not another part")
    func stillTheLoop() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        #expect(Guidance.grooves(in: song).last?.id == loop.drums.id)
        #expect(Guidance.basslines(in: song).last?.id == loop.bass.id)
        #expect(Guidance.melodies(in: song).last?.id == loop.tune.id)
        #expect(FormTools.defaultStitch(in: song).map(\.part) == [loop.drums, loop.bass, loop.chords, loop.tune].map(\.partID))
        #expect(WorkPath.count(.groove, in: song) == 1)
        let observed = SongObservation.of(song)
        #expect(observed.partCount == 4)
        #expect(observed.orphanedParts.isEmpty)
        #expect(Develop.isDeveloped(song))
        #expect(!Develop.isDeveloped(loop.song))
    }

    @Test("the MIDI file has a track for each part, its variations written on it where they play")
    func midi() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        let file = MIDIExport.file(for: song)
        #expect(file.tracks.map(\.name) == ["House loop", "Am7 Fmaj7", "Octaves", "The hook"])
        let drums = try #require(file.tracks.first)
        let ticksPerBar = MIDIExport.ticksPerBeat * 4
        let clap = DrumMap.note(for: .clap), kick = DrumMap.note(for: .kick), tambourine = DrumMap.note(for: .tambourine)
        func bar(_ number: Int, has pitch: Int) -> Bool {
            drums.notes.contains { $0.pitch == pitch && ($0.start / ticksPerBar) == number }
        }
        // The intro is thinned: a kick and no clap. The verse claps. The hook, from bar 20, has the tambourine on top.
        #expect(bar(0, has: kick) && !bar(0, has: clap))
        #expect(bar(4, has: clap) && !bar(4, has: tambourine))
        #expect(bar(20, has: tambourine))
        // The tune rests through the intro and is an octave up by the end of the last hook.
        let tune = try #require(file.tracks.last)
        #expect(tune.notes.allSatisfy { $0.start >= 4 * ticksPerBar })
        #expect(tune.notes.contains { $0.pitch == 84 + 7 }, "G5 lifted to G6")
    }

    @Test("a song written before variations round-trips byte for byte, and a variation survives the trip")
    func roundTrip() throws {
        let loop = try DevelopFixture.loop()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(loop.song)
        #expect(!String(decoding: before, as: UTF8.self).contains("variation"))
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        let decoded = try JSONDecoder().decode(Song.self, from: try encoder.encode(song))
        #expect(decoded == song)
        #expect(decoded.variations(of: loop.drums.partID).count == 3)
    }

    // MARK: Again

    @Test("developing twice writes nothing the second time, and a variation changed by hand is kept")
    func again() throws {
        let loop = try DevelopFixture.loop()
        let first = try #require(Develop.plan(for: loop.song))
        var song = try DevelopFixture.developed(loop.song, first)
        let second = try #require(Develop.plan(for: song))
        #expect(second.versions.isEmpty)
        #expect(second.sections == first.sections)
        #expect(second.form == .kept)

        // The thinned drums, changed by hand: the kick taken out of them.
        let thin = try #require(song.latestVersion(of: first.sections[0].stitch[0].part))
        guard case .groove(var groove) = thin.kind else { Issue.record("not a groove"); return }
        groove.patterns.removeAll { $0.voice == .kick }
        let edited = thin.deriving(.groove(groove), by: .user, operation: Operation.edit, note: thin.note)
        #expect(edited.variation == thin.variation, "an edit of a variation is still that variation")
        try song.append(edited)
        let third = try #require(Develop.plan(for: song))
        #expect(third.versions.isEmpty)
        #expect(third.sections[0].stitch[0].part == thin.partID)

        // The loop changed: the band's own variations are written again from it, as versions of
        // the parts they were; the one changed by hand is still left alone.
        guard case .groove(var changed) = loop.drums.kind else { return }
        changed.patterns.append(DevelopFixture.row(.cowbell, "..x...x...x...x."))
        try song.append(loop.drums.deriving(.groove(changed), by: .user, operation: Operation.edit, note: loop.drums.note))
        let fourth = try #require(Develop.plan(for: song))
        #expect(fourth.versions.map { $0.variation?.name } == ["lift", "ride"])
        #expect(fourth.versions.allSatisfy { version in song.versions.contains { $0.partID == version.partID } })
    }
}

@Suite("Develop: in the app") @MainActor
struct DevelopAppTests {

    @Test("the develop tool's answer asks for a genre to be offered when none is set, and says nothing of it when one is")
    func genreOffer() async throws {
        let (app, directory, _) = CompletenessFixture.app("develop-offer")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(try DevelopFixture.loop().song)
        let tool = DevelopTool(workspace: AppStateWorkspace(app))
        let plain = try await tool.run(.init(form: "", putBack: false))
        #expect(plain.genre == nil)
        #expect(plain.detail.contains("No genre is set") && plain.detail.contains("as an offer"), "\(plain.detail)")

        #expect(app.putBackDevelopment() && app.setGenre("house"))
        let house = try await tool.run(.init(form: "", putBack: false))
        #expect(house.genre != nil && !house.detail.contains("No genre is set"), "\(house.detail)")
    }

    @Test("developing keeps the arrangement as one move, and putting it back brings the form and the mix back")
    func developAndPutBack() throws {
        let (app, directory, _) = CompletenessFixture.app("develop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let loop = try DevelopFixture.loop()
        app.open(loop.song)
        #expect(app.canDevelop)
        #expect(!app.canPutBackDevelopment)
        let lines = app.log.count

        let development = try #require(app.develop())
        let song = try #require(app.song)
        #expect(song.sections == development.sections)
        #expect(song.versions.count == loop.song.versions.count + development.versions.count + 1, "the variations, and one mix")
        #expect(app.playback.segments.count == 8)
        #expect(app.hasUnsavedChanges)
        #expect(app.canPutBackDevelopment)
        // One line for the mix and one for the arrangement; not one for every variation.
        let said = app.log.dropFirst(lines).map(\.text)
        #expect(said.contains("Developed Afterglow: 8 sections, 72 bars"))
        #expect(said.count <= 3)

        #expect(app.putBackDevelopment())
        #expect(app.song?.sections == loop.song.sections)
        #expect(Guidance.mix(in: try #require(app.song)) == Mix.unity)
        #expect(!app.canPutBackDevelopment)
        #expect(app.playback.segments.allSatisfy { $0.groovePart == loop.drums.partID })
    }

    @Test("a sound picked on a variation is picked for the part it varies")
    func picks() throws {
        let (app, directory, _) = CompletenessFixture.app("develop-picks")
        defer { try? FileManager.default.removeItem(at: directory) }
        let loop = try DevelopFixture.loop()
        app.open(loop.song)
        let development = try #require(app.develop())
        let thin = development.sections[0].stitch[0].part
        #expect(app.setMachine("tr909", for: thin))
        let song = try #require(app.song)
        #expect(SongPlayback.machineID(for: loop.drums.partID, in: song) == "tr909")
        #expect(SongPlayback.machineID(for: thin, in: song) == "tr909")
        #expect(app.playback.segments.allSatisfy { $0.voices.first { $0.groove != nil }?.sound == "tr909" })
    }

    @Test("a part written after the song was developed joins the sections its kind plays in, and no others")
    func joinsWhereItBelongs() throws {
        let (app, directory, _) = CompletenessFixture.app("develop-join")
        defer { try? FileManager.default.removeItem(at: directory) }
        var loop = try DevelopFixture.loop()
        // No bass yet, and no tune.
        var song = Song.new(title: "Afterglow", key: loop.song.key, tempo: 120)
        try song.append(contentsOf: [loop.drums, loop.chords])
        for index in song.sections.indices { song.sections[index].stitch = [loop.drums, loop.chords].lanes }
        loop.song = song
        app.open(song)
        _ = try #require(app.develop())
        #expect(app.record(loop.bass))
        #expect(app.record(loop.tune))
        let sections = try #require(app.song?.sections)
        func names(playing part: PartID) -> [String] { sections.filter { $0.stitch.contains(part: part) }.map(\.name) }
        // Not the intro, which has its chords to stand on.
        #expect(names(playing: loop.bass.partID) == ["Verse", "Hook", "Verse", "Hook", "Bridge", "Hook", "Outro"])
        // Nor the bridge, nor the way in and out, for the tune.
        #expect(names(playing: loop.tune.partID) == ["Verse", "Hook", "Verse", "Hook", "Hook"])
        // Developing again plays each of them its own way.
        let again = try #require(app.develop())
        #expect(again.written == ["First phrase of The hook", "Second ending of The hook", "Bridge bass", "Last chorus bass",
                                  "Lift of The hook", "Lighter bass"])
    }

    @Test("a section held at versions of its own is left exactly as it was")
    func heldByHand() throws {
        let (app, directory, _) = CompletenessFixture.app("develop-held")
        defer { try? FileManager.default.removeItem(at: directory) }
        var loop = try DevelopFixture.loop(sections: [("Intro", 8), ("Groove", 16), ("Breakdown", 8), ("Groove", 16), ("Outro", 8)])
        // The breakdown, arranged by hand: an older version of the drums held there, and the chords.
        guard case .groove(var bare) = loop.drums.kind else { return }
        bare.patterns.removeAll { $0.voice == .kick || $0.voice == .closedHat }
        let older = loop.drums.deriving(.groove(bare), by: .user, operation: Operation.edit, note: "Claps and a shaker")
        try loop.song.append(older)
        try loop.song.append(loop.drums.deriving(loop.drums.kind, by: .user, operation: Operation.restored, note: "House loop"))
        loop.song.sections[2].stitch = [Lane(part: loop.drums.partID, pin: older.id), Lane(part: loop.chords.partID, pin: loop.chords.id)]
        app.open(loop.song)
        #expect(Develop.isDeveloped(loop.song), "held by hand is arranged")
        let development = try #require(app.develop())
        #expect(development.sections[2].stitch == loop.song.sections[2].stitch)
        #expect(development.plays[2].parts == ["groove, as it was set", "chords, as it was set"])
        #expect(development.mix?.sectionGains.contains { $0.section == loop.song.sections[2].id } != true, "and levelled by nobody")
        // What it plays is the version held there: no kick but the two a drummer marks a section's
        // edges with, under the crash it opens on and at the head of the fill it leaves by.
        let kick = app.playback.segments[2].groove?.patterns.first { $0.voice == .kick }?.steps ?? []
        #expect(kick.indices.filter { kick[$0] != .rest } == [0, 120])
        #expect(app.playback.segments[2].groove?.patterns.contains { $0.voice == .closedHat } == false)
        // The rest is developed round it.
        #expect(development.plays[0].parts == ["drums, thinned", "chords"])
    }

    @Test("with nothing that plays, it says so and does nothing")
    func nothing() {
        let (app, directory, _) = CompletenessFixture.app("develop-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song.new(title: "Empty"))
        #expect(!app.canDevelop)
        #expect(app.develop() == nil)
        #expect(app.song?.sections.map(\.name) == ["Intro", "Verse", "Hook"])
    }
}

@Suite("Develop: on the Structure surface") @MainActor
struct DevelopStructureTests {
    private final class Host: StructureHosting {
        func arrange(_ sections: [Section]) -> Bool { true }
        func play() async {}
        func stop() async {}
        func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool { false }
    }

    @Test("a section plays a part or one of its variations: choosing one takes the other's place")
    func oneOfAFamily() throws {
        let loop = try DevelopFixture.loop()
        let development = try #require(Develop.plan(for: loop.song))
        let song = try DevelopFixture.developed(loop.song, development)
        let model = StructureModel(host: Host(), song: song)
        model.autoKeep.delay = nil
        let verse = song.sections[1]
        let thin = song.sections[0].stitch[0].part
        #expect(model.layer(thin)?.varies == loop.drums.partID)
        #expect(model.layer(loop.drums.partID)?.varies == nil)

        model.toggle(thin, in: verse.id)
        let after = try #require(model.sections.first { $0.id == verse.id })
        #expect(after.stitch.contains(part: thin))
        #expect(!after.stitch.contains(part: loop.drums.partID))
        #expect(after.stitch.count == verse.stitch.count)
        #expect(after.stitch.first?.part == thin, "in the same place in the section")

        // And back.
        model.toggle(loop.drums.partID, in: verse.id)
        #expect(model.sections.first { $0.id == verse.id }?.stitch.map(\.part) == verse.stitch.map(\.part))
        // A new section plays the loop, not the variation written last.
        #expect(model.defaultStitch.map(\.part) == [loop.drums, loop.bass, loop.chords, loop.tune].map(\.partID))
    }
}

// MARK: - Varied

@Suite("Develop: varied, so two songs are not arranged the same way") @MainActor
struct DevelopVariedTests {

    /// A loop with four chords and a tune that rests: Dm7 Bbmaj7 Gm7 A7, four bars.
    static func loop() throws -> DevelopFixture.Loop {
        let key = Key(parsing: "D minor")!
        var song = Song.new(title: "Borrowed Light", key: key, tempo: 96)
        func n(_ midi: Int, _ start: Double, _ duration: Double) -> NoteEvent { DevelopFixture.n(midi, start, duration) }
        let drums = PartVersion(partID: PartID(), kind: .groove(DevelopFixture.groove), author: .user, operation: Operation.written, note: "The beat")
        let bass = PartVersion(partID: PartID(), kind: .bassline(Bassline(
            notes: [n(38, 0, 1.5), n(38, 2, 1), n(34, 4, 1.5), n(34, 6, 1), n(31, 8, 1.5), n(31, 10, 1), n(33, 12, 1.5), n(33, 14, 1)],
            sound: "finger", key: key, lengthInBars: 4)), author: .user, operation: Operation.written, note: "My line")
        let chords = PartVersion(partID: PartID(), kind: .progression(try Progression.parse("Dm7 | Bbmaj7 | Gm7 | A7", key: key).get()),
                                 author: .user, operation: Operation.written, note: "Dm7 Bbmaj7 Gm7 A7")
        let tune = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [
            n(69, 0.5, 0.5), n(72, 1, 0.5), n(74, 1.5, 1.5), n(77, 4, 1), n(74, 5, 0.5), n(70, 5.5, 0.5),
            n(74, 8, 1), n(70, 9, 1), n(67, 10, 1.5), n(69, 12, 1), n(73, 13, 1),
        ], lengthInBars: 4)), author: .user, operation: Operation.written, note: "The tune")
        try song.append(contentsOf: [drums, bass, chords, tune])
        for index in song.sections.indices { song.sections[index].stitch = [drums, bass, chords, tune].lanes }
        return DevelopFixture.Loop(song: song, drums: drums, bass: bass, chords: chords, tune: tune)
    }

    private func chords(_ name: String, _ development: Development, _ song: Song, nth: Int = 0) throws -> String {
        let section = try #require(development.sections.filter { $0.name == name }.dropFirst(nth).first)
        for lane in section.stitch {
            let version = development.versions.last { $0.partID == lane.part } ?? song.latestVersion(of: lane.part)
            if case .progression(let sheet)? = version?.kind { return sheet.symbols() }
        }
        return ""
    }

    @Test("plain is what developing always was: one bridge, the last chorus on the verse's chords")
    func plain() throws {
        let loop = try Self.loop()
        let development = try #require(Develop.plan(for: loop.song))
        #expect(try chords("Bridge", development, loop.song) == "Bbmaj7 | C7 | Gm7 | A7")
        #expect(try chords("Hook", development, loop.song, nth: 2) == "Dm7 | Bbmaj7 | Gm7 | A7")
        #expect(!development.written.contains { $0.contains("Answers") || $0.contains("Last chorus") || $0.contains("Push") })
    }

    @Test("varied: the seed picks the bridge, and a song gets the same one every time")
    func bridges() throws {
        let loop = try Self.loop()
        var seen = Set<String>()
        for seed in UInt64(0)..<5 {
            let development = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: seed)))
            let bridge = try chords("Bridge", development, loop.song)
            seen.insert(bridge)
            #expect(bridge.hasSuffix("A7") && !bridge.hasPrefix("Dm7"), "leads back, and does not open where the loop does: \(bridge)")
            #expect(try chords("Bridge", try #require(Develop.plan(for: loop.song, harmony: .varied(seed: seed))), loop.song) == bridge)
        }
        #expect(seen.count == 5, "five seeds, five bridges: \(seen.sorted())")
        #expect(Develop.seed(for: loop.song) == Develop.seed(for: loop.song))
        #expect(Develop.seed(for: loop.song) != Develop.seed(for: try Self.loop().song))
    }

    @Test("varied: the last chorus says its chords another way, and the bass follows them in its own rhythm")
    func lastChorus() throws {
        let loop = try Self.loop()
        // Seed 0 starts from the bass line: the bass holds D, then steps down to C sharp.
        let development = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: 0)))
        #expect(try chords("Hook", development, loop.song, nth: 2) == "Dm7 | Bbmaj7/D | Gm7/D | A7/C#")
        #expect(try chords("Hook", development, loop.song) == "Dm7 | Bbmaj7 | Gm7 | A7", "the first hook is the loop's")
        let last = try #require(development.sections.filter { $0.name == "Hook" }.last)
        let bass = try #require(last.stitch.compactMap { lane in development.versions.last { $0.partID == lane.part && $0.type == .bassline } }.first)
        guard case .bassline(let line) = bass.kind, case .bassline(let own) = loop.bass.kind else { return }
        #expect(bass.variation?.of == loop.bass.partID && bass.variation?.name == "last-bass-line")
        #expect(line.notes.map(\.start) == own.notes.map(\.start) && line.notes.map(\.duration) == own.notes.map(\.duration), "its rhythm is its own")
        #expect(line.notes.map(\.pitch.midi) == [38, 38, 38, 38, 38, 38, 37, 37], "D under all of it, then C sharp")
        #expect(development.plays.last { $0.name == "Hook" }?.parts.contains { $0.hasPrefix("chords, a bass line") } == true)

        // Another seed starts from another move; whatever it is, the tune still sits on it.
        let other = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: 97)))
        let sheet = try chords("Hook", other, loop.song, nth: 2)
        #expect(sheet != "Dm7 | Bbmaj7 | Gm7 | A7" && sheet != "Dm7 | Bbmaj7/D | Gm7/D | A7/C#", "\(sheet)")
    }

    @Test("varied: the middle chorus leans on its bar lines, and a line answers the tune the last time")
    func tunes() throws {
        let loop = try Self.loop()
        let development = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: 0)))
        let hooks = development.sections.filter { $0.name == "Hook" }
        func tune(_ section: SongGraph.Section) -> PartVersion? {
            section.stitch.compactMap { lane in development.versions.last { $0.partID == lane.part && $0.type == .melody && $0.variation != nil } }.first
        }
        #expect(tune(hooks[0]) == nil, "the first hook plays the tune as written")
        // Eight bars and a four-bar tune: room to say it twice, the second time brought home.
        #expect(tune(hooks[1])?.variation?.name == "answered")
        #expect(tune(hooks[2])?.variation?.name == "lift")

        let answers = try #require(development.versions.first { ($0.note ?? "").hasPrefix("Answers to The tune") })
        #expect(answers.variation == nil && answers.type == .melody, "a line of its own, not the tune played another way")
        #expect(hooks[2].stitch.contains(part: answers.partID) && !hooks[1].stitch.contains(part: answers.partID))
        #expect(development.mix?.gainDB(for: answers.partID, in: hooks[2].id) == Develop.answeringLevel)
        #expect(development.plays.last { $0.name == "Hook" }?.parts.contains("a line answering the tune") == true)

        // Developed again, nothing is written twice: the same line, the same variations.
        let song = try DevelopFixture.developed(loop.song, development)
        let again = try #require(Develop.plan(for: song, harmony: .varied(seed: 0)))
        #expect(again.versions.isEmpty, "\(again.written)")
        #expect(again.sections.map(\.stitch) == development.sections.map(\.stitch))
    }

    @Test("two players on the song's chords both go where the bridge and the last chorus go, each played its own way")
    func everyChordPlayerFollows() throws {
        var loop = try Self.loop()
        guard case .progression(var held) = loop.chords.kind else { return }
        held.playing = ChordPlaying(.held, .rootless)
        var keys = held
        keys.playing = ChordPlaying(.pushes, .led, seed: 3)
        // The song's chords twice: a pad that holds them and keys that push them.
        let pad = PartVersion(partID: PartID(), kind: .progression(held), author: .user, operation: Operation.written, note: "Pad: held")
        let pushed = loop.chords.deriving(.progression(keys), by: .user, operation: Operation.written, note: "Keys: pushes")
        try loop.song.append(contentsOf: [pushed, pad])
        for index in loop.song.sections.indices { loop.song.sections[index].stitch.append(Lane(part: pad.partID)) }

        let development = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: 0)))
        func sheets(_ section: SongGraph.Section) -> [Progression] {
            section.stitch.compactMap { lane in
                let version = development.versions.last { $0.partID == lane.part } ?? loop.song.latestVersion(of: lane.part)
                if case .progression(let sheet)? = version?.kind { return sheet }
                return nil
            }
        }
        let bridge = sheets(try #require(development.sections.first { $0.name == "Bridge" }))
        #expect(bridge.count == 2 && bridge[0].bars == bridge[1].bars, "\(bridge.map { $0.symbols() })")
        #expect(bridge[0].symbols() != "Dm7 | Bbmaj7 | Gm7 | A7")
        #expect(Set(bridge.compactMap { $0.playing?.keysPattern }) == [.held, .pushes], "each still plays its own way")
        let last = sheets(try #require(development.sections.last { $0.name == "Hook" }))
        #expect(last.count == 2 && last[0].bars == last[1].bars && last[0].symbols() != "Dm7 | Bbmaj7 | Gm7 | A7", "\(last.map { $0.symbols() })")
    }

    @Test("a bass line follows other chords without being written again")
    func refit() throws {
        let key = Key(parsing: "D minor")!
        let old = try Progression.parse("Dm7 | Gm7", key: key).get()
        let new = try Progression.parse("Dm7 | Gm7 G#dim7", key: key).get()
        func n(_ midi: Int, _ start: Double, _ duration: Double) -> NoteEvent { DevelopFixture.n(midi, start, duration) }
        let line = Bassline(notes: [n(38, 0, 2), n(41, 2, 1), n(31, 4, 2), n(31, 6, 1), n(34, 7, 1)], key: key, lengthInBars: 2)
        let followed = try #require(Develop.refit(line, from: old, to: new, beatsPerBar: 4))
        #expect(followed.notes.map(\.pitch.midi) == [38, 41, 31, 32, 35], "the root moves to the new root, the third to the nearest note of the new chord")
        #expect(followed.notes.map(\.start) == line.notes.map(\.start))
        #expect(Develop.refit(line, from: old, to: old, beatsPerBar: 4) == nil)
    }
}
