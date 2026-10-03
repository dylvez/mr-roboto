import Foundation
import MusicTheory
import Testing
@testable import SongGraph

@Test func moduleVersion() {
    #expect(SongGraphModule.version == "0.1.0")
    #expect(SongGraphModule.schemaVersion == 4)
}

@Suite struct IdentityTests {
    @Test func typedIDsRoundTripAsUUIDStrings() throws {
        let id = VersionID()
        let data = try SongGraphCodec.encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.rawValue.uuidString)\"")
        #expect(try SongGraphCodec.decode(VersionID.self, from: data) == id)
        #expect(VersionID(uuidString: id.description) == id)
    }

    @Test func contentHashValidatesHex() {
        #expect(ContentHash(hex: String(repeating: "ab", count: 32)) != nil)
        #expect(ContentHash(hex: String(repeating: "AB", count: 32))?.hex == String(repeating: "ab", count: 32))
        #expect(ContentHash(hex: "abc") == nil)
        #expect(ContentHash(hex: String(repeating: "zz", count: 32)) == nil)
    }

    @Test func sha256MatchesKnownDigest() {
        let hash = ContentHash(of: Data("abc".utf8))
        #expect(hash.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHash(of: Data()).hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func mediaRefNormalizesExtension() {
        let ref = MediaRef(hash: ContentHash(of: Data()), fileExtension: " .WAV ")
        #expect(ref.fileExtension == "wav")
        #expect(ref.fileName.hasSuffix(".wav"))
    }
}

@Suite struct RoundTripTests {
    @Test(arguments: Fixtures.everyKind)
    func everyKindRoundTripsThroughJSON(kind: PartKind) throws {
        let data = try SongGraphCodec.encode(kind)
        let decoded = try SongGraphCodec.decode(PartKind.self, from: data)
        #expect(decoded == kind)
        #expect(decoded.type == kind.type)
        let json = try SongGraphCodec.decode(JSONValue.self, from: data)
        #expect(json["type"]?.stringValue == kind.type.rawValue)
    }

    @Test func partVersionRoundTripsWithProvenance() throws {
        let parent = VersionID()
        let version = PartVersion(partID: PartID(), kind: .sound(Fixtures.sound), author: Fixtures.bassist,
                                  parents: [parent], operation: Operation.edit, note: "warmer", origin: SeedID())
        let decoded = try SongGraphCodec.decode(PartVersion.self, from: try SongGraphCodec.encode(version))
        #expect(decoded == version)
        #expect(decoded.parents == [parent])
        #expect(decoded.author == .persona("Bassist"))
        #expect(decoded.createdAt == version.createdAt)
    }

    @Test func authorEncodesAsRoleAndName() throws {
        let user = try SongGraphCodec.decode(JSONValue.self, from: try SongGraphCodec.encode(Author.user))
        #expect(user["role"]?.stringValue == "user")
        #expect(user["name"] == nil)
        let persona = try SongGraphCodec.decode(JSONValue.self, from: try SongGraphCodec.encode(Author.persona("Keys")))
        #expect(persona["role"]?.stringValue == "persona")
        #expect(persona["name"]?.stringValue == "Keys")
    }

    @Test(arguments: [
        SeedKind.hummedTake(Fixtures.mediaRef(3)),
        SeedKind.brief("a slow one about arriving somewhere"),
        SeedKind.importedRecord(RecordID()),
    ])
    func seedsRoundTrip(kind: SeedKind) throws {
        let seed = Seed(kind: kind, note: "n")
        #expect(try SongGraphCodec.decode(Seed.self, from: try SongGraphCodec.encode(seed)) == seed)
    }

    @Test func songRoundTripsWithEverything() throws {
        let graph = try Fixtures.graph()
        let data = try SongGraphCodec.encodeSong(graph.song)
        let decoded = try SongGraphCodec.decodeSong(from: data)
        #expect(decoded == graph.song)
        #expect(decoded.schemaVersion == 4)
        #expect(decoded.sections.first?.transitionOut?.kind == .riser)
        #expect(decoded.key == Fixtures.dMajor)
    }

    // A sound may name the part it is for, so a pad can hold the chords while a lead plays the
    // tune. The field is new; every document written before it must still read and write the same
    // bytes, which is what lets this land without a schema bump.
    @Test func aSoundMayNameItsPart() throws {
        let songs = Sound(instrument: "rhodes")
        let encoded = try SongGraphCodec.encode(songs)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("forPart"), "a sound with no part must not write the key: \(json)")
        #expect(try SongGraphCodec.decode(Sound.self, from: encoded) == songs)

        let part = PartID()
        let mine = Sound(instrument: "pad", preset: "warm", parameters: ["cutoff": 0.4], forPart: part)
        let back = try SongGraphCodec.decode(Sound.self, from: try SongGraphCodec.encode(mine))
        #expect(back == mine)
        #expect(back.forPart == part)

        // And a document written before the field decodes with no part, rather than refusing.
        let old = Data(#"{"instrument":"juno","parameters":{}}"#.utf8)
        #expect(try SongGraphCodec.decode(Sound.self, from: old).forPart == nil)
    }

    @Test func libraryRoundTrips() throws {
        let graph = try Fixtures.graph()
        let analysis = PartVersion(partID: PartID(), kind: .analysis(Fixtures.analysis), author: .user, operation: Operation.analyzed)
        let record = Record(title: "Arrival", artist: "Vessel", media: Fixtures.mediaRef(4, ext: "mp3"), analysis: analysis)
        let idea = PartVersion(partID: PartID(), kind: .groove(Fixtures.groove), author: .user, operation: Operation.written)
        let album = Album(title: "Interior Season", artist: "Vessel", songs: [graph.song.id],
                          clearances: [SampleClearance(source: "Vessel – Arrival", status: .notRequired, record: record.id)])
        let library = Library(songs: [graph.song], albums: [album], ideas: [idea], records: [record],
                              samples: [LibrarySample(name: "snare", sample: Fixtures.sample, tags: ["drums", "lofi"])])
        let decoded = try SongGraphCodec.decode(Library.self, from: try SongGraphCodec.encode(library))
        #expect(decoded == library)
    }

    @Test func datesKeepMillisecondPrecision() throws {
        let odd = Date(timeIntervalSinceReferenceDate: 812_345_678.123456789)
        let version = PartVersion(partID: PartID(), kind: .sound(Fixtures.sound), createdAt: odd, author: .user, operation: "x")
        #expect(version.createdAt == odd.graphPrecision)
        #expect(abs(version.createdAt.timeIntervalSince(odd)) < 0.001)
        let decoded = try SongGraphCodec.decode(PartVersion.self, from: try SongGraphCodec.encode(version))
        #expect(decoded.createdAt == version.createdAt)
    }
}

@Suite struct ModelBehaviourTests {
    @Test func appendRejectsDuplicateVersions() throws {
        var song = Song(title: "x")
        let version = PartVersion(partID: PartID(), kind: .melody(Fixtures.melody), author: .user, operation: "hummed")
        try song.append(version)
        #expect(throws: SongGraphError.duplicateVersion(version.id)) { try song.append(version) }
        #expect(song.versions.count == 1)
    }

    @Test func derivingKeepsPartAndRecordsParent() {
        let v1 = PartVersion(partID: PartID(), kind: .melody(Fixtures.melody), author: .user, operation: "hummed")
        let v2 = v1.deriving(.melody(Fixtures.melody.transposed(by: 5)), by: Fixtures.bassist, operation: "transpose")
        #expect(v2.partID == v1.partID)
        #expect(v2.parents == [v1.id])
        #expect(v2.id != v1.id)
        let spawned = v1.spawning(.progression(Fixtures.progression), by: Fixtures.bassist, operation: "harmonize")
        #expect(spawned.partID != v1.partID)
        #expect(spawned.parents == [v1.id])
    }

    @Test func progressionUsesMusicTheory() {
        let progression = Fixtures.progression
        #expect(progression.romanNumerals.map(\.description) == ["I", "V", "vi", "IV", "V7"])
        #expect(progression.transposed(by: 2).key.tonic == NoteName(.e))
        #expect(progression.bars[1].beats == 4)
    }

    @Test func lyricTextJoinsSyllables() {
        #expect(Fixtures.lyric.text == "Arrival\nin light")
    }

    @Test func analysisConveniences() {
        let analysis = Fixtures.analysis
        #expect(analysis.dominantKey == Fixtures.dMajor)
        #expect(analysis.dominantTempo == 113)
        #expect(analysis.downbeats == [0.9])
    }

    @Test func songMediaReferencesAreDeduplicated() throws {
        var song = Song(title: "x")
        let ref = Fixtures.mediaRef(5)
        song.seeds = [Seed(kind: .hummedTake(ref))]
        let take = Audio(media: ref, role: .take, sampleRate: 48000, channelCount: 1, duration: 3)
        try song.append(PartVersion(partID: PartID(), kind: .audio(take), author: .user, operation: "recorded"))
        try song.append(PartVersion(partID: PartID(), kind: .sample(Sample(media: Fixtures.mediaRef(6))), author: .user, operation: "chop"))
        #expect(song.mediaReferences == [ref, Fixtures.mediaRef(6)])
    }
}

@Suite struct RecordGridTests {
    /// 120 bpm read at 240: beats every 0.25 s from 0.5, a downbeat every four.
    static func doubleTime() -> MusicAnalysis {
        let beats = (0..<64).map { BeatMarker(time: 0.5 + Double($0) * 0.25, isDownbeat: $0 % 4 == 0) }
        let bars = stride(from: 0, to: 64, by: 4).map { TimeRange(start: 0.5 + Double($0) * 0.25, end: 0.5 + Double($0 + 4) * 0.25) }
        let checker = (0..<32).map { BeatMarker(time: 0.5 + Double($0) * 0.5, isDownbeat: $0 % 4 == 0) }
        return MusicAnalysis(duration: 17, beats: beats, bars: bars, tempo: [TempoRange(start: 0, end: 17, bpm: 240)],
                             sections: [SectionRange(start: 0, end: 17, label: "song")], checkerBeats: checker)
    }

    @Test("as read is the analysis untouched; halved is half the bars at half the tempo, everything in seconds kept")
    func regridded() {
        let read = Self.doubleTime()
        #expect(read.regridded(RecordGrid()) == read)
        let half = read.regridded(RecordGrid(tempo: 0.5))
        #expect(half.bars.count == 8 && half.bars[0] == TimeRange(start: 0.5, end: 2.5))
        #expect(half.dominantTempo == 120 && half.beats.count == 32 && half.downbeats.prefix(2) == [0.5, 2.5])
        #expect(half.sections == read.sections && half.checkerBeats == read.checkerBeats)
        let second = read.regridded(RecordGrid(secondTracker: true))
        #expect(second.beats == read.checkerBeats && second.bars.count == 8 && second.dominantTempo == 120)
        let later = read.regridded(RecordGrid(secondTracker: true, downbeat: 1))
        #expect(later.downbeats.first == 1.0)
        #expect(RecordGrid(secondTracker: true, tempo: 0.5, downbeat: -1).description == "the second tracker's, halved, downbeat a beat earlier")
    }

    @Test("the second tracker's beats, its wandering downbeats ignored: bars of the record's meter from the first's downbeat")
    func secondTrackersBeatsNotItsBars() {
        var read = Self.doubleTime()
        // Downbeats where no bar line is: every beat, then none, then two in a row.
        read.checkerBeats = (0..<32).map { BeatMarker(time: 0.5 + Double($0) * 0.5, isDownbeat: [0, 1, 2, 3, 9, 10, 21].contains($0)) }
        read.beatCheck = BeatGridCheck(checker: "beat-this", agreement: 0.4, primaryBPM: 240, checkerBPM: 121, usedChecker: false)
        let second = read.regridded(RecordGrid(secondTracker: true))
        #expect(second.bars.count == 8 && second.downbeats == stride(from: 0.5, to: 16, by: 2).map { $0 })
        #expect(second.dominantTempo == 121, "the tracker's own figure")
        #expect(read.regridded(RecordGrid(downbeat: 1)).tempo == read.tempo, "a downbeat moved is no change of tempo")
        #expect(read.regridded(RecordGrid(tempo: 0.5)).dominantTempo == 120 && read.regridded(RecordGrid(secondTracker: true, tempo: 0.5)).dominantTempo == 60.5)
    }

    @Test("a record keeps its correction and reads through it; from before, it round-trips with neither")
    func record() throws {
        let analysis = PartVersion(partID: PartID(), kind: .analysis(Self.doubleTime()), author: .user, operation: Operation.imported)
        var record = Record(title: "Twice", media: Fixtures.mediaRef(90), analysis: analysis)
        let old = try SongGraphCodec.encode(record)
        #expect(!String(decoding: old, as: UTF8.self).contains("\"grid\""))
        #expect(record.reading?.bars.count == 16 && record.reading == record.readingAsRead)
        record.grid = RecordGrid(tempo: 0.5)
        #expect(record.reading?.bars.count == 8 && record.readingAsRead?.bars.count == 16)
        let decoded = try SongGraphCodec.decode(Record.self, from: try SongGraphCodec.encode(record))
        #expect(decoded == record && decoded.reading?.dominantTempo == 120)
    }
}
