import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The whole song read section by section off the Master's one bounce, a reference beside it, and
// what the Engineer and the Peer say from them: a band off the reference, a hook that sits back.
// The numbers are Máquina, 1915's, near enough — its coro 1.4 LU under its verse, its 2–6 kHz
// 15 dB under the whole mix against 8 in the disco beside it — which nothing in the app said.

/// A section as the meter hands it over.
private func row(_ name: String, at seconds: Double, lufs: Double?, bands: [Double]) -> SectionMeter.Reading {
    SectionMeter.Reading(name: name, startSeconds: seconds, seconds: 20, integratedLUFS: lufs, crestDB: 12, spreadLU: 3,
                         bandsDB: bands, energyDB: 0)
}

@Suite("The balance against a reference: the Engineer")
struct EngineerBalanceTests {
    let song = [-3.0, -5.0, -9.0, -15.2, -22.0]
    let disco = [-3.5, -5.5, -10.0, -8.1, -20.5]

    @Test("a band more than 3 dB off the reference is said with both numbers and the gap; the bands near it are said once")
    func offTheReference() {
        let readings = Engineer().read(balance: song, against: disco, named: "Mirror Ball, 1923")
        #expect(readings.count == 2, "\(readings.map(\.says))")
        let off = readings[0]
        #expect(off.rule == "engineer.balance-against-the-reference" && off.feature == .bandPresenceDB && !off.holds && off.value == -15.2)
        #expect(off.says == "2k–6k Hz sits 15.2 dB under the whole mix, against 8.1 in Mirror Ball, 1923 — 7.1 dB short. "
                    + "Lift what owns the band, no more than 6 dB a move.", "\(off.says)")
        #expect(readings[1].holds && readings[1].feature == .referenceBandGapDB && abs(readings[1].value - 1.5) < 1e-9)
        #expect(readings[1].says == "20–120, 120–500, 500–2k and 6k–16k Hz within 3 dB of Mirror Ball, 1923's balance.", "\(readings[1].says)")
        // Unique by rule and feature, so a list keyed by reading draws each once.
        #expect(Set(readings.map(\.id)).count == readings.count)

        // Over as well as short, the failing ones first and the widest of them first.
        let heavy = Engineer().read(balance: [-3.5, -5, -9, -15.2, -27], against: [-8, -5.5, -10, -8.1, -20.5], named: "X")
        #expect(heavy.prefix(3).map(\.feature) == [.bandPresenceDB, .bandAirDB, .bandSubDB], "\(heavy.map(\.says))")
        #expect(heavy[2].says.contains("— 4.5 dB over. Cut what owns the band"), "\(heavy[2].says)")
        // Every band near: one line, and it holds.
        let near = Engineer().read(balance: disco.map { $0 + 1 }, against: disco, named: "X")
        #expect(near.count == 1 && near[0].holds && near[0].says == "Every band within 3 dB of X's balance.", "\(near.map(\.says))")
        #expect(Engineer().read(balance: song, against: [], named: "X").isEmpty)
    }

    @Test("where the genre states a band's range, the range draws the line for that band, and the reading says both")
    func genreRange() throws {
        var cumbia = try #require(GenreBook.standard.profile(named: "cumbia"))
        #expect(cumbia.range(.bandPresenceDB) == nil, "no profile states a band yet; this one is the test's")
        cumbia.ranges.append(GenreRange(.bandPresenceDB, -16, -12, unit: "dB", evidence: .inferred("the test's own range")))
        cumbia.ranges.append(GenreRange(.bandMiddleDB, -6, -4, unit: "dB", evidence: .inferred("the test's own range")))
        let readings = Engineer().read(balance: song, against: disco, named: "Mirror Ball, 1923", genre: cumbia)
        // 7.1 dB off the disco, but inside the cumbia's own range: it stands, and says why.
        let presence = try #require(readings.first { $0.feature == .bandPresenceDB })
        #expect(presence.holds && presence.genre == "cumbia" && presence.says.hasSuffix("In Cumbia that is normal (-16–-12 dB), so it stands."),
                "\(presence.says)")
        // A dB from the disco, but outside the cumbia's: the genre's line, said.
        let middle = try #require(readings.first { $0.feature == .bandMiddleDB })
        #expect(!middle.holds && middle.genre == "cumbia" && middle.says.hasSuffix("1.0 dB away. But Cumbia wants -6–-4 dB."), "\(middle.says)")
        #expect(readings.last?.says == "20–120, 120–500 and 6k–16k Hz within 3 dB of Mirror Ball, 1923's balance.", "\(readings.map(\.says))")
        // A band's share of the mix is a genre's to range; the distance from a picked reference is not.
        #expect(GenreLens.judges(.bandPresenceDB) && !GenreLens.judges(.referenceBandGapDB))
        #expect(GenreMethod.features.isSuperset(of: Feature.mixBands))
        #expect(GenreMethod.lint(cumbia).isEmpty, "\(GenreMethod.lint(cumbia))")
    }
}

@Suite("Whether the hook lifts: the Peer")
struct PeerLiftTests {
    let verse = [-4.0, -6.0, -10.0, -14.0, -22.0]

    @Test("a coro no louder and no fuller than the verse before it is said, in seconds and LU")
    func sitsBack() {
        let readings = Peer().read(lifts: [row("Intro", at: 0, lufs: -16, bands: verse.map { $0 - 6 }),
                                           row("Verse", at: 9.9, lufs: -12, bands: verse),
                                           row("Coro", at: 29.7, lufs: -13.4, bands: verse.map { $0 - 1 })])
        #expect(readings.count == 1)
        let coro = readings[0]
        #expect(coro.rule == "peer.hook-lifts" && coro.feature == .hookLiftLU && !coro.holds && abs(coro.value + 1.4) < 1e-9)
        #expect(coro.says == "The Coro at 0:30 comes in 1.4 LU under the Verse before it, and no fuller. "
                    + "A hook has to lift: a decibel or more, or something coming in.", "\(coro.says)")
    }

    @Test("a decibel louder lifts; a band up 3 dB with none down as far is fuller; a trade, or only just louder, is not")
    func lifts() {
        let louder = Peer().read(lifts: [row("Verse", at: 0, lufs: -12, bands: verse), row("Chorus", at: 20, lufs: -10.5, bands: verse)])
        #expect(louder.first?.holds == true && louder.first?.says == "The Chorus at 0:20 lifts 1.5 LU over the Verse.", "\(louder.map(\.says))")
        var air = verse
        air[4] += 4
        let fuller = Peer().read(lifts: [row("Verse", at: 0, lufs: -12, bands: verse), row("Chorus", at: 20, lufs: -12.3, bands: air)])
        #expect(fuller.first?.holds == true && fuller.first?.says == "The Chorus at 0:20 is no louder than the Verse (-0.3 LU) but fuller: 6k–16k Hz up 4 dB.",
                "\(fuller.map(\.says))")
        var traded = air
        traded[0] -= 5
        let trade = Peer().read(lifts: [row("Verse", at: 0, lufs: -12, bands: verse), row("Chorus", at: 20, lufs: -12, bands: traded)])
        #expect(trade.first?.holds == false && trade.first?.says.contains("no fuller — what comes in at 6k–16k Hz goes out at 20–120 Hz") == true,
                "\(trade.map(\.says))")
        let barely = Peer().read(lifts: [row("Verse", at: 0, lufs: -12, bands: verse), row("Hook", at: 20, lufs: -11.6, bands: verse)])
        #expect(barely.first?.holds == false && barely.first?.says.contains("comes in only 0.4 LU over the Verse before it") == true, "\(barely.map(\.says))")
    }

    @Test("each hook against the nearest verse before it; a hook with none before it, a pre-chorus and a silent hook are not read")
    func pairing() {
        let readings = Peer().read(lifts: [row("Chorus", at: 0, lufs: -10, bands: verse),
                                           row("Verse 1", at: 20, lufs: -12, bands: verse),
                                           row("Pre-Chorus", at: 40, lufs: -12, bands: verse),
                                           row("Chorus 2", at: 50, lufs: -11.5, bands: verse),
                                           row("Verso", at: 70, lufs: -14, bands: verse),
                                           row("Breakdown", at: 90, lufs: -18, bands: verse),
                                           row("Coro", at: 100, lufs: -12, bands: verse),
                                           row("Refrain", at: 120, lufs: nil, bands: verse)])
        #expect(readings.count == 2, "\(readings.map(\.says))")
        #expect(readings.first?.says.hasPrefix("The Chorus 2 at 0:50 comes in only 0.5 LU over the Verse 1 before it") == true, "\(readings.map(\.says))")
        #expect(readings.last?.holds == true && readings.last?.says == "The Coro at 1:40 lifts 2.0 LU over the Verso.", "\(readings.map(\.says))")
        #expect(FormObservation.isVerse("Verse 2") && FormObservation.isVerse("Estrofa") && !FormObservation.isVerse("Pre-verse")
                    && !FormObservation.isVerse("Chorus"))
    }

    @Test("the new rules hold to the method and the bibles on disk carry them")
    func bibles() {
        #expect(BibleMethod.lint(Engineer.bible).isEmpty, "\(BibleMethod.lint(Engineer.bible))")
        #expect(BibleMethod.lint(Peer.bible).isEmpty, "\(BibleMethod.lint(Peer.bible))")
        let bundled = BibleDocument.bundled()
        #expect(bundled.first { $0.id == .engineer }?.rules.contains { $0.id == "engineer.balance-against-the-reference" } == true)
        #expect(bundled.first { $0.id == .peer }?.rules.contains { $0.id == "peer.hook-lifts" } == true)
    }
}

// MARK: - The Master, off its one bounce

/// A song of two sections, two bars each at 120 — four seconds a section — playing the groove and
/// the bass, as `SectionBounce` would bounce it.
@MainActor
private enum TwoSections {
    static let rate = 48_000.0

    static func song() -> (Song, SongPlayback) {
        let built = FormFixture.build(tempo: 120)
        var song = built.song
        let lanes = [built.groove, built.bass].map { Lane(part: $0) }
        song.sections = [Section(name: "Verse", stitch: lanes, lengthInBars: 2), Section(name: "Chorus", stitch: lanes, lengthInBars: 2)]
        return (song, SongPlayback.plan(for: song) { _ in nil })
    }

    /// Five tones a section, one in each band, at `levelDB` each; the chorus `chorusDB` from the
    /// verse; half a second of tail.
    static func bounce(chorusDB: Double) -> [[Float]] {
        func section(_ levelDB: Double) -> [Float] {
            let amplitude = pow(10, levelDB / 20)
            return (0..<Int(4 * rate)).map { i in
                let t = Double(i) / rate
                return Float(amplitude * [60.0, 250, 1_000, 3_500, 10_000].reduce(0) { $0 + sin(2 * .pi * $1 * t) })
            }
        }
        let lane = section(-26) + section(-26 + chorusDB) + [Float](repeating: 0, count: Int(0.5 * rate))
        return [lane, lane]
    }
}

@MainActor
private final class ReadingHost: MixHosting {
    var song: Song?
    var playback: SongPlayback
    var isPlaying = false
    var targets = Master()
    var bounceResult: (planar: [[Float]], sampleRate: Double)
    var bounced: [SectionID?] = []
    var kept: [WholeSongReading] = []
    var picked: MixReference?
    var measured: [MixReference] = []
    var referenceBands = [-6.0, -7.0, -7.0, -1.0, -7.0]

    init(song: Song, playback: SongPlayback, planar: [[Float]]) {
        self.song = song
        self.playback = playback
        bounceResult = (planar, TwoSections.rate)
    }

    func preview(_ mix: Mix) {}
    func commit(_ mix: Mix, base: PartVersion?, note: String) -> PartVersion? { nil }
    func meters(for parts: [PartID]) async -> [PartID: (peak: Float, rms: Float)] { [:] }
    func bounce(mix: Mix, section: SectionID?) async throws -> (planar: [[Float]], sampleRate: Double) {
        bounced.append(section)
        return bounceResult
    }
    func note(_ text: String, detail: String?) {}
    var reference: MixReference? { picked }
    func setReference(_ reference: MixReference?) { picked = reference }
    func measureReference(_ reference: MixReference) async throws -> ReferenceReading {
        measured.append(reference)
        let whole = SectionMeter.Reading(name: "Mirror Ball, 1923", startSeconds: 0, seconds: 268, integratedLUFS: -10.4, crestDB: 12,
                                         spreadLU: 4, bandsDB: referenceBands, energyDB: 0)
        return ReferenceReading(reference: reference, name: "Mirror Ball, 1923", kind: .song,
                                sheet: SectionMeter.Sheet(whole: whole, sections: [], spectrum: []), source: "the test")
    }
    func keep(_ reading: WholeSongReading) { kept.append(reading) }
}

@Suite("The Master, section by section", .serialized) @MainActor
struct MasterSectionsTests {

    @Test("the form's sections lie where the bounce plays them, on its clock")
    func spans() {
        let (song, plan) = TwoSections.song()
        let spans = SectionBounce.spans(of: plan, sampleRate: TwoSections.rate)
        #expect(spans.map(\.section) == song.sections.map(\.id))
        #expect(spans.map(\.span.name) == ["Verse", "Chorus"])
        #expect(spans.map(\.span.frames) == [0..<192_000, 192_000..<384_000])
        var flat = plan
        flat.segments = []
        #expect(SectionBounce.spans(of: flat, sampleRate: TwoSections.rate).isEmpty, "a song with no form has no sections to read")
    }

    @Test("one bounce, read whole and by section: the chorus 1.4 LU under the verse is the Peer's to say, and the reading is kept")
    func oneBounce() async {
        let (song, plan) = TwoSections.song()
        let host = ReadingHost(song: song, playback: plan, planar: TwoSections.bounce(chorusDB: -1.4))
        let model = MasterModel(host: host)
        await model.read()
        #expect(host.bounced.count == 1 && host.bounced.first! == nil, "the whole song, bounced once — no second render for the sections")
        guard let reading = model.reading else { Issue.record("no reading: \(model.lastError ?? "")"); return }
        #expect(reading.sections.map(\.name) == ["Verse", "Chorus"])
        let verse = reading.sections[0].integratedLUFS ?? 0, chorus = reading.sections[1].integratedLUFS ?? 0
        #expect(abs(chorus - verse + 1.4) < 0.05, "\(verse) \(chorus)")
        #expect(reading.sections[1].startSeconds == 4)
        // The whole-song numbers are the ones the Master always showed, from the same bounce.
        #expect(reading.observation.integratedLUFS == MixMeter.integratedLoudness(host.bounceResult.planar, sampleRate: TwoSections.rate))
        #expect(reading.truePeakDBTP == MixMeter.truePeakDB(host.bounceResult.planar, sampleRate: TwoSections.rate))
        #expect(reading.lifts.count == 1 && reading.lifts[0].holds == false, "\(reading.lifts.map(\.says))")
        #expect(reading.lifts.first?.says.hasPrefix("The Chorus at 0:04 comes in 1.4 LU under the Verse before it, and no fuller.") == true,
                "\(reading.lifts.map(\.says))")
        // Kept where the Director's tools read from, and current for the plan it was bounced from.
        #expect(host.kept.count == 1)
        var heard = plan
        heard.mix = model.mix
        #expect(host.kept[0].isCurrent(for: heard))
        // Nothing to read against yet: no band readings.
        #expect(!reading.readings.contains { $0.rule == "engineer.balance-against-the-reference" })

        // A chorus a decibel and a half up is a lift.
        host.bounceResult.planar = TwoSections.bounce(chorusDB: 1.5)
        await model.read()
        #expect(model.reading?.lifts.first?.holds == true && model.reading?.lifts.first?.says.contains("lifts 1.5 LU over the Verse") == true,
                "\(model.reading?.lifts.map(\.says) ?? [])")
    }

    @Test("a reference picked is measured once and judged against with no new bounce; picked again it is not measured again; cleared, its lines go")
    func reference() async {
        let (song, plan) = TwoSections.song()
        let host = ReadingHost(song: song, playback: plan, planar: TwoSections.bounce(chorusDB: 0))
        let model = MasterModel(host: host)
        await model.read()
        let mirror = MixReference.song(SongID())
        await model.chooseReference(mirror)
        #expect(host.picked == mirror && host.measured == [mirror])
        #expect(host.bounced.count == 1, "the song is not bounced again to be judged against a reference")
        let balance = model.reading?.readings.filter { $0.rule == "engineer.balance-against-the-reference" } ?? []
        // Five equal tones: each band a fifth of the whole, 7 dB under it. The reference's 2–6 kHz is
        // 1 dB under its whole — 6 dB short — and the rest sit within 3 dB.
        #expect(balance.first?.feature == .bandPresenceDB && balance.first?.holds == false, "\(balance.map(\.says))")
        #expect(balance.first?.says.contains("against 1.0 in Mirror Ball, 1923") == true, "\(balance.map(\.says))")
        #expect(balance.last?.holds == true && balance.count == 2, "\(balance.map(\.says))")
        #expect(model.reading?.firstToChange != nil)
        // Read again: the reference is not measured again.
        await model.read()
        #expect(host.measured == [mirror] && host.bounced.count == 2)
        #expect(model.reading?.readings.contains { $0.rule == "engineer.balance-against-the-reference" } == true)
        await model.chooseReference(nil)
        #expect(host.picked == nil && model.reading?.readings.contains { $0.rule == "engineer.balance-against-the-reference" } == false)
    }

    @Test("a reading is current while the song and the mix sound the same: the target is not in the audio, a fader is")
    func current() {
        let (song, plan) = TwoSections.song()
        var mixed = plan
        mixed.mix = .unity
        let reading = WholeSongReading.measure(TwoSections.bounce(chorusDB: 0), sampleRate: TwoSections.rate, plan: mixed, label: song.title)
        #expect(reading.isCurrent(for: mixed))
        var target = mixed
        target.mix?.master.targetLUFS = -9
        #expect(reading.isCurrent(for: target))
        #expect(reading.isCurrent(for: mixed.looping(true)), "the loop is the transport's, not the bounce's")
        var louder = mixed
        louder.mix?.master.gainDB = 3
        #expect(!reading.isCurrent(for: louder))
        #expect(reading.sectionIDs == song.sections.map(\.id))
    }
}

// MARK: - The reference in the library, and the Director

@Suite("A reference from the crate or the library, and the Director's whole song", .serialized) @MainActor
struct SectionReferenceTests {

    /// A library with a record in its crate — "Bright", ten seconds of five tones with its
    /// 2–6 kHz tone 6 dB up, two analysed sections with no labels — and another song in it; the
    /// two-section song open.
    static func app(_ label: String) throws -> (app: AppState, directory: URL, record: Record, other: Song) {
        let directory = WiringFixture.temporaryDirectory(label)
        let store = LibraryStore(directoryURL: directory)
        try store.save(Library())
        let rate = TwoSections.rate
        let samples = (0..<Int(10 * rate)).map { i -> Float in
            let t = Double(i) / rate
            return Float(0.05 * (sin(2 * .pi * 60 * t) + sin(2 * .pi * 250 * t) + sin(2 * .pi * 1_000 * t) + 2 * sin(2 * .pi * 3_500 * t) + sin(2 * .pi * 10_000 * t)))
        }
        let file = directory.appendingPathComponent("bright.wav")
        try BoothAdapter.write([samples, samples], sampleRate: rate, to: file)
        let media = try store.addMedia(copying: file, kind: .record)
        let analysis = MusicAnalysis(duration: 10, sections: [SectionRange(start: 0, end: 4), SectionRange(start: 4, end: 10)])
        let record = Record(title: "Bright", artist: "The Test Band", media: media,
                            analysis: PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user, operation: Operation.imported))
        let (other, _) = TwoSections.song()
        var renamed = other
        renamed.title = "Another Song"
        try store.save(Library(songs: [renamed], records: [record]))
        let app = AppState(library: try store.load(), store: store, transportHost: StubTransportHost())
        app.autosaveDelay = nil
        let (song, _) = TwoSections.song()
        app.open(song)
        return (app, directory, record, renamed)
    }

    @Test("the crate's records and the library's other songs are the choices; a pick is kept with the song, never the song itself")
    func picking() throws {
        let (app, directory, record, other) = try Self.app("reference-pick")
        defer { WiringFixture.remove(directory) }
        let choices = app.referenceChoices
        #expect(choices.map(\.title).contains("Bright") && choices.map(\.title).contains("Another Song"))
        #expect(!choices.contains { $0.reference == .song(app.song!.id) }, "a song is not its own reference")
        #expect(choices.first { $0.title == "Bright" }?.detail == "The Test Band")
        #expect(!app.setMixReference(.song(app.song!.id)))
        #expect(app.setMixReference(.record(record.id)))
        #expect(app.song?.mixReference == .record(record.id) && app.mixReference == .record(record.id))
        // Kept with the song, as {"record": id}, and a song with none writes nothing new.
        let data = try JSONEncoder().encode(app.song!)
        #expect(String(decoding: data, as: UTF8.self).contains("\"mixReference\":{\"record\":\"\(record.id)\"}"))
        #expect(try JSONDecoder().decode(Song.self, from: data).mixReference == .record(record.id))
        #expect(!String(decoding: try JSONEncoder().encode(other), as: UTF8.self).contains("mixReference"))
        #expect(app.setMixReference(.song(other.id)) && app.mixReference == .song(other.id))
        #expect(app.setMixReference(nil) && app.song?.mixReference == nil)
    }

    @Test("a record is read from its file by the sections its analysis heard, once; its balance carries its bright 2–6 kHz")
    func record() async throws {
        let (app, directory, record, _) = try Self.app("reference-record")
        defer { WiringFixture.remove(directory) }
        let reading = try await app.measureReference(.record(record.id))
        #expect(reading.name == "Bright" && reading.kind == .record)
        #expect(reading.sheet.sections.map(\.name) == ["Part", "Part 2"], "unlabelled sections are parts, numbered")
        #expect(reading.sheet.sections.map(\.seconds) == [4, 6])
        let bands = reading.sheet.whole.bandsDB
        // Four tones at one level and one at twice it: the loud one is 4/8 of the energy, −3 dB; each
        // of the others 1/8, −9 dB.
        #expect(abs(bands[3] + 3.01) < 0.3 && abs(bands[2] + 9.03) < 0.3, "\(bands)")
        let again = try await app.measureReference(.record(record.id))
        #expect(again == reading && app.referenceReadings.count == 1, "measured once, then kept")
    }

    @Test("another song is bounced whole through its own mix, once, and read by its own form; the song itself is refused")
    func song() async throws {
        let (app, directory, _, other) = try Self.app("reference-song")
        defer { WiringFixture.remove(directory) }
        let reading = try await app.measureReference(.song(other.id))
        #expect(reading.name == "Another Song" && reading.kind == .song)
        #expect(reading.sheet.sections.map(\.name) == ["Verse", "Chorus"])
        #expect(reading.sheet.whole.integratedLUFS != nil && reading.sheet.sections[1].startSeconds == 4)
        let again = try await app.measureReference(.song(other.id))
        #expect(again == reading, "kept: not bounced again")
        await #expect(throws: (any Error).self) { try await app.measureReference(.song(app.song!.id)) }
    }

    @Test("read_mix reads the whole song once, section by section, against a reference it can name; master reads it again after its move")
    func director() async throws {
        let (app, directory, record, _) = try Self.app("reference-director")
        defer { WiringFixture.remove(directory) }
        let workspace = AppStateWorkspace(app)
        let box = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace)

        let read = await box.run(ClaudeToolUse(id: "r", name: "read_mix", input: .object([.init("section", .string("")), .init("reference", .string(""))])))
        #expect(!read.isError, "\(read.content)")
        #expect(read.content.contains("\"whole_song\":{") && read.content.contains("\"bands_hz\":[\"20–120\"") && read.content.contains("\"section\":\"Chorus\""),
                "\(read.content.prefix(800))")
        #expect(read.content.contains("Read whole: whole song"), "\(read.content.suffix(600))")
        let first = try #require(app.wholeSongReading)
        #expect(first.isCurrent(for: app.playback))

        // A reference by name: the record's balance beside the song's, and the Engineer's lines on it.
        let against = await box.run(ClaudeToolUse(id: "b", name: "read_mix", input: .object([.init("section", .string("")), .init("reference", .string("bright"))])))
        #expect(!against.isError, "\(against.content)")
        #expect(app.song?.mixReference == .record(record.id))
        #expect(against.content.contains("\"reference\":{\"bands_db\"") || against.content.contains("\"name\":\"Bright\""), "\(against.content.prefix(1200))")
        #expect(against.content.contains("Bright's balance") || against.content.contains("in Bright"), "\(against.content)")
        // The song was not bounced again for it: the reading kept is the same one.
        #expect(app.wholeSongReading?.sheet == first.sheet)

        let unknown = await box.run(ClaudeToolUse(id: "u", name: "read_mix", input: .object([.init("section", .string("")), .init("reference", .string("Nothing Like It"))])))
        #expect(unknown.isError && unknown.content.contains("neither a record in the crate nor another song") && unknown.content.contains("Another Song"),
                "\(unknown.content)")

        let master = await box.run(ClaudeToolUse(id: "m", name: "master", input: .object([
            .init("target_lufs", .double(-14)), .init("ceiling_dbtp", .double(-1)), .init("gain_db", .double(3)),
            .init("reason", .string("whole_song: under the target")), .init("fade_out_bars", .int(-1))])))
        #expect(!master.isError, "\(master.content)")
        #expect(master.content.contains("\"whole_song\":{") && master.content.contains("Read whole: whole song") && master.content.contains("the target"),
                "\(master.content.suffix(800))")
        #expect(app.wholeSongReading?.isCurrent(for: app.playback) == true, "read again through the new master")
        #expect(app.wholeSongReading?.sheet != first.sheet)
    }
}
