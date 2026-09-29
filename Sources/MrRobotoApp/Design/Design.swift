import AppKit
import Foundation
import Observation
import Synchronization
import SwiftUI

/// The instrument's visual identity, as a set of interchangeable themes.
///
/// One `Theme` value carries every colour token and every typeface stack the surfaces
/// draw with. Exactly one theme is current at a time; `Design.Palette` and `Design.Typography` read
/// through it, so a surface still writes `Design.Palette.accent` and never knows a theme exists.
///
/// Switching is live. `ThemeStore` is `Observable`, and every token read goes through it, so a read
/// inside a SwiftUI `body` registers a dependency on the current theme the same way a read of any
/// other observable property does. Choosing a theme therefore invalidates every body that paints —
/// which is all of them — and nothing else. No view identity changes, so the bench, the loaded song
/// and the transport are untouched by a switch.
///
/// Nothing in a surface should hard-code a colour or a size; take it from here.
public enum Design {
    /// True under `MRROBOTO_RENDER`, when the frame is being drawn by `ImageRenderer` for a test
    /// rather than shown. AppKit-backed controls render as prohibited blocks there, so the few
    /// that would hide something worth seeing step aside.
    public static let isOffscreenRender = ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil


    // MARK: - A colour, defined once for both appearances

    /// One colour token's two values. Light and dark are declared together and neither is optional,
    /// so a token cannot exist in only one appearance — the failure mode that produces an invisible
    /// control the first time someone flips the system to dark.
    public struct ColorPair: Sendable, Equatable, Hashable {
        public let light: UInt32
        public let dark: UInt32

        public init(_ light: UInt32, _ dark: UInt32) {
            self.light = light
            self.dark = dark
        }

        /// The SwiftUI colour. Memoised: a token is read hundreds of times per frame and each read
        /// would otherwise allocate a fresh dynamic `NSColor` with its own resolver block.
        public var color: Color { Design.memoisedColor(self) }
    }

    /// Guarded by `colorCacheLock`. Same idiom as `FontRegistration`: the flag and the work live
    /// under one lock rather than behind a "done yet?" check that a second thread can slip past.
    private nonisolated(unsafe) static var colorCache: [ColorPair: Color] = [:]
    private static let colorCacheLock = NSLock()

    fileprivate static func memoisedColor(_ pair: ColorPair) -> Color {
        colorCacheLock.lock()
        defer { colorCacheLock.unlock() }
        if let cached = colorCache[pair] { return cached }
        let made = Color(hex: pair.light, dark: pair.dark)
        colorCache[pair] = made
        return made
    }

    // MARK: - Themes

    /// The three directions, and the only three. A theme is a complete set of tokens, not a tweak on
    /// top of another one, so there is no way to add a colour to one and forget it in the others.
    public enum Theme: String, CaseIterable, Identifiable, Sendable {
        /// The editorial notebook the mockups were approved in: warm paper, warm inks, an ink-blue
        /// accent. Kept so the other two can be judged against it rather than against a memory.
        case notebook

        /// No warmth anywhere. True greys carrying a slight blue bias, white panels, near-black ink
        /// and one blue. Reads as a precision tool.
        case cool

        /// A committed hue as the ground rather than a neutral — the way a piece of hardware has a
        /// colour. Deep blue-green, cold and saturated, with the TR-808's own button orange spent on
        /// almost nothing.
        case petrol

        public var id: String { rawValue }

        /// What the View menu calls it.
        public var displayName: String {
            switch self {
            case .notebook: return "Notebook"
            case .cool: return "Cool Neutral"
            case .petrol: return "Petrol"
            }
        }

        /// A theme whose ground *is* its identity cannot follow the system between light and dark:
        /// a deep petrol window under the Aqua appearance gets light scrollbars, light menus and a
        /// light text selection drawn over it. Petrol therefore pins the application appearance to
        /// dark so the AppKit furniture agrees with the ground it sits on. The other two follow the
        /// system, which is why this is nil for them.
        public var pinnedAppearance: NSAppearance.Name? {
            switch self {
            case .notebook, .cool: return nil
            case .petrol: return .darkAqua
            }
        }

        public var palette: Palette.Values {
            switch self {
            case .notebook: return Palette.notebook
            case .cool: return Palette.cool
            case .petrol: return Palette.petrol
            }
        }

        /// One family for prose and UI, differentiated by size and weight; a mono for columns. The
        /// same for all three themes at present — the themes differ in colour, not in voice — but it
        /// lives on the theme so a future one can carry its own without a second mechanism.
        public var typeface: Typography.Faces {
            switch self {
            case .notebook, .cool, .petrol: return .plex
            }
        }
    }

    // MARK: - The current theme

    /// Holds the current theme and tells SwiftUI when it changes.
    ///
    /// `Observable` by hand rather than by macro, for one reason: the macro's storage is not
    /// `Sendable`, and this object is a process-wide `let` read from whichever thread happens to be
    /// evaluating a view. `ObservationRegistrar` is `Sendable` and `Mutex` makes the value so, which
    /// leaves the whole thing safely shared without a `nonisolated(unsafe)` escape hatch. The
    /// registrar calls are what SwiftUI's tracking actually keys on, so observation behaves exactly
    /// as it would with the macro.
    public final class ThemeStore: Observable, Sendable {
        private let registrar = ObservationRegistrar()
        private let storage: Mutex<Theme>

        init(_ initial: Theme) { storage = Mutex(initial) }

        public var theme: Theme {
            get {
                registrar.access(self, keyPath: \.theme)
                return storage.withLock { $0 }
            }
            set {
                registrar.withMutation(of: self, keyPath: \.theme) {
                    storage.withLock { $0 = newValue }
                }
            }
        }
    }

    /// Where the choice is remembered between launches.
    public static let themeDefaultsKey = "design.theme"

    /// The theme the app opens in when nothing has been chosen yet.
    public static let defaultTheme = Theme.cool

    public static let store = ThemeStore(storedTheme())

    /// The current theme. Reading this inside a `body` is what makes a switch repaint.
    public static var theme: Theme { store.theme }

    /// What `UserDefaults` remembers, or the default if it remembers nothing usable.
    static func storedTheme(_ defaults: UserDefaults = .standard) -> Theme {
        guard let raw = defaults.string(forKey: themeDefaultsKey), let theme = Theme(rawValue: raw) else {
            return defaultTheme
        }
        return theme
    }

    /// Choose a theme: repaint, remember it, and put the AppKit furniture on the same footing.
    @MainActor
    public static func select(_ theme: Theme, defaults: UserDefaults = .standard) {
        store.theme = theme
        defaults.set(theme.rawValue, forKey: themeDefaultsKey)
        applyPinnedAppearance()
    }

    /// Called once at launch and again on every switch. `NSApp` rather than `NSApplication.shared`
    /// so this is a no-op in a test process instead of conjuring an application object.
    @MainActor
    public static func applyPinnedAppearance() {
        guard let app = NSApp else { return }
        app.appearance = theme.pinnedAppearance.flatMap { NSAppearance(named: $0) }
    }

    // MARK: - Colour

    /// Paper, panel and ink, per theme. The token names are the contract: a surface asks for
    /// `Design.Palette.accent` and gets whichever accent the current theme defines.
    public enum Palette {

        /// Every token, once, for one theme. Adding a token here forces all three themes to define
        /// it — which is the point of the struct.
        public struct Values: Sendable, Equatable, Hashable {
            public let paper: ColorPair
            public let panel: ColorPair
            public let panelAlt: ColorPair
            public let ink: ColorPair
            public let inkSecondary: ColorPair
            public let inkTertiary: ColorPair
            public let line: ColorPair
            public let lineStrong: ColorPair
            public let accent: ColorPair
            public let accentSoft: ColorPair
            public let warn: ColorPair
            public let warnSoft: ColorPair
            public let plate: ColorPair
            public let trace: ColorPair

            /// The tokens with their names, for anything that has to walk the whole set — the tests
            /// that check both appearances and the hue of every neutral, mainly.
            public var tokens: [(name: String, pair: ColorPair)] {
                [("paper", paper), ("panel", panel), ("panelAlt", panelAlt), ("ink", ink),
                 ("inkSecondary", inkSecondary), ("inkTertiary", inkTertiary),
                 ("line", line), ("lineStrong", lineStrong),
                 ("accent", accent), ("accentSoft", accentSoft),
                 ("warn", warn), ("warnSoft", warnSoft),
                 ("plate", plate), ("trace", trace)]
            }

            /// The subset that is a grey rather than a colour: everything the frame is built out of
            /// before an accent or a warning is spent. These are the ones a theme can quietly get
            /// wrong by letting them drift warm.
            public static let neutralTokenNames = ["paper", "panel", "panelAlt", "ink",
                                                   "inkSecondary", "inkTertiary", "line", "lineStrong"]
        }

        // MARK: Notebook

        /// The approved editorial notebook, unchanged: warm paper (#f6f4ef), warm inks, sand
        /// hairlines, one ink-blue accent. Kept verbatim so it is a real comparison and not a
        /// reconstruction.
        static let notebook = Values(
            paper: ColorPair(0xf6f4ef, 0x171614),
            panel: ColorPair(0xffffff, 0x201f1c),
            panelAlt: ColorPair(0xfaf9f6, 0x1c1b18),
            ink: ColorPair(0x1b1a18, 0xece8df),
            inkSecondary: ColorPair(0x6b6862, 0xa8a398),
            inkTertiary: ColorPair(0xa39f96, 0x6f6a60),
            line: ColorPair(0xe3dfd6, 0x34322d),
            lineStrong: ColorPair(0xd6d1c6, 0x45423b),
            accent: ColorPair(0x2b4c7e, 0x8fa9d2),
            accentSoft: ColorPair(0xeef2f8, 0x23293a),
            warn: ColorPair(0xb4432a, 0xd9866f),
            warnSoft: ColorPair(0xfbeee9, 0x352420),
            plate: ColorPair(0x1b1a18, 0x100f0e),
            trace: ColorPair(0x9fb6dc, 0x9fb6dc))

        // MARK: Cool neutral

        /// True greys with a slight blue bias, white panels, near-black ink, one blue.
        ///
        /// Every neutral below is built on one hue — 210–216°, the blue-grey end — at a saturation
        /// low enough that it reads as grey rather than as blue. The discipline that matters is the
        /// one the tests enforce: in every neutral, red never exceeds blue. A grey whose red channel
        /// leads is a warm grey, and warm grey across a full screen is the complaint.
        ///
        /// The accent is IBM Carbon Blue 70 (#0043ce) over light and Blue 40 (#78a9ff) over dark —
        /// real tokens from the design system IBM Plex was drawn for, rather than a blue picked by
        /// eye. Carbon's own Blue 60 (#0f62fe) is the more familiar interactive blue but lands at
        /// 4.38:1 on this paper, under AA, so the palette takes the next step down.
        ///
        /// The hairlines are not a straight translation of the notebook's. On warm paper a sand
        /// hairline separates partly by hue; on a cold ground that help is gone and the same
        /// luminance step reads thinner. `line` and `lineStrong` are therefore set a touch darker
        /// than a like-for-like conversion, which restores the separation without touching
        /// `Metric.hairline`.
        static let cool = Values(
            paper: ColorPair(0xeef0f3, 0x101315),
            panel: ColorPair(0xffffff, 0x191d21),
            panelAlt: ColorPair(0xf7f8fa, 0x15181b),
            ink: ColorPair(0x14171a, 0xe6eaee),
            inkSecondary: ColorPair(0x5a6068, 0x9aa3ac),
            inkTertiary: ColorPair(0x8f969e, 0x6a727a),
            line: ColorPair(0xd7dce2, 0x2c3238),
            lineStrong: ColorPair(0xc6ccd4, 0x3f4750),
            accent: ColorPair(0x0043ce, 0x78a9ff),
            accentSoft: ColorPair(0xdce9fb, 0x17233f),
            warn: ColorPair(0xc21f30, 0xff8389),
            warnSoft: ColorPair(0xfadfe2, 0x2f1518),
            plate: ColorPair(0x14181c, 0x0a0c0e),
            trace: ColorPair(0x6fa8e6, 0x8cbcf0))

        // MARK: Petrol

        /// A deep blue-green ground, cold and saturated, at 188°: the colour of a piece of equipment
        /// rather than the colour of a page. Both appearances are that ground — the light pair is
        /// the same petrol one step up, not a light theme — because a machine does not change colour
        /// when the operating system does. `Theme.pinnedAppearance` keeps AppKit's own chrome dark
        /// to match; see the note there for why that is not optional.
        ///
        /// The accent is the TR-808's orange step keys — the second group, steps 5 to 8 (the first
        /// group, 1 to 4, is the red-orange one). #f97f23 is measured from Sound to Parts' product
        /// photograph of their injection-moulded TR-808 orange switch cap, shot against a near-neutral
        /// #f6f8f7 background, which is the closest thing to the physical part with a trustworthy
        /// white balance:
        ///
        ///   https://www.soundtoparts.com/en/tr-808/4-orange-switch-cap.html
        ///
        /// Two corroborating references, for whoever wants to re-derive it. io-808, the faithful web
        /// recreation of the front panel, publishes `buttonOrange` as #e98e2f in
        /// `src/theme/variables.stylex.js` (github.com/vincentriemer/io-808) and assigns it to steps
        /// 5–8; it reads lighter and more amber than any photograph of the hardware. Roland's own
        /// 808303.studio publishes #ff5a00 in its `mask-icon` link, but that is the screen-printed
        /// stencil orange of the panel graphics and the 808 branding, not the colour of a key.
        /// No Pantone or RAL match for the caps is published anywhere findable.
        ///
        /// Warn is held a long way round the wheel from the accent (355° against 26°) so a critic
        /// finding cannot be mistaken for the accent on a ground this dark.
        ///
        /// The hairlines here are the most-adjusted values in the whole set. Petrol's panels sit
        /// *above* its paper in luminance rather than below it, which is the opposite of a light
        /// theme, so a hairline is squeezed between two grounds instead of dropping away from one.
        /// Straight conversions of the notebook's ratios came out at 1.23:1 against a panel — a line
        /// that is present in a screenshot and absent on a screen. `line` is lifted until it clears
        /// both grounds; `lineStrong` was already dark-ground-appropriate and is unchanged.
        static let petrol = Values(
            paper: ColorPair(0x0e2b30, 0x0a2226),
            panel: ColorPair(0x123840, 0x0f2e33),
            panelAlt: ColorPair(0x103138, 0x0d282d),
            ink: ColorPair(0xe2f0f0, 0xdbeced),
            inkSecondary: ColorPair(0x9dbabd, 0x93b0b3),
            inkTertiary: ColorPair(0x6b9095, 0x628589),
            line: ColorPair(0x245157, 0x1f464c),
            lineStrong: ColorPair(0x306169, 0x2a565c),
            accent: ColorPair(0xf2801f, 0xf97f23),
            accentSoft: ColorPair(0x40281a, 0x381f12),
            warn: ColorPair(0xfa5a66, 0xff5f6d),
            warnSoft: ColorPair(0x421e22, 0x3a181c),
            plate: ColorPair(0x071a1e, 0x051417),
            trace: ColorPair(0x57c8bf, 0x63d2c9))

        // MARK: The tokens themselves

        public static var paper: Color { Design.theme.palette.paper.color }
        public static var panel: Color { Design.theme.palette.panel.color }
        public static var panelAlt: Color { Design.theme.palette.panelAlt.color }

        public static var ink: Color { Design.theme.palette.ink.color }
        public static var inkSecondary: Color { Design.theme.palette.inkSecondary.color }
        public static var inkTertiary: Color { Design.theme.palette.inkTertiary.color }

        public static var line: Color { Design.theme.palette.line.color }
        public static var lineStrong: Color { Design.theme.palette.lineStrong.color }

        /// Spend this on one thing per surface: the selected candidate, the active section.
        public static var accent: Color { Design.theme.palette.accent.color }
        public static var accentSoft: Color { Design.theme.palette.accentSoft.color }

        /// A critic finding, never decoration.
        public static var warn: Color { Design.theme.palette.warn.color }
        public static var warnSoft: Color { Design.theme.palette.warnSoft.color }

        /// The dark plate a waveform or pitch trace is drawn on.
        public static var plate: Color { Design.theme.palette.plate.color }
        public static var trace: Color { Design.theme.palette.trace.color }
    }

    // MARK: - Type

    /// IBM Plex Sans for prose and for controls — one family, told apart by size and weight — and
    /// IBM Plex Mono for anything that lines up in a column.
    ///
    /// One family for two roles rather than two families is deliberate. The previous pairing put a
    /// serif against a grotesque, and the serif carried as much of the room's warmth as the paper
    /// did. Plex is a technical face drawn for an engineering system; it does not editorialise, and
    /// at 15.5/regular against 13/medium the two roles stay legibly apart without a second voice.
    ///
    /// Both families ship with the app — see `FontRegistration`, which registers them from
    /// `Bundle.module` before the first view renders. The fallback stacks below are not decoration:
    /// PNG and PDF export run outside that registration, and any face that fails to register lands
    /// here. They are named families with close metrics, not a shrug at the system font.
    public enum Typography {

        /// The three stacks a theme draws with, in preference order.
        public struct Faces: Sendable, Equatable, Hashable {
            public let prose: [String]
            public let ui: [String]
            public let numeric: [String]

            /// Helvetica Neue is the closest grotesque that ships with macOS — a comparable x-height
            /// and a similarly neutral tone; Arial is the floor. Menlo is the monospace every Mac
            /// has and is metrically close enough to Plex Mono that a column does not reflow;
            /// Courier New is the floor.
            public static let plex = Faces(
                prose: ["IBM Plex Sans", "Helvetica Neue", "Arial"],
                ui: ["IBM Plex Sans", "Helvetica Neue", "Arial"],
                numeric: ["IBM Plex Mono", "Menlo", "Courier New"])

            var all: [[String]] { [prose, ui, numeric] }
        }

        /// Every stack any theme can ask for. Deliberately independent of the current theme:
        /// `FontRegistration` consults it while it is registering, from whichever thread it was
        /// called on, and must not have to know what is selected.
        static var allStacks: [[String]] {
            var seen: [[String]] = []
            for theme in Theme.allCases {
                for stack in theme.typeface.all where !seen.contains(stack) { seen.append(stack) }
            }
            return seen
        }

        static var proseStack: [String] { Design.theme.typeface.prose }
        static var uiStack: [String] { Design.theme.typeface.ui }
        static var numericStack: [String] { Design.theme.typeface.numeric }

        static var proseFamily: String { resolvedFamily(in: proseStack) }
        static var uiFamily: String { resolvedFamily(in: uiStack) }
        static var numericFamily: String { resolvedFamily(in: numericStack) }

        /// Whether CoreText can resolve a family by name right now.
        static func isAvailable(_ family: String) -> Bool {
            NSFont(name: family, size: 12) != nil
        }

        /// The first name in a stack the machine can actually render, or the last as a final resort.
        static func firstAvailable(in stack: [String]) -> String {
            stack.first(where: isAvailable) ?? stack[stack.count - 1]
        }

        /// `firstAvailable`, memoised. Resolving a family goes out to `fontd` over XPC, and a font is
        /// built for every run of text in every body pass; asking the daemon that often would be
        /// absurd. Guarded the same way `FontRegistration` guards its own cache, and for the same
        /// reason — the work inside makes XPC calls, so a waiter should sleep rather than spin.
        private nonisolated(unsafe) static var familyCache: [String: String] = [:]
        private static let familyCacheLock = NSLock()

        static func resolvedFamily(in stack: [String]) -> String {
            let key = stack.joined(separator: "\u{1}")
            familyCacheLock.lock()
            defer { familyCacheLock.unlock() }
            if let cached = familyCache[key] { return cached }
            let resolved = firstAvailable(in: stack)
            familyCache[key] = resolved
            return resolved
        }

        /// What a given family degrades to if it will not register. Used in the log line so the
        /// message says what the reader will actually see, not just what went wrong.
        static func fallbackName(for family: String) -> String {
            let stack = allStacks.first { $0.first == family } ?? Faces.plex.ui
            return firstAvailable(in: Array(stack.dropFirst()))
        }

        public static func prose(_ size: CGFloat = 15.5, weight: Font.Weight = .regular) -> Font {
            .custom(proseFamily, size: size, relativeTo: .body).weight(weight)
        }

        public static func ui(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
            .custom(uiFamily, size: size, relativeTo: .body).weight(weight)
        }

        /// Uppercase, letterspaced, small: the label above a control or a column.
        public static var label: Font {
            .custom(uiFamily, size: 11, relativeTo: .caption).weight(.medium)
        }

        /// Tabular figures, for anything a reader compares down a column. Plex Mono rather than the
        /// system monospace, so a column of numbers is in the same voice as the prose beside it.
        public static func numeric(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
            .custom(numericFamily, size: size, relativeTo: .body).weight(weight)
        }
    }

    // MARK: - Metrics

    public enum Metric {
        /// The side regions, at the width they are drawn when they are open. They no longer set the
        /// window's minimum — every one of them collapses to `collapsedRegionWidth` — so these are
        /// what a region costs when you have asked for it, not what the frame costs you always.
        public static let librarySidebarWidth: CGFloat = 220
        /// Open from the first launch, so it is what the bench pays most for: 340 holds the band's
        /// question, the log and the field, and leaves the bench 824 at the 1440 default.
        public static let conversationRailWidth: CGFloat = 340
        public static let partsLedgerWidth: CGFloat = 230
        public static let headerHeight: CGFloat = 56
        public static let transportHeight: CGFloat = 84

        /// A collapsed region: wide enough for a rotated title, a count and the control that brings
        /// it back, and nothing else. A region never disappears entirely — the strip is the way back.
        public static let collapsedRegionWidth: CGFloat = 44

        /// What one surface actually needs to be worth opening, and therefore what the window's
        /// minimum is built from rather than from the sum of the furniture.
        ///
        /// The Chop lane is the demanding one: a waveform with draggable slice markers, a four-by-four
        /// pad grid with a classification on each pad, the per-slice controls under it and the
        /// re-groove picker beside them. Below this it is not cramped, it is unusable.
        public static let surfaceMinimumWidth: CGFloat = 640
        public static let surfaceMinimumHeight: CGFloat = 460

        public static let corner: CGFloat = 3
        public static let hairline: CGFloat = 1

        /// A control a finger or a hurried cursor has to hit.
        public static let controlHeight: CGFloat = 36
        public static let chipHeight: CGFloat = 28
        /// A label you read but do not aim at: the verb on a parts-ledger row, which is part of the
        /// row's own hit area rather than a control of its own. Deliberately below `chipHeight` so it
        /// cannot be mistaken for something separately clickable.
        public static let tagHeight: CGFloat = 20

        public static let gutter: CGFloat = 18
        public static let inset: CGFloat = 18
    }

    /// How many surfaces are drawn at once: the one you are working in, plus one you pinned.
    ///
    /// The bench itself has no ceiling any more. It held three and closed the oldest to make room,
    /// which a person experienced as surfaces vanishing from behind them — forty times in a few
    /// days of sessions — and answered by closing everything to get control back. Now there is one
    /// surface of each kind, it stays open until you close it, and turning it to another part is its
    /// title's menu.
    public static let maximumVisibleSurfaces = 2
}

extension Color {
    /// One definition per colour, light and dark together, so no token can exist in only one theme.
    init(hex light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 0xff) / 255,
                           green: Double((value >> 8) & 0xff) / 255,
                           blue: Double(value & 0xff) / 255,
                           alpha: 1)
        })
    }
}

// MARK: - Controls, as an offscreen render draws them

/// A text field in an offscreen render. The native field is AppKit-backed and `ImageRenderer`
/// draws it as a block, so a render shows the text it holds in a field's border instead, where the
/// field is. Only renders use it; the app always has the real field.
struct RenderedField: View {
    let text: String
    let placeholder: String
    var font: Font = Design.Typography.ui(12.5)
    var alignment: Alignment = .leading

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(font)
            .foregroundStyle(text.isEmpty ? Design.Palette.inkTertiary : Design.Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: alignment)
            .background(Design.Palette.panel, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
    }
}

/// A stepper in an offscreen render: its label, and the pair of arrows beside it.
struct RenderedStepper<Label: View>: View {
    @ViewBuilder let label: Label

    var body: some View {
        HStack(spacing: 6) {
            label
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Design.Palette.inkSecondary)
                .frame(width: 16, height: 20)
                .background(Design.Palette.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
        }
    }
}
