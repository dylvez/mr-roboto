/// The colours the Mac app and Roboto Capture share, as numbers.
///
/// Pure Swift — no AppKit, no UIKit, no SwiftUI — because the phone's project compiles this same
/// file (`Capture/project.yml` lists it), so a hue cannot be retuned on one and not the other: a
/// verse is the same blue on the phone it is sung on as on the Mac it lands in. Each app turns
/// these into its own colours.
enum SharedPalette {

    /// Vibrant Dark: near-black, with the music's colours at full strength. `Design.Palette.dark`
    /// is built from these, the Mac's other two palettes take their plates and the colours drawn on
    /// them from here, and Roboto Capture is drawn in them.
    enum Vibrant {
        static let paper: UInt32 = 0x09090b
        static let panel: UInt32 = 0x121215
        static let panelAlt: UInt32 = 0x0e0e11
        static let raised: UInt32 = 0x1a1a1f
        static let ink: UInt32 = 0xf4f4f8
        static let inkSecondary: UInt32 = 0xbdbdc8
        static let inkTertiary: UInt32 = 0x8d8d99
        static let inkQuiet: UInt32 = 0x585862
        static let line: UInt32 = 0x29292f
        static let lineStrong: UInt32 = 0x37373f
        /// The translucent grey a control's fill is made of, at 14%, 20% and 30%.
        static let fillGrey: UInt32 = 0x8e8e9a
        /// The accent with nothing to follow: Studio's blue, turned up.
        static let accent: UInt32 = 0x5c8dff
        static let accentSoft: UInt32 = 0x18233f
        static let warn: UInt32 = 0xffc247
        static let warnSoft: UInt32 = 0x3a2c0c
        static let danger: UInt32 = 0xff5a52
        static let dangerSoft: UInt32 = 0x3d1414
        static let soundingInk: UInt32 = 0xff9d4f
        static let mute: UInt32 = 0x4fb3e8
        static let ok: UInt32 = 0x3ddc84
        static let plate: UInt32 = 0x060608
        static let trace: UInt32 = 0x7cc4ff
        static let lcdInk: UInt32 = 0xe8f2ff
        static let lcdLabel: UInt32 = 0x8696aa
        static let lcdRecording: UInt32 = 0x2a0b0a
        static let lcdRecordingInk: UInt32 = 0xffc4bf

        /// Kick, snare, closed hat, open hat, clap, perc, toms, cymbal — and, borrowed in the same
        /// order, the parts' and the sections' hues. Lightness alternates down the list, chroma as
        /// far as sRGB goes, and each reads at 4.5:1 or better as text on the paper, so any of them
        /// can be the accent.
        static let lanes: [UInt32] = [0xff4d6a, 0x36c5ff, 0xf5d63a, 0x1fd6c4, 0xb083ff, 0x4fe07f, 0xff4fc0, 0xa6b9ff]

        /// A selected row's tint when the accent is a lane's: the lane at 18% over the panel.
        static func soft(_ lane: UInt32) -> UInt32 { mix(panel, lane, 0.18) }
    }

    /// The meanings no palette changes. Orange is what is sounding, the TR-808's step-key orange
    /// the app icon is drawn in; the ink on it is near-black. Solo is a desk's yellow.
    static let sounding: UInt32 = 0xf97f23
    static let onSounding: UInt32 = 0x24160a
    static let solo: UInt32 = 0xffd60a

    /// The lane a part wears, by its kind, the way a desk colours its tracks.
    enum PartLane {
        static let melody = 1
        static let groove = 2
        static let progression = 3
        static let bassline = 4
        /// Audio: a record, a take, an idea from the phone.
        static let audio = 5
        static let sample = 6
        static let lyric = 7
    }

    /// A section's lane, by its kind, so a verse is the same colour in every song. Names the app
    /// writes — Intro, Verse, Hook, Bridge, Outro and their numbered kin — get fixed hues; anything
    /// else gets one from its letters, so it is at least the same every time.
    static func sectionLane(for name: String) -> Int {
        let word = name.lowercased()
        // Neighbours in a form get hues apart: an intro's green against a verse's blue, a verse's
        // blue against a hook's gold. The kick's red is left to the drums, where it means kick; on
        // a section it would read as record.
        let kinds: [(keys: [String], lane: Int)] = [
            (["pre-chorus", "prechorus", "pre-hook", "pre chorus", "build"], 4),
            (["intro"], 5),
            (["verse"], 1),
            (["hook", "chorus", "refrain"], 2),
            (["bridge", "middle"], 6),
            (["break", "drop", "solo", "interlude"], 7),
            (["outro", "ending", "coda", "tag"], 3),
        ]
        for kind in kinds where kind.keys.contains(where: word.contains) { return kind.lane }
        return 1 + word.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 7
    }

    /// `top` laid over `base` at `amount`, channel by channel.
    static func mix(_ base: UInt32, _ top: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let b = Double((base >> shift) & 0xff), t = Double((top >> shift) & 0xff)
            return UInt32((b + (t - b) * amount).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}
