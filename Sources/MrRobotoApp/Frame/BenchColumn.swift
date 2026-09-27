import SongGraph
import SwiftUI

/// The bench: the dock of surfaces, then the surface you are working in, filling everything below it.
///
/// One surface at a time, drawn from `Bench.visible` — the active surface, plus anything pinned — so
/// the instrument gets the whole bench. Pinning a second surface splits the bench between them,
/// which is the one case where two at once is what you asked for.
///
/// The dock is the app's one bar of places to work. It used to sit under a second bar, the song's
/// path, whose steps opened these same surfaces under other names; two bars for one job, one of
/// them reading as a sequence the work does not have to follow. A lit chip brings its surface
/// forward as you left it; an unlit one opens it on the most useful thing the song has for it
/// (`Guidance.dockAction`).
struct BenchColumn: View {
    let app: AppState
    var registry: SurfaceRegistry = .shared

    var body: some View {
        VStack(spacing: 0) {
            SurfaceDock(app: app)
            Hairline()
            content
        }
        .background(Design.Palette.paper)
        // Never wider than the column it was given. A row in here that could not fit — the dock,
        // once it held seven chips — made the whole column wider than its frame; SwiftUI centred
        // the overflow, and the column's own background painted over the last 88 points of the
        // rail beside it, so every card in the rail looked cut off at the right. The dock fits
        // now, and this is the belt to that braces.
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        let visible = app.bench.visible
        VStack(spacing: FrameLayout.benchSpacing) {
            if visible.isEmpty {
                empty
                Spacer(minLength: 0)
            } else {
                ForEach(visible) { item in
                    SurfaceHost(item: item, app: app, registry: registry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(FrameLayout.benchPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A library row dropped on the bench is adopted into the open song and opened on the
        // surface it belongs on: a sample on the Chop lane, a groove idea in the Grid, a record cut
        // into a bar. A song opens; an album opens its surface.
        .acceptsLibraryDrops(app, at: .bench)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            if app.song == nil {
                VStack(spacing: 6) {
                    Wordmark(size: 30)
                    ArtImage("empty-first-launch", width: 300, height: 200)
                }
                .frame(maxWidth: .infinity)
            }
            if app.regions.isCollapsed(.rail) {
                // The band's question, in the room the bench has while nothing is on it: at launch
                // the Director asks where to start, and after Close all whoever's step it is asks.
                NextQuestionCard(app: app, question: app.nextQuestion, showsAsker: true)
                    .padding(Design.Metric.inset)
                    .background(Design.Palette.panelAlt)
                    .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                    .frame(maxWidth: 620, alignment: .leading)
            } else {
                emptyNote
            }
        }
    }

    private var emptyNote: some View {
        EmptyNote(title: app.song == nil ? "Nothing open." : "The bench is empty.",
                  detail: app.song == nil
                      ? "The Director is asking where to start, in the Band column: pick up a song, start a new one, or flip a record. Every song you have made is in the library, in the strip on the left."
                      : "Answer the band's question on the right, or press a surface above and it fills the bench. Pin one to keep it on screen while you work in another.")
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Palette.panelAlt)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(Design.Palette.line, lineWidth: Design.Metric.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}

/// Every surface you work in, in no order you have to follow, each with how many of its parts the
/// song has (the same count as its title's menu) and the shortcut that also opens it — and, when
/// the band's column is folded away, the band's question, so folding it never costs you that.
///
/// A chip is lit while its surface is open and accented while it is the one filling the bench, so the
/// dock doubles as "what am I looking at" and "what else is open".
struct SurfaceDock: View {
    let app: AppState

    var body: some View {
        // The widest that fits, trying each in turn. Every surface keeps its name for as long as
        // anything else can give way first: the shortcuts, then the "Surfaces" label and the words
        // on Close all, then the chips' padding — and only then the names, which fold to glyphs
        // with the one you are in still named. Names and shortcuts are in the tooltips either way.
        //
        // The band's question, when its column is folded away, is kept before the names go: it is
        // what is being asked of you, and every chip's name is in its tooltip.
        let asked = app.dockQuestion
        ViewThatFits(in: .horizontal) {
            dockRow(.full, labelled: true, next: asked, room: .both)
            dockRow(.compact, labelled: true, next: asked, room: .both)
            dockRow(.tight, labelled: false, next: asked, room: .both)
            dockRow(.tight, labelled: false, next: asked, room: .question)
            dockRow(.tight, labelled: false, next: asked, room: .answer)
            dockRow(.current, labelled: false, next: asked, room: .question)
            dockRow(.glyphs, labelled: false, next: asked, room: .question)
            dockRow(.glyphs, labelled: false, next: asked, room: .answer)
            dockRow(.glyphs, labelled: false, next: asked, room: .button)
        }
        .padding(.horizontal, Design.Metric.gutter)
        .frame(height: FrameLayout.dockHeight)
        .background(Design.Palette.paper)
        .confirmationDialog("Close every surface? The song would not take some of their edits.",
                            isPresented: $isConfirmingCloseAll, titleVisibility: .visible) {
            Button("Close all anyway", role: .destructive) { app.closeAllSurfaces() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unkeptNames)
        }
    }

    @State private var isConfirmingCloseAll = false

    /// One way the row can be drawn: the chips, the band's question, and Close all.
    private func dockRow(_ style: DockChip.Style, labelled: Bool,
                         next asked: (question: NextQuestion, option: NextOption)?,
                         room: DockQuestion.Room) -> some View {
        HStack(spacing: style == .tight ? 5 : 8) {
            if labelled { SmallLabel("Surfaces") }
            chips(style)
            Spacer(minLength: 8)
            if let asked {
                DockQuestion(app: app, question: asked.question, option: asked.option, room: room)
                    .fixedSize()
            }
            if !app.bench.items.isEmpty { closeAll(worded: labelled) }
        }
    }

    /// Close all, in words when there is room and as a glyph when there is not.
    @ViewBuilder
    private func closeAll(worded: Bool) -> some View {
        let press = {
            app.keepSurfaceWork()
            if app.bench.items.contains(where: { app.closingWouldLoseWork($0.id) }) {
                isConfirmingCloseAll = true
            } else {
                app.closeAllSurfaces()
            }
        }
        let help = "Close every surface on the bench. One holding unkept work asks first."
        if worded {
            FrameButton(title: "Close all", emphasis: .quiet, action: press).help(help)
        } else {
            ChipButton(systemImage: "xmark.square", help: help, action: press)
                .accessibilityLabel("Close all surfaces")
        }
    }

    /// "Grid: Boom-bap pocket, Chords: Dm7 G7" — what would go.
    private var unkeptNames: String {
        app.bench.items.filter { app.closingWouldLoseWork($0.id) }
            .map { "\($0.kind.rawValue): \($0.title)" }.joined(separator: ", ")
    }

    private var kinds: [SurfaceKind] { Guidance.dockSurfaces(for: app.song) }

    private func chips(_ style: DockChip.Style) -> some View {
        HStack(spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                DockChip(kind: kind,
                         shortcut: Guidance.dockShortcut(for: kind),
                         count: app.dockCount(for: kind),
                         style: style,
                         isOpen: app.bench.items.contains { $0.kind == kind },
                         isActive: app.bench.active?.kind == kind) {
                    app.showSurface(kind)
                }
            }
        }
    }
}

private struct DockChip: View {
    /// How much of the chip there is room for, widest first.
    /// `.current` is the glyphs with the one filling the bench named: where you are, in words,
    /// when there is no room for every name.
    enum Style { case full, compact, tight, current, glyphs }

    let kind: SurfaceKind
    let shortcut: String
    /// How many of its parts the song has; nil draws none.
    var count: Int? = nil
    var style: Style = .full
    let isOpen: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: style == .tight ? 4 : 6) {
                Glyph(name: kind.glyph.name, symbol: kind.glyph.symbol, size: 13)
                if style == .full || style == .compact || style == .tight || (style == .current && isActive) {
                    Text(kind.rawValue)
                        .font(Design.Typography.ui(12.5, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
                if let count, style != .glyphs {
                    Text("\(count)")
                        .font(Design.Typography.numeric(11))
                        .foregroundStyle(isActive ? Design.Palette.accent : Design.Palette.inkSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if style == .full {
                    Text(shortcut)
                        .font(Design.Typography.numeric(10))
                        .foregroundStyle(isActive ? Design.Palette.accent : Design.Palette.inkTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isActive ? Design.Palette.accent : Design.Palette.ink)
            .padding(.horizontal, style == .tight ? 7 : 10)
            .frame(height: Design.Metric.controlHeight)
            .background(isActive ? Design.Palette.accentSoft : Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isActive ? Design.Palette.accent : (isOpen ? Design.Palette.ink : Design.Palette.lineStrong),
                            lineWidth: Design.Metric.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("\(kind.rawValue), \(shortcut)\(isActive ? ", filling the bench" : isOpen ? ", open" : "")")
    }

    private var helpText: String {
        let held = count.map { " · \($0) in the song" } ?? ""
        if isActive { return "\(kind.rawValue) is filling the bench (\(shortcut))\(held)" }
        if isOpen { return "Bring \(kind.rawValue) forward (\(shortcut))\(held)" }
        return "Open \(kind.rawValue) (\(shortcut))\(held)"
    }
}
