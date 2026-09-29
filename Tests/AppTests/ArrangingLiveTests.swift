import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Whether the band, given a sentence, reaches for what was built for it: develop for a loop that
// should be a song, a second draft for a tune nothing came back in, play_chords for how the chords
// are played, a feel by its name whatever grid it is on.
//
// **Disabled by default**, like every test that costs money:
//
//     MRROBOTO_LIVE=1 [MRROBOTO_LIVE_REPORT=/path/to/report.md] swift test --filter ArrangingLive
//
// Every turn runs against a song made here, in a library made here and thrown away: the real
// library is never opened. The key is found the way the app finds it and is never printed. Like
// `BandLiveTests`, it reports what the band did and asserts only what the tools guarantee — a test
// that failed because the model wrote a different tune would be a test of the weather.

/// What a turn did, tool by tool, with what each one said.
final class ArrangingTurnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, failed: Bool, said: String)] = []
    private var opened: [String] = []

    func finished(_ name: String, failed: Bool, said: String) { lock.lock(); entries.append((name, failed, said)); lock.unlock() }
    func opened(_ kind: SurfaceKind, _ title: String) { lock.lock(); opened.append("\(kind.rawValue): \(title)"); lock.unlock() }

    var calls: [(name: String, failed: Bool, said: String)] { lock.lock(); defer { lock.unlock() }; return entries }
    var surfaces: [String] { lock.lock(); defer { lock.unlock() }; return opened }
    func count(_ name: String) -> Int { calls.filter { $0.name == name }.count }
}

@Suite("Arranging: the live lines", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_LIVE"] == "1",
                "set MRROBOTO_LIVE=1 to run the tests that cost money"))
@MainActor
final class ArrangingLiveTests {

    nonisolated(unsafe) static var lines: [String] = []

    private func report(_ key: String, _ value: String) {
        let line = "\(key.padding(toLength: max(key.count, 22), withPad: " ", startingAt: 0)) \(value)"
        print("[live] \(line)")
        Self.lines.append(line)
        if let path = ProcessInfo.processInfo.environment["MRROBOTO_LIVE_REPORT"] {
            try? Self.lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private struct Rig {
        var app: AppState
        var director: Director
        var directory: URL
    }

    /// A scratch app over a scratch library, with the real client.
    private func rig(_ label: String, song: Song) async throws -> Rig {
        let (app, directory, _) = CompletenessFixture.app("live-\(label)")
        app.open(song)
        let director = Director.live(for: app)
        try #require(await director.keyStatus().hasKey, "no API key in the environment or the keychain")
        return Rig(app: app, director: director, directory: directory)
    }

    @discardableResult
    private func turn(_ sentence: String, _ rig: Rig, label: String) async -> (turn: DirectorTurn, log: ArrangingTurnLog) {
        let log = ArrangingTurnLog()
        let started = Date()
        report("", "")
        report("## \(label)", "“\(sentence)”")
        let turn = await rig.director.direct(sentence) { event in
            switch event {
            case .toolFinished(let name, let isError, let message): log.finished(name, failed: isError, said: message)
            case .opened(let kind, let title): log.opened(kind, title)
            case .toolStarted, .say, .finished: break
            }
        }
        report("ending", "\(turn.ending)")
        report("elapsed", String(format: "%.0f s", Date().timeIntervalSince(started)))
        report("calls", log.calls.map { $0.failed ? "\($0.name)✗" : $0.name }.joined(separator: " → "))
        for call in log.calls where call.failed || ["develop", "write_melody", "play_chords", "write_groove", "set_progression"].contains(call.name) {
            report(call.failed ? "  failed" : "  said", "\(call.name): \(call.said.prefix(420))")
        }
        report("opened", log.surfaces.isEmpty ? "(nothing)" : log.surfaces.joined(separator: " · "))
        report("the Director", turn.say.replacingOccurrences(of: "\n", with: " "))
        report("cost", "\(ClaudeSpend.money(turn.spend.total)) over \(turn.spend.turnCount) requests")
        return (turn, log)
    }

    @Test("a loop that should be a song is developed")
    func makeItASong() async throws {
        let loop = try DevelopFixture.loop(title: "Afterglow")
        let rig = try await rig("develop", song: loop.song)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let (_, log) = await turn("This is just a loop. Make it a whole song.", rig, label: "develop")
        let song = try #require(rig.app.song)
        report("sections", song.sections.map { "\($0.name) \($0.lengthInBars)" }.joined(separator: " · "))
        report("variations", song.partIDs.filter(song.isVariation).compactMap { song.latestVersion(of: $0) }.map(PartLabel.title(of:)).joined(separator: ", "))
        report("developed", "\(Develop.isDeveloped(song))")
        #expect(log.count("develop") >= 1, "it arranged by hand, or not at all: \(log.calls.map(\.name))")
        #expect(Develop.isDeveloped(song))
    }

    @Test("a tune is drafted until a figure comes back in it, and shown")
    func aHook() async throws {
        var loop = try DevelopFixture.loop(title: "Signal")
        var song = Song.new(title: "Signal", key: loop.song.key, tempo: 110)
        try song.append(contentsOf: [loop.drums, loop.bass, loop.chords])
        for index in song.sections.indices { song.sections[index].stitch = [loop.drums, loop.bass, loop.chords].lanes }
        loop.song = song
        let rig = try await rig("tune", song: song)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let (_, log) = await turn("Write me a hook over these chords, on a bell.", rig, label: "a tune")
        let tunes = (rig.app.song?.versions ?? []).filter { $0.type == .melody }
        report("drafts", "\(log.count("write_melody")) written, \(tunes.count) kept")
        for tune in tunes {
            guard case .melody(let melody) = tune.kind, let key = rig.app.song?.key else { continue }
            let observed = MelodyObservation.of(melody, label: "", key: key, progression: nil)
            report("  kept", "\(tune.note ?? "") — \(melody.notes.count) notes, \(Int((observed.motifRatio * 100).rounded()))% comes back")
        }
        let said = rig.app.log.filter { $0.source == .persona("Melodist") && !$0.text.contains(" → ") }.map(\.text)
        report("the Melodist said", said.isEmpty ? "(nothing)" : said.joined(separator: " / "))
        #expect(log.count("write_melody") >= 1)
        #expect(!tunes.isEmpty, "no tune was kept")
    }

    @Test("the chords asked for on the first day: ninths, voice-led")
    func voiceLed() async throws {
        let rig = try await rig("chords", song: Song.new(title: "Still Water", key: Key.cMajor, tempo: 72))
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let (_, log) = await turn("Let's start a meditative loop on Cmaj9, Em7, Fmaj7, Am7, voiced so each note moves by a step or stays where it is.",
                                  rig, label: "chords")
        let song = try #require(rig.app.song)
        if case .progression(let sheet)? = Guidance.progressions(in: song).last?.kind {
            report("chords", "\(sheet.symbols()) — \(sheet.playing?.sentence ?? "held, close")")
            let voiced = Voicing.voicings(of: sheet.chords, as: sheet.playing?.keysVoicing ?? .close)
            report("voiced", voiced.map { $0.map { Pitch(midi: $0).description }.joined(separator: " ") }.joined(separator: " | "))
            #expect(sheet.chords.first?.quality == .majorNinth, "the ninth was written as something else")
        } else {
            Issue.record("no chords were written")
        }
        #expect(!log.calls.contains { $0.name == "set_progression" && $0.failed }, "a chord symbol was refused")
        report("play_chords", "\(log.count("play_chords")) call\(log.count("play_chords") == 1 ? "" : "s")")
    }

    @Test("a waltz, by name, in a song in four")
    func aWaltz() async throws {
        let loop = try DevelopFixture.loop(title: "trynta")
        let rig = try await rig("waltz", song: loop.song)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let before = Guidance.grooves(in: loop.song).count
        let (_, log) = await turn("Give me a new beat for a bridge, a jazz waltz to mix things up.", rig, label: "a waltz")
        let grooves = Guidance.grooves(in: try #require(rig.app.song))
        report("grooves written", "\(grooves.count - before)")
        for version in grooves.suffix(max(0, grooves.count - before)) {
            guard case .groove(let groove) = version.kind else { continue }
            report("  groove", "\(version.note ?? "") — \(groove.stepsPerBar) steps a bar, \(groove.bars) bars, feel \(groove.feel?.name ?? "none")")
        }
        #expect(grooves.count > before, "no beat was written")
        #expect(!log.calls.contains { $0.name == "write_groove" && $0.failed && $0.said.contains("sixteenth grid") })
    }
}
