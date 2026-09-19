import AppKit
import Foundation
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// Renders the frame offscreen to PNG, for looking at rather than asserting on. Off by default:
//
//     MRROBOTO_RENDER=/path/to/dir swift test --filter FrameRender
//
// It exists because the assistant working on this app cannot screenshot the running window, and a
// layout change nobody has looked at is a layout change nobody has checked.

@Suite("Frame render", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil,
                                "set MRROBOTO_RENDER to a directory to write the renders"))
@MainActor
struct FrameRenderTests {

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] ?? NSTemporaryDirectory())
    }

    private func write<V: View>(_ view: V, size: CGSize, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func app(_ song: Song) -> AppState {
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let dir = GuidanceFixture.temporaryDirectory("render")
        let app = AppState(library: Library(songs: [song]), song: nil, store: LibraryStore(directoryURL: dir),
                           status: .loaded(dir), transportHost: StubTransportHost(),
                           regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        app.open(song)
        return app
    }

    @Test("the frame with a dusty chop on the bench, wide and narrow")
    func dustyChop() throws {
        FontRegistration.registerBundledFonts()
        var built = GuidanceFixture.chopped()
        let dusty = try #require(Dust.version(dirtying: built.sample!, through: [Dust.pass(.sp1200, mix: 0.6)],
                                              by: .persona("Director")))
        try built.song.append(dusty)
        let app = app(built.song)
        app.perform(SurfaceAction(surface: .chopLane, title: "Bar 5 of Arrival", bound: [built.sample!.id]))

        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-1440")
        try write(FrameView(app: app), size: CGSize(width: 1100, height: 800), name: "frame-1100")
        try write(FieldGuideView(), size: CGSize(width: 620, height: 900), name: "field-guide")
    }

    @Test("the app icon, at 1024 and at Dock sizes")
    func icon() throws {
        try write(AppIconArt(), size: CGSize(width: 512, height: 512), name: "app-icon-1024")
        try write(HStack(spacing: 24) {
            ForEach([16.0, 32, 64, 128], id: \.self) { AppIconArt().frame(width: $0, height: $0) }
        }.padding(20).background(Color(white: 0.93)), size: CGSize(width: 340, height: 170), name: "app-icon-sizes")
    }

    @Test("a real Grid and Sound on the bench, with glyphs and bands")
    func realSurfaces() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.grooved()
        let app = app(built.song)
        app.perform(SurfaceAction(surface: .grid, title: "New groove"))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-grid")
        app.perform(SurfaceAction(surface: .sound, title: "Motown, 120", bound: [built.groove!.id]))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-sound")
    }

    @Test("the Piano roll and the Chords surfaces on the bench")
    func m2Surfaces() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.grooved()
        let app = app(built.song)
        app.perform(SurfaceAction(surface: .pianoRoll, title: "Bass under Motown, 120", bound: [built.groove!.id]))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-roll")
        app.perform(SurfaceAction(surface: .chords, title: "Chords"))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-chords")
    }

    @Test("the Structure surface on the bench, with a form kept")
    func structure() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = FormFixture.build()
        let app = app(built.song)
        app.arrange([Section(name: "Intro", stitch: [built.groove], lengthInBars: 4),
                     Section(name: "Verse", stitch: [built.groove, built.bass], lengthInBars: 16),
                     Section(name: "Hook", stitch: [built.groove, built.bass], lengthInBars: 8)])
        app.perform(SurfaceAction(surface: .structure, title: built.song.title))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-structure")
    }

    @Test("the library with an idea, a sample, a record and an album; the Album surface open")
    func library() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = LibraryFixture.directory("render")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory),
                           transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults),
                           primers: PrimerStore(defaults: defaults))
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))
        let (song, groove, chop) = try LibraryFixture.songWithChop("Arrival", record: record, app: app)
        #expect(app.keepAsIdea(groove) != nil)
        #expect(app.saveToSamples(chop) != nil)
        app.arrange([Section(name: "Verse", stitch: [groove, chop], lengthInBars: 16), Section(name: "Hook", stitch: [groove], lengthInBars: 8)])
        app.save()
        let album = try #require(app.createAlbum(title: "Interior Season", artist: "Vessel"))
        #expect(app.addSong(song.id, to: album))
        app.openAlbum(album)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-library")
    }

    @Test("the Merge surface on a chop and a bass line in different keys")
    func merge() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = try MergeFixture.build("render")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        built.app.perform(SurfaceAction(surface: .merge, title: "Horns + Bass line", bound: [built.sample.id, built.bass.id]))
        try write(FrameView(app: built.app), size: CGSize(width: 1440, height: 900), name: "frame-merge")
    }

    @Test("the Cast surface with the Bassist out of the room and one house call")
    func cast() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = FormFixture.build()
        let app = app(built.song)
        app.setCast([.beatmaker, .sampler])
        app.recordHouseCall(question: "beatmaker.oq.snare-direction", choice: .alternative, how: "late, by ear")
        app.openSurface(.cast, title: built.song.title)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-cast")
    }

    @Test("the Lyrics surface on a verse, read against a small house voice")
    func lyrics() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = LibraryFixture.directory("render-lyrics")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let app = AppState(library: Library(voice: [
            VoiceLyric(title: "Fluorescent", text: "Fluorescent window light\nA room that stays the same"),
            VoiceLyric(title: "The Survey", text: "A window and a form\nA room I never left"),
            VoiceLyric(title: "Exit Interview", text: "The window was a door\nThe room was every room"),
        ]), song: nil, store: LibraryStore(directoryURL: directory), status: .empty(directory),
                           transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        var song = FormFixture.build().song
        try song.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: PersonaLyricistTests.verse)), author: .user,
                                    operation: Operation.written, note: "Soft Machine, verse 1"))
        app.open(song)
        app.perform(Guidance.dockAction(for: .lyrics, in: app.song))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-lyrics")
    }

    @Test("first launch: nothing open")
    func firstLaunch() throws {
        FontRegistration.registerBundledFonts()
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let app = AppState(library: Library(), transportHost: StubTransportHost(),
                           regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-empty")
    }

    @Test("a fresh import: the path says separate the stems")
    func freshImport() throws {
        FontRegistration.registerBundledFonts()
        let app = app(GuidanceFixture.imported().song)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-import")
    }
}

extension FrameRenderTests {
    @Test("a disagreement between two personas, as a Compare with what settles it at the top")
    func disagreementCompare() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = FormFixture.build()
        let app = app(built.song)
        let engineer = PersonaReading(rule: "engineer.delivery-loudness", feature: .integratedLUFS, value: -22.3, holds: false,
                                      says: "-22.3 LUFS, peak -5.7 dBFS. 8 LU under −14; the platforms turn it up, at the cost of the noise floor.")
        let producer = PersonaReading(rule: "producer.fewer-parts", feature: .partsPerSong, value: 2, holds: true,
                                      says: "2 parts. Room to add, and nothing to subtract yet.")
        let card = DisagreementCard(about: "whether loudness is a decision or a delivery spec",
                                    settledBy: "the Engineer reads every bounce; the Producer decides at the last one",
                                    subject: "Verse, as it is",
                                    a: .init(persona: .engineer, name: "Engineer", says: engineer.says, readings: [CompareReading(.integratedLUFS, -22.3, unit: "LUFS")]),
                                    b: .init(persona: .producer, name: "Producer", says: producer.says, readings: [CompareReading(.partsPerSong, 2, unit: "parts")]),
                                    reference: built.groove, vocabulary: Engineer.bible)
        let workspace = AppStateWorkspace(app)
        #expect(workspace.openDisagreement(card) == card.title)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-compare-disagreement")
    }
}

extension FrameRenderTests {
    @Test("the Booth on a verse, and the Takes surface with two takes and a comp chosen")
    func boothAndTakes() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        var song = FormFixture.build(tempo: 120).song
        let ids = [Guidance.grooves(in: song).last!.id, Guidance.basslines(in: song).last!.id]
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 4), Section(name: "Hook", stitch: ids, lengthInBars: 2)]
        let part = PartID()
        for pass in 1...2 {
            let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: pass == 1 ? "d" : "e", count: 64))!, fileExtension: "wav"),
                              role: .take, sampleRate: 48_000, channelCount: 1, duration: 8, alignmentOffset: 0,
                              take: Take(section: song.sections[0].id, startBar: 0, input: "MacBook Pro Microphone", latencyCompensation: 0.012, pass: pass))
            try song.append(PartVersion(partID: part, kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take \(pass), Verse"))
        }
        let app = app(song)
        // A third take with real audio in the package, so the Takes surface carries the band's flags.
        app.save()
        if let store = app.store, let package = try? store.songStore(for: song.id) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sung-\(UUID().uuidString).wav")
            try BoothAdapter.write(SungTake.planar(), sampleRate: SungTake.rate, to: scratch)
            let media = try package.addMedia(copying: scratch)
            let audio = Audio(media: media, role: .take, sampleRate: SungTake.rate, channelCount: 1, duration: 2.2, alignmentOffset: SungTake.alignment,
                              take: Take(section: song.sections[0].id, startBar: 1, input: "MacBook Pro Microphone", latencyCompensation: 0.012, pass: 3))
            #expect(app.record(PartVersion(partID: part, kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 3, Verse")))
        }
        app.perform(Guidance.dockAction(for: .booth, in: app.song))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-booth")
        let id = try #require(app.perform(Guidance.dockAction(for: .takes, in: app.song)))
        let model = SurfaceWiring.shared.takesModel(for: app.bench.items.first { $0.id == id }!, app: app)
        model.choose(model.takes[0].id, forBars: 0..<2)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-takes")
    }
}
