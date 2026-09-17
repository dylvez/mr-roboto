import SwiftUI

/// The bench: up to three surfaces, stacked, newest at the bottom. The `Bench` owns the rule (replace
/// the oldest unpinned); this only draws what it holds.
struct BenchColumn: View {
    let app: AppState
    var registry: SurfaceRegistry = .shared

    var body: some View {
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
        .background(Design.Palette.paper)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmptyNote(title: "The bench is empty.",
                      detail: "Open a surface from the Surfaces menu, or drag something out of the library. At most three stay open at once; pin one to keep it.")
            HStack(spacing: 8) {
                ForEach(SurfaceKind.gateA, id: \.self) { kind in
                    FrameButton(title: kind.rawValue, emphasis: .quiet) {
                        app.openSurface(kind, title: app.song?.title ?? "Untitled")
                    }
                }
            }
        }
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
