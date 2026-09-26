import SongGraph
import SwiftUI

/// The bench: the dock of surfaces, then the surface you are working in, filling everything below it.
///
/// One surface at a time is the change. The `Bench` still holds three and still retires the oldest
/// unpinned one; it now draws `Bench.visible` — the active surface, plus anything pinned — so the
/// instrument gets the whole bench instead of a third of it. Pinning a second surface splits the
/// bench between them, which is the one case where two at once is what you asked for.
///
/// The dock is therefore load-bearing: it is no longer only a shelf saying the four surfaces exist,
/// it is how you move between the ones that are open. A lit chip brings its surface forward; an
/// unlit one opens it on the most useful thing the song has for it (`Guidance.dockAction`).
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
                    ArtImage("empty-first-launch", width: 420, height: 280)
                }
                .frame(maxWidth: .infinity)
            }
            emptyNote
            if app.song == nil {
                HStack(spacing: 8) {
                    Button("Import a Record…") { MrRobotoApp.importRecord(app) }
                        .buttonStyle(.borderedProminent)
                    // As File ▸ New Song does it: the settings open, so the first thing is a name,
                    // a tempo and a key rather than "Untitled, 120, no key" found out later.
                    Button("New Song") {
                        app.open(Song.new(title: MrRobotoApp.untitledName()))
                        app.wantsSongSettings = true
                    }
                }
                .font(Design.Typography.ui(12.5))
            }
        }
    }

    private var emptyNote: some View {
        EmptyNote(title: app.song == nil ? "Nothing open." : "The bench is empty.",
                  detail: app.song == nil
                      ? "Two ways in. Flip a record: import an audio file (⌘I, or drop one on the Record surface) and the app reads its key, tempo and form, then splits it into stems to chop. Or start from nothing: New Song (⌘N) opens an Intro, a Verse and a Hook, ready for a groove on the Grid. Songs you have made are in the library on the left."
                      : "Press a surface above and it fills the bench. Pin one to keep it on screen while you work in another.")
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

/// The four surfaces, on screen, with the shortcuts that also open them — and, when the session rail
/// is folded away, the next step, so collapsing the rail never costs you the one thing in it that
/// tells you what to do.
///
/// A chip is lit while its surface is open and accented while it is the one filling the bench, so the
/// dock doubles as "what am I looking at" and "what else is open".
struct SurfaceDock: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 8) {
            SmallLabel("Surfaces")
            // Seven chips with their shortcuts when the bench is wide enough; without the shortcuts
            // when it is not; and as glyphs alone at the bench's minimum, where even the names did
            // not fit — the names and the shortcuts are in the tooltips and the Surfaces menu
            // either way. A dock that cannot fit its chips is what made the bench overflow its
            // column and paint over the rail.
            //
            // The next step folds before the names do: its title goes into its tooltip, "Next →"
            // stays. At the default window the names used to go first, and the dock was a row of
            // unlabelled glyphs beside a sentence.
            let proposal = app.dockProposal
            ViewThatFits(in: .horizontal) {
                dockRow(.full, next: proposal, short: false)
                dockRow(.compact, next: proposal, short: false)
                dockRow(.compact, next: proposal, short: true)
                dockRow(.current, next: proposal, short: false)
                dockRow(.current, next: proposal, short: true)
                dockRow(.glyphs, next: proposal, short: true)
            }
            if !app.bench.items.isEmpty {
                FrameButton(title: "Close all", emphasis: .quiet) {
                    app.keepSurfaceWork()
                    if app.bench.items.contains(where: { app.closingWouldLoseWork($0.id) }) {
                        isConfirmingCloseAll = true
                    } else {
                        app.closeAllSurfaces()
                    }
                }
                .help("Close every surface on the bench. One holding unkept work asks first.")
                .confirmationDialog("Close every surface? The song would not take some of their edits.",
                                    isPresented: $isConfirmingCloseAll, titleVisibility: .visible) {
                    Button("Close all anyway", role: .destructive) { app.closeAllSurfaces() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(unkeptNames)
                }
            }
        }
        .padding(.horizontal, Design.Metric.gutter)
        .frame(height: FrameLayout.dockHeight)
        .background(Design.Palette.paper)
    }

    @State private var isConfirmingCloseAll = false

    /// The chips, then the next step, as one row the fit is tried against.
    private func dockRow(_ style: DockChip.Style, next proposal: Proposal?, short: Bool) -> some View {
        HStack(spacing: 8) {
            chips(style)
            Spacer(minLength: 8)
            if let proposal {
                NextStepChip(proposal: proposal, short: short) { app.perform(proposal.action) }
                    .fixedSize()
            }
        }
    }

    /// "Grid: Boom-bap pocket, Chords: Dm7 G7" — what would go.
    private var unkeptNames: String {
        app.bench.items.filter { app.closingWouldLoseWork($0.id) }
            .map { "\($0.kind.rawValue): \($0.title)" }.joined(separator: ", ")
    }

    /// The seven the dock always carries, then the ones the song has reached.
    private var kinds: [SurfaceKind] { SurfaceKind.gateA + Guidance.laterSurfaces(for: app.song) }

    private func chips(_ style: DockChip.Style) -> some View {
        HStack(spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                DockChip(kind: kind,
                         shortcut: Guidance.dockShortcut(for: kind),
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
    enum Style { case full, compact, current, glyphs }

    let kind: SurfaceKind
    let shortcut: String
    var style: Style = .full
    let isOpen: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Glyph(name: kind.glyph.name, symbol: kind.glyph.symbol, size: 13)
                if style == .full || style == .compact || (style == .current && isActive) {
                    Text(kind.rawValue)
                        .font(Design.Typography.ui(12.5, weight: isActive ? .semibold : .medium))
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
            .padding(.horizontal, 10)
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
        if isActive { return "\(kind.rawValue) is filling the bench (\(shortcut))" }
        if isOpen { return "Bring \(kind.rawValue) forward (\(shortcut))" }
        return "Open \(kind.rawValue) (\(shortcut))"
    }
}

/// The leading proposal, in the dock, shown only while the rail is collapsed. One line, the accent,
/// and the same `perform` the rail's own control calls — there is no second way to take a step.
private struct NextStepChip: View {
    let proposal: Proposal
    /// Just "Next →", the step in the tooltip: what the chip becomes when the dock is tight.
    var short = false
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                SmallLabel(short ? "Next →" : "Next", color: Design.Palette.accent)
                if !short {
                    Text(proposal.title)
                        .font(Design.Typography.ui(12.5, weight: .medium))
                        .foregroundStyle(Design.Palette.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Capped so the next step cannot push the surface chips off a narrow dock:
                        // the chips are the navigation and they win.
                        .frame(maxWidth: 200, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Design.Metric.controlHeight)
            .background(Design.Palette.accentSoft)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(Design.Palette.accent, lineWidth: Design.Metric.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(proposal.title) — \(proposal.rationale) (⌘])")
    }
}
