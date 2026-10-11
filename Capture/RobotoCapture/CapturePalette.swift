import SwiftUI

/// Roboto Capture's colours: Vibrant, from the numbers the Mac app is drawn in (`SharedPalette`,
/// compiled into both). Near-black, the music's colours at full strength, and an accent that is
/// the colour of what is being recorded — a verse's blue, a hook's gold, an idea's green — so the
/// phone and the Mac agree on what a section looks like.
enum CapturePalette {
    private typealias V = SharedPalette.Vibrant

    static let paper = Color(hex: V.paper)
    static let panel = Color(hex: V.panel)
    static let raised = Color(hex: V.raised)
    static let ink = Color(hex: V.ink)
    static let inkSecondary = Color(hex: V.inkSecondary)
    static let inkTertiary = Color(hex: V.inkTertiary)
    static let inkQuiet = Color(hex: V.inkQuiet)
    static let line = Color(hex: V.line)
    static let fill = Color(hex: V.fillGrey).opacity(0.14)
    static let warn = Color(hex: V.warn)
    static let danger = Color(hex: V.danger)
    static let ok = Color(hex: V.ok)
    /// What is making sound: the level of what the microphone hears.
    static let sounding = Color(hex: SharedPalette.sounding)
    static let plate = Color(hex: V.plate)
    static let lcdInk = Color(hex: V.lcdInk)
    static let lcdLabel = Color(hex: V.lcdLabel)
    static let lcdRecording = Color(hex: V.lcdRecording)
    static let lcdRecordingInk = Color(hex: 0xffc4bf)

    /// One of the eight hues, by lane, wrapping.
    static func lane(_ index: Int) -> Color {
        let lanes = V.lanes
        return Color(hex: lanes[((index % lanes.count) + lanes.count) % lanes.count])
    }

    /// The accent: the lane of the work, or Vibrant's blue with nothing to follow.
    static func accent(_ lane: Int?) -> Color {
        lane.map(Self.lane) ?? Color(hex: V.accent)
    }

    /// A row's tint under the accent, for the lane of the work.
    static func soft(_ lane: Int?) -> Color {
        Color(hex: lane.map { V.soft(V.lanes[(($0 % 8) + 8) % 8]) } ?? V.accentSoft)
    }
}

extension Color {
    /// An sRGB colour from a 0xRRGGBB value.
    init(hex value: UInt32) {
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

extension Recorder {
    /// The lane of what the next take is for: the section's, for a take on a song — a verse is
    /// blue here as on the Mac — and audio's green for an idea. Nil for a take on a song with no
    /// section named, which keeps Vibrant's blue.
    var workLane: Int? {
        if song.isEmpty { return SharedPalette.PartLane.audio }
        let name = guide?.name ?? section
        return name.isEmpty ? nil : SharedPalette.sectionLane(for: name)
    }
}

extension Capture {
    /// The lane a capture wears in the list: its section's, or an idea's green.
    var lane: Int {
        if song.isEmpty { return SharedPalette.PartLane.audio }
        return section.isEmpty ? SharedPalette.PartLane.audio : SharedPalette.sectionLane(for: section)
    }
}
