import AppKit
import Observation
import SongGraph
import Synchronization
import SwiftUI
import Testing

@testable import MrRobotoApp

/// The palettes are three sets of tokens — Studio in its two appearances, Mid Dark and Vibrant —
/// and what used to be guaranteed by one person reading one list of constants has to be guaranteed
/// by arithmetic instead.
///
/// Everything here works on the declared `UInt32` pairs rather than on a rendered view: a token's two
/// values are the design, and every claim worth making about a colour — is it warm, does it read
/// against its ground — is decidable from them. The one test that goes through `NSAppearance` is the
/// one checking that the declared values are actually what the system resolves.
@Suite("Palettes")
struct DesignPaletteTests {

    /// One scheme per distinct palette: Auto, Light and Dark are Studio's one palette.
    static let palettes: [Design.Scheme] = [.system, .mid, .vibrant]

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

    private func ratio(_ a: UInt32, _ b: UInt32) -> String { String(format: "%.2f:1", contrast(a, b)) }

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
    private static var appearances: [(String, KeyPath<Design.ColorPair, UInt32>)] {
        [("light", \.light), ("dark", \.dark)]
    }

    /// The tokens the frame paints with, as opposed to the two that only appear inside a waveform
    /// plate. These are the ones that must visibly change between Studio's appearances.
    private static let frameTokenNames = ["paper", "panel", "panelAlt", "ink", "inkSecondary",
                                          "inkTertiary", "line", "lineStrong", "accent",
                                          "accentSoft", "warn", "warnSoft"]

    // MARK: Completeness

    /// Structurally a `ColorPair` cannot be half-defined, but the resolver in between could still be
    /// wrong. This runs the whole set through `NSAppearance` and checks that what the system draws is
    /// exactly what the palette declared, in both appearances.
    @Test("Every palette defines every token, and resolves to the declared value", arguments: Self.palettes)
    @MainActor
    func everyTokenResolves(scheme: Design.Scheme) throws {
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

        let palette = scheme.palette
        #expect(palette.tokens.count == 40, "\(scheme.displayName) has \(palette.tokens.count) tokens, expected 40")
        #expect(palette.lanes.count == 8, "\(scheme.displayName) has \(palette.lanes.count) lane hues, expected 8")
        for (name, pair) in palette.tokens {
            #expect(resolved(pair.color, .aqua) == pair.light, "\(scheme.displayName).\(name) light")
            #expect(resolved(pair.color, .darkAqua) == pair.dark, "\(scheme.displayName).\(name) dark")
        }
    }

    /// A Studio token that is the same colour in both appearances is usually a token somebody forgot
    /// to finish. The plate tokens are the deliberate exception.
    @Test("Every one of Studio's frame tokens is a different colour in its two appearances")
    func studioFrameTokensDifferBetweenAppearances() {
        for (name, pair) in Design.Palette.studio.tokens where Self.frameTokenNames.contains(name) {
            #expect(pair.light != pair.dark, "studio.\(name) is the same colour in both appearances")
        }
    }

    /// Mid Dark and Vibrant are drawn for a dark window and set the window dark, so a value in only
    /// one appearance would be a value nobody sees — or worse, one somebody does, in a render.
    @Test("Mid Dark and Vibrant are one appearance only, and set the window dark",
          arguments: [Design.Scheme.mid, .vibrant])
    func singleAppearancePalettes(scheme: Design.Scheme) {
        for (name, pair) in scheme.palette.tokens {
            #expect(pair.light == pair.dark && pair.lightAlpha == pair.darkAlpha,
                    "\(scheme.displayName).\(name) differs between appearances")
        }
        #expect(scheme.appearanceName == .darkAqua)
    }

    /// Each one has to earn its place in the menu: if two converge, one of them has stopped.
    @Test("No two palettes are the same, and none shares a ground with another")
    func palettesAreDistinct() {
        let palettes = Self.palettes.map(\.palette)
        #expect(Set(palettes).count == palettes.count)
        #expect(Set(palettes.map(\.paper)).count == palettes.count)
        #expect(Set(palettes.map(\.panel)).count == palettes.count)
    }

    /// Mid Dark is in between: lighter than Studio's dark by a long way, and nowhere near its light.
    @Test("Mid Dark sits between Studio's appearances, nearer the dark")
    func midIsInBetween() {
        let studio = Design.Palette.studio, mid = Design.Palette.mid
        for token in [\Design.Palette.Values.paper, \.panel, \.raised] {
            let dark = luminance(studio[keyPath: token].dark)
            let light = luminance(studio[keyPath: token].light)
            let between = luminance(mid[keyPath: token].dark)
            #expect(between > dark * 4 && between < light / 4)
        }
    }

    // MARK: Warmth

    /// The greys are near-neutral, the way Apple's are: faintly cool where they lean at all, and
    /// never warm, in any palette or appearance — including the translucent fills. A saturated
    /// ground was Petrol's mistake, and Vibrant's colour is spent on the work, not on its ground.
    @Test("Not one grey drifts warm, and none of them is a colour", arguments: Self.palettes)
    func neutralsAreNearNeutral(scheme: Design.Scheme) {
        for (name, pair) in scheme.palette.tokens where Design.Palette.Values.neutralTokenNames.contains(name) {
            for (appearance, index) in Self.appearances {
                let (r, g, b) = channels(pair[keyPath: index])
                #expect(r <= b, "\(scheme.displayName).\(name) (\(appearance)) is warm: red \(Int(r)) leads blue \(Int(b))")
                // The spread between the channels, not HSL saturation, which runs high for any
                // near-white: #F5F6F8 is 18% "saturated" and three units of blue.
                let spread = max(r, g, b) - min(r, g, b)
                #expect(spread <= 16, "\(scheme.displayName).\(name) (\(appearance)) leans \(Int(spread)) units — a colour, not a grey")
            }
        }
    }

    /// Each fixed meaning is its own colour: a critic's finding must not look like record, and
    /// nothing may look like the sounding orange.
    @Test("Sounding, record, caution and the accent are a colour each", arguments: Self.palettes)
    func meaningsAreDistinct(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (appearance, index) in Self.appearances {
            let meanings = [palette.accent, palette.sounding, palette.danger, palette.warn,
                            palette.solo, palette.mute, palette.ok].map { $0[keyPath: index] }
            #expect(Set(meanings).count == meanings.count, "two of \(scheme.displayName)'s meanings share a colour (\(appearance))")
            // No lane hue sits in the orange the sounding colour owns.
            for (offset, lane) in palette.lanes.enumerated() {
                let (hue, saturation) = hueAndSaturation(lane[keyPath: index])
                #expect(saturation < 0.2 || !(20...45).contains(hue),
                        "\(scheme.displayName) lane \(offset) (\(appearance)) sits at \(Int(hue))°, in the sounding orange")
            }
            // And the orange is the one the app icon is drawn in, everywhere.
            #expect(palette.sounding[keyPath: index] == 0xf97f23)
        }
    }

    // MARK: The display and the plates

    /// The display and the plate are a piece of equipment: dark in every palette, with figures that
    /// read on them at a glance.
    @Test("The transport display reads", arguments: Self.palettes)
    func displayReads(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (appearance, index) in Self.appearances {
            let plate = palette.plate[keyPath: index]
            #expect(contrast(palette.lcdInk[keyPath: index], plate) >= 12, "\(scheme.displayName) figures (\(appearance)) are faint")
            #expect(contrast(palette.lcdLabel[keyPath: index], plate) >= 4.5, "\(scheme.displayName) labels (\(appearance)) are under AA")
            #expect(contrast(palette.lcdRecordingInk[keyPath: index], palette.lcdRecording[keyPath: index]) >= 12,
                    "\(scheme.displayName) recording figures (\(appearance)) are faint")
            #expect(luminance(plate) < 0.02, "\(scheme.displayName) plate (\(appearance)) is not dark")
        }
    }

    /// Vibrant lights the display in the colour of the section playing, so every lane has to read
    /// on the plate as a figure does: not at the 12:1 of the display's own ink, but well past AA.
    @Test("Vibrant's display figures read in every section's colour")
    func vibrantDisplayGlowReads() {
        let palette = Design.Palette.vibrant
        for (offset, lane) in palette.lanes.enumerated() {
            #expect(contrast(lane.dark, palette.plate.dark) >= 5, "lane \(offset) on the plate is \(ratio(lane.dark, palette.plate.dark))")
        }
    }

    /// The waveform plate is drawn in the palette's own dark, and the trace on top of it — in
    /// Vibrant, in the colour of the part being worked on.
    @Test("The trace reads on its plate", arguments: Self.palettes)
    func traceOnPlate(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (appearance, index) in Self.appearances {
            #expect(contrast(palette.trace[keyPath: index], palette.plate[keyPath: index]) >= 4.5,
                    "\(scheme.displayName) trace on plate (\(appearance)) is faint")
        }
        guard scheme.followsWork else { return }
        for (offset, lane) in palette.lanes.enumerated() {
            #expect(contrast(lane.dark, palette.plate.dark) >= 4.5, "lane \(offset) as a trace is faint")
        }
    }

    /// The text on an orange fill — Stop while a part plays, the lit Play — reads on it.
    @Test("Text on the sounding orange reads", arguments: Self.palettes)
    func onSoundingReads(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (_, index) in Self.appearances {
            #expect(contrast(palette.onSounding[keyPath: index], palette.sounding[keyPath: index]) >= 4.5)
            #expect(contrast(palette.soundingInk[keyPath: index], palette.paper[keyPath: index]) >= 4.5)
        }
    }

    // MARK: Contrast

    /// The accent is spent on the one thing worth doing on a surface, so it has to be legible as
    /// text on the ground it is spent on, and legible under its own fill when it becomes a button.
    private func accentCarries(_ accent: UInt32, soft: UInt32, on palette: Design.Palette.Values,
                               _ index: KeyPath<Design.ColorPair, UInt32>, _ label: String) {
        let paper = palette.paper[keyPath: index], panel = palette.panel[keyPath: index]
        #expect(contrast(accent, paper) >= 4.5, "\(label) on paper is \(ratio(accent, paper))")
        #expect(contrast(accent, panel) >= 4.5, "\(label) on panel is \(ratio(accent, panel))")
        // `FrameButton.accent` fills with the accent and sets its label in `panel`.
        #expect(contrast(panel, accent) >= 4.5, "panel label on \(label) is \(ratio(panel, accent))")
        // And the accent has to stay visible on its own soft tint, which a selected row is painted with.
        #expect(contrast(accent, soft) >= 4.5, "\(label) on its soft tint is \(ratio(accent, soft))")
    }

    @Test("The accent carries its own ground", arguments: Self.palettes)
    func accentContrast(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (appearance, index) in Self.appearances {
            accentCarries(palette.accent[keyPath: index], soft: palette.accentSoft[keyPath: index],
                          on: palette, index, "\(scheme.displayName) accent (\(appearance))")
        }
    }

    /// Vibrant's accent is whichever of the eight hues the work is: each one has to carry the ground
    /// the way the accent does, with its own soft tint under a selected row.
    @Test("Each of Vibrant's eight hues carries the ground as its accent")
    func vibrantWorkAccents() throws {
        let palette = Design.Palette.vibrant
        for hue in 0..<8 {
            let lane = try #require(Design.Palette.workLane(in: .vibrant, hue: hue))
            #expect(lane == palette.lanes[hue])
            let soft = Design.Palette.workSoft(lane, over: palette.panel)
            accentCarries(lane.dark, soft: soft.dark, on: palette, \.dark, "lane \(hue)")
        }
    }

    /// Only Vibrant follows the work; the others keep their accent wherever you are.
    @Test("Only Vibrant's accent follows the work, and a hue wraps rather than traps")
    func onlyVibrantFollowsTheWork() {
        for scheme in Design.Scheme.allCases where scheme != .vibrant {
            #expect(Design.Palette.workLane(in: scheme, hue: 2) == nil)
        }
        #expect(Design.Palette.workLane(in: .vibrant, hue: nil) == nil)
        #expect(Design.Palette.workLane(in: .vibrant, hue: 10) == Design.Palette.vibrant.lanes[2])
        #expect(Design.Palette.workLane(in: .vibrant, hue: -1) == Design.Palette.vibrant.lanes[7])
    }

    /// Body text, and the two quieter inks under it. `inkTertiary` is a deliberately faint label, so
    /// it is held to the large-text bar rather than the body-text one.
    @Test("Ink reads on paper", arguments: Self.palettes)
    func inkContrast(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (appearance, index) in Self.appearances {
            let paper = palette.paper[keyPath: index]
            #expect(contrast(palette.ink[keyPath: index], paper) >= 7, "\(scheme.displayName) ink (\(appearance)) is under AAA")
            #expect(contrast(palette.inkSecondary[keyPath: index], paper) >= 4.5, "\(scheme.displayName) inkSecondary (\(appearance)) is under AA")
            #expect(contrast(palette.inkTertiary[keyPath: index], paper) >= 2.3, "\(scheme.displayName) inkTertiary (\(appearance)) has vanished")
            #expect(contrast(palette.warn[keyPath: index], paper) >= 4, "\(scheme.displayName) warn (\(appearance)) is under AA")
        }
    }

    /// A hairline is the only thing separating two panels, so it has to be a visible step off both
    /// the ground behind it and the panel it edges.
    @Test("Hairlines separate", arguments: Self.palettes)
    func hairlineSeparation(scheme: Design.Scheme) {
        let palette = scheme.palette
        for (appearance, index) in Self.appearances {
            let line = palette.line[keyPath: index]
            #expect(contrast(line, palette.paper[keyPath: index]) >= 1.10, "\(scheme.displayName) line on paper (\(appearance))")
            #expect(contrast(line, palette.panel[keyPath: index]) >= 1.25, "\(scheme.displayName) line on panel (\(appearance))")
            #expect(contrast(palette.lineStrong[keyPath: index], palette.panel[keyPath: index]) >= 1.50,
                    "\(scheme.displayName) lineStrong on panel (\(appearance))")
        }
    }

    /// A system accent drawn for a near-black window can fall under AA on Mid Dark's charcoal; it is
    /// lightened until it reads, and one that already reads is left alone.
    @Test("A system accent is made legible on the palette's panel")
    func systemAccentIsLifted() {
        let blue = NSColor(hex: 0x0a84ff), charcoal = NSColor(hex: Design.Palette.mid.panel.dark)
        let lifted = SystemAccent.legible(blue, on: charcoal).usingColorSpace(.sRGB)!
        let hex = UInt32((lifted.redComponent * 255).rounded()) << 16
            | UInt32((lifted.greenComponent * 255).rounded()) << 8 | UInt32((lifted.blueComponent * 255).rounded())
        #expect(contrast(hex, Design.Palette.mid.panel.dark) >= 4.5, "the lifted accent is \(ratio(hex, Design.Palette.mid.panel.dark))")
        let readable = NSColor(hex: Design.Palette.mid.accent.dark)
        #expect(SystemAccent.legible(readable, on: charcoal).usingColorSpace(.sRGB) == readable.usingColorSpace(.sRGB))
    }

    // MARK: Wiring

    /// Every accessor must read through whatever palette is current. One left pointing at a
    /// specific palette would look right in that one and be wrong in the rest.
    @Test("Every token accessor reads through the current palette")
    func accessorsReadThroughThePalette() {
        let palette = Design.scheme.palette
        #expect(Design.Palette.paper == palette.paper.color)
        #expect(Design.Palette.panel == palette.panel.color)
        #expect(Design.Palette.panelAlt == palette.panelAlt.color)
        #expect(Design.Palette.ink == palette.ink.color)
        #expect(Design.Palette.inkSecondary == palette.inkSecondary.color)
        #expect(Design.Palette.inkTertiary == palette.inkTertiary.color)
        #expect(Design.Palette.line == palette.line.color)
        #expect(Design.Palette.lineStrong == palette.lineStrong.color)
        #expect(Design.Palette.warn == palette.warn.color)
        #expect(Design.Palette.warnSoft == palette.warnSoft.color)
        #expect(Design.Palette.plate == palette.plate.color)
        if !Design.scheme.followsWork {
            #expect(Design.Palette.trace == palette.trace.color)
            if !SystemAccent.isChosen {
                #expect(Design.Palette.accent == palette.accent.color)
                #expect(Design.Palette.accentSoft == palette.accentSoft.color)
            }
        }
    }

    /// The memo in front of `ColorPair.color` must hand back one colour per pair rather than a fresh
    /// dynamic `NSColor` per read: two separately built dynamic colours are never `==`, so a token
    /// equal to itself across two reads is the evidence.
    @Test("A token is one colour, not a new one per read")
    func colourMemoIsStable() {
        for scheme in Self.palettes {
            for (name, pair) in scheme.palette.tokens {
                #expect(pair.color == pair.color, "\(scheme.displayName).\(name) is rebuilt on every read")
            }
        }
        // Different pairs stay different, so the memo is not collapsing tokens onto one key.
        let distinct = Set(Design.Palette.studio.tokens.map(\.pair))
        #expect(Set(distinct.map(\.color)).count == distinct.count)
    }

    // MARK: Switching and persistence

    /// The repaint. A store mutation has to reach observation tracking, because that — and nothing
    /// else — is what makes every body that reads a token re-run when the menu item is picked. A
    /// local store rather than `Design.store`: the global one is what the rest of the suite reads
    /// through, and tests run in parallel.
    @Test("Changing the palette, or the work's hue, notifies observers")
    func switchingIsObservable() {
        let store = Design.SchemeStore(.mid)
        let notified = Mutex(0)
        func track(_ read: @escaping () -> Void) {
            withObservationTracking { read() } onChange: { notified.withLock { $0 += 1 } }
        }

        track { _ = store.scheme }
        store.scheme = .vibrant
        #expect(notified.withLock { $0 } == 1, "a palette change did not reach observation tracking")
        #expect(store.scheme == .vibrant)

        track { _ = store.workHue }
        store.workHue = 2
        #expect(notified.withLock { $0 } == 2, "a change of work did not reach observation tracking")
        // The same hue again is not a change: switching between two Grids repaints nothing.
        track { _ = store.workHue }
        store.workHue = 2
        #expect(notified.withLock { $0 } == 2)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "design.palette.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("The chosen palette survives a launch", arguments: Design.Scheme.allCases)
    func paletteIsPersisted(scheme: Design.Scheme) throws {
        try withDefaults { defaults in
            #expect(Design.storedScheme(defaults) == .vibrant, "an empty defaults should give Vibrant")
            defaults.set(scheme.rawValue, forKey: Design.schemeDefaultsKey)
            #expect(Design.storedScheme(defaults) == scheme)
        }
    }

    /// Light or Dark chosen in the Appearance menu, before there were palettes, is the same choice
    /// now; a palette chosen since wins over it.
    @Test("Light or Dark chosen before the palettes carries over")
    func appearanceCarriesOver() throws {
        for (old, carried) in [("light", Design.Scheme.light), ("dark", .dark), ("system", .system), ("sepia", .vibrant)] {
            try withDefaults { defaults in
                defaults.set(old, forKey: Design.appearanceDefaultsKey)
                #expect(Design.storedScheme(defaults) == carried, "\(old)")
                defaults.set("vibrant", forKey: Design.schemeDefaultsKey)
                #expect(Design.storedScheme(defaults) == .vibrant)
            }
        }
    }

    /// The themes are gone: a theme remembered from before — Cool Neutral, Studio, or the two
    /// retired before them — opens in the default, Vibrant, and a palette name we do not have falls
    /// back rather than trapping on an optional.
    @Test("A theme remembered from before, or an unknown palette, opens in Vibrant")
    func oldThemesFallBack() throws {
        for theme in ["cool", "studio", "notebook", "petrol"] {
            try withDefaults { defaults in
                defaults.set(theme, forKey: "design.theme")
                defaults.set(2, forKey: "design.themeVersion")
                #expect(Design.storedScheme(defaults) == .vibrant, "\(theme)")
            }
        }
        try withDefaults { defaults in
            defaults.set("parchment", forKey: Design.schemeDefaultsKey)
            #expect(Design.storedScheme(defaults) == .vibrant)
        }
    }

    /// Auto hands the window back to the system; Light and Dark pin it; Mid Dark and Vibrant are
    /// drawn for a dark window and pin it dark.
    @Test("Each palette sets the window's appearance")
    func appearanceFollowsThePalette() {
        #expect(Design.Scheme.system.appearanceName == nil)
        #expect(Design.Scheme.light.appearanceName == .aqua)
        #expect(Design.Scheme.dark.appearanceName == .darkAqua)
        #expect(Design.Scheme.mid.appearanceName == .darkAqua)
        #expect(Design.Scheme.vibrant.appearanceName == .darkAqua)
        #expect(Design.defaultScheme == .vibrant)
    }

    /// The View menu's shortcuts are positional, so the order of `allCases` is load-bearing: it is
    /// what ⌃⌘1–5 mean.
    @Test("The menu order is the shortcut order")
    func menuOrder() {
        #expect(Design.Scheme.allCases == [.system, .light, .dark, .mid, .vibrant])
        #expect(Design.Scheme.allCases.map(\.displayName) == ["Auto", "Light", "Dark", "Mid Dark", "Vibrant"])
        #expect(Design.Scheme.allCases.map(\.shortcut) == ["1", "2", "3", "4", "5"])
    }

    // MARK: The work

    /// What fills the bench gives Vibrant its accent: the part a surface is bound to, else the kind
    /// of part the surface makes, and nothing for a surface about the song or the library.
    @Test("A surface's work is the part it edits, or the kind it makes")
    func workHueOfASurface() {
        #expect(PartHue.work(of: .grid, bound: []) == PartHue.index(for: .groove))
        #expect(PartHue.work(of: .pianoRoll, bound: []) == PartHue.index(for: .bassline))
        #expect(PartHue.work(of: .pianoRoll, bound: [.melody]) == PartHue.index(for: .melody))
        // The Piano roll draws the groove's kicks under the line: the line is the work.
        #expect(PartHue.work(of: .pianoRoll, bound: [.groove, .bassline]) == PartHue.index(for: .bassline))
        #expect(PartHue.work(of: .chords, bound: []) == PartHue.index(for: .progression))
        #expect(PartHue.work(of: .chopLane, bound: [.sample]) == PartHue.index(for: .sample))
        #expect(PartHue.work(of: .importRecord, bound: []) == PartHue.index(for: .audio))
        #expect(PartHue.work(of: .lyrics, bound: []) == PartHue.index(for: .lyric))
        // A Compare or a Check is about whichever part it is bound to; a sound or a mix is not a track.
        #expect(PartHue.work(of: .compare, bound: [.melody]) == PartHue.index(for: .melody))
        #expect(PartHue.work(of: .sound, bound: [.sound]) == nil)
        for kind in [SurfaceKind.library, .mixer, .master, .cast, .album, .sources, .mashup, .merge] {
            #expect(PartHue.work(of: kind, bound: [.groove]) == nil, "\(kind.rawValue)")
        }
        // Gold in the Grid and blue for a tune, as the menu promised.
        #expect(PartHue.index(for: .groove) == 2)
        #expect(PartHue.index(for: .melody) == 1)
    }

    @Test("The frame's work follows the surface in front")
    @MainActor
    func workHueFollowsTheBench() {
        let built = GuidanceFixture.grooved()
        let app = AppState(library: Library(songs: [built.song]), song: built.song, transportHost: StubTransportHost())
        #expect(app.workHue == nil, "nothing is open")
        app.perform(SurfaceAction(surface: .grid, title: "New groove"))
        #expect(app.workHue == PartHue.index(for: .groove))
        app.showSurface(.library)
        #expect(app.workHue == nil)
    }

    // MARK: The phone

    /// Roboto Capture is drawn in Vibrant from the same numbers: its project compiles the shared
    /// file rather than a copy of it, so a hue retuned here is retuned there.
    @Test("Roboto Capture compiles the same palette file, and Vibrant is built from it")
    func thePhoneSharesThePalette() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("Capture/project.yml"), encoding: .utf8)
        #expect(project.contains("../Sources/MrRobotoApp/Design/SharedPalette.swift"))
        let phone = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Capture/RobotoCapture").path)
        #expect(!phone.contains("SharedPalette.swift"), "the phone keeps a copy instead of the shared file")

        let vibrant = Design.Palette.vibrant
        #expect(vibrant.paper.dark == SharedPalette.Vibrant.paper && vibrant.ink.dark == SharedPalette.Vibrant.ink)
        #expect(vibrant.lanes.map(\.dark) == SharedPalette.Vibrant.lanes)
        #expect(vibrant.accent.dark == SharedPalette.Vibrant.accent)
        #expect(SharedPalette.Vibrant.soft(SharedPalette.Vibrant.lanes[2]) == Design.Palette.workSoft(vibrant.lanes[2], over: vibrant.panel).dark)
        for name in ["Intro", "Verse 2", "Hook", "Bridge", "Outro", "Pre-Chorus", "Breakdown", "Whatever"] {
            #expect(SectionHue.index(for: name) == SharedPalette.sectionLane(for: name))
        }
    }
}
