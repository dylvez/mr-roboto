import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The genre layer: profiles held to the method, a song placed in one, the band's readings re-judged
// in it, the Director's three tools, and the bass players the genres call for.

@MainActor
enum GenreFixture {
    /// A small, well-formed profile, so the lens is tested against numbers this file states.
    static let house: GenreProfile = try! GenreBook.decode(Data("""
    {
      "id": "test-house", "name": "Test House", "aliases": ["th"], "family": "electronic",
      "summary": "A four-on-the-floor dance genre used only by these tests, with numbers stated here.",
      "summaryEvidence": {"cited": ["https://example.org/house"]},
      "idioms": ["house"], "feels": ["Classic House", "Four on the Floor"], "meters": ["4/4"],
      "ranges": [
        {"feature": "tempo.bpm", "low": 118, "high": 128, "typical": 124, "unit": "BPM", "evidence": {"cited": ["https://example.org/tempo"]}},
        {"feature": "form.hook.seconds", "low": 30, "high": 75, "unit": "seconds", "evidence": {"inferred": "from the intro lengths cited"}},
        {"feature": "mix.lufs.integrated", "low": -9, "high": -6, "unit": "LUFS", "evidence": {"cited": ["https://example.org/loud"]}},
        {"feature": "mix.master.target.lufs", "low": -10, "high": -6, "unit": "LUFS", "evidence": {"cited": ["https://example.org/loud"]}}
      ],
      "notes": [], "bassHands": ["octave"], "sounds": {"machines": ["tr909"], "bass": ["sub"], "instruments": ["stab"]},
      "lineages": [], "references": [], "pitfalls": []
    }
    """.utf8))

    static let book = GenreBook([house])
}

@Suite("Genres", .serialized) @MainActor
struct GenreTests {

    // MARK: The shipped profiles

    @Test("every shipped profile holds to the method")
    func shippedProfilesLint() {
        let book = GenreBook.standard
        for profile in book.profiles {
            let violations = GenreMethod.lint(profile)
            #expect(violations.isEmpty, "\(profile.id): \(violations)")
        }
        #expect(Set(book.profiles.map(\.id)).count == book.profiles.count, "ids are unique")
    }

    /// Feels no profile covers, each for a reason: a meter is not a genre, and a guess would judge
    /// the song by the wrong numbers.
    static let genreless: Set<String> = ["Five Four", "Seven Eight", "Baião", "Second Line"]

    @Test("every shipped feel belongs to a genre, but the ones no profile covers, which get no guess")
    func everyFeelHasAGenre() throws {
        let book = GenreBook.standard
        try #require(!book.profiles.isEmpty, "the profiles ship in Resources/Genres")
        let orphans = Set(FeelLibrary.standard.feels.filter { book.guess(feel: $0.name, tempo: $0.suggestedTempo) == nil }.map(\.name))
        #expect(orphans == Self.genreless, "\(orphans.symmetricDifference(Self.genreless))")
    }

    @Test("a feel's guess is the genre it is, not one that merely shares a tag")
    func guesses() {
        let book = GenreBook.standard
        func guess(_ feel: String) -> String? {
            book.guess(feel: feel, tempo: FeelLibrary.standard.feel(named: feel)!.suggestedTempo)?.id
        }
        #expect(guess("Trap Rolling Hats") == "trap")
        #expect(guess("UK Drill") == "drill")
        #expect(guess("Classic House") == "house")
        #expect(guess("Cha-Cha-Chá") == "salsa")
        #expect(guess("Slow Blues 12/8") == "blues")
        #expect(guess("Gospel Shout") == "gospel")
        #expect(guess("Baião") == nil)
        // The genres written for the feels that had none.
        #expect(guess("Big Band Swing") == "swing")
        #expect(guess("Ska") == "ska")
        #expect(guess("Steppers") == "dub")
        #expect(guess("Dancehall") == "dancehall")
        #expect(guess("New Jack Swing") == "rnb")
        #expect(guess("Cinematic Toms") == "film-score")
        #expect(guess("Rumba Flamenca") == "flamenco")
        #expect(guess("Bulgar") == "klezmer")
        #expect(guess("Saidi") == "arabic-pop")
        #expect(guess("Reggae One Drop") == "reggae", "the one drop is reggae's before it is dub's")
    }

    @Test("a tempo fits its genre counted any way players count it: half time, double time, a compound meter's dotted quarter")
    func tempoFits() throws {
        let salsa = try #require(GenreBook.standard.profile(named: "salsa"))
        #expect(salsa.fits(tempo: 96, meter: .fourFour), "the feel library writes salsa at half the quarter note")
        let blues = try #require(GenreBook.standard.profile(named: "blues"))
        #expect(!blues.fits(tempo: 40, meter: .fourFour))
    }

    @Test("numerals become chords in the key, in the progression's own mode")
    func numerals() {
        let aMinor = Key(parsing: "A minor")!, cMajor = Key(parsing: "C major")!
        #expect(GenreNumerals.symbols("i - bVII - bVI - bVII", in: aMinor) == "Am | G | F | G")
        #expect(GenreNumerals.symbols("i - VII - VI", in: aMinor, mode: "aeolian") == "Am | G | F")
        #expect(GenreNumerals.symbols("I - V - vi - IV", in: cMajor) == "C | G | Am | F")
        #expect(GenreNumerals.symbols("ii7 - V7 - Imaj7", in: cMajor) == "Dm7 | G7 | Cmaj7")
        // The colours past the seventh are chords the app reads now; they used to be cut to it.
        #expect(GenreNumerals.symbols("Imaj7#11 - bVIImaj7#11", in: cMajor) == "Cmaj7#11 | Bbmaj7#11")
        #expect(GenreNumerals.symbols("ii9 - V13 - Imaj9 - I6/9", in: cMajor) == "Dm9 | G13 | Cmaj9 | C6/9")
        #expect(GenreNumerals.chords("I - Q", in: cMajor) == nil)
        #expect(GenreNumerals.fits(mode: "dorian", aMinor) && !GenreNumerals.fits(mode: "ionian", aMinor))
    }

    @Test("every shipped progression reads as chords")
    func shippedNumerals() {
        for profile in GenreBook.standard.profiles {
            for progression in profile.progressions {
                let key = Key(parsing: GenreNumerals.fits(mode: progression.mode, Key(parsing: "A minor")!) ? "A minor" : "C major")!
                #expect(GenreNumerals.chords(progression.roman, in: key, mode: progression.mode) != nil, "\(profile.id): \(progression.roman)")
            }
        }
    }

    // MARK: Finding and guessing

    @Test("a profile answers to its id, its name and its aliases, however they are cased")
    func lookup() {
        let book = GenreFixture.book
        #expect(book.profile(named: "test-house")?.id == "test-house")
        #expect(book.profile(named: "Test House")?.id == "test-house")
        #expect(book.profile(named: "TH")?.id == "test-house")
        #expect(book.profile(named: "polka") == nil)
    }

    @Test("a song's genre is what it was given, else the feel its groove was written in")
    func songGenre() {
        let book = GenreFixture.book
        var song = Song(title: "S", tempo: 124)
        #expect(book.genre(of: song) == nil, "nothing points anywhere")
        let feel = FeelLibrary.standard.feel(named: "Four on the Floor")!
        var groove = feel.groove
        groove.feel = GrooveFeel(name: feel.name, seed: 1)
        try? song.append(PartVersion(partID: PartID(), kind: .groove(groove), author: .user, operation: Operation.written, note: nil))
        #expect(book.genre(of: song)?.profile.id == "test-house")
        #expect(book.genre(of: song)?.source == .feel("Four on the Floor"))
        song.genre = "test-house"
        #expect(book.genre(of: song)?.source == .set)
    }

    // MARK: The lens

    @Test("a reading the genre calls normal stands, with both numbers said")
    func lensLoosens() {
        let lens = GenreLens(GenreFixture.house)
        let reading = PersonaReading(rule: "engineer.delivery-loudness", feature: .integratedLUFS, value: -7.5, holds: false,
                                     says: "-7.5 LUFS is past the -14 delivery.")
        let judged = lens.apply(reading, bible: Engineer.bible)
        #expect(judged.holds && judged.genre == "test-house")
        #expect(judged.says.hasPrefix("-7.5 LUFS is past the -14 delivery.") && judged.says.contains("Test House") && judged.says.contains("-9–-6 LUFS"))
    }

    @Test("a one-sided rule keeps its side: an early hook is still no fault, a late one is judged by the genre's ceiling")
    func lensKeepsTheSide() {
        let lens = GenreLens(GenreFixture.house)
        func hook(_ seconds: Double, holds: Bool) -> PersonaReading {
            lens.apply(PersonaReading(rule: "peer.hook-inside-thirty", feature: .hookArrivalSeconds, value: seconds, holds: holds, says: "hook"), bible: Peer.bible)
        }
        #expect(hook(12, holds: true).holds, "an early hook is under the ceiling, not outside a range")
        #expect(hook(12, holds: true).genre == nil, "nothing changed, nothing said")
        #expect(hook(50, holds: false).holds, "50 s is inside this genre's 75")
        #expect(!hook(90, holds: false).holds)
        #expect(hook(90, holds: false).says.contains("up to 75 seconds"))
    }

    @Test("a reading on a feature the genre has no number for, or a condition rule, is left alone")
    func lensLeavesAlone() {
        let lens = GenreLens(GenreFixture.house)
        let crest = PersonaReading(rule: "engineer.drums-keep-their-crest", feature: .crestDB, value: 5, holds: false, says: "flat")
        #expect(lens.apply(crest, bible: Engineer.bible) == crest)
        let decay = PersonaReading(rule: "bassist.808-is-the-bass", feature: .kickDecaySeconds, value: 0.6, holds: false, says: "808")
        #expect(lens.apply(decay, bible: Bassist.bible) == decay)
    }

    @Test("a refusal the genre would not make becomes agreement, with the refusal kept as its caveat")
    func lensOnVerdicts() {
        let lens = GenreLens(GenreFixture.house)
        let bible = Engineer.bible
        let refused = PersonaVerdict.refuse(rule: "engineer.master-target", because: "Too loud for delivery.", counter: "Go quieter.")
        let loud = PersonaProposal.setMaster(targetLUFS: -7, ceilingDBTP: -1)
        guard case .agreeWithCaveat(let line, let caveat) = lens.apply(refused, to: loud, bible: bible) else {
            Issue.record("-7 is inside this genre's master target"); return
        }
        #expect(line.contains("Test House") && caveat.contains("Too loud for delivery."))
        let louder = PersonaProposal.setMaster(targetLUFS: -4, ceilingDBTP: -1)
        #expect(lens.apply(refused, to: louder, bible: bible) == refused, "past the genre's own ceiling, the refusal stands")
        #expect(lens.apply(.agree("fine"), to: loud, bible: bible) == .agree("fine"), "agreement passes through")
    }

    // MARK: The Director's tools

    @Test("list_genres, read_genre and set_genre work from the app's own profiles")
    func tools() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "Night Bus", tempo: 124))
        let list = try await ListGenresTool(workspace: workspace, book: GenreFixture.book).run(.init())
        #expect(list.genres.map(\.id) == ["test-house"] && list.song == nil)

        let read = try await ReadGenreTool(workspace: workspace, book: GenreFixture.book).run(.init(genre: "th"))
        #expect(read.tempo == "118–128 BPM" && read.bassHands == ["octave"])
        #expect(read.ranges.contains("mix.lufs.integrated: -9–-6 LUFS"))
        await #expect(throws: DirectorToolFailure.self) { try await ReadGenreTool(workspace: workspace, book: GenreFixture.book).run(.init(genre: "polka")) }
    }

    @Test("set_genre places the song in a shipped genre and clears back to the guess")
    func setGenre() async throws {
        let first = try #require(GenreBook.standard.profiles.first, "the profiles ship in Resources/Genres")
        let workspace = DirectorScratchWorkspace(song: Song(title: "Night Bus", tempo: 124))
        let out = try await SetGenreTool(workspace: workspace).run(.init(genre: first.name))
        #expect(out.genre == first.id && workspace.song?.genre == first.id)
        _ = try await SetGenreTool(workspace: workspace).run(.init(genre: ""))
        #expect(workspace.song?.genre == nil)
        let none = try await SetGenreTool(workspace: workspace).run(.init(genre: "none"))
        #expect(none.genre == nil && workspace.song?.genre == GenreBook.none && workspace.genre == nil, "none is no genre, not a guess")
        await #expect(throws: DirectorToolFailure.self) { try await SetGenreTool(workspace: workspace).run(.init(genre: "no such genre")) }
    }

    // MARK: The bass players

    private func line(_ lineage: BassLineage, density: Double = 0.6, bars: Int = 2) -> [NoteEvent] {
        let feel = FeelLibrary.standard.feel(named: "Four on the Floor")!
        let chords = [ChordSpan(Chord(.a, .minor), beats: 4), ChordSpan(Chord(.f, .major), beats: 4)]
        return BassWriter.write(BassRequest(key: Key(tonic: NoteName(.a), mode: .aeolian), chords: chords, groove: feel.groove,
                                            tempo: 120, lineage: lineage, density: density, seed: 7, bars: bars)).notes
    }

    private func beatInBar(_ note: NoteEvent) -> Double { note.start.truncatingRemainder(dividingBy: 4) }

    @Test("every player writes a line in its register, on its default sound")
    func everyPlayerWrites() {
        for lineage in BassLineage.allCases {
            let notes = line(lineage)
            #expect(!notes.isEmpty, "\(lineage)")
            #expect(notes.allSatisfy { lineage.register.contains($0.pitch.midi) }, "\(lineage) leaves its register")
        }
    }

    @Test("each figure is the figure its genre is known by")
    func figures() {
        let oneDrop = line(.oneDrop)
        #expect(oneDrop.allSatisfy { beatInBar($0) >= 0.75 }, "the one drop leaves beat one empty")
        #expect(oneDrop.contains { abs(beatInBar($0) - 2) < 0.01 }, "and lands on three")

        let tumbao = line(.tumbao)
        #expect(tumbao.allSatisfy { abs(beatInBar($0)) > 0.01 }, "the tumbao never strikes one")
        #expect(Set(tumbao.map { beatInBar($0) }) == [1.5, 3], "the and of two, and four")

        let walking = line(.walking)
        #expect(walking.count == 8 && Set(walking.map { beatInBar($0) }) == [0, 1, 2, 3], "a note a beat")

        let rootFifth = line(.rootFifth, density: 0.2)
        #expect(Set(rootFifth.map { beatInBar($0) }) == [0, 2])
        let first = rootFifth.sorted { $0.start < $1.start }
        #expect((first[0].pitch.midi - first[1].pitch.midi + 120) % 12 == 5, "the fifth below the root")

        let octave = line(.octave, density: 0.9)
        #expect(octave.count == 16 && Set(octave.map { $0.pitch.midi % 12 }).count <= 2, "eighths on the root and its octave")
        let sparseOctave = line(.octave, density: 0.2)
        #expect(sparseOctave.allSatisfy { abs(beatInBar($0).truncatingRemainder(dividingBy: 1) - 0.5) < 0.01 }, "sparse: the off-beats")

        #expect(line(.rolling, density: 0.2).count == 2, "one long note a bar")
        #expect(line(.logDrum).allSatisfy { $0.duration < 0.3 }, "log-drum hits are short")
    }

    @Test("the Bassist agrees to a genre figure on the grid and says what it is")
    func bassistOnFigures() {
        let verdict = Bassist().consider(.writeBassline(lineage: "tumbao", lagMS: 0, tempo: 180, hatLagMS: 0, kickLagMS: 0,
                                                        kickDecaySeconds: 0.2, sound: "upright"))
        guard case .agree(let line) = verdict else { Issue.record("\(verdict)"); return }
        #expect(line.hasPrefix("Tumbao:"))
    }
}
