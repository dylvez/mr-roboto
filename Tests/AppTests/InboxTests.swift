import AVFAudio
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// M5 R11: a file in the inbox becomes an idea, or a take when its name says which song and section.

@Suite("Inbox: what lands becomes an idea or a take", .serialized) @MainActor
struct InboxTests {

    private func wav(seconds: Double, at url: URL) throws {
        let rate = 48_000.0
        let planar = [(0..<Int(seconds * rate)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }]
        try BoothAdapter.write(planar, sampleRate: rate, to: url)
    }

    @Test("a plain file is an idea; a file named for the open song's verse is a take on it, pass by pass")
    func ideasAndTakes() throws {
        let directory = LibraryFixture.directory("inbox")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = directory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4), Section(name: "Hook", stitch: [], lengthInBars: 2)]
        app.open(song)
        app.save()

        var taken: [URL] = []
        let watcher = InboxWatcher(folders: [.init(url: inbox)], interval: .milliseconds(10)) { url in
            taken.append(url)
            if case .failed = app.importFromInbox(url) { return false }
            return true
        }

        // A memo with no name lands as an idea, after two scans at the same size.
        try wav(seconds: 1, at: inbox.appendingPathComponent("voice memo.wav"))
        watcher.scan()
        #expect(taken.isEmpty, "the first scan only notes the size")
        watcher.scan()
        #expect(taken.count == 1)
        #expect(app.library.ideas.count == 1)
        #expect(Guidance.audio(of: app.library.ideas[0])?.duration == 1)
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Done/voice memo.wav").path))
        #expect(store.hasMedia(Guidance.audio(of: app.library.ideas[0])!.media))

        // A capture named for Arrival's hook is a take on the open song, at the hook's bar.
        let name = CaptureName(song: "Arrival", section: "Hook", pass: nil, stamp: "20260919-211205").fileName(extension: "wav")
        try wav(seconds: 2, at: inbox.appendingPathComponent(name))
        watcher.scan(); watcher.scan()
        let takes = Guidance.takes(in: app.song!)
        #expect(takes.count == 1)
        let take = try #require(Guidance.audio(of: takes[0])?.take)
        #expect(take.section == app.song?.sections[1].id && take.startBar == 4 && take.pass == 1 && take.input == "Roboto Capture")
        #expect(Guidance.audio(of: takes[0])?.alignmentOffset == 8, "the hook starts at bar 4 of 120 bpm")
        #expect(PartLabel.title(of: takes[0]) == "Take 1")
        // A second one is pass 2 of the same part.
        try wav(seconds: 2, at: inbox.appendingPathComponent(CaptureName(song: "arrival", section: "hook", stamp: "20260919-211300").fileName(extension: "wav")))
        watcher.scan(); watcher.scan()
        let again = Guidance.takes(in: app.song!)
        #expect(again.count == 2 && again[1].partID == again[0].partID && Guidance.audio(of: again[1])?.take?.pass == 2)
        // A name for a song the library does not hold is an idea that says so.
        try wav(seconds: 1, at: inbox.appendingPathComponent(CaptureName(song: "Nowhere", section: "Verse", stamp: "x").fileName(extension: "wav")))
        watcher.scan(); watcher.scan()
        #expect(app.library.ideas.count == 2 && app.library.ideas[1].note?.contains("does not hold") == true)
        #expect(app.log.contains { $0.text.contains("came in as Take 1") })
    }

    @Test("the capture name round-trips, and a plain name says nothing")
    func names() {
        let name = CaptureName(song: "Soft Machine", section: "Verse 2", pass: 3, stamp: "20260919-090000")
        let file = name.fileName()
        #expect(file == "roboto-capture--Soft_Machine--Verse_2--3--20260919-090000.m4a")
        let back = CaptureName(fileName: file)
        #expect(back.song == "Soft Machine" && back.section == "Verse 2" && back.pass == 3 && back.stamp == "20260919-090000")
        #expect(CaptureName(fileName: "voice memo 12.m4a") == CaptureName())
        #expect(InboxWatcher.isCandidate(URL(fileURLWithPath: "/x/roboto-capture--a--b--1--s.m4a"), prefix: "roboto-capture"))
        #expect(!InboxWatcher.isCandidate(URL(fileURLWithPath: "/x/holiday.m4a"), prefix: "roboto-capture"))
        #expect(!InboxWatcher.isCandidate(URL(fileURLWithPath: "/x/.hidden.wav"), prefix: nil))
        #expect(!InboxWatcher.isCandidate(URL(fileURLWithPath: "/x/notes.txt"), prefix: nil))
    }

    @Test("a song in the library that is not open takes the capture into its package")
    func libraryTake() throws {
        let directory = LibraryFixture.directory("inbox-lib")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        var other = Song(title: "Exit Interview", artist: "Vessel", tempo: 100)
        other.sections = [Section(name: "Verse", stitch: [], lengthInBars: 8)]
        app.open(other)
        app.save()
        app.open(Song(title: "Arrival", artist: "Vessel", tempo: 120))
        app.save()
        let file = directory.appendingPathComponent(CaptureName(song: "Exit Interview", section: "Verse", stamp: "s").fileName(extension: "wav"))
        try wav(seconds: 1, at: file)
        let outcome = app.importFromInbox(file)
        guard case .takeInLibrary(let id, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(id == other.id)
        let saved = try store.songStore(for: other.id).load()
        #expect(Guidance.takes(in: saved).count == 1)
        #expect(app.song?.title == "Arrival", "the open song is still the open song")
    }
}
