import SwiftUI

/// The approved visual direction: an editorial notebook. Warm paper, a serif for anything the
/// agent says, a sans for controls and data, one ink-blue accent spent sparingly.
///
/// These values come from the design canvas Dylan chose over a dark studio idiom and a playful one.
/// Nothing in a surface should hard-code a colour or a size; take it from here so the twenty-two
/// surfaces read as one instrument rather than twenty-two screens.
public enum Design {

    // MARK: Colour

    /// Paper, panel and ink. Light is the primary design; dark is derived, not inverted.
    public enum Palette {
        public static let paper = Color(hex: 0xf6f4ef, dark: 0x171614)
        public static let panel = Color(hex: 0xffffff, dark: 0x201f1c)
        public static let panelAlt = Color(hex: 0xfaf9f6, dark: 0x1c1b18)

        public static let ink = Color(hex: 0x1b1a18, dark: 0xece8df)
        public static let inkSecondary = Color(hex: 0x6b6862, dark: 0xa8a398)
        public static let inkTertiary = Color(hex: 0xa39f96, dark: 0x6f6a60)

        public static let line = Color(hex: 0xe3dfd6, dark: 0x34322d)
        public static let lineStrong = Color(hex: 0xd6d1c6, dark: 0x45423b)

        /// Spend this on one thing per surface: the selected candidate, the active section.
        public static let accent = Color(hex: 0x2b4c7e, dark: 0x8fa9d2)
        public static let accentSoft = Color(hex: 0xeef2f8, dark: 0x23293a)

        /// A critic finding, never decoration.
        public static let warn = Color(hex: 0xb4432a, dark: 0xd9866f)
        public static let warnSoft = Color(hex: 0xfbeee9, dark: 0x352420)

        /// The dark plate a waveform or pitch trace is drawn on.
        public static let plate = Color(hex: 0x1b1a18, dark: 0x100f0e)
        public static let trace = Color(hex: 0x9fb6dc, dark: 0x9fb6dc)
    }

    // MARK: Type

    /// Newsreader for prose, Karla for controls, a monospace for anything that lines up in columns.
    ///
    /// Both families ship with the app — see `FontRegistration`, which registers them from
    /// `Bundle.module` before the first view renders. The fallback stacks below are not decoration:
    /// PNG and PDF export run outside that registration, and any face that fails to register lands
    /// here. They are named families with close metrics, not a shrug at the system font.
    public enum Typography {

        /// Serif fallbacks for Newsreader, in order. Charter is the closest match that ships with
        /// macOS — a sturdy text serif at a similar x-height and set width; Georgia is wider but
        /// safe; Times New Roman is the floor.
        static let proseStack = ["Newsreader", "Charter", "Georgia", "Times New Roman"]

        /// Grotesque fallbacks for Karla, in order. Helvetica Neue carries a comparable x-height
        /// and a similar neutral tone; Arial is the floor.
        static let uiStack = ["Karla", "Helvetica Neue", "Arial"]

        /// Resolved once, after `FontRegistration.registerBundledFonts()` has run in `init`.
        static let proseFamily = firstAvailable(in: proseStack)
        static let uiFamily = firstAvailable(in: uiStack)

        /// Whether CoreText can resolve a family by name right now.
        static func isAvailable(_ family: String) -> Bool {
            NSFont(name: family, size: 12) != nil
        }

        /// The first name in a stack the machine can actually render, or the last as a final resort.
        static func firstAvailable(in stack: [String]) -> String {
            stack.first(where: isAvailable) ?? stack[stack.count - 1]
        }

        /// What a given family degrades to if it will not register. Used in the log line so the
        /// message says what the reader will actually see, not just what went wrong.
        static func fallbackName(for family: String) -> String {
            let stack = family == "Newsreader" ? proseStack : uiStack
            return firstAvailable(in: Array(stack.dropFirst()))
        }

        public static func prose(_ size: CGFloat = 15.5, weight: Font.Weight = .regular) -> Font {
            .custom(proseFamily, size: size, relativeTo: .body).weight(weight)
        }

        public static func ui(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
            .custom(uiFamily, size: size, relativeTo: .body).weight(weight)
        }

        /// Uppercase, letterspaced, small: the label above a control or a column.
        public static let label = Font.custom(uiFamily, size: 11, relativeTo: .caption).weight(.medium)

        /// Tabular figures, for anything a reader compares down a column.
        public static func numeric(_ size: CGFloat = 12) -> Font {
            .system(size: size, weight: .regular, design: .monospaced)
        }
    }

    // MARK: Metrics

    public enum Metric {
        /// The persistent frame. These are fixed because the frame never moves; only the bench does.
        public static let librarySidebarWidth: CGFloat = 220
        public static let conversationRailWidth: CGFloat = 380
        public static let partsLedgerWidth: CGFloat = 230
        public static let headerHeight: CGFloat = 56
        public static let transportHeight: CGFloat = 84

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

    /// At most three surfaces in the bench, from the catalog's own rule.
    public static let maximumOpenSurfaces = 3
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
