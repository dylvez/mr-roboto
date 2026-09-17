import SwiftUI

/// The bench: the dock of surfaces, then up to three of them, stacked, newest at the bottom. The
/// `Bench` owns the rule (replace the oldest unpinned); this only draws what it holds.
///
/// The dock exists because the catalog used to be reachable only from the Surfaces menu and ⌘1–⌘4,
/// which is to say it was not reachable at all: nothing on screen said the four surfaces existed.
/// It is a shelf, not advice — the advice is in the rail. Picking a surface off the shelf opens it
/// on the most useful thing the song has for it (`Guidance.dockAction`) rather than on nothing.
struct BenchColumn: View {
    let app: AppState
    var registry: SurfaceRegistry = .shared

    var body: some View {
        VStack(spacing: 0) {
            SurfaceDock(app: app)
            Hairline()
            ScrollView {
                VStack(spacing: 18) {
                    if app.bench.items.isEmpty {
                        empty
                    } else {
                        ForEach(app.bench.items) { item in
                            SurfaceHost(item: item, app: app, registry: registry)
                        }
                    }
                }
                .padding(.horizontal, Design.Metric.gutter)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Design.Palette.paper)
    }

    private var empty: some View {
        EmptyNote(title: app.song == nil ? "Nothing open." : "The bench is empty.",
                  detail: app.song == nil
                      ? "Open a song from the library and its record lands here. Or press Import above and drop an audio file on it."
                      : "Press a surface above, or take the next step from the rail on the left. At most three stay open at once; pin one to keep it.")
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

/// The four surfaces, on screen, with the shortcuts that also open them.
///
/// A chip is lit while its surface is on the bench, so the dock doubles as "what am I looking at".
/// Pressing a lit chip reopens rather than duplicates — `AppState.perform` reuses an open surface
/// bound to the same versions.
struct SurfaceDock: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 8) {
            SmallLabel("Surfaces")
            ForEach(Array(SurfaceKind.gateA.enumerated()), id: \.element) { index, kind in
                DockChip(kind: kind,
                         shortcut: "⌘\(index + 1)",
                         isOpen: app.bench.items.contains { $0.kind == kind }) {
                    app.perform(Guidance.dockAction(for: kind, in: app.song))
                }
            }
            Spacer(minLength: 8)
            if !app.bench.items.isEmpty {
                FrameButton(title: "Close all", emphasis: .quiet) {
                    for item in app.bench.items { app.closeSurface(item.id) }
                }
            }
        }
        .padding(.horizontal, Design.Metric.gutter)
        .frame(height: FrameLayout.headerHeight)
        .background(Design.Palette.paper)
    }
}

private struct DockChip: View {
    let kind: SurfaceKind
    let shortcut: String
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(kind.rawValue)
                    .font(Design.Typography.ui(12.5, weight: isOpen ? .semibold : .medium))
                Text(shortcut)
                    .font(Design.Typography.numeric(10))
                    .foregroundStyle(isOpen ? Design.Palette.accent : Design.Palette.inkTertiary)
            }
            .foregroundStyle(isOpen ? Design.Palette.accent : Design.Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: Design.Metric.controlHeight)
            .background(isOpen ? Design.Palette.accentSoft : Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOpen ? Design.Palette.accent : Design.Palette.lineStrong,
                            lineWidth: Design.Metric.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(kind.rawValue) (\(shortcut))")
    }
}
