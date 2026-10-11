import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

/// ⇧⌘P: what the palette offers, how typing narrows it, and that a command does what it says.
@Suite("Command palette")
@MainActor
struct CommandPaletteTests {

    /// On a defaults suite of its own: folding a region writes to defaults, and the test runner's
    /// standard ones are shared by every suite.
    private func app() -> (AppState, Song) {
        let open = FrameFixture.playableSong(title: "Arrival")
        let other = FrameFixture.song(title: "Night Bus")
        let defaults = UserDefaults(suiteName: "mrroboto.palette.\(UUID().uuidString)")!
        let app = AppState(library: Library(songs: [open, other]), song: open, transportHost: StubTransportHost(),
                           regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults),
                           defaults: defaults)
        return (app, open)
    }

    @Test("Every surface in the dock is offered with the key that opens it")
    func surfacesAndTheirKeys() {
        let (app, _) = app()
        let commands = CommandPalette.commands(for: app)
        for kind in Guidance.dockSurfaces(for: app.song) {
            let command = commands.first { $0.id == "surface.\(kind.rawValue)" }
            #expect(command != nil, "\(kind.rawValue) is missing from the palette")
            #expect(command?.shortcut == Guidance.dockShortcut(for: kind))
        }
    }

    @Test("The band's question comes first, and its first answer is on ⌘]")
    func theQuestionFirst() {
        let (app, _) = app()
        let commands = CommandPalette.commands(for: app)
        let asked = app.nextQuestion
        guard let first = asked.options.first else { return }
        #expect(commands.first?.title == first.title)
        #expect(commands.first?.shortcut == "⌘]")
        #expect(commands.contains { $0.id == "asked.ask" })
    }

    @Test("Typing narrows the list, best first: the start of a title, then a word, then its letters in order")
    func typingNarrows() {
        let (app, _) = app()
        let commands = CommandPalette.commands(for: app)
        #expect(CommandPalette.matching(commands, query: "grid").first?.title == "Grid")
        #expect(CommandPalette.matching(commands, query: "lane").first?.title == "Chop lane")
        #expect(CommandPalette.matching(commands, query: "chln").first?.title == "Chop lane")
        // A keyword finds what its title does not say.
        #expect(CommandPalette.matching(commands, query: "metronome").contains { $0.id == "song.click" })
        #expect(CommandPalette.matching(commands, query: "zzzz").isEmpty)
        // Nothing typed is everything, in the palette's own order.
        #expect(CommandPalette.matching(commands, query: "").map(\.id) == commands.map(\.id))
    }

    @Test("Songs in the library are offered to open, except the one already open")
    func songsToOpen() {
        let (app, open) = app()
        let songs = CommandPalette.commands(for: app).filter { $0.shelf == .songs }
        #expect(songs.map(\.title) == ["Night Bus"])
        #expect(!songs.contains { $0.title == open.title })
    }

    @Test("A command does what it says: Loop loops, Show Library shows it")
    func commandsRun() {
        let (app, _) = app()
        let wasLooping = app.isLooping
        CommandPalette.commands(for: app).first { $0.id == "song.loop" }?.run()
        #expect(app.isLooping != wasLooping)

        let folded = app.regions.isCollapsed(.library)
        CommandPalette.commands(for: app).first { $0.id == "view.region.library" }?.run()
        #expect(app.regions.isCollapsed(.library) != folded)
    }
}
