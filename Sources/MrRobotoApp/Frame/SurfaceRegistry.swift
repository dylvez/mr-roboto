import SwiftUI

/// How a `SurfaceKind` becomes a view.
///
/// The frame knows the catalog but not the surfaces: each surface is written independently and registers
/// itself in one call, from its own file, at launch:
///
/// ```swift
/// SurfaceRegistry.shared.register(.chopLane) { item, app in
///     ChopLaneView(item: item, app: app)
/// }
/// ```
///
/// A kind with no builder is not an error and never crashes the frame — the bench renders a labelled
/// placeholder saying which surface is missing, so four surfaces can be built in parallel against a
/// frame that already runs.
@MainActor
public final class SurfaceRegistry {
    /// The registry the app's frame reads. Surfaces register into this one.
    public static let shared = SurfaceRegistry()

    private var builders: [SurfaceKind: (BenchItem, AppState) -> AnyView] = [:]

    public init() {}

    /// Registers the view for a kind. Registering a kind twice replaces the first: last registration wins.
    public func register<Content: View>(_ kind: SurfaceKind,
                                        @ViewBuilder _ build: @escaping (BenchItem, AppState) -> Content) {
        builders[kind] = { item, app in AnyView(build(item, app)) }
    }

    /// Whether anything is registered for this kind.
    public func hasBuilder(for kind: SurfaceKind) -> Bool { builders[kind] != nil }

    /// Kinds with a registered view, in catalog order.
    public var registeredKinds: [SurfaceKind] { SurfaceKind.allCases.filter(hasBuilder(for:)) }

    /// Forgets a registration. For tests; nothing in the app unregisters.
    public func unregister(_ kind: SurfaceKind) { builders[kind] = nil }

    /// The one call site that wires the catalog up, run once at launch from `MrRobotoApp.init()`.
    ///
    /// Swift has no launch-time auto-registration, so a surface becomes visible by adding exactly one
    /// line here — for example:
    ///
    /// ```swift
    /// shared.register(.chopLane) { item, app in ChopLaneView(item: item, app: app) }
    /// ```
    ///
    /// Until a kind is added, the bench shows its placeholder; the frame runs either way, which is what
    /// lets the four surfaces be built in parallel. Registering later (from a surface's own file, before
    /// the first render) works just as well — this is a convenience, not a requirement.
    public static func registerGateASurfaces() {
        // One line per surface. Each builds its model from the bench item and the app through
        // `SurfaceWiring`, which owns the models and the host adapters — the builder runs on every
        // render, so nothing that holds an edit in progress can be built inside it.
        shared.register(.importRecord) { item, app in
            ImportSurfaceView(model: SurfaceWiring.shared.importModel(for: item, app: app))
        }
        shared.register(.chopLane) { item, app in
            ChopLanePanel(binding: SurfaceWiring.shared.chopBinding(for: item, app: app), app: app)
        }
        shared.register(.grid) { item, app in
            GridSurfaceView(model: SurfaceWiring.shared.gridModel(for: item, app: app))
        }
        shared.register(.sound) { item, app in
            let (surface, adapter) = SurfaceWiring.shared.soundSurface(for: item, app: app)
            SoundSurfacePanel(surface: surface, hasSelection: adapter.selectedPart != nil, app: app)
        }
    }

    /// What the bench should draw for this item: the registered surface, or the placeholder.
    /// Never throws and never traps for an unregistered kind.
    public func resolve(_ item: BenchItem, app: AppState) -> SurfaceResolution {
        guard let build = builders[item.kind] else { return .placeholder(item.kind) }
        return .surface(build(item, app))
    }
}

/// The outcome of a registry lookup, separated from the view so it can be asserted in a test.
public enum SurfaceResolution {
    case surface(AnyView)
    case placeholder(SurfaceKind)

    public var isPlaceholder: Bool { if case .placeholder = self { return true } else { return false } }
}

/// One surface in the bench: its header (kind, title, pin, close) plus whatever the registry resolves.
struct SurfaceHost: View {
    let item: BenchItem
    let app: AppState
    var registry: SurfaceRegistry = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Design.Palette.line)
            content
        }
        .background(Design.Palette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(item.isPinned ? Design.Palette.accent : Design.Palette.line, lineWidth: Design.Metric.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.kind.rawValue.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkSecondary)
            Text(item.title)
                .font(Design.Typography.ui(16, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            ChipButton(systemImage: item.isPinned ? "pin.fill" : "pin",
                       help: item.isPinned ? "Unpin this surface" : "Pin this surface so the next answer does not replace it",
                       isOn: item.isPinned) {
                app.setPinned(!item.isPinned, for: item.id)
            }
            ChipButton(systemImage: "xmark", help: "Close this surface") {
                app.closeSurface(item.id)
            }
        }
        .padding(.horizontal, Design.Metric.inset)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch registry.resolve(item, app: app) {
        case .surface(let view):
            view
        case .placeholder(let kind):
            SurfacePlaceholder(kind: kind, title: item.title)
        }
    }
}

/// What the bench shows for a kind nothing has registered a view for. It names the missing surface
/// rather than pretending to be one.
struct SurfacePlaceholder: View {
    let kind: SurfaceKind
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(kind.rawValue) is not built yet.")
                .font(Design.Typography.prose(15.5))
                .foregroundStyle(Design.Palette.ink)
            Text("The frame opened it and bound it to \(title.isEmpty ? "nothing" : title); no view is registered for this kind.")
                .font(Design.Typography.prose(14))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Metric.inset)
        .background(Design.Palette.panelAlt)
    }
}
