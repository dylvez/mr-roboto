import Instrument
import AppKit
import Foundation
import MusicTheory
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

    /// Writes a view in the dark appearance: the app's appearance is what the theme's colours
    /// resolve against, so it is set for the draw and put back after.
    private func writeDark<V: View>(_ view: V, size: CGSize, name: String) throws {
        let before = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApplication.shared.appearance = before }
        try write(view.environment(\.colorScheme, .dark), size: size, name: name)
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

    @Test("every region open at the window's minimum: the dock falls back to glyphs and nothing paints over the rail")
    func everyRegionOpenAtTheMinimum() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.separated()
        let app = app(built.song)
        app.regions.setCollapsed(false, for: .rail)
        let width = FrameLayout.minimumWindowWidth(collapsed: [])
        try write(FrameView(app: app), size: CGSize(width: width, height: FrameLayout.minimumWindowHeight), name: "frame-minimum-all-open")
    }

    @Test("an eight-section form: the section strip fits the bar at 1440 and at the window's minimum")
    func longForm() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        var song = FormFixture.build(tempo: 92).song
        let lanes = [Guidance.grooves(in: song).last!].lanes
        song.sections = ["Intro", "Verse", "Pre-chorus", "Chorus", "Verse", "Pre-chorus", "Chorus", "Bridge", "Chorus", "Outro"]
            .map { Section(name: $0, stitch: lanes, lengthInBars: $0 == "Intro" || $0 == "Outro" ? 4 : 8) }
        let app = app(song)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-long-form")
        try write(FrameView(app: app), size: CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed),
                                                    height: FrameLayout.minimumWindowHeight), name: "frame-long-form-minimum")
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

    @Test("the Chop lane on a real bar: slices, pads, the feel and Make the groove")
    func chopLaneLoaded() throws {
        FontRegistration.registerBundledFonts()
        // The lane holds its host weakly: keep the stub alive, or Play has nothing to play through.
        // The pad grid is lazy, which `ImageRenderer` does not draw; the space it takes is blank here.
        let (lane, host) = ChopLaneFixtures.cleanLane()
        try withExtendedLifetime(host) {
            lane.feelName = "Boom-Bap Pocket"
            lane.playRegroove()
            try write(ChopLaneView(surface: lane).background(Design.Palette.panel), size: CGSize(width: 1240, height: 820),
                      name: "chop-lane")
            try write(ChopLaneView(surface: lane).background(Design.Palette.panel), size: CGSize(width: 900, height: 820),
                      name: "chop-lane-900")
        }
    }

    @Test("a groove made from a chop in the Grid: its kit is the chop's slices, wide and narrow")
    func gridOnAChop() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.chopped()
        let sample = try #require(built.sample)
        let app = app(built.song)
        let groove = sample.spawning(.groove(TransportFixture.groove()), by: .user, operation: Operation.regroove,
                                     note: "Boom-Bap Pocket at 92 bpm")
        #expect(app.record(groove))
        app.playGroove(groove.partID, onChop: sample.partID)
        app.perform(SurfaceAction(surface: .grid, title: "Boom-Bap Pocket at 92 bpm", bound: [groove.id]))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-grid-chop")
        try write(FrameView(app: app), size: CGSize(width: 1100, height: 800), name: "frame-grid-chop-1100")
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
        // The shape a real song reaches: arranged early, then parts written after it. The chords
        // belong to no section, which is what the form-level line exists to say.
        app.arrange([Section(name: "Intro", stitch: [built.groove].lanes, lengthInBars: 4),
                     Section(name: "Verse", stitch: [built.groove, built.bass].lanes, lengthInBars: 16),
                     Section(name: "Hook", stitch: [built.groove, built.bass].lanes, lengthInBars: 8)])
        // Words labelled for the Verse and the Hook, none for the Intro: the first section shows the
        // way to label one, the Verse its stanza.
        #expect(app.record(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "[Verse]\nI put the coffee on at six\nI watched it make itself\nit made itself a morning\n\n[Hook]\nsoft machine")),
                                       author: .user, operation: Operation.written, note: "Lyric")))
        let id = try #require(app.perform(SurfaceAction(surface: .structure, title: built.song.title)))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-structure")
        let model = SurfaceWiring.shared.structureModel(for: app.bench.items.first { $0.id == id }!, app: app)
        model.select(model.sections[1].id)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-structure-verse")
    }

    @Test("a developed song on the Structure surface: the variations as chips, the intensity along each block, at 1440 and at the minimum")
    func developed() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let loop = try DevelopFixture.loop(genre: "breakbeat")
        let app = app(loop.song)
        // Before: the loop in a new song's form, with Develop offered.
        let id = try #require(app.perform(SurfaceAction(surface: .structure, title: loop.song.title)))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-develop-before")
        try write(FrameView(app: app), size: CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed),
                                                    height: FrameLayout.minimumWindowHeight), name: "frame-develop-before-narrow")
        let development = try #require(app.develop())
        #expect(development.sections.count == 9)
        let model = SurfaceWiring.shared.structureModel(for: app.bench.items.first { $0.id == id }!, app: app)
        #expect(model.sections == development.sections)
        #expect(model.canPutBackDevelopment)
        model.select(model.sections.first { $0.name == "Breakdown" }?.id)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-develop")
        try write(FrameView(app: app), size: CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed), height: FrameLayout.minimumWindowHeight), name: "frame-develop-narrow")
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
        app.arrange([Section(name: "Verse", stitch: song.lanes([groove, chop]), lengthInBars: 16),
                     Section(name: "Hook", stitch: song.lanes([groove]), lengthInBars: 8)])
        app.save()
        let album = try #require(app.createAlbum(title: "Interior Season", artist: "Vessel"))
        #expect(app.addSong(song.id, to: album))
        app.openAlbum(album)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-library")
    }

    @Test("the Library surface: songs with the open one chosen, records with one chosen, wide and at the minimum, light and dark")
    func librarySurface() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let shelf = LibraryIndexFixture.shelf()
        let app = AppState(library: shelf.library, song: shelf.nightBus, transportHost: StubTransportHost())
        // What the surface remembers goes to the app's defaults: put back what this changed.
        defer { for key in ["shelf"] + LibraryShelf.allCases.map(\.rawValue) { UserDefaults.standard.removeObject(forKey: LibraryBrowserMemory.prefix + key) } }
        // The strip on the left is folded, as a first launch has it; nothing here unfolds it.
        app.showSurface(.library)
        let wide = CGSize(width: 1440, height: 900)
        let minimum = CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed), height: FrameLayout.minimumWindowHeight)
        try write(FrameView(app: app), size: wide, name: "frame-library-songs")
        // A render runs no update cycle, so the surface's model takes what was asked of it here.
        let item = try #require(app.bench.active)
        let model = SurfaceWiring.shared.libraryModel(for: item, app: app)
        app.showInLibrary(.record(shelf.drifter.id))
        model.takeAsk()
        try write(FrameView(app: app), size: wide, name: "frame-library-records")
        try writeDark(FrameView(app: app), size: wide, name: "frame-library-records-dark")
        app.showInLibrary(.song(shelf.river.id))
        model.takeAsk()
        try write(FrameView(app: app), size: minimum, name: "frame-library-minimum")
        try writeDark(FrameView(app: app), size: minimum, name: "frame-library-minimum-dark")
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
        try write(FrameView(app: app), size: CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed),
                                                    height: FrameLayout.minimumWindowHeight), name: "frame-lyrics-minimum")
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
                                    reference: built.song.latestVersion(of: built.groove)?.id,
                                    vocabulary: Engineer.bible)
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
        let ids = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
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

extension FrameRenderTests {
    @Test("the Mixer with strips and the overlay read, and the Master with a bounce read")
    func mixerAndMaster() async throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        var song = FormFixture.build(tempo: 92).song
        let ids = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 2)]
        let app = app(song)
        let mixerID = try #require(app.perform(Guidance.dockAction(for: .mixer, in: app.song)))
        let mixer = SurfaceWiring.shared.mixerModel(for: app.bench.items.first { $0.id == mixerID }!, app: app)
        if let bass = mixer.rows.first(where: { $0.label.contains("line") }) {
            mixer.setGain(-3, for: bass.part)
            mixer.setEQ(band: 1, gainDB: -6, for: bass.part)
            mixer.setEQ(band: 1, frequency: 80, for: bass.part)
            mixer.endGesture()
        }
        await mixer.readOverlay()
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-mixer")
        // At the window's narrowest the EQ moves under each strip rather than off the side.
        try write(FrameView(app: app), size: CGSize(width: 1100, height: 900), name: "frame-mixer-narrow")
        // A section picked for the level faders: the bass's own level in the Verse, with its Reset.
        mixer.levelSection = song.sections.first?.id
        if let bass = mixer.rows.first(where: { $0.label.contains("line") }) {
            mixer.setLevel(-12, for: bass.part)
            mixer.endGesture()
        }
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-mixer-section")
        mixer.levelSection = nil
        let masterID = try #require(app.perform(Guidance.dockAction(for: .master, in: app.song)))
        let master = SurfaceWiring.shared.masterModel(for: app.bench.items.first { $0.id == masterID }!, app: app)
        await master.read()
        #expect(master.reading != nil, "\(master.lastError ?? "")")
        // The Master is the Mixer's tab; the frame's hook that turns it is the app's, not this test's.
        if let item = app.bench.items.first(where: { $0.id == masterID }) {
            let mixer = SurfaceWiring.shared.mixerModel(for: item, app: app)
            mixer.tab = .master
            // As the tab does when it is first drawn: one working mix under both.
            master.follow(mixer)
        }
        master.setFadeOut(bars: 4)
        #expect(master.mix.master.fadeOutBars == 4)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-master")
    }
}

extension FrameRenderTests {
    @Test("the Album surface with three tracks, the readings, the palette and a drawn cover")
    func albumGrown() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = LibraryFixture.directory("render-album")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost(),
                           regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        var ids: [SongID] = []
        for (title, key, tempo) in [("Arrival", Key(tonic: NoteName(.d)), 92.0), ("Exit Interview", Key(tonic: NoteName(.b), mode: .aeolian), 96.0), ("Fluorescent", Key(tonic: NoteName(.g)), 140.0)] {
            var song = FormFixture.build(tempo: tempo).song
            song.title = title
            song.key = key
            let stitch = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
            song.sections = [Section(name: "Verse", stitch: stitch, lengthInBars: 16), Section(name: "Hook", stitch: stitch, lengthInBars: 8)]
            app.open(song)
            app.save()
            ids.append(song.id)
        }
        let album = try #require(app.createAlbum(title: "Soft Machine", artist: "Vessel"))
        for id in ids { app.addSong(id, to: album) }
        app.setCover(CoverDesign(layout: .band, paper: "#eef0f3", ink: "#0043ce"), for: album)
        app.recordReleases([ids[0]: TrackRelease(mixVersion: nil, integratedLUFS: -14.1, truePeakDBTP: -1.2, durationSeconds: 62, trimDB: 2)], for: album)
        _ = app.openAlbum(album)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-album")
        try write(FrameView(app: app), size: CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed),
                                                    height: FrameLayout.minimumWindowHeight), name: "frame-album-minimum")
    }
}

extension FrameRenderTests {
    @Test("the Mashup surface on two analysed songs, the plan written out")
    func mashup() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = WiringFixture.temporaryDirectory("render-mashup")
        defer { WiringFixture.remove(directory) }
        let (app, a, b) = try MashupFixture.app(in: directory)
        app.open(a)
        let id = app.openSurface(.mashup, title: "Mashup")
        let model = SurfaceWiring.shared.mashupModel(for: app.bench.items.first { $0.id == id }!, app: app)
        model.b = b.id
        model.barShift = 4
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-mashup")
    }
}

extension FrameRenderTests {
    @Test("the Sources surface on a mashup: a third record's vocal planned, a clip already in the song")
    func sources() async throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let (app, directory, a, b) = try await SourcesFixture.mashup("render-sources")
        defer { WiringFixture.remove(directory) }
        _ = try await app.addSource(SourceRequest(song: a.id, stem: "bass", bars: 1..<3))
        let id = app.openSurface(.sources, title: "Sources")
        let model = SurfaceWiring.shared.sourcesModel(for: app.bench.items.first { $0.id == id }!, app: app)
        model.from = .song(b.id)
        model.atBar = 2
        #expect(model.stem == "vocals" && model.blocker == nil && !model.sentences.isEmpty)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-sources")
    }

    @Test("Parts with a bass line set aside: under its own heading, with why, and Bring back")
    func aside() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = WiringFixture.temporaryDirectory("render-aside")
        defer { WiringFixture.remove(directory) }
        var built = FormFixture.build()
        built.song.sections = [Section(name: "Verse", stitch: [Lane(part: built.groove), Lane(part: built.bass)], lengthInBars: 4)]
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory), status: .empty(directory),
                           transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        app.open(built.song)
        app.regions.setCollapsed(false, for: .ledger)
        app.regions.setCollapsed(true, for: .rail)
        #expect(app.setAside(built.bass, note: "too busy under the vocal"))
        app.openSurface(.structure, title: built.song.title)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-aside")
    }

    @Test("Sources with nothing to take from: the record picture, where records come from, and Import Records")
    func sourcesEmpty() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let root = WiringFixture.temporaryDirectory("render-sources-empty")
        defer { WiringFixture.remove(root) }
        let store = LibraryStore(directoryURL: root)
        let app = AppState(library: Library(), store: store, status: .empty(root), transportHost: StubTransportHost())
        app.open(Song.new(title: "From nothing", tempo: 96))
        let id = app.openSurface(.sources, title: "Sources")
        let model = SurfaceWiring.shared.sourcesModel(for: app.bench.items.first { $0.id == id }!, app: app)
        #expect(model.origins.isEmpty && model.unheard?.hasPrefix("No record in the crate") == true)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-sources-empty")
    }

    @Test("the crate in the sidebar: one record separating, one read and opened on its stems; the header says how far")
    func crate() async throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let root = WiringFixture.temporaryDirectory("render-crate")
        defer { WiringFixture.remove(root) }
        let (app, files, stub) = try CrateFixture.app(in: root, records: 2)
        app.importRecords([files[0]], separating: true)
        await app.crate.waitUntilIdle()
        var host = stub
        host.separationHold = .seconds(30)
        app.crate.host = host
        app.importRecords([files[1]], separating: true)
        while app.crate.running?.kind != .separate { await Task.yield() }
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(app.library.records.enumerated()), id: \.offset) { index, record in
                RecordRowView(record: record, app: app, startsOpen: index == 0)
            }
        }
        .padding(Design.Metric.inset)
        .background(Design.Palette.panelAlt)
        #expect(app.crate.status(of: app.library.records[1].id) == "separating…")
        #expect(app.crate.line == "Separating Record 2")
        try write(rows, size: CGSize(width: FrameLayout.librarySidebarWidth, height: 260), name: "sidebar-crate")
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-crate")
        app.crate.cancel(app.library.records[1].id)
        await app.crate.waitUntilIdle()
    }
}

extension FrameRenderTests {
    @Test("the Piano roll in melody mode: the instrument picker, and the Melodist reading the tune")
    func melodyMode() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let song = FormFixture.build(tempo: 92).song
        let app = app(song)
        let id = try #require(app.perform(Guidance.dockAction(for: .pianoRoll, in: app.song)))
        let item = try #require(app.bench.items.first { $0.id == id })
        let model = SurfaceWiring.shared.pianoRollModel(for: item, app: app)
        model.setMode(.melody)
        model.setInstrument(InstrumentVoiceSpec.rhodes.id)
        // The roll opened on the song's bass line; a tune starts from an empty grid.
        while !model.notes.isEmpty { model.deleteNote(at: 0) }
        // A tune worth reading: mostly steps, a figure that comes back, and it breathes.
        for (pitch, beat) in [(72, 0.0), (74, 1), (76, 2), (74, 3), (76, 4), (77, 5), (79, 6), (76, 7)] {
            model.addNote(pitch: pitch, at: beat, duration: 0.5)
        }
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-melody")
    }
}

extension FrameRenderTests {
    @Test("the Chords surface voiced on an imported instrument: the Imported family and its line")
    func importedInstrument() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.grooved()
        let app = app(built.song)
        let spec = InstrumentVoiceSpec(
            id: "sfz-render-upright", name: "Salamander Upright", family: ImportedInstruments.family, engine: .sampled,
            summary: "Sampled, from Salamander Upright.sfz: 480 zones from 480 recordings, A0–C8.",
            sampledKit: "/nonexistent")
        ImportedInstruments.register(spec)
        defer { ImportedInstruments.unregister(id: spec.id) }
        app.importedInstruments = [spec]
        #expect(app.setInstrument(spec.id))
        app.perform(SurfaceAction(surface: .chords, title: "Chords"))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-chords-imported")
    }
}

extension FrameRenderTests {
    @Test("the Chords surface with a playing chosen: both rows of chips, the top line and a caution, at 1440 and at the minimum")
    func chordsPlayed() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        var built = GuidanceFixture.grooved()
        var sheet = try Progression.parse("Cmaj9 | Em7 | Fmaj7 | Am9 | Dm9 G13 | Cmaj9 | C6/9 | E7#9 Am11", key: Key.cMajor).get()
        sheet.playing = ChordPlaying(.stabs, .led, seed: 11)
        let chords = PartVersion(partID: PartID(), kind: .progression(sheet), author: .user,
                                 operation: Operation.written, note: "Eight bars")
        try built.song.append(chords)
        let app = app(built.song)
        // A pad, so the caution is on the sheet: stabs on something that swells.
        if let pad = InstrumentVoiceSpec.available.first(where: { $0.family == "pad" }) { app.setInstrument(pad.id) }
        app.perform(SurfaceAction(surface: .chords, title: "Eight bars", bound: [chords.id]))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-chords-played")
        try write(FrameView(app: app), size: CGSize(width: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed),
                                                    height: FrameLayout.minimumWindowHeight), name: "frame-chords-played-minimum")
        let all = FrameLayout.minimumWindowWidth(collapsed: [])
        for region in FrameRegion.allCases where app.regions.collapsed.contains(region) { app.regions.toggle(region) }
        try write(FrameView(app: app), size: CGSize(width: all, height: FrameLayout.minimumWindowHeight), name: "frame-chords-played-all-open")
    }
}
