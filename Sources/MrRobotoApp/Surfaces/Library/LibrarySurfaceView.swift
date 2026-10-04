import MusicTheory
import SongGraph
import SwiftUI

/// The library, whole. The shelves on the left, the shelf's list in the middle — searched,
/// narrowed and sorted by any column — and the chosen item on the right: what it is, what it is
/// made from or used in, and what can be done to it. Narrower than `wide`, the shelves go across
/// the top; narrower than `medium`, the chosen item sits under the list as well.
struct LibrarySurfaceView: View {
    @Bindable var model: LibraryBrowserModel
    /// An action that asks first, or asks for a name, from a button or a row's menu.
    @State private var pending: LibraryAction?
    @FocusState private var listHasFocus: Bool

    /// From this width the surface has three columns: shelves, list, the chosen item.
    static let wide: CGFloat = 1100
    /// From this width the list and the chosen item sit side by side, the shelves across the top.
    static let medium: CGFloat = 760
    static let shelvesWidth: CGFloat = 156
    static let detailWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= Self.wide {
                HStack(spacing: 0) {
                    shelves.frame(width: Self.shelvesWidth)
                    Hairline(axis: .vertical)
                    list(width: geometry.size.width - Self.shelvesWidth - Self.detailWidth - 2)
                    Hairline(axis: .vertical)
                    detail.frame(width: Self.detailWidth)
                }
            } else if geometry.size.width >= Self.medium {
                VStack(spacing: 0) {
                    shelfRow
                    Hairline()
                    HStack(spacing: 0) {
                        list(width: geometry.size.width - Self.detailWidth - 1)
                        Hairline(axis: .vertical)
                        detail.frame(width: Self.detailWidth)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    shelfRow
                    Hairline()
                    list(width: geometry.size.width)
                    // Under the list, as much as the list can spare: none at all when that is too
                    // little to read, and the rows keep the room.
                    let room = Self.detailHeight(surfaceHeight: geometry.size.height)
                    if model.selected != nil, room > 0 {
                        Hairline()
                        detail.frame(height: room)
                    }
                }
            }
        }
        .background(Design.Palette.panel)
        .modifier(LibraryActionPrompt(pending: $pending))
        // An item asked for while the surface is showing, and one asked for while it was not.
        .onChange(of: model.app.libraryAsk) { model.takeAsk() }
        .onAppear { model.takeAsk() }
    }

    /// The chosen item's height under the list, in the narrow layout: half of what the shelves,
    /// the search and the column titles leave, up to 320, and nothing below 90.
    static func detailHeight(surfaceHeight: CGFloat) -> CGFloat {
        let spare = (surfaceHeight - 170) / 2
        return spare < 90 ? 0 : min(320, spare)
    }

    // MARK: Shelves

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 2) {
            SmallLabel("Shelves")
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            ForEach(LibraryShelf.allCases, id: \.self) { shelf in
                shelfButton(shelf)
            }
            Spacer(minLength: 12)
            ForEach(model.shelfActions) { action in
                FrameButton(title: action.buttonTitle, emphasis: .quiet, isEnabled: action.isEnabled) {
                    LibraryActions.perform(action) { pending = $0 }
                }
                .help(action.help)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Design.Palette.panelAlt)
    }

    private func shelfButton(_ shelf: LibraryShelf) -> some View {
        let isOn = model.shelf == shelf
        return Button { model.choose(shelf) } label: {
            HStack(spacing: 7) {
                Glyph(name: LibrarySidebar.glyphs[shelf.title] ?? "song", symbol: "circle", size: 13)
                Text(shelf.title)
                    .font(Design.Typography.ui(13, weight: isOn ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(model.count(on: shelf))")
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkTertiary)
            }
            .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isOn ? Design.Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shelf.title), \(model.count(on: shelf))")
    }

    /// The shelves across the top, when the surface is narrow.
    private var shelfRow: some View {
        HStack(spacing: 6) {
            ForEach(LibraryShelf.allCases, id: \.self) { shelf in
                BoothChip("\(shelf.title) \(model.count(on: shelf))", isOn: model.shelf == shelf) { model.choose(shelf) }
            }
            Spacer(minLength: 8)
            ForEach(model.shelfActions) { action in
                BoothChip(action.title) { LibraryActions.perform(action) { pending = $0 } }
                    .disabled(!action.isEnabled)
                    .help(action.help)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Design.Palette.panelAlt)
    }

    // MARK: The list

    private func list(width: CGFloat) -> some View {
        let rows = model.rows
        let columns = Self.columns(for: model.shelf, width: width, fitting: model.index.fitTarget != nil)
        return VStack(spacing: 0) {
            toolbar(shown: rows.count)
            Hairline()
            if model.count(on: model.shelf) == 0 {
                emptyShelf
                Spacer(minLength: 0)
            } else if rows.isEmpty {
                nothingMatches
                Spacer(minLength: 0)
            } else {
                headerRow(columns)
                Hairline()
                rowList(rows, columns: columns)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toolbar(shown: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                searchField
                Text(shown == model.count(on: model.shelf) ? "\(shown)" : "\(shown) of \(model.count(on: model.shelf))")
                    .font(Design.Typography.numeric(11.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !model.filters.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(model.filters, id: \.self) { filter in filterChip(filter) }
                    if model.query.narrows {
                        BoothChip("Clear") { model.clearFilters() }
                            .help("Take away the words and every filter; the order stays")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var searchField: some View {
        let prompt = "Search \(model.shelf.title.lowercased()): every word, anywhere"
        if Design.isOffscreenRender {
            RenderedField(text: model.text, placeholder: prompt)
        } else {
            TextField(prompt, text: $model.text)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.ui(12.5))
        }
    }

    private func headerRow(_ columns: [LibraryColumn]) -> some View {
        HStack(spacing: Self.columnSpacing) {
            Color.clear.frame(width: Self.playWidth, height: 1)
            ForEach(columns, id: \.self) { column in
                Button { model.sort(by: column) } label: {
                    HStack(spacing: 3) {
                        if column.isNumeric { Spacer(minLength: 0) }
                        Text(column.title(on: model.shelf).uppercased())
                            .font(Design.Typography.label)
                            .tracking(0.8)
                            .lineLimit(1)
                        if let sort = model.query.sort, sort.column == column {
                            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        if !column.isNumeric { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(model.query.sort?.column == column ? Design.Palette.accent : Design.Palette.inkTertiary)
                    .frame(width: Self.width(of: column), alignment: column.isNumeric ? .trailing : .leading)
                    .frame(maxWidth: Self.width(of: column) == nil ? .infinity : nil, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.title(on: model.shelf).lowercased()): up, down, then the library's order")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func rowList(_ rows: [LibraryFacts], columns: [LibraryColumn]) -> some View {
        let open = model.app.song.map { model.index.records(in: $0.id) } ?? []
        return ScrollViewReader { reader in
            LibraryScroll {
                rowStack(rows, columns: columns, openRecords: Set(open))
            }
            .focusable(!Design.isOffscreenRender)
            .focused($listHasFocus)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, reader); return .handled }
            .onKeyPress(.downArrow) { move(1, reader); return .handled }
            .onKeyPress(.return) {
                if let id = model.selection, let action = model.primary(for: id) { LibraryActions.perform(action) { pending = $0 } }
                return .handled
            }
        }
    }

    @ViewBuilder
    private func rowStack(_ rows: [LibraryFacts], columns: [LibraryColumn], openRecords: Set<RecordID>) -> some View {
        // Lazy in the app, for a long shelf; whole in a render, which does not draw a lazy stack.
        if Design.isOffscreenRender {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { pair in row(pair.element, at: pair.offset, columns: columns, openRecords: openRecords) }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { pair in row(pair.element, at: pair.offset, columns: columns, openRecords: openRecords) }
            }
        }
    }

    private func move(_ step: Int, _ reader: ScrollViewProxy) {
        model.moveSelection(by: step)
        if let id = model.selection { reader.scrollTo(id, anchor: nil) }
    }

    private func row(_ facts: LibraryFacts, at index: Int, columns: [LibraryColumn], openRecords: Set<RecordID>) -> some View {
        let isChosen = model.selection == facts.id
        return HStack(spacing: Self.columnSpacing) {
            playCell(facts)
            ForEach(columns, id: \.self) { column in
                if column == .title {
                    titleCell(facts, isChosen: isChosen, openRecords: openRecords)
                } else if column == .fit {
                    fitCell(facts)
                } else {
                    let text = column.text(facts)
                    Text(text.isEmpty ? "–" : text)
                        .font(column.isNumeric || column == .changed ? Design.Typography.numeric(11.5) : Design.Typography.ui(12, weight: .regular))
                        .foregroundStyle(text.isEmpty ? Design.Palette.line
                                         : (column == .genre && facts.genreIsGuessed) ? Design.Palette.inkTertiary : Design.Palette.inkSecondary)
                        .lineLimit(1)
                        .frame(width: Self.width(of: column), alignment: column.isNumeric ? .trailing : .leading)
                        .help(column == .genre && facts.genreIsGuessed ? "Guessed from a groove's feel; nobody has said" : "")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isChosen ? Design.Palette.accentSoft : index.isMultiple(of: 2) ? Color.clear : Design.Palette.panelAlt.opacity(0.55))
        .contentShape(Rectangle())
        .id(facts.id)
        .gesture(TapGesture(count: 2).onEnded {
            model.select(facts.id)
            if let action = model.primary(for: facts.id) { LibraryActions.perform(action) { pending = $0 } }
        })
        .simultaneousGesture(TapGesture().onEnded {
            model.select(facts.id)
            listHasFocus = true
        })
        .draggable(Self.payload(for: facts))
        .contextMenu {
            LibraryActionMenuItems(actions: model.actions(for: facts.id)) { pending = $0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// How it goes with the open song: as it is in the ink, moved in grey, far in the warning colour.
    private func fitCell(_ facts: LibraryFacts) -> some View {
        let fit = facts.fit
        let text = LibraryColumn.fit.text(facts)
        let colour: Color = switch fit?.verdict {
        case .asIs?, .near?: Design.Palette.ink
        case .moves?: Design.Palette.inkSecondary
        case .far?, .refused?: Design.Palette.warn
        case .unknown?, nil: Design.Palette.line
        }
        return HStack(spacing: 4) {
            if fit?.verdict == .asIs || fit?.verdict == .near {
                Circle().fill(Design.Palette.accent).frame(width: 5, height: 5)
            }
            Text(text.isEmpty ? "–" : text)
                .font(Design.Typography.numeric(11.5))
                .foregroundStyle(colour)
                .lineLimit(1)
        }
        .frame(width: Self.width(of: .fit), alignment: .leading)
        .help(fit.map { ($0.sentences + $0.flags).joined(separator: " ") } ?? "")
    }

    /// Hear it without choosing it: play, or stop when it is what is sounding.
    @ViewBuilder
    private func playCell(_ facts: LibraryFacts) -> some View {
        if model.preview.canHear(facts.id) {
            let sounding = model.preview.isSounding(facts.id)
            Button { Task { await model.preview.toggle(facts.id) } } label: {
                Image(systemName: sounding ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(sounding ? Design.Palette.accent : Design.Palette.inkTertiary)
                    .frame(width: Self.playWidth, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sounding ? "Stop" : facts.id.shelf == .songs ? "Hear \(facts.title): a preview, made the first time" : "Hear \(facts.title)")
            .accessibilityLabel(sounding ? "Stop \(facts.title)" : "Play \(facts.title)")
        } else {
            Color.clear.frame(width: Self.playWidth, height: 1)
        }
    }

    private func titleCell(_ facts: LibraryFacts, isChosen: Bool, openRecords: Set<RecordID>) -> some View {
        HStack(spacing: 6) {
            Text(facts.title)
                .font(Design.Typography.ui(13, weight: isChosen ? .semibold : .regular))
                .foregroundStyle(isChosen ? Design.Palette.accent : Design.Palette.ink)
                .lineLimit(1)
            if facts.id.shelf == .songs, model.app.song?.id.rawValue == facts.id.id {
                Text("open")
                    .font(Design.Typography.ui(10, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
                    .help("The song open in the frame")
            } else if facts.id.shelf == .records, openRecords.contains(RecordID(rawValue: facts.id.id)) {
                Circle().fill(Design.Palette.accent).frame(width: 5, height: 5)
                    .help("The open song takes from it")
            }
            if facts.id.shelf == .records, let status = model.app.crate.status(of: RecordID(rawValue: facts.id.id)) {
                Text(status)
                    .font(Design.Typography.ui(10.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: Self.titleMinimum, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Filters

    @ViewBuilder
    private func filterChip(_ filter: LibraryBrowserModel.Filter) -> some View {
        let query = model.query
        switch filter {
        case .goesWith:
            BoothChip("Goes with \(model.index.fitTarget?.title ?? "this song")", isOn: query.goesWith == true) { model.toggleGoesWith() }
                .help("Only what comes into the open song moved no further than a sample bears — four semitones — nearest first")
        case .key:
            menuChip(query.key.map(Self.keyLabel) ?? "Key", isOn: query.key != nil) { keyMenu }
        case .tempo:
            menuChip(query.tempo.map(Self.tempoLabel) ?? "Tempo", isOn: query.tempo != nil) { tempoMenu }
        case .genre:
            menuChip(query.genre.flatMap { id in model.genresOnShelf.first { $0.id == id }?.name } ?? "Genre", isOn: query.genre != nil) {
                Button("Any genre") { model.setGenre(nil) }
                ForEach(model.genresOnShelf, id: \.id) { genre in Button(genre.name) { model.setGenre(genre.id) } }
            }
        case .stems:
            BoothChip(query.hasStems.map { $0 ? "With stems" : "No stems" } ?? "Stems", isOn: query.hasStems != nil) { model.cycleStems() }
                .help("Any, separated into stems, or not yet")
        case .usage:
            BoothChip(Self.usageLabel(query.usage, shelf: model.shelf), isOn: query.usage != nil) { model.cycleUsage() }
                .help(model.shelf == .songs ? "Any, on an album, or on none" : "Any, taken by a song, or by none")
        case .offPitch:
            BoothChip("Off pitch", isOn: query.offPitch == true) { model.toggleOffPitch() }
                .help("Records read far enough from concert pitch that fitting one moves it")
        }
    }

    /// A chip that opens a menu; in a render, the chip alone, as a menu draws as a block there.
    @ViewBuilder
    private func menuChip<Content: View>(_ title: String, isOn: Bool, @ViewBuilder content: () -> Content) -> some View {
        if Design.isOffscreenRender {
            BoothChip(title, isOn: isOn) {}
        } else {
            Menu { content() } label: {
                Text(title)
                    .font(Design.Typography.ui(11.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: Design.Metric.chipHeight)
            .background(isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
    }

    @ViewBuilder
    private var keyMenu: some View {
        Button("Any key") { model.setKey(nil) }
        if let key = model.songKey {
            Button("The open song's: \(key.name)") { model.setKey(.init(key, within: model.query.key?.within ?? 0)) }
        }
        Section("On this shelf") {
            ForEach(model.keysOnShelf, id: \.self) { key in
                Button(key.name) { model.setKey(.init(key, within: model.query.key?.within ?? 0)) }
            }
        }
        if model.query.key != nil {
            Picker("Within", selection: Binding(get: { model.query.key?.within ?? 0 }, set: { model.setWithin($0) })) {
                Text("The key or its relative").tag(0)
                ForEach(1...6, id: \.self) { n in Text("\(n) semitone\(n == 1 ? "" : "s") away").tag(n) }
            }
        }
    }

    @ViewBuilder
    private var tempoMenu: some View {
        Button("Any tempo") { model.setTempo(nil) }
        if let bpm = model.songTempo {
            Button("Near the open song's \(LibraryText.tempo(bpm)) bpm") { model.setTempo(.around(bpm)) }
        }
        Section("Ranges") {
            ForEach(Self.tempoRanges, id: \.title) { range in
                Button(range.title) { model.setTempo(.init(range.low, range.high, halfAndDouble: false)) }
            }
        }
        if model.query.tempo != nil {
            Toggle("Count half and double time", isOn: Binding(get: { model.query.tempo?.halfAndDouble ?? false },
                                                               set: { model.setHalfAndDouble($0) }))
        }
    }

    static let tempoRanges: [(title: String, low: Double, high: Double)] = [
        ("Under 80", 1, 79.99), ("80 to 100", 80, 99.99), ("100 to 120", 100, 119.99), ("120 to 140", 120, 139.99), ("140 and over", 140, 400),
    ]

    static func keyLabel(_ filter: LibraryQuery.KeyFilter) -> String {
        filter.within == 0 ? "\(filter.key.name) or relative" : "Within \(filter.within) of \(filter.key.name)"
    }

    static func tempoLabel(_ filter: LibraryQuery.TempoFilter) -> String {
        let range = filter.high >= 400 ? "\(LibraryText.tempo(filter.low))+ bpm"
            : filter.low <= 1 ? "under \(LibraryText.tempo(filter.high.rounded())) bpm"
            : "\(LibraryText.tempo(filter.low.rounded()))–\(LibraryText.tempo(filter.high.rounded())) bpm"
        return filter.halfAndDouble ? "\(range), ½ or 2×" : range
    }

    static func usageLabel(_ usage: LibraryQuery.Usage?, shelf: LibraryShelf) -> String {
        switch (usage, shelf) {
        case (nil, .songs): "Albums"
        case (.used?, .songs): "On an album"
        case (.unused?, .songs): "On no album"
        case (nil, _): "Used"
        case (.used?, _): "In a song"
        case (.unused?, _): "In no song"
        }
    }

    // MARK: Empty

    private var emptyShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmptyNote(title: Self.emptyTitle(model.shelf), detail: Self.emptyDetail(model.shelf))
            ForEach(model.shelfActions) { action in
                FrameButton(title: action.buttonTitle, isEnabled: action.isEnabled) { LibraryActions.perform(action) { pending = $0 } }
                    .help(action.help)
            }
        }
        .padding(Design.Metric.inset)
    }

    private var nothingMatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmptyNote(title: "Nothing on this shelf matches.",
                      detail: "Every word typed has to be found somewhere in what an item says about itself, and every filter has to hold.")
            FrameButton(title: "Clear the search and filters", emphasis: .quiet) { model.clearFilters() }
        }
        .padding(Design.Metric.inset)
    }

    static func emptyTitle(_ shelf: LibraryShelf) -> String {
        switch shelf {
        case .songs: "No songs yet."
        case .records: "No records in the crate yet."
        case .ideas: "No ideas yet."
        case .samples: "No samples yet."
        case .albums: "No albums yet."
        }
    }

    static func emptyDetail(_ shelf: LibraryShelf) -> String {
        switch shelf {
        case .songs: "File ▸ New Song starts one from nothing; a record's Start a Song from It starts one from the crate."
        case .records: "File ▸ Import Records… brings records in; each is read for its bars and key, and separated, in the background."
        case .ideas: "Audio dropped into the Mr. Roboto Inbox folder arrives here, and a part kept as an idea from a song's ledger."
        case .samples: "A chop saved from the Chop lane arrives here, ready to adopt into any song."
        case .albums: "An album is songs in order, delivered together. Make one and add songs to it."
        }
    }

    // MARK: The chosen item

    @ViewBuilder
    private var detail: some View {
        if let facts = model.selected {
            LibraryScroll {
                LibraryDetail(facts: facts, model: model, pending: $pending)
                    .padding(Design.Metric.inset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Design.Palette.panel)
        } else {
            VStack(alignment: .leading) {
                EmptyNote(title: "Nothing chosen.",
                          detail: "Choose something on the shelf to read it here: what it is, what it is made from or used in, and what can be done with it. Double-click to open it.")
                Spacer(minLength: 0)
            }
            .padding(Design.Metric.inset)
        }
    }

    // MARK: Columns

    static let columnSpacing: CGFloat = 10
    static let titleMinimum: CGFloat = 170
    /// The play button at the head of each row.
    static let playWidth: CGFloat = 16

    /// A column's width; nil for the title, which takes what is left.
    static func width(of column: LibraryColumn) -> CGFloat? {
        switch column {
        case .title: nil
        case .artist: 140
        case .key: 96
        case .tempo: 64
        case .bars: 44
        case .length: 52
        case .genre: 116
        case .changed: 76
        case .loudness: 50
        case .stems: 46
        case .tuning: 54
        case .songs: 58
        case .records: 88
        case .kind: 90
        case .note: 170
        case .root: 46
        case .slices: 48
        case .source: 150
        case .fit: 104
        }
    }

    /// The shelf's columns that fit, in order, the title always.
    static func columns(for shelf: LibraryShelf, width: CGFloat, fitting: Bool = false) -> [LibraryColumn] {
        var room = width - 24 - titleMinimum - playWidth - columnSpacing
        var shown: [LibraryColumn] = [.title]
        for column in LibraryColumn.columns(for: shelf, fitting: fitting) where column != .title {
            let needs = (Self.width(of: column) ?? 0) + columnSpacing
            guard needs <= room else { break }
            room -= needs
            shown.append(column)
        }
        return shown
    }

    static func payload(for facts: LibraryFacts) -> LibraryDragPayload {
        let kind: LibraryDragPayload.Kind = switch facts.id.shelf {
        case .songs: .song
        case .records: .record
        case .ideas: .idea
        case .samples: .sample
        case .albums: .album
        }
        return LibraryDragPayload(kind: kind, id: facts.id.id, title: facts.title)
    }
}

/// A scroll view in the app; in a render, which does not draw what a scroll view holds, the
/// content itself, clipped where the scroll view would end.
private struct LibraryScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if Design.isOffscreenRender {
            content
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { content }
        }
    }
}

// MARK: - The chosen item

/// What is said about the chosen item: its facts, what can be done to it, and what it is made from
/// or used in, each a link to the other item.
private struct LibraryDetail: View {
    let facts: LibraryFacts
    let model: LibraryBrowserModel
    @Binding var pending: LibraryAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Glyph(name: LibrarySidebar.glyphs[facts.id.shelf.title] ?? "song", symbol: "circle", size: 12)
                    SmallLabel(Self.kind(facts))
                }
                .foregroundStyle(Design.Palette.inkTertiary)
                Text(facts.title)
                    .font(Design.Typography.prose(19, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !facts.artist.isEmpty {
                    Text(facts.artist).font(Design.Typography.ui(12.5)).foregroundStyle(Design.Palette.inkSecondary)
                }
                if let brief = facts.brief {
                    Text(brief)
                        .font(Design.Typography.prose(14))
                        .italic()
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            actions
            if let fit = facts.fit, let target = model.index.fitTarget {
                withSong(fit, target)
            }
            if model.preview.canHear(facts.id) {
                LibraryListen(facts: facts, model: model)
            }
            factsGrid
            relations
        }
        // The record chosen is the one whose bars and stems are drawn.
        .task(id: facts.id) {
            // Settled on, not passed over with the arrows: a record's file is read and a song's
            // preview made only for what stays chosen a moment.
            if !Design.isOffscreenRender {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            // A song chosen is likely to be heard next: its preview starts being made.
            if facts.id.shelf == .songs { model.preview.prepare(song: SongID(rawValue: facts.id.id)) }
            await model.preview.show(record: facts.id.shelf == .records ? RecordID(rawValue: facts.id.id) : nil)
        }
    }

    static func kind(_ facts: LibraryFacts) -> String {
        switch facts.id.shelf {
        case .songs: "Song"
        case .records: "Record"
        case .ideas: facts.kind.map { "Idea · \(LibraryText.kind($0))" } ?? "Idea"
        case .samples: "Sample"
        case .albums: "Album"
        }
    }

    // MARK: Actions

    private var actions: some View {
        let all = model.actions(for: facts.id)
        return FlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(Array(all.enumerated()), id: \.element.id) { index, action in
                button(action, leads: index == 0 && action.isEnabled)
            }
        }
    }

    @ViewBuilder
    private func button(_ action: LibraryAction, leads: Bool) -> some View {
        switch action.kind {
        case .menu(let choices):
            if Design.isOffscreenRender {
                ActionChip(title: action.title + " ▾", isEnabled: action.isEnabled) {}
            } else {
                Menu {
                    ForEach(choices) { choice in
                        Button(choice.title) { LibraryActions.perform(choice) { pending = $0 } }.disabled(!choice.isEnabled)
                    }
                } label: {
                    Text(action.title).font(Design.Typography.ui(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: Design.Metric.chipHeight)
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
                .disabled(!action.isEnabled)
                .help(action.help)
            }
        default:
            ActionChip(title: action.buttonTitle, leads: leads, isDestructive: action.isDestructive, isEnabled: action.isEnabled) {
                LibraryActions.perform(action) { pending = $0 }
            }
            .help(action.help)
        }
    }

    // MARK: With the open song

    /// What bringing it into the open song would do, as Sources says it.
    private func withSong(_ fit: LibraryFit, _ target: FitTarget) -> some View {
        section("With \(target.title)") {
            if fit.verdict == .unknown {
                Text("Nothing to go on: no key and no tempo read.").font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkTertiary)
            } else {
                ForEach(fit.sentences, id: \.self) { sentence in
                    Text(sentence).font(Design.Typography.ui(12, weight: .regular)).foregroundStyle(Design.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(fit.flags, id: \.self) { flag in
                    Text(flag).font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Facts

    private var factsGrid: some View {
        let rows = Self.factRows(facts)
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label.uppercased())
                        .font(Design.Typography.label)
                        .tracking(0.8)
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .font(Design.Typography.numeric(12))
                        .foregroundStyle(Design.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func factRows(_ facts: LibraryFacts) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let key = facts.key { rows.append(("Key", key.name)) }
        if let tempo = facts.tempo { rows.append(("Tempo", "\(LibraryText.tempo(tempo)) bpm")) }
        if let bars = facts.bars, bars > 0 { rows.append(("Bars", "\(bars)")) }
        if let seconds = facts.seconds { rows.append(("Length", LibraryText.duration(seconds))) }
        if let genre = facts.genre { rows.append(("Genre", facts.genreIsGuessed ? "\(genre), guessed" : genre)) }
        if let loudness = facts.loudness { rows.append(("Loudness", String(format: "%.1f LUFS", loudness))) }
        if let tuning = facts.tuning { rows.append(("Tuning", LibraryText.cents(tuning, words: true))) }
        if let grid = facts.grid { rows.append(("Grid", grid)) }
        if let root = facts.root { rows.append(("Root", "\(root)")) }
        if let slices = facts.slices, slices > 0 { rows.append(("Slices", "\(slices)")) }
        if facts.id.shelf == .samples, let note = facts.note { rows.append(("Dust", note)) }
        if !facts.tags.isEmpty { rows.append(("Tags", facts.tags.joined(separator: ", "))) }
        rows.append((facts.id.shelf == .records ? "Imported" : facts.id.shelf == .songs ? "Worked on" : "Made",
                     facts.changed.formatted(date: .abbreviated, time: .shortened)))
        return rows
    }

    // MARK: Relations

    @ViewBuilder
    private var relations: some View {
        switch facts.id.shelf {
        case .songs: songRelations(SongID(rawValue: facts.id.id))
        case .records: recordRelations(RecordID(rawValue: facts.id.id))
        case .ideas, .samples: takenRelations
        case .albums: albumRelations(AlbumID(rawValue: facts.id.id))
        }
    }

    @ViewBuilder
    private func songRelations(_ id: SongID) -> some View {
        if let song = model.song(id), !song.sections.isEmpty {
            section("Form") { FormStrip(sections: song.sections) }
        }
        let made = model.madeFrom(id)
        if !made.isEmpty {
            section("Made from") {
                ForEach(made, id: \.record.id) { taken in
                    VStack(alignment: .leading, spacing: 2) {
                        link(taken.record.title, glyph: "record", to: .record(taken.record.id))
                        Text(Self.takes(taken.uses))
                            .font(Design.Typography.ui(11, weight: .regular))
                            .foregroundStyle(Design.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        let albums = model.index.albums(holding: id)
        if !albums.isEmpty {
            section("On albums") {
                ForEach(albums, id: \.self) { album in
                    link(model.index.facts(.album(album))?.title ?? "An album", glyph: "album", to: .album(album))
                }
            }
        }
    }

    @ViewBuilder
    private func recordRelations(_ id: RecordID) -> some View {
        if let record = model.app.library.record(id), let stems = record.stems, !stems.isEmpty {
            section("Stems") {
                ForEach(stems.sorted { RecordStems.order($0.name) < RecordStems.order($1.name) }, id: \.name) { stem in
                    StemRow(stem: stem, record: record)
                }
            }
        }
        let used = model.usedIn(id)
        section("Used in") {
            if used.isEmpty {
                Text("No song takes from it yet.").font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkTertiary)
            }
            ForEach(used, id: \.song) { taken in
                VStack(alignment: .leading, spacing: 2) {
                    link(model.songTitle(taken.song), glyph: "song", to: .song(taken.song))
                    Text(Self.takes(taken.uses))
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        let chops = model.index.chops(of: id)
        if !chops.isEmpty {
            section("Samples cut from it") {
                ForEach(chops, id: \.self) { chop in
                    link(model.index.facts(.sample(chop))?.title ?? "A sample", glyph: "chop", to: .sample(chop))
                }
            }
        }
    }

    @ViewBuilder
    private var takenRelations: some View {
        if let record = model.index.source(of: facts.id) {
            section("Cut from") {
                link(model.index.facts(.record(record))?.title ?? "A record", glyph: "record", to: .record(record))
            }
        }
        let songs = model.index.songs(holding: facts.id)
        section("In songs") {
            if songs.isEmpty {
                Text("No song holds it yet.").font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkTertiary)
            }
            ForEach(songs, id: \.self) { song in link(model.songTitle(song), glyph: "song", to: .song(song)) }
        }
    }

    @ViewBuilder
    private func albumRelations(_ id: AlbumID) -> some View {
        let tracks = model.app.library.album(id)?.songs ?? []
        section("Songs") {
            if tracks.isEmpty {
                Text("No songs on it yet: open it to add some.").font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkTertiary)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { number, song in
                HStack(spacing: 6) {
                    Text("\(number + 1)").font(Design.Typography.numeric(11)).foregroundStyle(Design.Palette.inkTertiary).frame(width: 16, alignment: .trailing)
                    link(model.songTitle(song), glyph: "song", to: .song(song))
                    Spacer(minLength: 4)
                    if let seconds = model.index.facts(.song(song))?.seconds {
                        Text(LibraryText.duration(seconds)).font(Design.Typography.numeric(11)).foregroundStyle(Design.Palette.inkTertiary)
                    }
                }
            }
        }
    }

    /// "Drums of Drifter (drums), Bar 12, Vocals of Drifter (bars 5–8)": what a song takes, part by part.
    static func takes(_ uses: [RecordUse]) -> String {
        let parts = uses.map { use -> String in
            guard use.part != nil else { return "the song grew from it" }
            var notes: [String] = []
            if let stem = use.stem, !use.title.localizedCaseInsensitiveContains(stem) { notes.append(stem) }
            if let bars = use.bars { notes.append(bars.count == 1 ? "bar \(bars.lowerBound + 1)" : "bars \(bars.lowerBound + 1)–\(bars.upperBound)") }
            return notes.isEmpty ? use.title : "\(use.title) (\(notes.joined(separator: ", ")))"
        }
        let counted = Dictionary(parts.map { ($0, 1) }, uniquingKeysWith: +)
        return LibraryIndex.unique(parts).map { part in counted[part, default: 1] > 1 ? "\(part) ×\(counted[part]!)" : part }
            .joined(separator: ", ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SmallLabel(title, color: Design.Palette.inkTertiary)
            content()
        }
    }

    private func link(_ title: String, glyph: String, to id: LibraryItemID) -> some View {
        Button { model.show(id) } label: {
            HStack(spacing: 5) {
                Glyph(name: glyph, symbol: "circle", size: 11)
                Text(title).font(Design.Typography.ui(12.5)).lineLimit(1)
            }
            .foregroundStyle(Design.Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show it in the Library")
    }
}

/// A button under the chosen item's name: the first one filled, a destructive one in the warning
/// colour.
private struct ActionChip: View {
    let title: String
    var leads = false
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(12, weight: leads ? .semibold : .medium))
                .foregroundStyle(leads ? Design.Palette.panel : isDestructive ? Design.Palette.warn : Design.Palette.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: Design.Metric.chipHeight)
                .background(leads ? Design.Palette.accent : .clear, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(leads ? Design.Palette.accent : Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A song's form as a strip: each section a block as long as its bars, named where it fits.
private struct FormStrip: View {
    let sections: [SongGraph.Section]

    var body: some View {
        let total = max(1, sections.reduce(0) { $0 + max(1, $1.lengthInBars) })
        GeometryReader { geometry in
            let room = geometry.size.width - CGFloat(sections.count - 1) * 2
            HStack(spacing: 2) {
                ForEach(sections) { section in
                    let width = max(3, room * CGFloat(max(1, section.lengthInBars)) / CGFloat(total))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Design.Palette.panelAlt)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
                        .overlay(alignment: .leading) {
                            if width > 34 {
                                Text(section.name)
                                    .font(Design.Typography.ui(10, weight: .medium))
                                    .foregroundStyle(Design.Palette.inkSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .frame(width: width)
                        .help("\(section.name), \(section.lengthInBars) bars")
                }
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sections.map { "\($0.name) \($0.lengthInBars) bars" }.joined(separator: ", "))
    }
}
