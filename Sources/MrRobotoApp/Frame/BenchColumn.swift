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
        }
    }

    private var emptyNote: some View {
        EmptyNote(title: app.song == nil ? "Nothing open." : "The bench is empty.",
                  detail: app.song == nil
                      ? "Open a song from the library and its record lands here. Or press Record above and drop an audio file on it."
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
            // Six chips with their shortcuts when the bench is wide enough; without the shortcuts
            // (they are still in the tooltips and the Surfaces menu) when it is not.
            ViewThatFits(in: .horizontal) {
                chips(compact: false)
                chips(compact: true)
            }
            Spacer(minLength: 8)
            if let proposal = app.dockProposal {
                // Never squeezed: with seven chips and the shortcuts on, the fit fails here and
                // the dock drops to its compact chips rather than folding this one.
                NextStepChip(proposal: proposal) { app.perform(proposal.action) }
                    .fixedSize()
            }
            if !app.bench.items.isEmpty {
                FrameButton(title: "Close all", emphasis: .quiet) {
                    for item in app.bench.items { app.closeSurface(item.id) }
                }
            }
        }
        .padding(.horizontal, Design.Metric.gutter)
        .frame(height: FrameLayout.dockHeight)
        .background(Design.Palette.paper)
    }

    private func chips(compact: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(SurfaceKind.gateA.enumerated()), id: \.element) { index, kind in
                DockChip(kind: kind,
                         shortcut: "⌘\(index + 1)",
                         compact: compact,
                         isOpen: app.bench.items.contains { $0.kind == kind },
                         isActive: app.bench.active?.kind == kind) {
                    app.showSurface(kind)
                }
            }
        }
    }
}

private struct DockChip: View {
    let kind: SurfaceKind
    let shortcut: String
    var compact = false
    let isOpen: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Glyph(name: kind.glyph.name, symbol: kind.glyph.symbol, size: 13)
                Text(kind.rawValue)
                    .font(Design.Typography.ui(12.5, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                if !compact {
                    Text(shortcut)
                        .font(Design.Typography.numeric(10))
                        .foregroundStyle(isActive ? Design.Palette.accent : Design.Palette.inkTertiary)
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
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                SmallLabel("Next", color: Design.Palette.accent)
                Text(proposal.title)
                    .font(Design.Typography.ui(12.5, weight: .medium))
                    .foregroundStyle(Design.Palette.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Capped so the next step cannot push the four surface chips off a narrow dock:
                    // the chips are the navigation and they win.
                    .frame(maxWidth: 200, alignment: .leading)
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
        .help("\(proposal.title) — \(proposal.rationale)")
    }
}
