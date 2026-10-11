import AppKit
import CoreText
import Foundation
import Observation
import Synchronization
import SwiftUI

/// The instrument's visual identity: one look, drawn in one of five palettes.
///
/// The look is fixed — the type, the controls, the metrics and the layout are Studio's, and there is
/// one way of drawing each thing. What can be chosen is colour: `Scheme` picks a complete set of
/// tokens, and `Design.Palette` reads through it, so a surface still writes `Design.Palette.accent`
/// and never knows which palette is current.
///
/// Switching is live. `SchemeStore` is `Observable`, and every token read goes through it, so a read
/// inside a SwiftUI `body` registers a dependency on the current palette the same way a read of any
/// other observable property does. Choosing a palette therefore invalidates every body that paints —
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
    ///
    /// A pair may carry an opacity per appearance. Studio's control fills are translucent greys, the
    /// way Apple's own are, so that one fill reads as a step up from whatever ground it lands on —
    /// paper, a panel, the band's column — instead of being right on one of them and wrong on the rest.
    public struct ColorPair: Sendable, Equatable, Hashable {
        public let light: UInt32
        public let dark: UInt32
        public let lightAlpha: Double
        public let darkAlpha: Double

        public init(_ light: UInt32, _ dark: UInt32) {
            self.init(light, dark, lightAlpha: 1, darkAlpha: 1)
        }

        public init(_ light: UInt32, _ dark: UInt32, lightAlpha: Double, darkAlpha: Double) {
            self.light = light
            self.dark = dark
            self.lightAlpha = lightAlpha
            self.darkAlpha = darkAlpha
        }

        /// The same value in both appearances: a colour that belongs to a plate, a lane or a lamp
        /// rather than to the ground under it.
        public static func fixed(_ value: UInt32) -> ColorPair { ColorPair(value, value) }

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
        let made = Color(hex: pair.light, dark: pair.dark, lightAlpha: pair.lightAlpha, darkAlpha: pair.darkAlpha)
        colorCache[pair] = made
        return made
    }

    // MARK: - Palettes

    /// The palettes, as the View menu's Palette list offers them.
    ///
    /// Auto, Light and Dark are one palette in its two appearances. Mid Dark and Vibrant are each
    /// drawn for a dark window only, so choosing one sets the window dark as well: menus, popovers
    /// and fields go dark with the rest.
    ///
    /// There were themes before these — Notebook, Petrol and last Cool Neutral, each with its own
    /// way of drawing a control. A second look meant every control was drawn twice, and what was
    /// wanted from a choice was colour, so the look is Studio's alone and the choice is the palette.
    /// A choice remembered from then opens in Auto.
    public enum Scheme: String, CaseIterable, Identifiable, Sendable {
        /// Light or dark, as macOS is set.
        case system
        case light
        case dark
        /// Charcoal: between Light and Dark, nearer Dark. The panels are a grey you can see, the
        /// text is light, the plates stay black — Logic's and Ableton's mid greys.
        case mid
        /// Near-black, with the music's colours at full strength. The accent is the colour of the
        /// part being worked on — a groove's gold in the Grid, a tune's blue in the Piano roll — and
        /// the transport's display glows in the colour of the section that is playing.
        case vibrant

        public var id: String { rawValue }

        /// What the View menu calls it.
        public var displayName: String {
            switch self {
            case .system: return "Auto"
            case .light: return "Light"
            case .dark: return "Dark"
            case .mid: return "Mid Dark"
            case .vibrant: return "Vibrant"
            }
        }

        /// One line on what it is, for the command palette.
        public var summary: String {
            switch self {
            case .system: return "Light or dark, as macOS is"
            case .light: return "Light panels, dark text"
            case .dark: return "Near-black panels, light text"
            case .mid: return "Charcoal panels, light text"
            case .vibrant: return "Near-black, coloured by what you work on"
            }
        }

        public var palette: Palette.Values {
            switch self {
            case .system, .light, .dark: return Palette.studio
            case .mid: return Palette.mid
            case .vibrant: return Palette.vibrant
            }
        }

        /// What `NSApp.appearance` is set to; nil hands it back to the system.
        public var appearanceName: NSAppearance.Name? {
            switch self {
            case .system: return nil
            case .light: return .aqua
            case .dark, .mid, .vibrant: return .darkAqua
            }
        }

        /// Whether the accent, a selected row's tint and a waveform's trace take the hue of the part
        /// being worked on.
        public var followsWork: Bool { self == .vibrant }

        /// Whether the music's colours are carried further than a mark: a part's colour washed
        /// across its row, a section's filling its block, the display lit by the section playing.
        public var isVivid: Bool { self == .vibrant }

        /// ⌃⌘1–5, in the order the menu lists them. Plain ⌘1–7 are the surfaces.
        public var shortcut: Character {
            Character("\((Scheme.allCases.firstIndex(of: self) ?? 0) + 1)")
        }
    }

    // MARK: - The current palette

    /// Holds the palette, and the hue of the part being worked on, and tells SwiftUI when either
    /// changes.
    ///
    /// `Observable` by hand rather than by macro, for one reason: the macro's storage is not
    /// `Sendable`, and this object is a process-wide `let` read from whichever thread happens to be
    /// evaluating a view. `ObservationRegistrar` is `Sendable` and `Mutex` makes the values so, which
    /// leaves the whole thing safely shared without a `nonisolated(unsafe)` escape hatch. The
    /// registrar calls are what SwiftUI's tracking actually keys on, so observation behaves exactly
    /// as it would with the macro.
    public final class SchemeStore: Observable, Sendable {
        private let registrar = ObservationRegistrar()
        private let storage: Mutex<Scheme>
        private let work = Mutex<Int?>(nil)

        init(_ initial: Scheme) { storage = Mutex(initial) }

        public var scheme: Scheme {
            get {
                registrar.access(self, keyPath: \.scheme)
                return storage.withLock { $0 }
            }
            set {
                registrar.withMutation(of: self, keyPath: \.scheme) {
                    storage.withLock { $0 = newValue }
                }
            }
        }

        /// One of the eight lane hues — the part being worked on — or nil when what fills the bench
        /// is not a part. Only Vibrant reads it, so in the other palettes a change repaints nothing,
        /// and setting the value it already has does not count as a change.
        public var workHue: Int? {
            get {
                registrar.access(self, keyPath: \.workHue)
                return work.withLock { $0 }
            }
            set {
                guard work.withLock({ $0 }) != newValue else { return }
                registrar.withMutation(of: self, keyPath: \.workHue) {
                    work.withLock { $0 = newValue }
                }
            }
        }
    }

    /// Where the choice is remembered between launches.
    public static let schemeDefaultsKey = "design.palette"

    /// Where Light or Dark was remembered before there were palettes: the same choice now, carried
    /// over the first time the app opens without a palette remembered.
    public static let appearanceDefaultsKey = "design.appearance"

    /// The palette the app opens in when nothing has been chosen yet.
    public static let defaultScheme = Scheme.system

    public static let store = SchemeStore(renderScheme ?? storedScheme())

    /// Under `MRROBOTO_RENDER`, `MRROBOTO_PALETTE` names the palette the renders are drawn in, so the
    /// same frames can be drawn in each and laid side by side.
    static let renderScheme: Scheme? = isOffscreenRender
        ? ProcessInfo.processInfo.environment["MRROBOTO_PALETTE"].flatMap(Scheme.init(rawValue:))
        : nil

    /// The current palette. Reading this inside a `body` is what makes a switch repaint.
    public static var scheme: Scheme { store.scheme }

    /// What `UserDefaults` remembers, or the default if it remembers nothing usable.
    static func storedScheme(_ defaults: UserDefaults = .standard) -> Scheme {
        if let raw = defaults.string(forKey: schemeDefaultsKey) {
            return Scheme(rawValue: raw) ?? defaultScheme
        }
        return defaults.string(forKey: appearanceDefaultsKey).flatMap(Scheme.init(rawValue:)) ?? defaultScheme
    }

    /// Choose a palette: repaint, remember it, and set the window light or dark to suit it.
    @MainActor
    public static func select(_ scheme: Scheme, defaults: UserDefaults = .standard) {
        store.scheme = scheme
        defaults.set(scheme.rawValue, forKey: schemeDefaultsKey)
        applyAppearance()
    }

    /// Called once at launch, before the first window is ordered front, and again on every choice.
    /// `NSApp` rather than `NSApplication.shared` so this is a no-op in a test process instead of
    /// conjuring an application object.
    @MainActor
    public static func applyAppearance() {
        guard let app = NSApp else { return }
        app.appearance = scheme.appearanceName.flatMap { NSAppearance(named: $0) }
    }

    /// The hue of the part being worked on — a lane index, from `PartHue` — or nil for a surface
    /// that is not about one part. The frame calls this as the bench changes; Vibrant draws with it.
    @MainActor
    public static func follow(hue: Int?) {
        store.workHue = hue
    }

    // MARK: - Colour

    /// Paper, panel and ink, per palette, and the colours with one meaning each. The token names
    /// are the contract: a surface asks for `Design.Palette.sounding` and gets whichever orange the
    /// current palette defines for "this is making sound".
    public enum Palette {

        /// Every token, once, for one palette. Adding a token here forces every palette to define it
        /// — which is the point of the struct.
        public struct Values: Sendable, Equatable, Hashable {
            // The ground and the inks.
            public let paper: ColorPair
            public let panel: ColorPair
            public let panelAlt: ColorPair
            /// A card, a popover, a title row: the step above the ground it sits on.
            public let raised: ColorPair
            public let ink: ColorPair
            public let inkSecondary: ColorPair
            public let inkTertiary: ColorPair
            /// Placeholder and disabled text only: the one ink allowed under the contrast floor.
            public let inkQuiet: ColorPair
            public let line: ColorPair
            public let lineStrong: ColorPair

            // A control's fill, at rest, under the pointer and chosen.
            public let fill: ColorPair
            public let hover: ColorPair
            public let selected: ColorPair

            // What is chosen.
            public let accent: ColorPair
            public let accentSoft: ColorPair
            /// Text or a mark that stands out from its neighbours without being a choice: ink, since
            /// the accent means chosen and nothing else.
            public let emphasis: ColorPair

            // Fixed meanings.
            /// A critic's finding, a caution, a notice: never decoration.
            public let warn: ColorPair
            public let warnSoft: ColorPair
            /// Record, a failure, a destructive action.
            public let danger: ColorPair
            public let dangerSoft: ColorPair
            /// What is making sound: the playhead while it moves, a lit pad, a part auditioning.
            public let sounding: ColorPair
            /// The same, as text on the ground.
            public let soundingInk: ColorPair
            /// Text on a `sounding` fill.
            public let onSounding: ColorPair
            public let solo: ColorPair
            public let mute: ColorPair
            /// Kept, in the song, saved.
            public let ok: ColorPair

            // Plates: dark in both appearances.
            /// The dark plate a waveform or pitch trace is drawn on.
            public let plate: ColorPair
            public let trace: ColorPair
            /// The transport display: its values, its labels, and its ground while recording.
            public let lcdInk: ColorPair
            public let lcdLabel: ColorPair
            public let lcdRecording: ColorPair
            public let lcdRecordingInk: ColorPair

            /// Eight hues for the music itself: drum lanes by class, sections by kind. Lightness
            /// alternates from one to the next, so neighbours stay apart for a colour-blind eye, and
            /// none of them is orange, so the sounding orange stays the only one on screen.
            public let lanes: [ColorPair]

            /// The tokens with their names, for anything that has to walk the whole set — the tests
            /// that check every palette's contrast and the hue of every neutral, mainly.
            public var tokens: [(name: String, pair: ColorPair)] {
                [("paper", paper), ("panel", panel), ("panelAlt", panelAlt), ("raised", raised),
                 ("ink", ink), ("inkSecondary", inkSecondary), ("inkTertiary", inkTertiary), ("inkQuiet", inkQuiet),
                 ("line", line), ("lineStrong", lineStrong),
                 ("fill", fill), ("hover", hover), ("selected", selected),
                 ("accent", accent), ("accentSoft", accentSoft), ("emphasis", emphasis),
                 ("warn", warn), ("warnSoft", warnSoft), ("danger", danger), ("dangerSoft", dangerSoft),
                 ("sounding", sounding), ("soundingInk", soundingInk), ("onSounding", onSounding),
                 ("solo", solo), ("mute", mute), ("ok", ok),
                 ("plate", plate), ("trace", trace),
                 ("lcdInk", lcdInk), ("lcdLabel", lcdLabel), ("lcdRecording", lcdRecording),
                 ("lcdRecordingInk", lcdRecordingInk)]
                    + lanes.enumerated().map { ("lane\($0.offset)", $0.element) }
            }

            /// The subset that is a grey rather than a colour: everything the frame is built out of
            /// before an accent or a warning is spent. These are the ones a palette can quietly get
            /// wrong by letting them drift warm.
            public static let neutralTokenNames = ["paper", "panel", "panelAlt", "raised", "ink",
                                                   "inkSecondary", "inkTertiary", "inkQuiet",
                                                   "line", "lineStrong", "fill", "hover", "selected"]

            /// Kick, snare, closed hat, open hat, clap, perc, toms, cymbal — the order `LaneClass`
            /// counts in, and the order sections borrow them in. Lightness alternates down the list
            /// (OKLCH L 60, 74, 82, 68, 64, 76, 58, 80 in dark), which keeps every pair of neighbours
            /// at least ΔE 9.6 apart under simulated deuteranopia; a palette at one lightness let
            /// two of them fall under 1. The light-appearance values are a step deeper, so a hat's
            /// yellow still reads as a filled step on a white panel.
            static let laneHues: [ColorPair] = [
                ColorPair(0xc0433f, 0xca5551),
                ColorPair(0x2f8fc4, 0x5eb6e6),
                ColorPair(0xb89e1a, 0xd8c65a),
                ColorPair(0x1e8f84, 0x2baea1),
                ColorPair(0x8456b8, 0x9f76cb),
                ColorPair(0x4e9f52, 0x79c77c),
                ColorPair(0x9c3f78, 0xaf578c),
                ColorPair(0x6e8dcf, 0xa8beec),
            ]
        }

        // MARK: Studio

        /// The instrument's palette, built the way the music apps people trust build theirs.
        ///
        /// **The ground is a ramp, not a set of boxes.** Paper, the alternate panel, the panel and a
        /// raised step sit a few lightness points apart — Logic's own grounds step 2–3.5 L* at a time
        /// — and a region is told from its neighbour by that step rather than by a line drawn round
        /// it. The cast is faintly cool, as Apple's is: blue leads red by a few units, never by the
        /// eight the old dark panel carried.
        ///
        /// **Control fills are translucent.** `fill`, `hover` and `selected` are one grey (Apple's
        /// #767680 in light, a lighter one in dark) at three opacities, so each is the same step up
        /// from paper, from a panel or from the band's column.
        ///
        /// **Every colour has one job.** The accent is what is chosen: a selection, a focus ring, the
        /// one primary button, a link — #3264C4, Carbon's blue with its chroma taken down, which is
        /// what the app uses when the person's system accent is Multicolor. Orange is what is sounding:
        /// the TR-808's step-key orange the app icon is drawn in. Red is record and failure. Amber is
        /// a critic's finding, which used to be red and read as an error. Solo is yellow and mute a
        /// cyan-blue, as on Logic's strips.
        ///
        /// **The plates stay dark in both appearances.** The waveform's plate and the transport's
        /// display are a piece of equipment, not a page: Logic's display is #0E1012 with #CDE7FF
        /// values, and so is this one.
        ///
        /// Contrast, measured: ink on paper 15.3:1 light and 15.4:1 dark; `inkTertiary` 4.6:1 on
        /// light paper (the old one was 2.6:1) and 5.7:1 on dark; the accent 4.8:1 on light paper
        /// and 9.5:1 on dark.
        static let studio = Values(
            paper: ColorPair(0xeceef1, 0x0f0f11),
            panel: ColorPair(0xffffff, 0x18181b),
            panelAlt: ColorPair(0xf5f6f8, 0x141416),
            raised: ColorPair(0xffffff, 0x1f1f23),
            ink: ColorPair(0x16181b, 0xe6e6eb),
            inkSecondary: ColorPair(0x555b63, 0xb4b4bc),
            inkTertiary: ColorPair(0x656c75, 0x8c8c95),
            inkQuiet: ColorPair(0xa0a6ad, 0x5a5a62),
            line: ColorPair(0xdfe2e7, 0x2c2c31),
            lineStrong: ColorPair(0xc4c9d0, 0x3a3a40),
            fill: ColorPair(0x767680, 0x8e8e96, lightAlpha: 0.08, darkAlpha: 0.14),
            hover: ColorPair(0x767680, 0x8e8e96, lightAlpha: 0.13, darkAlpha: 0.2),
            selected: ColorPair(0x767680, 0x8e8e96, lightAlpha: 0.2, darkAlpha: 0.3),
            accent: ColorPair(0x3264c4, 0x8bb9fd),
            accentSoft: ColorPair(0xe8eefb, 0x21304a),
            emphasis: ColorPair(0x16181b, 0xe6e6eb),
            warn: ColorPair(0x8a5a00, 0xf1ba4b),
            warnSoft: ColorPair(0xfbf1dc, 0x33280f),
            danger: ColorPair(0xc42b27, 0xff6b61),
            dangerSoft: ColorPair(0xfbe5e4, 0x3a1716),
            sounding: .fixed(0xf97f23),
            soundingInk: ColorPair(0xb0500c, 0xff9a4d),
            onSounding: .fixed(0x24160a),
            solo: ColorPair(0xf2c200, 0xffd60a),
            mute: ColorPair(0x4299bd, 0x4fa9cf),
            ok: ColorPair(0x2b7a3b, 0x4cc56a),
            plate: ColorPair(0x0e1012, 0x0b0c0e),
            trace: ColorPair(0x6fa8e6, 0x8cbcf0),
            lcdInk: .fixed(0xcde7ff),
            lcdLabel: .fixed(0x7e93a8),
            lcdRecording: .fixed(0x220d0c),
            lcdRecordingInk: .fixed(0xffc4bf),
            lanes: Values.laneHues)

        // MARK: Mid Dark

        /// Charcoal, with light text: between Studio's two appearances, nearer the dark one.
        ///
        /// **The ground sits where a mid grey can still carry text.** A true middle grey leaves no
        /// room under body text for a quieter ink, so the ramp is set lower: paper at L* 29, the
        /// panel at 33 and a raised step at 38, four points apart as Studio's dark steps are, where
        /// Studio's dark paper is at 4. Ink is 9.0:1 on the paper, the secondary ink 6.7:1 and the
        /// tertiary 4.5:1.
        ///
        /// **Every colour is lifted to stand off charcoal.** The accent, the meanings and the eight
        /// lanes are Studio's dark values raised in lightness (OKLCH +0.06, +0.08 for the three
        /// darkest lanes), so a red kick step or a magenta section still reads on a grey that is
        /// thirty points lighter than the one they were drawn for.
        ///
        /// **The plates stay black.** The waveform's plate and the transport's display are the
        /// darkest things on screen, set into the grey the way a display is set into a desk.
        ///
        /// One appearance only: every pair is the same in both, and choosing it sets the window dark.
        static let mid = Values(
            paper: .fixed(0x444449),
            panel: .fixed(0x4e4e54),
            panelAlt: .fixed(0x49494e),
            raised: .fixed(0x58585e),
            ink: .fixed(0xf6f6f8),
            inkSecondary: .fixed(0xd6d6dc),
            inkTertiary: .fixed(0xb0b0b8),
            inkQuiet: .fixed(0x88888f),
            line: .fixed(0x5f5f66),
            lineStrong: .fixed(0x74747b),
            fill: ColorPair(0xa8a8b0, 0xa8a8b0, lightAlpha: 0.14, darkAlpha: 0.14),
            hover: ColorPair(0xa8a8b0, 0xa8a8b0, lightAlpha: 0.22, darkAlpha: 0.22),
            selected: ColorPair(0xa8a8b0, 0xa8a8b0, lightAlpha: 0.32, darkAlpha: 0.32),
            accent: .fixed(0xaed0ff),
            accentSoft: .fixed(0x44526b),
            emphasis: .fixed(0xf6f6f8),
            warn: .fixed(0xf8c962),
            warnSoft: .fixed(0x5a4c2c),
            danger: .fixed(0xff958c),
            dangerSoft: .fixed(0x5e3b3b),
            sounding: .fixed(0xf97f23),
            soundingInk: .fixed(0xffb073),
            onSounding: .fixed(0x24160a),
            solo: .fixed(0xffd60a),
            mute: .fixed(0x74c3e6),
            ok: .fixed(0x72dc90),
            plate: .fixed(0x131416),
            trace: .fixed(0x8cbcf0),
            lcdInk: .fixed(0xcde7ff),
            lcdLabel: .fixed(0x7e93a8),
            lcdRecording: .fixed(0x220d0c),
            lcdRecordingInk: .fixed(0xffc4bf),
            lanes: [0xe76d67, 0x70cafb, 0xecda6b, 0x41c2b4, 0xb88ee7, 0x8bdb8d, 0xcb6ea5, 0xbcd1fe].map(ColorPair.fixed))

        // MARK: Vibrant

        /// Near-black, with the music's colours at full strength.
        ///
        /// **The ground is darker than Studio's dark and has no colour in it.** Paper at L* 2.5 and
        /// the panel at 5.6, with the same faint cool cast as the other greys: a saturated dark
        /// ground was tried once, as Petrol, and it was the colour of everything. Here the colour is
        /// spent on the work.
        ///
        /// **The eight hues are turned up.** The lanes keep their order and their alternating
        /// lightness (OKLCH L 0.68 to 0.88), with chroma taken as far as sRGB allows, and every one
        /// is bright enough to be the accent: each reads at 4.5:1 or better as text on the paper and
        /// the panel, and under the panel as a button's label.
        ///
        /// **The accent is the work's.** In the Grid it is the groove's gold, in the Piano roll the
        /// line's violet or the tune's blue, on the Chop lane the sample's magenta, and the waveform's
        /// trace and a selected row's tint follow it (`Design.follow(hue:)`). With nothing on the
        /// bench that is a part, it is this electric blue — Studio's own, turned up.
        ///
        /// One appearance only: every pair is the same in both, and choosing it sets the window dark.
        static let vibrant = Values(
            paper: .fixed(0x09090b),
            panel: .fixed(0x121215),
            panelAlt: .fixed(0x0e0e11),
            raised: .fixed(0x1a1a1f),
            ink: .fixed(0xf4f4f8),
            inkSecondary: .fixed(0xbdbdc8),
            inkTertiary: .fixed(0x8d8d99),
            inkQuiet: .fixed(0x585862),
            line: .fixed(0x29292f),
            lineStrong: .fixed(0x37373f),
            fill: ColorPair(0x8e8e9a, 0x8e8e9a, lightAlpha: 0.14, darkAlpha: 0.14),
            hover: ColorPair(0x8e8e9a, 0x8e8e9a, lightAlpha: 0.2, darkAlpha: 0.2),
            selected: ColorPair(0x8e8e9a, 0x8e8e9a, lightAlpha: 0.3, darkAlpha: 0.3),
            accent: .fixed(0x5c8dff),
            accentSoft: .fixed(0x18233f),
            emphasis: .fixed(0xf4f4f8),
            warn: .fixed(0xffc247),
            warnSoft: .fixed(0x3a2c0c),
            danger: .fixed(0xff5a52),
            dangerSoft: .fixed(0x3d1414),
            sounding: .fixed(0xf97f23),
            soundingInk: .fixed(0xff9d4f),
            onSounding: .fixed(0x24160a),
            solo: .fixed(0xffd60a),
            mute: .fixed(0x4fb3e8),
            ok: .fixed(0x3ddc84),
            plate: .fixed(0x060608),
            trace: .fixed(0x7cc4ff),
            lcdInk: .fixed(0xe8f2ff),
            lcdLabel: .fixed(0x8696aa),
            lcdRecording: .fixed(0x2a0b0a),
            lcdRecordingInk: .fixed(0xffc4bf),
            lanes: [0xff4d6a, 0x36c5ff, 0xf5d63a, 0x1fd6c4, 0xb083ff, 0x4fe07f, 0xff4fc0, 0xa6b9ff].map(ColorPair.fixed))

        /// A selected row's tint in Vibrant when the accent is a lane's: the lane at 18% over the
        /// panel, which keeps the lane itself at 4.5:1 or better on it.
        static func workSoft(_ lane: ColorPair, over panel: ColorPair) -> ColorPair {
            func mix(_ base: UInt32, _ top: UInt32) -> UInt32 {
                let channel = { (shift: UInt32) -> UInt32 in
                    let b = Double((base >> shift) & 0xff), t = Double((top >> shift) & 0xff)
                    return UInt32((b + (t - b) * 0.18).rounded())
                }
                return channel(16) << 16 | channel(8) << 8 | channel(0)
            }
            return ColorPair(mix(panel.light, lane.light), mix(panel.dark, lane.dark))
        }

        // MARK: The tokens themselves

        /// The palette in use.
        static var current: Values { Design.scheme.palette }

        public static var paper: Color { current.paper.color }
        public static var panel: Color { current.panel.color }
        public static var panelAlt: Color { current.panelAlt.color }
        public static var raised: Color { current.raised.color }

        public static var ink: Color { current.ink.color }
        public static var inkSecondary: Color { current.inkSecondary.color }
        public static var inkTertiary: Color { current.inkTertiary.color }
        public static var inkQuiet: Color { current.inkQuiet.color }

        public static var line: Color { current.line.color }
        public static var lineStrong: Color { current.lineStrong.color }

        public static var fill: Color { current.fill.color }
        public static var hover: Color { current.hover.color }
        public static var selected: Color { current.selected.color }

        /// The lane the accent takes in a palette that follows the work, for the work's hue.
        static func workLane(in scheme: Scheme, hue: Int?) -> ColorPair? {
            guard scheme.followsWork, let hue else { return nil }
            let lanes = scheme.palette.lanes
            return lanes[((hue % lanes.count) + lanes.count) % lanes.count]
        }

        /// The same, now. The work's hue is read only in a palette that follows it, so in the others
        /// a change of surface does not repaint every body that reads the accent.
        private static var workLane: ColorPair? {
            let scheme = Design.scheme
            guard scheme.followsWork else { return nil }
            return workLane(in: scheme, hue: Design.store.workHue)
        }

        /// What is chosen. Spend it on one thing per surface: the selected candidate, the active
        /// section, the one primary button. It is the person's system accent unless they chose
        /// Multicolor, and in Vibrant the colour of the part being worked on.
        public static var accent: Color {
            if let lane = workLane { return lane.color }
            if let system = SystemAccent.accent(for: Design.scheme) { return system }
            return current.accent.color
        }

        public static var accentSoft: Color {
            if let lane = workLane { return workSoft(lane, over: current.panel).color }
            if let system = SystemAccent.soft(for: Design.scheme) { return system }
            return current.accentSoft.color
        }

        /// Stands out from its neighbours without claiming to be chosen.
        public static var emphasis: Color { current.emphasis.color }

        /// A critic finding, a caution: never decoration.
        public static var warn: Color { current.warn.color }
        public static var warnSoft: Color { current.warnSoft.color }

        /// The words of a critic's finding: ink, beside an amber mark, so a finding reads as
        /// something to look at rather than as an error.
        public static var findingText: Color { ink }

        /// Record, a failure, a destructive action.
        public static var danger: Color { current.danger.color }
        public static var dangerSoft: Color { current.dangerSoft.color }

        /// What is making sound, and only that.
        public static var sounding: Color { current.sounding.color }
        public static var soundingInk: Color { current.soundingInk.color }
        public static var onSounding: Color { current.onSounding.color }

        public static var solo: Color { current.solo.color }
        public static var mute: Color { current.mute.color }
        public static var ok: Color { current.ok.color }

        /// The dark plate a waveform or pitch trace is drawn on.
        public static var plate: Color { current.plate.color }
        /// The waveform on it — in Vibrant, in the colour of the part being worked on.
        public static var trace: Color { (workLane ?? current.trace).color }

        public static var lcdInk: Color { current.lcdInk.color }
        public static var lcdLabel: Color { current.lcdLabel.color }
        public static var lcdRecording: Color { current.lcdRecording.color }
        public static var lcdRecordingInk: Color { current.lcdRecordingInk.color }

        /// One hue of the eight, by index, wrapping.
        public static func lane(_ index: Int) -> Color {
            let lanes = current.lanes
            return lanes[((index % lanes.count) + lanes.count) % lanes.count].color
        }
    }

    // MARK: - Type

    /// Three voices with a size range each, so two grotesques never meet at one size: SF Pro for
    /// every control and every line of UI at 13 pt and under, with the system's own optical sizing
    /// and tracking; IBM Plex Sans for titles at 15 pt and over, and for the transport's readout in
    /// its condensed width; and tabular figures for numbers rather than a monospace. Type is set on
    /// eight sizes — 10, 11, 12, 13, 15, 17, 22 and the readout — the eight Apple's own scale uses,
    /// where the calls across the app had asked for twenty.
    ///
    /// Plex ships with the app — see `FontRegistration`, which registers it from `Bundle.module`
    /// before the first view renders. The fallback stacks below are not decoration: PNG and PDF
    /// export run outside that registration, and any face that fails to register lands here. They
    /// are named families with close metrics, not a shrug at the system font.
    public enum Typography {

        /// The three Plex stacks, in preference order.
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

        /// Every stack the app can ask for. Deliberately a constant: `FontRegistration` consults it
        /// while it is registering, from whichever thread it was called on.
        static var allStacks: [[String]] {
            var seen: [[String]] = []
            for stack in Faces.plex.all where !seen.contains(stack) { seen.append(stack) }
            return seen
        }

        static var proseFamily: String { resolvedFamily(in: Faces.plex.prose) }
        static var uiFamily: String { resolvedFamily(in: Faces.plex.ui) }
        static var numericFamily: String { resolvedFamily(in: Faces.plex.numeric) }

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

        // MARK: The calls

        /// Reading text: a sentence, a description, a lyric.
        public static func prose(_ size: CGFloat = 15.5, weight: Font.Weight = .regular) -> Font {
            Scale.prose(size, weight: weight)
        }

        /// A control's text, a row, a value: SF at the size snapped to the scale, Regular unless
        /// asked otherwise — a uniform Medium was half of why nothing stood out.
        public static func ui(_ size: CGFloat = 13, weight: Font.Weight? = nil) -> Font {
            Scale.ui(size, weight: weight)
        }

        /// The label above a control or a column, in sentence case: `SmallLabel` sets it.
        public static var label: Font { .system(size: 11, weight: .medium) }

        /// Figures, for anything a reader compares down a column: tabular figures of the UI face.
        public static func numeric(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
            Scale.numeric(size, weight: weight)
        }

        /// The named roles, for code written against the scale rather than a size.
        public enum Role: Sendable {
            /// 10 pt: counts, timestamps, the meter's scale.
            case caption
            /// 10 pt semibold capitals: a region's name, and nothing else.
            case eyebrow
            /// 11 pt medium: the label over a control.
            case label
            /// 12 pt: descriptions, a primer's line.
            case callout
            /// 13 pt: the default.
            case body
            /// 13 pt semibold: a title among rows.
            case headline
            /// 15 pt Plex semibold: the band's question, a section head.
            case title3
            /// 17 pt Plex semibold: a surface's title.
            case title2
            /// 22 pt Plex semibold: a record's or a song's name at the top of its page.
            case title1
        }

        public static func role(_ role: Role) -> Font {
            switch role {
            case .caption: return .system(size: 10)
            case .eyebrow: return .system(size: 10, weight: .semibold)
            case .label: return .system(size: 11, weight: .medium)
            case .callout: return .system(size: 12)
            case .body: return .system(size: 13)
            case .headline: return .system(size: 13, weight: .semibold)
            case .title3: return Scale.display(15, weight: .semibold)
            case .title2: return Scale.display(17, weight: .semibold)
            case .title1: return Scale.display(22, weight: .semibold)
            }
        }

        /// The transport's readout: Plex Sans in its condensed width, tabular figures and a slashed
        /// zero, so "10.1" never jitters and an O is never a 0.
        public static func readout(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            Scale.condensed(size, weight: weight)
        }

        /// The scale: what a size asks for, and the face and weight it gets.
        enum Scale {
            /// The eight sizes, by nearest: 9.5 is a caption, 11.5 a label, 14 is body text, 16 the
            /// band's question, 19 a title.
            static func snap(_ size: CGFloat) -> CGFloat {
                switch size {
                case ..<10.75: return 10
                case ..<11.75: return 11
                case ..<12.75: return 12
                case ..<14.75: return 13
                case ..<16.5: return 15
                case ..<20: return 17
                default: return 22
                }
            }

            /// Titles take one step more weight than they asked for: a Plex Medium title was set
            /// beside Plex Medium controls, and stood apart from them by size alone.
            static func displayWeight(_ weight: Font.Weight?) -> Font.Weight {
                guard let weight, weight != .medium else { return .semibold }
                return weight == .regular ? .medium : weight
            }

            static func ui(_ size: CGFloat, weight: Font.Weight?) -> Font {
                let snapped = snap(size)
                if snapped >= 15 { return display(snapped, weight: displayWeight(weight)) }
                return .system(size: snapped, weight: weight ?? .regular)
            }

            /// Reading text is body text: 15.5 pt prose was a book's size in a tool's window. Prose
            /// asked for at a heading's size is a heading.
            static func prose(_ size: CGFloat, weight: Font.Weight) -> Font {
                switch size {
                case ..<16.5: return .system(size: 13, weight: weight)
                case ..<20: return display(15, weight: displayWeight(weight))
                default: return display(17, weight: displayWeight(weight))
                }
            }

            static func numeric(_ size: CGFloat, weight: Font.Weight) -> Font {
                let snapped = snap(size)
                // Plex Sans's default figures are already tabular: one advance for every digit.
                if snapped >= 15 { return display(snapped, weight: weight) }
                return .system(size: snapped, weight: weight).monospacedDigit()
            }

            static func display(_ size: CGFloat, weight: Font.Weight) -> Font {
                .custom(resolvedFamily(in: Faces.plex.prose), size: size, relativeTo: .title3).weight(weight)
            }

            /// Plex Sans at `wdth` 82, a weight and a slashed zero, built through CoreText because
            /// `Font.custom` cannot set a variation axis. Memoised: the transport asks every frame.
            static func condensed(_ size: CGFloat, weight: Font.Weight) -> Font {
                let key = "\(size)|\(weight.axisValue)"
                condensedLock.lock()
                defer { condensedLock.unlock() }
                if let cached = condensedCache[key] { return cached }
                let made = makeCondensed(size, weight: weight)
                condensedCache[key] = made
                return made
            }

            private nonisolated(unsafe) static var condensedCache: [String: Font] = [:]
            private static let condensedLock = NSLock()

            private static func makeCondensed(_ size: CGFloat, weight: Font.Weight) -> Font {
                let family = resolvedFamily(in: Faces.plex.prose)
                guard family == "IBM Plex Sans" else { return .custom(family, size: size).weight(weight) }
                let tag = { (code: String) -> Int in code.unicodeScalars.reduce(0) { $0 << 8 | Int($1.value) } }
                let variation: [NSNumber: NSNumber] = [
                    NSNumber(value: tag("wdth")): NSNumber(value: 82),
                    NSNumber(value: tag("wght")): NSNumber(value: weight.axisValue),
                ]
                let features: [[CFString: Any]] = [[
                    kCTFontOpenTypeFeatureTag: "zero" as CFString,
                    kCTFontOpenTypeFeatureValue: 1,
                ]]
                let attributes: [CFString: Any] = [
                    kCTFontFamilyNameAttribute: family as CFString,
                    kCTFontVariationAttribute: variation as CFDictionary,
                    kCTFontFeatureSettingsAttribute: features as CFArray,
                ]
                let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
                return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
            }
        }
    }

    // MARK: - Metrics

    /// What the controls are built to: small and dense, at the sizes Mac controls are — a 28-point
    /// button, a 22-point chip, a four-point grid of spacing. A surface runs edge to edge in the
    /// bench, and two of them share a single hairline. There is no header of the app's own: the
    /// window's toolbar is the header, and AppKit draws it outside the content.
    public enum Metric {
        /// The side regions, at the width they are drawn when they are open. They no longer set the
        /// window's minimum — every one of them collapses to `collapsedRegionWidth` — so these are
        /// what a region costs when you have asked for it, not what the frame costs you always.
        ///
        /// The band's column is open from the first launch, so it is what the bench pays most for:
        /// 340 holds the band's question, the log and the field.
        public static let conversationRailWidth: CGFloat = 340
        public static let partsLedgerWidth: CGFloat = 230
        public static let dockHeight: CGFloat = 44
        public static let transportHeight: CGFloat = 56

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

        /// A control's corner: a chip, a button, a field.
        public static let corner: CGFloat = 5
        /// A card's corner: the band's options, a popover, a well.
        public static let containerCorner: CGFloat = 10
        /// A step's or a pad's corner, which sits close to its neighbours.
        public static let cellCorner: CGFloat = 2
        public static let hairline: CGFloat = 1

        /// A control a finger or a hurried cursor has to hit.
        public static let controlHeight: CGFloat = 28
        public static let chipHeight: CGFloat = 22
        /// A label you read but do not aim at: the verb on a parts-ledger row, which is part of the
        /// row's own hit area rather than a control of its own. Deliberately below `chipHeight` so it
        /// cannot be mistaken for something separately clickable.
        public static let tagHeight: CGFloat = 18

        public static let gutter: CGFloat = 16
        public static let inset: CGFloat = 16
        /// The side columns' own margin: the band's column, the parts.
        public static let regionInset: CGFloat = 16
        /// The bench's own padding around a surface, and the gap between two: none, and a hairline.
        public static let benchPadding: CGFloat = 0
        public static let benchSpacing: CGFloat = 1
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

/// The person's accent, when they chose one in System Settings.
///
/// Read once: `AppleAccentColor` is absent from the global domain exactly when the person picked
/// Multicolor, which is the one case where macOS hands an app its own accent. A change made while
/// the app runs is picked up at the next launch.
enum SystemAccent {
    static let isChosen = UserDefaults.standard.object(forKey: "AppleAccentColor") != nil

    /// The accent, made legible on the palette's ground. macOS draws its accents for a white or a
    /// near-black window; on Mid Dark's charcoal a blue can fall under 4.5:1, so there it is
    /// lightened until it reads on the panel.
    static func accent(for scheme: Design.Scheme) -> Color? {
        guard isChosen else { return nil }
        return memo("accent.\(scheme.rawValue)") {
            let panel = scheme.palette.panel
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let accent = resolved(NSColor.controlAccentColor, in: appearance)
                return legible(accent, on: NSColor(hex: dark ? panel.dark : panel.light))
            })
        }
    }

    /// The accent laid over the palette's panel at the strength the palette's own soft accent has,
    /// resolved at draw time so it follows the appearance.
    static func soft(for scheme: Design.Scheme) -> Color? {
        guard isChosen else { return nil }
        return memo("soft.\(scheme.rawValue)") {
            let panel = scheme.palette.panel
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let ground = NSColor(hex: dark ? panel.dark : panel.light)
                let accent = resolved(NSColor.controlAccentColor, in: appearance)
                return ground.blended(withFraction: dark ? 0.24 : 0.12, of: accent) ?? accent
            })
        }
    }

    /// One colour per palette and kind, made once: a token is read hundreds of times per frame.
    /// Guarded by `lock`, the way `Design`'s own colour memo is.
    private nonisolated(unsafe) static var made: [String: Color] = [:]
    private static let lock = NSLock()

    private static func memo(_ key: String, make: () -> Color) -> Color {
        lock.lock()
        defer { lock.unlock() }
        if let color = made[key] { return color }
        let color = make()
        made[key] = color
        return color
    }

    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    /// Lightened toward white in steps until it reads at 4.5:1 on `ground`, or as far as it goes.
    static func legible(_ color: NSColor, on ground: NSColor) -> NSColor {
        func luminance(_ c: NSColor) -> Double {
            guard let c = c.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let floor = luminance(ground)
        var out = color.usingColorSpace(.sRGB) ?? color
        for _ in 0..<12 {
            let l = luminance(out)
            if (max(l, floor) + 0.05) / (min(l, floor) + 0.05) >= 4.5 || l < floor { break }
            out = out.blended(withFraction: 0.12, of: .white) ?? out
        }
        return out
    }
}

extension Font.Weight {
    /// The `wght` axis value a weight names, for building a variable instance by hand.
    var axisValue: Double {
        switch self {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
}

extension NSColor {
    /// An sRGB colour from a 0xRRGGBB value.
    convenience init(hex value: UInt32, alpha: Double = 1) {
        self.init(srgbRed: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// One definition per colour, light and dark together, so no token can exist in only one
    /// appearance.
    init(hex light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
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
