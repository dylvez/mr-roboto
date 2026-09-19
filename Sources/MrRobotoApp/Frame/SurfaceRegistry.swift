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
    public static func registerGateASurfaces(in registry: SurfaceRegistry = .shared) {
        // One line per surface. Each builds its model from the bench item and the app through
        // `SurfaceWiring`, which owns the models and the host adapters — the builder runs on every
        // render, so nothing that holds an edit in progress can be built inside it.
        registry.register(.importRecord) { item, app in
            ImportSurfaceView(model: SurfaceWiring.shared.importModel(for: item, app: app))
        }
        registry.register(.chopLane) { item, app in
            ChopLanePanel(binding: SurfaceWiring.shared.chopBinding(for: item, app: app), app: app)
        }
        registry.register(.grid) { item, app in
            GridSurfaceView(model: SurfaceWiring.shared.gridModel(for: item, app: app))
        }
        registry.register(.sound) { item, app in
            let (surface, adapter) = SurfaceWiring.shared.soundSurface(for: item, app: app)
            SoundSurfacePanel(surface: surface, hasSelection: adapter.selectedPart != nil, app: app)
        }
        registry.register(.chords) { item, app in
            ChordsSurfaceView(model: SurfaceWiring.shared.chordsModel(for: item, app: app))
        }
        registry.register(.pianoRoll) { item, app in
            PianoRollSurfaceView(model: SurfaceWiring.shared.pianoRollModel(for: item, app: app))
        }
        registry.register(.structure) { item, app in
            StructureSurfaceView(model: SurfaceWiring.shared.structureModel(for: item, app: app))
        }
    }

    /// The two the Director answers with.
    ///
    /// Separate from `registerGateASurfaces` and not folded into it, because the two lists are two
    /// different promises. The Gate A four are the catalog you drive; these two only ever exist
    /// because something was asked, and both of them draw content that is not in the binding —
    /// `AppState.answer(for:)` is where that content is, and `SurfaceWiring` is what turns it into a
    /// model. A Compare whose brief has gone (a session restored, a song reopened) falls back to
    /// reading its binding rather than drawing nothing.
    public static func registerAnswerSurfaces(in registry: SurfaceRegistry = .shared) {
        registry.register(.compare) { item, app in
            ComparePanel(filling: SurfaceWiring.shared.compareFilling(for: item, app: app))
        }
        registry.register(.check) { item, app in
            CheckPanel(filling: SurfaceWiring.shared.checkFilling(for: item, app: app))
        }
    }

    /// The library's own surface. Apart from the Gate A list because it is not on the dock — an
    /// album opens from its row in the sidebar — and apart from the answers because nobody asked.
    public static func registerLibrarySurfaces(in registry: SurfaceRegistry = .shared) {
        registry.register(.album) { item, app in
            AlbumSurfaceView(surfaceID: item.id, app: app)
        }
        registry.register(.merge) { item, app in
            MergeSurfaceView(model: SurfaceWiring.shared.mergeModel(for: item, app: app))
        }
        registry.register(.cast) { _, app in
            CastSurfaceView(app: app)
        }
        registry.register(.lyrics) { item, app in
            LyricsSurfaceView(model: SurfaceWiring.shared.lyricsModel(for: item, app: app))
        }
        registry.register(.mashup) { item, app in
            MashupSurfaceView(model: SurfaceWiring.shared.mashupModel(for: item, app: app))
        }
        registry.register(.booth) { item, app in
            BoothSurfaceView(model: SurfaceWiring.shared.boothModel(for: item, app: app))
        }
        registry.register(.takes) { item, app in
            TakesSurfaceView(model: SurfaceWiring.shared.takesModel(for: item, app: app))
        }
        registry.register(.mixer) { item, app in
            MixerSurfaceView(model: SurfaceWiring.shared.mixerModel(for: item, app: app), midi: SurfaceWiring.shared.midi(for: app))
        }
        registry.register(.master) { item, app in
            MasterSurfaceView(model: SurfaceWiring.shared.masterModel(for: item, app: app))
        }
    }

    /// Everything a running app draws. One call at launch, from `MrRobotoApp.init()`.
    public static func registerSurfaces(in registry: SurfaceRegistry = .shared) {
        registerGateASurfaces(in: registry)
        registerAnswerSurfaces(in: registry)
        registerLibrarySurfaces(in: registry)
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
            if app.primers.isShowing(item.kind) {
                PrimerBanner(kind: item.kind, store: app.primers)
            }
            Divider().overlay(Design.Palette.line)
            content
                // The surface takes everything the bench gives it. This is the other half of drawing
                // one at a time: a panel that sized itself to its content left the rest of the bench
                // blank, which looked like the frame had simply run out of things to say.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Design.Palette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(item.isPinned ? Design.Palette.accent : Design.Palette.line, lineWidth: Design.Metric.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Glyph(name: item.kind.glyph.name, symbol: item.kind.glyph.symbol, size: 14)
                .foregroundStyle(Design.Palette.inkSecondary)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(item.kind.rawValue.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkSecondary)
            Text(item.title)
                .font(Design.Typography.ui(16, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
                .lineLimit(1)
                .layoutPriority(1)
            // Where the bound part came from. It gives way before the title does.
            if crumbs.count > 1 {
                LineageCrumbs(crumbs: crumbs, app: app)
            }
            // The band takes the free space between the words and the buttons, and only that, so
            // it never sits under anything you read or press.
            SurfaceBand(kind: item.kind)
                .frame(minWidth: 8, maxWidth: .infinity)
                .frame(height: 28)
                .layoutPriority(-1)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            SurfacePlayControl(item: item, app: app)
            ChipButton(systemImage: "questionmark",
                       help: app.primers.isShowing(item.kind)
                           ? "Hide what \(item.kind.rawValue) is for"
                           : "What is \(item.kind.rawValue) for?",
                       isOn: app.primers.isShowing(item.kind)) {
                app.primers.toggle(item.kind)
            }
            ChipButton(systemImage: item.isPinned ? "pin.fill" : "pin",
                       help: item.isPinned
                           ? "Unpin this surface — the one you are working in fills the bench again"
                           : "Pin this surface: it stays on screen, splitting the bench, while you work in another",
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

    /// The lineage of the first bound part, when there is one.
    private var crumbs: [PartLineage.Crumb] {
        guard let song = app.song, let first = app.bound(for: item.id).first else { return [] }
        return PartLineage.crumbs(for: first, in: song)
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
