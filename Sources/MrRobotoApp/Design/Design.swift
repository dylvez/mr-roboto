import AppKit
import CoreText
import Foundation
import Observation
import Synchronization
import SwiftUI

/// The instrument's visual identity, as a set of interchangeable themes.
///
/// One `Theme` value carries every colour token, every typeface stack, the metrics the controls are
/// built to and the handful of choices that make a theme more than a palette: how a label is cased,
/// whether a control is outlined or filled, where a surface explains itself. Exactly one theme is
/// current at a time; `Design.Palette`, `Design.Typography`, `Design.Metric` and `Design.style` read
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

    // MARK: - Themes

    /// The two directions. A theme is a complete set of tokens, not a tweak on top of another one,
    /// so there is no way to add a colour to one and forget it in the other.
    ///
    /// Notebook (warm paper) and Petrol (a saturated teal ground) were retired when Studio arrived:
    /// three hand-tuned palettes tripled the work of every new token, and neither was the direction
    /// the app was going. A defaults entry naming either falls back to the default.
    public enum Theme: String, CaseIterable, Identifiable, Sendable {
        /// The instrument. A quiet ramp of near-neutral greys with no boxes drawn around panels, one
        /// accent for what is chosen, fixed meanings for what is sounding, recording, soloed and
        /// muted, and the rest of the colour spent on the music: drum lanes and sections. SF Pro for
        /// controls at the system's sizes, Plex for titles and the transport's readout.
        case studio

        /// True greys carrying a slight blue bias, white panels, near-black ink and one blue, every
        /// control outlined, IBM Plex throughout. Kept so Studio can be judged against it.
        case cool

        public var id: String { rawValue }

        /// What the View menu calls it.
        public var displayName: String {
            switch self {
            case .studio: return "Studio"
            case .cool: return "Cool Neutral"
            }
        }

        public var palette: Palette.Values {
            switch self {
            case .studio: return Palette.studio
            case .cool: return Palette.cool
            }
        }

        /// The families a theme draws with. Both use Plex — Studio for its titles and readout, Cool
        /// for everything — so the registered stacks are the same; what differs is `voice`.
        public var typeface: Typography.Faces { .plex }

        /// How the theme sets type: Plex at whatever size a call asks for, or Studio's scale.
        public var voice: Typography.Voice {
            switch self {
            case .studio: return .studio
            case .cool: return .plex
            }
        }

        public var metrics: Metric.Values {
            switch self {
            case .studio: return Metric.studio
            case .cool: return Metric.cool
            }
        }

        public var style: Style {
            switch self {
            case .studio: return Style.studio
            case .cool: return Style.cool
            }
        }

        /// Whether the accent is the one the person chose in System Settings. macOS hands an app its
        /// own accent only when the person picked Multicolor; otherwise their choice wins, as it does
        /// in every native app. Studio follows it; Cool keeps Carbon's blue.
        public var followsSystemAccent: Bool { self == .studio }
    }

    /// The choices that make a theme more than its colours. Each is read by the one or two
    /// components that draw it, never by a surface directly.
    public struct Style: Sendable, Equatable, Hashable {
        /// A label above a control set in letterspaced capitals (Cool) or in sentence case at the
        /// system's own spacing (Studio).
        public let uppercaseLabels: Bool
        /// Controls drawn as outlined boxes (Cool) or as fills that step up on hover and selection,
        /// with no stroke (Studio).
        public let filledControls: Bool
        /// A surface explains itself in a banner across its top (Cool), or in one line under its
        /// title with the whole primer behind its `?` (Studio).
        public let inlinePrimers: Bool
        /// The transport's position, tempo and key on a dark display plate.
        public let lcdTransport: Bool
        /// Drum lanes and song sections each in a hue of their own.
        public let laneColours: Bool
        /// A surface drawn as a bordered card inset in the bench (Cool), or edge to edge (Studio).
        public let surfaceCards: Bool

        static let cool = Style(uppercaseLabels: true, filledControls: false, inlinePrimers: true,
                                lcdTransport: false, laneColours: false, surfaceCards: true)
        static let studio = Style(uppercaseLabels: false, filledControls: true, inlinePrimers: false,
                                  lcdTransport: true, laneColours: true, surfaceCards: false)
    }

    /// The current theme's style.
    public static var style: Style { theme.style }

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

    /// Which generation of themes the remembered choice was made among. Version 2 is the one with
    /// Studio in it: a choice remembered from before it — which was Cool Neutral, the default then,
    /// for nearly everyone — is moved to Studio once. Choosing Cool Neutral again afterwards sticks,
    /// because a choice made now is written with the version.
    public static let themeVersionKey = "design.themeVersion"
    public static let themeVersion = 2

    /// The theme the app opens in when nothing has been chosen yet.
    public static let defaultTheme = Theme.studio

    public static let store = ThemeStore(renderTheme ?? storedTheme())

    /// Under `MRROBOTO_RENDER`, `MRROBOTO_THEME` names the theme the renders are drawn in, so the
    /// same frames can be drawn in each and laid side by side.
    static let renderTheme: Theme? = isOffscreenRender
        ? ProcessInfo.processInfo.environment["MRROBOTO_THEME"].flatMap(Theme.init(rawValue:))
        : nil

    /// The current theme. Reading this inside a `body` is what makes a switch repaint.
    public static var theme: Theme { store.theme }

    /// What `UserDefaults` remembers, or the default if it remembers nothing usable. Writes only to
    /// move a choice made before Studio existed, and only when there is one to move.
    static func storedTheme(_ defaults: UserDefaults = .standard) -> Theme {
        guard let raw = defaults.string(forKey: themeDefaultsKey) else { return defaultTheme }
        if defaults.integer(forKey: themeVersionKey) < themeVersion {
            defaults.set(themeVersion, forKey: themeVersionKey)
            defaults.set(defaultTheme.rawValue, forKey: themeDefaultsKey)
            return defaultTheme
        }
        return Theme(rawValue: raw) ?? defaultTheme
    }

    /// Choose a theme: repaint and remember it.
    @MainActor
    public static func select(_ theme: Theme, defaults: UserDefaults = .standard) {
        store.theme = theme
        defaults.set(theme.rawValue, forKey: themeDefaultsKey)
        defaults.set(themeVersion, forKey: themeVersionKey)
    }

    // MARK: - Appearance

    /// Light, dark, or whatever the system is. A theme no longer decides this: every theme is drawn
    /// for both appearances, and the person picks, as in any Mac app with an Appearance setting.
    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .system: return "Follow System Appearance"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// What `NSApp.appearance` is set to; nil hands it back to the system.
        public var name: NSAppearance.Name? {
            switch self {
            case .system: return nil
            case .light: return .aqua
            case .dark: return .darkAqua
            }
        }
    }

    /// The same shape as `ThemeStore`, for the appearance: the View menu's checkmarks read it.
    public final class AppearanceStore: Observable, Sendable {
        private let registrar = ObservationRegistrar()
        private let storage: Mutex<Appearance>

        init(_ initial: Appearance) { storage = Mutex(initial) }

        public var appearance: Appearance {
            get {
                registrar.access(self, keyPath: \.appearance)
                return storage.withLock { $0 }
            }
            set {
                registrar.withMutation(of: self, keyPath: \.appearance) {
                    storage.withLock { $0 = newValue }
                }
            }
        }
    }

    public static let appearanceDefaultsKey = "design.appearance"

    public static let appearanceStore = AppearanceStore(storedAppearance())

    public static var appearance: Appearance { appearanceStore.appearance }

    static func storedAppearance(_ defaults: UserDefaults = .standard) -> Appearance {
        defaults.string(forKey: appearanceDefaultsKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    /// Choose light, dark or the system's: remember it and put the AppKit furniture on it.
    @MainActor
    public static func select(_ appearance: Appearance, defaults: UserDefaults = .standard) {
        appearanceStore.appearance = appearance
        defaults.set(appearance.rawValue, forKey: appearanceDefaultsKey)
        applyAppearance()
    }

    /// Called once at launch, before the first window is ordered front, and again on every choice.
    /// `NSApp` rather than `NSApplication.shared` so this is a no-op in a test process instead of
    /// conjuring an application object.
    @MainActor
    public static func applyAppearance() {
        guard let app = NSApp else { return }
        app.appearance = appearance.name.flatMap { NSAppearance(named: $0) }
    }

    // MARK: - Colour

    /// Paper, panel and ink, per theme, and the colours with one meaning each. The token names are
    /// the contract: a surface asks for `Design.Palette.sounding` and gets whichever orange the
    /// current theme defines for "this is making sound".
    public enum Palette {

        /// Every token, once, for one theme. Adding a token here forces both themes to define it —
        /// which is the point of the struct.
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
            /// Text or a mark that stands out from its neighbours without being a choice: the accent
            /// in Cool, ink in Studio, where blue means chosen and nothing else.
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
            /// that check both appearances and the hue of every neutral, mainly.
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
            /// before an accent or a warning is spent. These are the ones a theme can quietly get
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
        ///
        /// The tokens Studio brought — fills, the fixed meanings, the display — are set here to
        /// whatever Cool already drew in their place, so Cool looks as it did: `sounding` is its
        /// accent, `danger` its warn, a fill its alternate panel.
        static let cool = Values(
            paper: ColorPair(0xeef0f3, 0x101315),
            panel: ColorPair(0xffffff, 0x191d21),
            panelAlt: ColorPair(0xf7f8fa, 0x15181b),
            raised: ColorPair(0xffffff, 0x191d21),
            ink: ColorPair(0x14171a, 0xe6eaee),
            inkSecondary: ColorPair(0x5a6068, 0x9aa3ac),
            inkTertiary: ColorPair(0x8f969e, 0x6a727a),
            inkQuiet: ColorPair(0x8f969e, 0x6a727a),
            line: ColorPair(0xd7dce2, 0x2c3238),
            lineStrong: ColorPair(0xc6ccd4, 0x3f4750),
            fill: ColorPair(0xf7f8fa, 0x15181b),
            hover: ColorPair(0xeef0f3, 0x101315),
            selected: ColorPair(0xdce9fb, 0x17233f),
            accent: ColorPair(0x0043ce, 0x78a9ff),
            accentSoft: ColorPair(0xdce9fb, 0x17233f),
            emphasis: ColorPair(0x0043ce, 0x78a9ff),
            warn: ColorPair(0xc21f30, 0xff8389),
            warnSoft: ColorPair(0xfadfe2, 0x2f1518),
            danger: ColorPair(0xc21f30, 0xff8389),
            dangerSoft: ColorPair(0xfadfe2, 0x2f1518),
            sounding: ColorPair(0x0043ce, 0x78a9ff),
            soundingInk: ColorPair(0x0043ce, 0x78a9ff),
            onSounding: ColorPair(0xffffff, 0x191d21),
            solo: ColorPair(0x0043ce, 0x78a9ff),
            mute: ColorPair(0x0043ce, 0x78a9ff),
            ok: ColorPair(0x5a6068, 0x9aa3ac),
            plate: ColorPair(0x14181c, 0x0a0c0e),
            trace: ColorPair(0x6fa8e6, 0x8cbcf0),
            lcdInk: .fixed(0xcde7ff),
            lcdLabel: .fixed(0x7e93a8),
            lcdRecording: .fixed(0x220d0c),
            lcdRecordingInk: .fixed(0xffc4bf),
            lanes: Values.laneHues)

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

        // MARK: The tokens themselves

        public static var paper: Color { Design.theme.palette.paper.color }
        public static var panel: Color { Design.theme.palette.panel.color }
        public static var panelAlt: Color { Design.theme.palette.panelAlt.color }
        public static var raised: Color { Design.theme.palette.raised.color }

        public static var ink: Color { Design.theme.palette.ink.color }
        public static var inkSecondary: Color { Design.theme.palette.inkSecondary.color }
        public static var inkTertiary: Color { Design.theme.palette.inkTertiary.color }
        public static var inkQuiet: Color { Design.theme.palette.inkQuiet.color }

        public static var line: Color { Design.theme.palette.line.color }
        public static var lineStrong: Color { Design.theme.palette.lineStrong.color }

        public static var fill: Color { Design.theme.palette.fill.color }
        public static var hover: Color { Design.theme.palette.hover.color }
        public static var selected: Color { Design.theme.palette.selected.color }

        /// What is chosen. Spend it on one thing per surface: the selected candidate, the active
        /// section, the one primary button. In Studio it is the person's system accent unless they
        /// chose Multicolor.
        public static var accent: Color {
            let theme = Design.theme
            if theme.followsSystemAccent, let system = SystemAccent.accent { return system }
            return theme.palette.accent.color
        }

        public static var accentSoft: Color {
            let theme = Design.theme
            if theme.followsSystemAccent, let system = SystemAccent.soft { return system }
            return theme.palette.accentSoft.color
        }

        /// Stands out from its neighbours without claiming to be chosen.
        public static var emphasis: Color { Design.theme.palette.emphasis.color }

        /// A critic finding, a caution: never decoration.
        public static var warn: Color { Design.theme.palette.warn.color }
        public static var warnSoft: Color { Design.theme.palette.warnSoft.color }

        /// The words of a critic's finding. Cool sets the whole sentence in its warn red; Studio sets
        /// it in ink beside an amber mark, so a finding reads as something to look at rather than
        /// as an error.
        public static var findingText: Color { Design.style.filledControls ? ink : warn }

        /// Record, a failure, a destructive action.
        public static var danger: Color { Design.theme.palette.danger.color }
        public static var dangerSoft: Color { Design.theme.palette.dangerSoft.color }

        /// What is making sound, and only that.
        public static var sounding: Color { Design.theme.palette.sounding.color }
        public static var soundingInk: Color { Design.theme.palette.soundingInk.color }
        public static var onSounding: Color { Design.theme.palette.onSounding.color }

        public static var solo: Color { Design.theme.palette.solo.color }
        public static var mute: Color { Design.theme.palette.mute.color }
        public static var ok: Color { Design.theme.palette.ok.color }

        /// The dark plate a waveform or pitch trace is drawn on.
        public static var plate: Color { Design.theme.palette.plate.color }
        public static var trace: Color { Design.theme.palette.trace.color }

        public static var lcdInk: Color { Design.theme.palette.lcdInk.color }
        public static var lcdLabel: Color { Design.theme.palette.lcdLabel.color }
        public static var lcdRecording: Color { Design.theme.palette.lcdRecording.color }
        public static var lcdRecordingInk: Color { Design.theme.palette.lcdRecordingInk.color }

        /// One hue of the eight, by index, wrapping.
        public static func lane(_ index: Int) -> Color {
            let lanes = Design.theme.palette.lanes
            return lanes[((index % lanes.count) + lanes.count) % lanes.count].color
        }
    }

    // MARK: - Type

    /// IBM Plex Sans for prose and for controls — one family, told apart by size and weight — and
    /// IBM Plex Mono for anything that lines up in a column. That is Cool's voice.
    ///
    /// Studio's is three voices with a size range each, so two grotesques never meet at one size:
    /// SF Pro for every control and every line of UI at 13 pt and under, with the system's own
    /// optical sizing and tracking; Plex Sans for titles at 15 pt and over, and for the transport's
    /// readout in its condensed width; and tabular figures for numbers rather than a monospace. It
    /// sets type on eight sizes — 10, 11, 12, 13, 15, 17, 22 and the readout — the eight Apple's own
    /// scale uses, where the calls across the app had asked for twenty.
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

        /// How a theme turns a call — "UI text, 11.5 pt, medium" — into a face.
        public enum Voice: Sendable, Equatable, Hashable {
            /// Plex at exactly the size asked for.
            case plex
            /// The size snapped to the scale; SF Pro at 13 and under, Plex above.
            case studio
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

        // MARK: The calls

        /// Reading text: a sentence, a description, a lyric.
        public static func prose(_ size: CGFloat = 15.5, weight: Font.Weight = .regular) -> Font {
            switch Design.theme.voice {
            case .plex: return .custom(proseFamily, size: size, relativeTo: .body).weight(weight)
            case .studio: return Scale.prose(size, weight: weight)
            }
        }

        /// A control's text, a row, a value. Without a weight it is the theme's own: Plex Medium in
        /// Cool, SF Regular in Studio — the uniform Medium was half of why nothing stood out.
        public static func ui(_ size: CGFloat = 13, weight: Font.Weight? = nil) -> Font {
            switch Design.theme.voice {
            case .plex: return .custom(uiFamily, size: size, relativeTo: .body).weight(weight ?? .medium)
            case .studio: return Scale.ui(size, weight: weight)
            }
        }

        /// The label above a control or a column: uppercase and letterspaced in Cool, sentence case
        /// in Studio. Cased and spaced by `labelText` and `labelTracking`, or by `SmallLabel`.
        public static var label: Font {
            switch Design.theme.voice {
            case .plex: return .custom(uiFamily, size: 11, relativeTo: .caption).weight(.medium)
            case .studio: return .system(size: 11, weight: .medium)
            }
        }

        /// A label's words, cased for the theme.
        public static func labelText(_ text: String) -> String {
            Design.style.uppercaseLabels ? text.uppercased() : text
        }

        /// A label's letterspacing: 1.1 under Cool's capitals, none in sentence case.
        public static var labelTracking: CGFloat { Design.style.uppercaseLabels ? 1.1 : 0 }

        /// Figures, for anything a reader compares down a column: Plex Mono in Cool, tabular figures
        /// of the UI face in Studio.
        public static func numeric(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
            switch Design.theme.voice {
            case .plex: return .custom(numericFamily, size: size, relativeTo: .body).weight(weight)
            case .studio: return Scale.numeric(size, weight: weight)
            }
        }

        /// The named roles, for code written against the scale rather than a size. Cool maps each to
        /// the size it used for the same job.
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
            switch Design.theme.voice {
            case .plex:
                switch role {
                case .caption: return ui(10, weight: .regular)
                case .eyebrow, .label: return label
                case .callout: return ui(11.5, weight: .regular)
                case .body: return ui(13, weight: .regular)
                case .headline: return ui(13, weight: .semibold)
                case .title3: return prose(15.5, weight: .medium)
                case .title2: return ui(17, weight: .medium)
                case .title1: return ui(24, weight: .medium)
                }
            case .studio:
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
        }

        /// The transport's readout: Plex Sans in its condensed width, tabular figures and a slashed
        /// zero, so "10.1" never jitters and an O is never a 0. Cool sets it in Plex Mono.
        public static func readout(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            switch Design.theme.voice {
            case .plex: return numeric(size, weight: weight)
            case .studio: return Scale.condensed(size, weight: weight)
            }
        }

        /// Studio's scale: what a size asks for, and the face and weight it gets.
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

    public enum Metric {
        /// What a theme builds its controls to.
        public struct Values: Sendable, Equatable, Hashable {
            /// A control's corner: a chip, a button, a field.
            public let corner: CGFloat
            /// A card's corner: the band's options, a popover, a well.
            public let containerCorner: CGFloat
            /// A step's or a pad's corner, which sits close to its neighbours.
            public let cellCorner: CGFloat
            public let controlHeight: CGFloat
            public let chipHeight: CGFloat
            public let tagHeight: CGFloat
            public let gutter: CGFloat
            public let inset: CGFloat
            /// The side columns' own margin: the band's column, the header.
            public let regionInset: CGFloat
            public let headerHeight: CGFloat
            public let dockHeight: CGFloat
            public let transportHeight: CGFloat
            /// The bench's own padding around a surface, and the gap between two.
            public let benchPadding: CGFloat
            public let benchSpacing: CGFloat
        }

        static let cool = Values(corner: 3, containerCorner: 3, cellCorner: 3,
                                 controlHeight: 36, chipHeight: 28, tagHeight: 20,
                                 gutter: 18, inset: 18, regionInset: 28,
                                 headerHeight: 56, dockHeight: 56, transportHeight: 84,
                                 benchPadding: 18, benchSpacing: 18)

        /// Smaller and denser, at the sizes Mac controls are: a 28-point button where Cool's was
        /// 36, a 22-point chip, a four-point grid of spacing. A surface runs edge to edge in the
        /// bench, and two of them share a single hairline.
        static let studio = Values(corner: 5, containerCorner: 10, cellCorner: 2,
                                   controlHeight: 28, chipHeight: 22, tagHeight: 18,
                                   gutter: 16, inset: 16, regionInset: 16,
                                   headerHeight: 48, dockHeight: 44, transportHeight: 56,
                                   benchPadding: 0, benchSpacing: 1)

        private static var current: Values { Design.theme.metrics }

        /// The side regions, at the width they are drawn when they are open. They no longer set the
        /// window's minimum — every one of them collapses to `collapsedRegionWidth` — so these are
        /// what a region costs when you have asked for it, not what the frame costs you always.
        public static let librarySidebarWidth: CGFloat = 220
        /// Open from the first launch, so it is what the bench pays most for: 340 holds the band's
        /// question, the log and the field, and leaves the bench 824 at the 1440 default.
        public static let conversationRailWidth: CGFloat = 340
        public static let partsLedgerWidth: CGFloat = 230
        public static var headerHeight: CGFloat { current.headerHeight }
        public static var dockHeight: CGFloat { current.dockHeight }
        public static var transportHeight: CGFloat { current.transportHeight }

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

        public static var corner: CGFloat { current.corner }
        public static var containerCorner: CGFloat { current.containerCorner }
        public static var cellCorner: CGFloat { current.cellCorner }
        public static let hairline: CGFloat = 1

        /// A control a finger or a hurried cursor has to hit.
        public static var controlHeight: CGFloat { current.controlHeight }
        public static var chipHeight: CGFloat { current.chipHeight }
        /// A label you read but do not aim at: the verb on a parts-ledger row, which is part of the
        /// row's own hit area rather than a control of its own. Deliberately below `chipHeight` so it
        /// cannot be mistaken for something separately clickable.
        public static var tagHeight: CGFloat { current.tagHeight }

        public static var gutter: CGFloat { current.gutter }
        public static var inset: CGFloat { current.inset }
        public static var regionInset: CGFloat { current.regionInset }
        public static var benchPadding: CGFloat { current.benchPadding }
        public static var benchSpacing: CGFloat { current.benchSpacing }
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

    static let accent: Color? = isChosen ? Color(nsColor: .controlAccentColor) : nil

    /// The accent laid over the panel at the strength Studio's own soft accent has, resolved at draw
    /// time so it follows the appearance.
    static let soft: Color? = isChosen
        ? Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let panel = Design.Palette.studio.panel
            let ground = NSColor(hex: dark ? panel.dark : panel.light)
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            return ground.blended(withFraction: dark ? 0.24 : 0.12, of: accent) ?? accent
        })
        : nil
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
    /// One definition per colour, light and dark together, so no token can exist in only one theme.
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
