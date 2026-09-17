import AppKit
import Observation
import Synchronization
import SwiftUI
import Testing

@testable import MrRobotoApp

/// The palette is now three palettes, and the thing that used to be guaranteed by one person reading
/// one list of constants has to be guaranteed by arithmetic instead.
///
/// Everything here works on the declared `UInt32` pairs rather than on a rendered view: a token's two
/// values are the design, and every claim worth making about a colour — is it warm, does it read
/// against its ground — is decidable from them. The one test that goes through `NSAppearance` is the
/// one checking that the declared values are actually what the system resolves.
@Suite("Themes")
struct DesignThemeTests {

    // MARK: Colour arithmetic

    private func channels(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xff), Double((hex >> 8) & 0xff), Double(hex & 0xff))
    }

    /// WCAG relative luminance in sRGB.
    private func luminance(_ hex: UInt32) -> Double {
        func linear(_ value: Double) -> Double {
            let c = value / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = channels(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1:1 to 21:1.
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// Hue in degrees, and saturation as a fraction. Hue is meaningless at zero saturation, which is
    /// why the callers below check saturation first.
    private func hueAndSaturation(_ hex: UInt32) -> (hue: Double, saturation: Double) {
        let (r, g, b) = (channels(hex).r / 255, channels(hex).g / 255, channels(hex).b / 255)
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low
        let lightness = (high + low) / 2
        guard delta > 0 else { return (0, 0) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if high == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = 60 * (((b - r) / delta) + 2) }
        else { hue = 60 * (((r - g) / delta) + 4) }
        if hue < 0 { hue += 360 }
        return (hue, saturation)
    }

    /// Both values of a token, labelled, so a failure says which appearance broke.
    private func appearances(_ pair: Design.ColorPair) -> [(String, UInt32)] {
        [("light", pair.light), ("dark", pair.dark)]
    }

    /// The tokens the frame paints with, as opposed to the two that only appear inside a waveform
    /// plate. These are the ones that must visibly change between appearances.
    private static let frameTokenNames = ["paper", "panel", "panelAlt", "ink", "inkSecondary",
                                          "inkTertiary", "line", "lineStrong", "accent",
                                          "accentSoft", "warn", "warnSoft"]

    // MARK: Completeness

    /// Structurally a `ColorPair` cannot be half-defined, but the resolver in between could still be
    /// wrong. This runs the whole set through `NSAppearance` and checks that what the system draws is
    /// exactly what the theme declared, in both appearances.
    @Test("Every theme defines every token in both appearances, and resolves to the declared value",
          arguments: Design.Theme.allCases)
    @MainActor
    func everyTokenResolvesInBothAppearances(theme: Design.Theme) throws {
        func resolved(_ color: Color, _ name: NSAppearance.Name) -> UInt32 {
            var out: UInt32 = 0
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let component = { (value: CGFloat) in UInt32((value * 255).rounded()) }
                out = component(srgb.redComponent) << 16
                    | component(srgb.greenComponent) << 8
                    | component(srgb.blueComponent)
            }
            return out
        }

        let tokens = theme.palette.tokens
        #expect(tokens.count == 14, "\(theme.displayName) has \(tokens.count) tokens, expected 14")

        for (name, pair) in tokens {
            #expect(resolved(pair.color, .aqua) == pair.light,
                    "\(theme.displayName).\(name) does not resolve to its declared light value")
            #expect(resolved(pair.color, .darkAqua) == pair.dark,
                    "\(theme.displayName).\(name) does not resolve to its declared dark value")
        }
    }

    /// A token that is the same colour in both appearances is usually a token somebody forgot to
    /// finish. The two plate tokens are the deliberate exception and are checked separately.
    @Test("Every frame token is a different colour in the two appearances",
          arguments: Design.Theme.allCases)
    func frameTokensDifferBetweenAppearances(theme: Design.Theme) {
        for (name, pair) in theme.palette.tokens where Self.frameTokenNames.contains(name) {
            #expect(pair.light != pair.dark,
                    "\(theme.displayName).\(name) is the same colour in both appearances")
        }
    }

    /// The three are meant to be three directions, not three tunings of one. If two ever converge,
    /// one of them has stopped earning its place in the menu.
    @Test("No two themes are the same palette")
    func themesAreDistinct() {
        let palettes = Design.Theme.allCases.map(\.palette)
        #expect(Set(palettes).count == Design.Theme.allCases.count)
        // And none of them shares even a ground with another: the ground is what the complaint was.
        #expect(Set(palettes.map(\.paper)).count == Design.Theme.allCases.count)
    }

    // MARK: Warmth

    /// The complaint, made decidable.
    ///
    /// A grey is warm when its red channel leads its blue. Cool Neutral's whole premise is that this
    /// never happens — not in a hairline, not in a tertiary ink, not in either appearance — so the
    /// rule is asserted on every neutral rather than on the ones anyone happened to look at. Where a
    /// neutral carries enough saturation for hue to mean anything, it is additionally pinned to the
    /// blue-grey band it was built on.
    @Test("Not one of Cool Neutral's greys drifts warm")
    func coolNeutralsAreNeverWarm() {
        let palette = Design.Theme.cool.palette
        for (name, pair) in palette.tokens
        where Design.Palette.Values.neutralTokenNames.contains(name) {
            for (appearance, value) in appearances(pair) {
                let (r, _, b) = channels(value)
                #expect(r <= b,
                        "cool.\(name) (\(appearance)) is warm: red \(Int(r)) leads blue \(Int(b))")

                let (hue, saturation) = hueAndSaturation(value)
                if saturation > 0.05 {
                    #expect((195...235).contains(hue),
                            "cool.\(name) (\(appearance)) sits at \(Int(hue))°, outside the blue-grey band")
                }
            }
        }
    }

    /// Petrol is a cold theme too — the ground is a hue, but it is a blue-green one. Its neutrals
    /// must not slide up the wheel toward the accent.
    @Test("Petrol's ground stays blue-green rather than sliding toward its own accent")
    func petrolNeutralsAreCold() {
        let palette = Design.Theme.petrol.palette
        for (name, pair) in palette.tokens
        where Design.Palette.Values.neutralTokenNames.contains(name) {
            for (appearance, value) in appearances(pair) {
                let (r, _, b) = channels(value)
                #expect(r <= b,
                        "petrol.\(name) (\(appearance)) is warm: red \(Int(r)) leads blue \(Int(b))")

                let (hue, saturation) = hueAndSaturation(value)
                if saturation > 0.05 {
                    #expect((170...200).contains(hue),
                            "petrol.\(name) (\(appearance)) sits at \(Int(hue))°, outside the petrol band")
                }
            }
        }
    }

    /// The control. Notebook is the warm one, kept for comparison — and if this ever stops being
    /// true, the warmth test above has stopped being able to detect anything.
    @Test("Notebook is still the warm one, which is what the other two are measured against")
    func notebookIsWarm() {
        let palette = Design.Theme.notebook.palette
        let warmNeutrals = palette.tokens
            .filter { Design.Palette.Values.neutralTokenNames.contains($0.name) }
            .flatMap { appearances($0.pair) }
            .filter { channels($0.1).r > channels($0.1).b }
        #expect(warmNeutrals.count >= 12,
                "notebook has gone cool — only \(warmNeutrals.count) warm neutral values left")
    }

    // MARK: Contrast

    /// The accent is spent on the one thing worth doing on a surface, so it has to be legible as
    /// text on the ground it is spent on, and legible under its own fill when it becomes a button.
    /// Both directions, both appearances, all three themes.
    @Test("The accent carries its own ground in both appearances",
          arguments: Design.Theme.allCases)
    func accentContrast(theme: Design.Theme) {
        let palette = theme.palette
        for (appearance, index) in [("light", \Design.ColorPair.light), ("dark", \Design.ColorPair.dark)] {
            let accent = palette.accent[keyPath: index]
            let paper = palette.paper[keyPath: index]
            let panel = palette.panel[keyPath: index]

            // The accent as text on the window's ground, and on a panel sitting on it.
            let soft = palette.accentSoft[keyPath: index]
            func ratio(_ a: UInt32, _ b: UInt32) -> String { String(format: "%.2f:1", contrast(a, b)) }

            #expect(contrast(accent, paper) >= 4.5,
                    "\(theme.displayName) accent on paper (\(appearance)) is \(ratio(accent, paper))")
            #expect(contrast(accent, panel) >= 4.5,
                    "\(theme.displayName) accent on panel (\(appearance)) is \(ratio(accent, panel))")

            // `FrameButton.accent` fills with the accent and sets its label in `panel`.
            #expect(contrast(panel, accent) >= 4.5,
                    "\(theme.displayName) panel label on the accent fill (\(appearance)) is \(ratio(panel, accent))")

            // And the accent has to stay visible on its own soft tint, which is what a selected row
            // is painted with.
            #expect(contrast(accent, soft) >= 4.5,
                    "\(theme.displayName) accent on accentSoft (\(appearance)) is \(ratio(accent, soft))")
        }
    }

    /// Body text, and the two quieter inks under it. `inkTertiary` is a deliberately faint label, so
    /// it is held to the large-text bar rather than the body-text one.
    @Test("Ink reads on paper in both appearances", arguments: Design.Theme.allCases)
    func inkContrast(theme: Design.Theme) {
        let palette = theme.palette
        for (appearance, index) in [("light", \Design.ColorPair.light), ("dark", \Design.ColorPair.dark)] {
            let paper = palette.paper[keyPath: index]
            #expect(contrast(palette.ink[keyPath: index], paper) >= 7,
                    "\(theme.displayName) ink on paper (\(appearance)) is under AAA")
            #expect(contrast(palette.inkSecondary[keyPath: index], paper) >= 4.5,
                    "\(theme.displayName) inkSecondary on paper (\(appearance)) is under AA")
            #expect(contrast(palette.inkTertiary[keyPath: index], paper) >= 2.3,
                    "\(theme.displayName) inkTertiary on paper (\(appearance)) has vanished")
            #expect(contrast(palette.warn[keyPath: index], paper) >= 4,
                    "\(theme.displayName) warn on paper (\(appearance)) is under AA")
        }
    }

    /// A hairline is the only thing separating two panels, so it has to be a visible step off both
    /// the ground behind it and the panel it edges. The floor is the notebook's own separation,
    /// which is the one that was approved — this is what stops a cold palette from being translated
    /// straight across and coming out thinner than the warm one it replaced.
    @Test("Hairlines separate at least as well as the approved ones do",
          arguments: Design.Theme.allCases)
    func hairlineSeparation(theme: Design.Theme) {
        let palette = theme.palette
        for (appearance, index) in [("light", \Design.ColorPair.light), ("dark", \Design.ColorPair.dark)] {
            let line = palette.line[keyPath: index]
            #expect(contrast(line, palette.paper[keyPath: index]) >= 1.10,
                    "\(theme.displayName) line on paper (\(appearance)) has almost no step")
            #expect(contrast(line, palette.panel[keyPath: index]) >= 1.25,
                    "\(theme.displayName) line on panel (\(appearance)) has almost no step")
            #expect(contrast(palette.lineStrong[keyPath: index], palette.panel[keyPath: index]) >= 1.50,
                    "\(theme.displayName) lineStrong on panel (\(appearance)) is no stronger than line")
        }
    }

    /// The waveform plate is drawn in the theme's own dark, and the trace on top of it.
    @Test("The trace reads on its plate in both appearances", arguments: Design.Theme.allCases)
    func traceOnPlate(theme: Design.Theme) {
        let palette = theme.palette
        for (appearance, index) in [("light", \Design.ColorPair.light), ("dark", \Design.ColorPair.dark)] {
            #expect(contrast(palette.trace[keyPath: index], palette.plate[keyPath: index]) >= 4.5,
                    "\(theme.displayName) trace on plate (\(appearance)) is faint")
        }
    }

    // MARK: Wiring

    /// Every accessor must read through whatever theme is current. A single one left pointing at a
    /// specific palette would look right in that theme and be wrong in the other two — which is the
    /// only way this refactor can fail quietly.
    @Test("Every token accessor reads through the current theme")
    func accessorsReadThroughTheTheme() {
        let palette = Design.theme.palette
        #expect(Design.Palette.paper == palette.paper.color)
        #expect(Design.Palette.panel == palette.panel.color)
        #expect(Design.Palette.panelAlt == palette.panelAlt.color)
        #expect(Design.Palette.ink == palette.ink.color)
        #expect(Design.Palette.inkSecondary == palette.inkSecondary.color)
        #expect(Design.Palette.inkTertiary == palette.inkTertiary.color)
        #expect(Design.Palette.line == palette.line.color)
        #expect(Design.Palette.lineStrong == palette.lineStrong.color)
        #expect(Design.Palette.accent == palette.accent.color)
        #expect(Design.Palette.accentSoft == palette.accentSoft.color)
        #expect(Design.Palette.warn == palette.warn.color)
        #expect(Design.Palette.warnSoft == palette.warnSoft.color)
        #expect(Design.Palette.plate == palette.plate.color)
        #expect(Design.Palette.trace == palette.trace.color)
    }

    /// The memo in front of `ColorPair.color` must hand back one colour per pair rather than a fresh
    /// dynamic `NSColor` per read.
    ///
    /// Equality is the check that can be made here: two separately built dynamic colours are never
    /// `==` to each other even when they resolve identically, because each carries its own resolver.
    /// So a token being equal to itself across two reads is exactly the evidence that the memo is
    /// doing its job. That the memoised colour is the *right* one is settled by
    /// `everyTokenResolvesInBothAppearances`, which resolves it under both appearances.
    @Test("A token is one colour, not a new one per read")
    func colourMemoIsStable() {
        for theme in Design.Theme.allCases {
            for (name, pair) in theme.palette.tokens {
                #expect(pair.color == pair.color, "\(theme.displayName).\(name) is rebuilt on every read")
            }
        }
        // Different pairs stay different, so the memo is not collapsing tokens onto one key.
        let distinct = Set(Design.Theme.cool.palette.tokens.map(\.pair))
        #expect(Set(distinct.map(\.color)).count == distinct.count)
    }

    // MARK: Switching and persistence

    /// The repaint. A store mutation has to reach observation tracking, because that — and nothing
    /// else — is what makes every body that reads a token re-run when the menu item is picked.
    ///
    /// A local store rather than `Design.store`: the global one is what the rest of the suite reads
    /// through, and tests run in parallel.
    @Test("Changing the theme notifies observers, which is what repaints the app")
    func switchingIsObservable() {
        let store = Design.ThemeStore(.notebook)
        // A box rather than a captured `var`: `onChange` is a `@Sendable` closure and runs wherever
        // the mutation happened.
        let notified = Mutex(false)

        withObservationTracking {
            _ = store.theme
        } onChange: {
            notified.withLock { $0 = true }
        }

        #expect(!notified.withLock { $0 })
        store.theme = .petrol
        #expect(notified.withLock { $0 }, "a theme change did not reach observation tracking")
        #expect(store.theme == .petrol)
    }

    /// A store reads its starting theme from defaults, so the app opens in whatever was last chosen.
    @Test("The chosen theme survives a launch", arguments: Design.Theme.allCases)
    func themeIsPersisted(theme: Design.Theme) throws {
        let suite = "design.theme.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(Design.storedTheme(defaults) == Design.defaultTheme,
                "an empty defaults should give the default theme")

        defaults.set(theme.rawValue, forKey: Design.themeDefaultsKey)
        #expect(Design.storedTheme(defaults) == theme)
    }

    /// Anything else in defaults — a theme that was removed, a hand-edited plist — falls back rather
    /// than trapping on an optional.
    @Test("A theme name we no longer have falls back to the default")
    func unknownThemeFallsBack() throws {
        let suite = "design.theme.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set("parchment", forKey: Design.themeDefaultsKey)
        #expect(Design.storedTheme(defaults) == Design.defaultTheme)
    }

    /// Only Petrol pins the appearance, and it pins it to dark. If another theme ever started
    /// pinning, the app would stop following the system for no stated reason.
    @Test("Petrol is the only theme that takes the appearance out of the system's hands")
    func onlyPetrolPinsTheAppearance() {
        #expect(Design.Theme.notebook.pinnedAppearance == nil)
        #expect(Design.Theme.cool.pinnedAppearance == nil)
        #expect(Design.Theme.petrol.pinnedAppearance == .darkAqua)
    }

    /// The View menu's shortcuts are positional, so the order of `allCases` is load-bearing: it is
    /// what ⌃⌘1, ⌃⌘2 and ⌃⌘3 mean.
    @Test("The menu order is the shortcut order")
    func menuOrder() {
        #expect(Design.Theme.allCases == [.notebook, .cool, .petrol])
        #expect(Design.Theme.allCases.map(\.displayName) == ["Notebook", "Cool Neutral", "Petrol"])
    }
}
