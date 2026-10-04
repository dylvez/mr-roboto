import Analysis
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A record between the keys: measured when the crate reads it, and brought to concert pitch when a
// stem or some bars of it are fitted into a song, so it is in tune with the band and with the next
// record. A song that takes a record as it is takes its pitch too.

@Suite("Concert pitch: a record between the keys is measured, and tuned as it is fitted", .serialized) @MainActor
struct ConcertPitchAppTests {

    /// Chords in C a bar each, every note with its partials, the whole `cents` off concert pitch.
    static func chords(cents: Double, seconds: Double = CrateFixture.seconds) -> [[Float]] {
        let chords: [[Int]] = [[48, 60, 64, 67], [53, 60, 65, 69], [55, 62, 67, 71], [48, 60, 64, 72]]
        let rate = CrateFixture.rate
        let frames = Int(seconds * rate), each = frames / chords.count
        var out = [Float](repeating: 0, count: frames)
        for (index, chord) in chords.enumerated() {
            for note in chord {
                let hz = 440 * pow(2, (Double(note) - 69 + cents / 100) / 12)
                for partial in 1...4 {
                    let step = 2 * Double.pi * hz * Double(partial) / rate
                    for frame in 0..<each { out[index * each + frame] += Float(0.1 / Double(partial)) * Float(sin(step * Double(frame))) }
                }
            }
        }
        return [out]
    }

    /// The crate fixture with its one record written again as chords `cents` off pitch.
    static func crate(_ label: String, cents: Double) async throws -> (app: AppState, directory: URL, record: Record) {
        let directory = WiringFixture.temporaryDirectory(label)
        let (app, files, _) = try CrateFixture.app(in: directory, records: 1)
        try BoothAdapter.write(chords(cents: cents), sampleRate: CrateFixture.rate, to: files[0])
        app.importRecords(files, separating: true)
        await app.crate.waitUntilIdle()
        return (app, directory, try #require(app.library.records.first))
    }

    @Test("read 28 cents flat: kept on the record, said in the rail, fitted up 28 cents, the fit keeping them; fitted again the same")
    func flat() async throws {
        let (app, directory, record) = try await Self.crate("pitch-flat", cents: -28)
        defer { WiringFixture.remove(directory) }
        let tuning = try #require(record.tuning)
        #expect(abs(tuning + 28) < 2, "\(tuning)")
        #expect(app.log.contains { $0.text == "Record 1 is read" && ($0.detail ?? "").contains("cents flat of concert pitch") })
        #expect(LibrarySidebar.recordDetail(record).contains("¢ flat"), "its row says so")

        app.open(Song.new(title: "At pitch", key: Key(tonic: NoteName(.e)), tempo: 100))
        app.save()
        let request = SourceRequest(record: record.id, stem: Mashups.full, atBar: 0, takesItsGrid: false)
        let pick = try app.sourcePick(request)
        #expect(abs(pick.plan.move.cents - 28) < 2 && pick.plan.move.semitones == 2)
        #expect(app.sentences(for: pick, request: request).contains { $0.contains("cents to concert pitch") })
        let version = try await app.addSource(request)
        let fit = try #require(Guidance.audio(of: version)?.fit)
        #expect(fit.cents == pick.plan.move.cents && fit.semitones == 2)
        // What the song plays is at pitch: the render reads within a few cents of it.
        let store = try #require(app.store)
        let media = try #require(Guidance.audio(of: version)?.media)
        let rendered = try BoothAdapter.planar(try store.mediaURL(for: media, song: app.song?.id))
        let heard = try #require(Tuning.read(ChopAudio.mono(rendered.planar), sampleRate: rendered.sampleRate))
        #expect(abs(heard.cents) < 5, "\(heard.cents)")

        let again = try await app.refitSource(version.partID, semitones: -1)
        #expect(Guidance.audio(of: again)?.fit?.cents == fit.cents && Guidance.audio(of: again)?.fit?.semitones == -1)
        let clip = try await app.addSource(SourceRequest(record: record.id, stem: Mashups.full, bars: 2..<4, takesItsGrid: false))
        guard case .sample(let sample) = clip.kind else { Issue.record("a clip is a sample"); return }
        #expect(sample.fit?.cents == fit.cents)
    }

    @Test("at pitch: nothing kept on the fit, nothing said; a fit without cents writes what it always wrote")
    func atPitch() async throws {
        let (app, directory, record) = try await Self.crate("pitch-true", cents: 0)
        defer { WiringFixture.remove(directory) }
        #expect(abs(try #require(record.tuning)) < 2)
        #expect(!LibrarySidebar.recordDetail(record).contains("¢"), "a record at pitch says nothing of it")
        app.open(Song.new(title: "At pitch", key: Key(tonic: NoteName(.e)), tempo: 100))
        app.save()
        let request = SourceRequest(record: record.id, stem: Mashups.full, atBar: 0, takesItsGrid: false)
        let pick = try app.sourcePick(request)
        #expect(pick.plan.move.cents == 0 && pick.fit.cents == nil)
        #expect(!app.sentences(for: pick, request: request).contains { $0.contains("concert pitch") })
        let written = String(decoding: try SongGraphCodec.encode(pick.fit), as: UTF8.self)
        #expect(!written.contains("cents"))
        let bare = Record(title: "Never measured", media: record.media)
        #expect(!String(decoding: try SongGraphCodec.encode(bare), as: UTF8.self).contains("tuning"))
    }

    @Test("a blank song takes the record as it is, pitch and all; a record read before tunings were kept is measured as it is first taken from")
    func asItIs() async throws {
        let (app, directory, record) = try await Self.crate("pitch-blank", cents: 30)
        defer { WiringFixture.remove(directory) }
        app.open(Song.new(title: "Untitled"))
        app.save()
        let blank = SourceRequest(record: record.id, stem: Mashups.full, atBar: 0)
        #expect(app.takesGrid(blank))
        let pick = try app.sourcePick(blank)
        #expect(pick.plan.move.isUntouched && pick.fit.cents == nil, "the record is not moved")

        // As a library from before has it: no tuning on the record.
        var older = app.library
        older.records[0].tuning = nil
        #expect(app.writeLibrary(older))
        app.open(Song.new(title: "With a key", key: Key(tonic: NoteName(.c)), tempo: 120))
        app.save()
        let version = try await app.addSource(SourceRequest(record: record.id, stem: Mashups.full, atBar: 0, takesItsGrid: false))
        let measured = try #require(app.library.records.first?.tuning)
        #expect(abs(measured - 30) < 2)
        #expect(abs((Guidance.audio(of: version)?.fit?.cents ?? 0) + 30) < 2)
    }

    @Test("read_library says how far a record sits from pitch; adopt's sentences say what was taken off")
    func band() async throws {
        let (app, directory, record) = try await Self.crate("pitch-band", cents: -28)
        defer { WiringFixture.remove(directory) }
        app.open(Song.new(title: "The band's", key: Key(tonic: NoteName(.d)), tempo: 120))
        // Something of its own in it, so its key and tempo stand and the record is moved onto them.
        #expect(app.record(PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1, velocity: 90)],
                                                                                  sound: "sub", key: Key(tonic: NoteName(.d)), lengthInBars: 1)),
                                       author: .user, operation: Operation.written)))
        app.save()
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        func json(_ result: ClaudeToolResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]) ?? [:]
        }
        let read = json(await toolbox.run(ClaudeToolUse(id: "l", name: "read_library", input: .object([]))))
        let listed = try #require((read["records"] as? [[String: Any]])?.first)
        #expect(abs((listed["tuning_cents"] as? Double ?? 0) + 28) < 2)
        let adopted = await toolbox.run(ClaudeToolUse(id: "a", name: "adopt", input: .object([
            .init("kind", .string("record")), .init("id", .string(record.id.description)), .init("stem", .string("full")),
            .init("bars", .array([])), .init("at_bar", .int(0)), .init("tighten", .string("")),
        ])))
        #expect(!adopted.isError, "\(adopted.content)")
        #expect((json(adopted)["sentences"] as? [String])?.contains { $0.contains("cents to concert pitch") } == true)
    }
}
