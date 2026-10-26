import SongGraph
import SwiftUI

/// One thing the palette can do: what it is called, which shelf of the palette it sits on, the key
/// that does it without the palette, and the doing.
///
/// The key is shown on every row, the way Raycast shows an action's shortcut beside it: the palette
/// is also how the shortcuts are learned.
struct PaletteCommand: Identifiable {
    enum Shelf: Int, CaseIterable, Sendable {
        case asked, surfaces, song, songs, view

        var title: String {
            switch self {
            case .asked: return "The band asks"
            case .surfaces: return "Surfaces"
            case .song: return "This song"
            case .songs: return "Songs"
            case .view: return "View"
            }
        }
    }

    let id: String
    let title: String
    let shelf: Shelf
    /// A surface's own drawn glyph, when it has one; otherwise the SF Symbol.
    var glyph: String? = nil
    let symbol: String
    var shortcut: String = ""
    var detail: String = ""
    /// Other words it answers to: "metronome" finds Click.
    var keywords: String = ""
    var isEnabled: Bool = true
    let run: @MainActor () -> Void
}

/// ⇧⌘P: every surface, the band's question, what can be done to the song, every song in the
/// library and how the window looks, in one list that narrows as you type.
enum CommandPalette {

    /// What the palette offers right now, shelf by shelf.
    @MainActor
    static func commands(for app: AppState) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []

        // The band's question first: it is what is being asked of you.
        let asked = app.nextQuestion
        for (index, option) in asked.options.enumerated() {
            commands.append(PaletteCommand(id: "asked.\(option.id)", title: option.title, shelf: .asked,
                                           symbol: "bubble.left", shortcut: index == 0 ? "⌘]" : "",
                                           detail: option.rationale, keywords: asked.question,
                                           run: { app.take(option, from: asked) }))
        }
        commands.append(PaletteCommand(id: "asked.ask", title: "Ask the band…", shelf: .asked,
                                       symbol: "bubble.left.and.text.bubble.right",
                                       detail: "Say what you want in your own words",
                                       keywords: "director talk chat",
                                       run: { app.askTheBand() }))

        for kind in Guidance.dockSurfaces(for: app.song) {
            commands.append(PaletteCommand(id: "surface.\(kind.rawValue)", title: kind.rawValue, shelf: .surfaces,
                                           glyph: kind.glyph.name, symbol: kind.glyph.symbol,
                                           shortcut: Guidance.dockShortcut(for: kind),
                                           detail: Primer.summary(for: kind),
                                           run: { app.showSurface(kind) }))
        }
        if let song = app.song {
            commands.append(PaletteCommand(id: "surface.cast", title: SurfaceKind.cast.rawValue, shelf: .surfaces,
                                           glyph: SurfaceKind.cast.glyph.name, symbol: SurfaceKind.cast.glyph.symbol,
                                           shortcut: "⌘8", detail: Primer.summary(for: .cast),
                                           run: { app.openSurface(.cast, title: song.title) }))
        }

        let hasSong = app.song != nil
        commands += [
            PaletteCommand(id: "song.play", title: app.transport.isPlaying ? "Stop" : "Play", shelf: .song,
                           symbol: app.transport.isPlaying ? "pause.fill" : "play.fill", shortcut: "Space",
                           keywords: "transport start pause", isEnabled: hasSong,
                           run: { Task { await SurfaceWiring.shared.player(for: app).spaceBar() } }),
            PaletteCommand(id: "song.loop", title: app.isLooping ? "Loop off" : "Loop", shelf: .song,
                           symbol: "repeat", shortcut: "⌘L", keywords: "cycle repeat",
                           run: { app.toggleLoop() }),
            PaletteCommand(id: "song.click", title: app.isClicking ? "Click off" : "Click", shelf: .song,
                           symbol: "metronome", shortcut: "⌘K", keywords: "metronome count",
                           run: { app.toggleClick() }),
            PaletteCommand(id: "song.save", title: "Save", shelf: .song, symbol: "square.and.arrow.down",
                           shortcut: "⌘S", isEnabled: hasSong && app.store != nil,
                           run: { app.save() }),
            PaletteCommand(id: "song.settings", title: "Song Settings…", shelf: .song, symbol: "slider.horizontal.3",
                           shortcut: "⇧⌘,", detail: "Title, tempo, key, meter and the brief",
                           keywords: "rename tempo key meter bpm", isEnabled: hasSong,
                           run: { app.wantsSongSettings = true }),
            PaletteCommand(id: "song.develop", title: app.song?.isIdea == true ? "Develop into a Song" : "Develop the Song",
                           shelf: .song, symbol: "wand.and.stars", shortcut: "⇧⌘D",
                           detail: app.song?.isIdea == true ? "A song made of the idea, its loop arranged into sections; the idea stays as it was"
                                                            : "The loop arranged into sections, each played its own way",
                           keywords: "arrange form structure",
                           isEnabled: app.canDevelop && !app.isDeveloping && !app.isMastering,
                           run: { Task { await app.developAndMaster() } }),
            PaletteCommand(id: "song.new", title: "New Song", shelf: .song, symbol: "plus",
                           shortcut: "⌘N", keywords: "start blank",
                           run: {
                               app.open(Song.new(title: MrRobotoApp.untitledName()))
                               app.wantsSongSettings = true
                           }),
            PaletteCommand(id: "song.new-idea", title: "New Idea", shelf: .song, symbol: "lightbulb",
                           shortcut: "⌥⌘N", detail: "A few bars at a tempo and key of their own, with no song around them",
                           keywords: "sketch part loop idea start",
                           run: { app.newIdea() }),
            PaletteCommand(id: "song.import", title: "Import Records…", shelf: .song, symbol: "square.and.arrow.down.on.square",
                           shortcut: "⌘I", keywords: "crate audio file record", isEnabled: app.store != nil,
                           run: { MrRobotoApp.importRecords(app) }),
            PaletteCommand(id: "song.close", title: "Close Song", shelf: .song, symbol: "xmark",
                           shortcut: "⇧⌘W", isEnabled: hasSong,
                           run: { app.closeSong() }),
        ]

        for song in app.library.songs where song.id != app.song?.id {
            let facts = [song.key?.name, "\(Int(song.tempo.rounded())) bpm"].compactMap { $0 }.joined(separator: " · ")
            commands.append(PaletteCommand(id: "songs.\(song.id.rawValue.uuidString)", title: song.title, shelf: .songs,
                                           symbol: "music.note", detail: facts, keywords: "open song \(song.artist)",
                                           run: { app.openSong(song.id) }))
        }
        // Ideas sit with the songs, said as ideas: what you open, by name.
        for idea in app.library.ideaSongs where idea.id != app.song?.id {
            let facts = ["Idea", idea.key?.name, "\(Int(idea.tempo.rounded())) bpm"].compactMap { $0 }.joined(separator: " · ")
            commands.append(PaletteCommand(id: "songs.\(idea.id.rawValue.uuidString)", title: idea.title, shelf: .songs,
                                           symbol: "lightbulb", detail: facts, keywords: "open idea",
                                           run: { app.openSong(idea.id) }))
        }

        for scheme in Design.Scheme.allCases {
            commands.append(PaletteCommand(id: "view.palette.\(scheme.rawValue)", title: "\(scheme.displayName) Palette",
                                           shelf: .view,
                                           symbol: Design.scheme == scheme ? "checkmark" : "paintpalette",
                                           shortcut: "⌃⌘\(scheme.shortcut)", detail: scheme.summary,
                                           keywords: "palette theme colour color appearance dark light mode mid vibrant",
                                           run: { Design.select(scheme) }))
        }
        for region in FrameRegion.allCases {
            let folded = app.regions.isCollapsed(region)
            commands.append(PaletteCommand(id: "view.region.\(region.rawValue)",
                                           title: "\(folded ? "Show" : "Hide") \(region.title)", shelf: .view,
                                           symbol: "sidebar.squares.left", shortcut: "⌥⌘\(region.shortcut)",
                                           keywords: "column panel fold",
                                           run: { app.regions.setCollapsed(!folded, for: region) }))
        }
        commands.append(PaletteCommand(id: "view.primers", title: "Show Every Primer Again", shelf: .view,
                                       symbol: "questionmark.circle", keywords: "help explain",
                                       run: { app.primers.resetAll() }))
        return commands
    }

    /// How well `command` answers `query`, or nil when it does not: the title starting with it
    /// beats a word in the title starting with it, beats the title containing it, beats its letters
    /// in order ("chln" for Chop lane), beats a keyword or the detail containing it.
    static func score(_ command: PaletteCommand, query: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return 0 }
        let title = command.title.lowercased()
        if title.hasPrefix(query) { return 100 }
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(query) }) { return 80 }
        if title.contains(query) { return 60 }
        if isSubsequence(query, of: title) { return 40 }
        let more = (command.keywords + " " + command.detail).lowercased()
        if more.contains(query) { return 20 }
        return nil
    }

    /// The commands that answer `query`, best first; on a tie, in the palette's own order.
    static func matching(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        commands.enumerated()
            .compactMap { index, command in score(command, query: query).map { (command, $0, index) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(haystack)
        for character in needle where character != " " {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}

/// The palette itself: a field, the commands that answer it, and the keys that drive it — ↑ and ↓
/// to choose, Return to do it, Escape to put it away.
struct CommandPaletteView: View {
    let app: AppState
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let results = CommandPalette.matching(CommandPalette.commands(for: app), query: query)
        let chosen = min(selection, max(0, results.count - 1))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Design.Palette.inkTertiary)
                field(results: results, chosen: chosen)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Hairline()
            ScrollViewReader { proxy in
                ScrollsUnlessRendered {
                    VStack(alignment: .leading, spacing: 0) {
                        if results.isEmpty {
                            Text("Nothing answers “\(query)”.")
                                .font(Design.Typography.role(.callout))
                                .foregroundStyle(Design.Palette.inkTertiary)
                                .padding(16)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            if query.isEmpty, index == 0 || results[index - 1].shelf != command.shelf {
                                SmallLabel(command.shelf.title, color: Design.Palette.inkTertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, index == 0 ? 10 : 14)
                                    .padding(.bottom, 4)
                            }
                            PaletteRow(command: command, isChosen: index == chosen)
                                .id(command.id)
                                .onTapGesture { run(command) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 380)
                .onChange(of: chosen) { _, index in
                    guard results.indices.contains(index) else { return }
                    proxy.scrollTo(results[index].id)
                }
            }
            Hairline()
            HStack(spacing: 16) {
                hint("↑↓", "choose")
                hint("⏎", "do it")
                hint("esc", "close")
                Spacer()
                hint("⇧⌘P", "this palette")
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .frame(width: 580)
        .background(Design.Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Design.Palette.line, lineWidth: Design.Metric.hairline))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onChange(of: query) { selection = 0 }
    }

    @ViewBuilder
    private func field(results: [PaletteCommand], chosen: Int) -> some View {
        if Design.isOffscreenRender {
            Text(query.isEmpty ? "Go to a surface or a song, or do something…" : query)
                .font(.system(size: 15))
                .foregroundStyle(query.isEmpty ? Design.Palette.inkQuiet : Design.Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Go to a surface or a song, or do something…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onSubmit { if results.indices.contains(chosen) { run(results[chosen]) } }
                .onKeyPress(.downArrow) {
                    selection = min(chosen + 1, max(0, results.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(chosen - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
        }
    }

    private func hint(_ key: String, _ does: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Palette.inkSecondary)
            Text(does).font(.system(size: 10)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    private func run(_ command: PaletteCommand) {
        guard command.isEnabled else { return }
        dismiss()
        command.run()
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let isChosen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let glyph = command.glyph {
                    Glyph(name: glyph, symbol: command.symbol, size: 14)
                } else {
                    Image(systemName: command.symbol).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(isChosen ? Design.Palette.ink : Design.Palette.inkSecondary)
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 13, weight: isChosen ? .medium : .regular))
                    .foregroundStyle(command.isEnabled ? Design.Palette.ink : Design.Palette.inkQuiet)
                    .lineLimit(1)
                if !command.detail.isEmpty {
                    Text(command.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isChosen ? Design.Palette.selected : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .opacity(command.isEnabled ? 1 : 0.6)
    }
}

/// A scroll view in the app; in an offscreen render, which draws no scroll view's content, the
/// content itself, clipped to the same height.
private struct ScrollsUnlessRendered<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if Design.isOffscreenRender {
            content.frame(maxHeight: 380, alignment: .top).clipped()
        } else {
            ScrollView { content }
        }
    }
}
