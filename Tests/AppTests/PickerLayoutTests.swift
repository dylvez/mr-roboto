import AppKit
import Foundation
import Instrument
import MusicTheory
import Performance
import SwiftUI
import Testing

@testable import MrRobotoApp

// Chips, or a menu? The rule is written on `ChipMenu`: a set stays as chips only when the whole of
// it fits in one row at the window's minimum and its options are peers compared at a glance;
// anything larger, and anything with a hierarchy in it, is a menu. The instrument, the bass sound
// and the hands were walls of pills — fourteen family chips and the browsed family's instruments
// in two rows under them, thirty-six sounds in three rows, fifteen hands in one that ran off the
// bench — and open from one chip now. These hold the rows that stay chips to the one-row half of
// the rule, and hold the menus to the height they won back, measured the way `PianoRollLaneTests`
// measures: drawn through `ImageRenderer` at the three widths a surface's content is laid out in.
//
// "What the chips took" is what the same blocks drew before the change, read off this rig on
// 2026-10-15. The numbers are kept rather than derived so that a return to chips, or a sixth
// lever, has to walk past them.

@Suite("Pickers: chips where a row fits, menus for the rest") @MainActor
struct PickerLayoutTests {

    /// The widths a surface's content is laid out in: 608 at the window's minimum, 1022 at the
    /// default window, 1318 with the side regions folded.
    private static var widths: [CGFloat] { SurfaceGeometry.all.map { SurfaceGeometry.content(of: $0).width } }

    /// How big a view draws when offered `width` and, when given, `height`; nothing proposed is
    /// the view's own size.
    private func drawn<V: View>(_ view: V, width: CGFloat? = nil, height: CGFloat? = nil) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        return try #require(renderer.nsImage).size
    }

    private func bass() -> PianoRollModel {
        PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
    }

    private func chords() -> ChordsModel {
        let model = ChordsModel(host: ChordsStub(), key: Key.cMajor)
        model.autoKeep.delay = nil
        model.text = "Dm7 G7 | Cmaj7 | Am7 | Fmaj7"
        return model
    }

    /// A row of chips as the surfaces draw one, at its own width: what a set of titles costs.
    private func row(_ titles: [String]) throws -> CGFloat {
        try drawn(HStack(spacing: 4) { ForEach(titles, id: \.self) { FormChip($0, isOn: false) {} } }).width
    }

    /// The room a row has beside its label at a width: the chords' rows give the label 58 points
    /// and 8 after it; the roll's Length row is about the same.
    private func room(at width: CGFloat) -> CGFloat { width - 66 }

    // MARK: The menus, and what they won back

    @Test("The bass levers share one row from the default window up and take two at the minimum, where the chips took three and four")
    func bassLeversFitTheirRows() throws {
        FontRegistration.registerBundledFonts()
        let model = bass()
        let heights = try Self.widths.map { try drawn(BassLevers(model: model), width: $0).height }
        // One row of levers is its tallest column: a label, a chip and the sound's two-line summary.
        let oneRow: CGFloat = 72
        #expect(heights[1] <= oneRow, "the default window: one row, \(heights[1])")
        #expect(heights[2] <= oneRow, "folded: one row, \(heights[2])")
        #expect(heights[0] <= 2 * oneRow + 12, "the minimum: two rows and the gap, \(heights[0])")
        // What the chips took: 244 at the minimum, 193 at the default window, 142 folded.
        for (height, chips) in zip(heights, [244, 193, 142] as [CGFloat]) {
            #expect(height <= chips - 70, "\(height) against the chips' \(chips)")
        }
    }

    @Test("The lane gets the height the chips took: at the default window the work no longer scrolls, and the lane fills what is left")
    func laneGetsTheHeightBack() throws {
        FontRegistration.registerBundledFonts()
        let model = bass()
        let standard = SurfaceGeometry.standard
        // The surface at its own height is its chrome and the lane at its floor, caption and all.
        let whole = try drawn(PianoRollSurfaceView(model: model), width: standard.width).height
        let floor = try drawn(NoteLane(model: model), width: standard.width).height
        // With the chips the work was 799 points at its floor, in a bench of 798: it scrolled, and
        // the lane was drawn at its floor. Now it fits, with a hundred points and more to spare.
        #expect(whole < standard.height)
        #expect(whole <= 799 - 100, "\(whole) against the chips' 799")
        // What the lane is handed when the work fits: the bench less the chrome.
        let lane = standard.height - (whole - floor)
        #expect(lane >= floor + 100, "the lane gets \(lane) over its floor of \(floor)")
        // At the minimum the work still scrolls — the register alone is most of 460 — but there is
        // a hundred points less of it to scroll past than the chips' 864.
        let tight = try drawn(PianoRollSurfaceView(model: model), width: SurfaceGeometry.minimum.width).height
        #expect(tight <= 864 - 100, "\(tight) against the chips' 864")
    }

    @Test("The instrument is one chip and its line at every width; it was a row of families and two of instruments")
    func instrumentIsOneChip() throws {
        FontRegistration.registerBundledFonts()
        for width in Self.widths {
            let height = try drawn(InstrumentPicker(selected: InstrumentVoiceSpec.rhodes.id) { _ in }, width: width).height
            // A label, the chip, and the one-line character of the instrument.
            #expect(height <= 64, "\(height) at \(width)")
        }
        // What the chips took: 144 at the minimum, 90 from the default window up.
    }

    @Test("The chords' controls are shorter at every width, so the bars sit higher on the sheet")
    func chordsControlsAreShorter() throws {
        FontRegistration.registerBundledFonts()
        let model = chords()
        let heights = try Self.widths.map { try drawn(ChordsControls(model: model), width: $0).height }
        // What the chips took: 352 at the minimum, 246 from the default window up. The minimum
        // wins back the most, because that is where the families' row wrapped.
        for (height, chips) in zip(heights, [352, 246, 246] as [CGFloat]) {
            #expect(height < chips, "\(height) against the chips' \(chips)")
        }
        #expect(heights[0] <= 352 - 70)
        #expect(heights[1] <= 246 - 20)
    }

    // MARK: The rows that stay chips

    @Test("Bass or Melody, the lengths with Double and Tighten, Voiced, and the tune's other ways each fit one row at the window's minimum")
    func rowsThatStayFitOneRow() throws {
        FontRegistration.registerBundledFonts()
        let minimum = Self.widths[0]
        let modes = try drawn(SegmentedChoice(options: PianoRollModel.Mode.allCases, selection: .bass, title: \.title) { _ in }).width
        #expect(modes <= room(at: minimum))
        // The Length row: the counts, "bars", Double and Tighten.
        let lengths = PianoRollModel.lengthChoices.map(String.init) + ["bars", "Double", "Tighten"]
        #expect(try row(lengths) <= room(at: minimum))
        #expect(try row(KeysVoicing.allCases.map(\.name)) <= room(at: minimum))
        let ways = PianoRollModel.tuneWaysOffered.map { Develop.tuneTitle($0, twice: true) }
        #expect(try row(ways) <= room(at: minimum))
    }

    @Test("Played's ten patterns and the sheet's six other ways are the rule's exceptions: two rows at the minimum, one from the default window, kept as chips because they are peers")
    func rowsAllowedASecondLine() throws {
        FontRegistration.registerBundledFonts()
        let minimum = Self.widths[0], standard = Self.widths[1]
        let patterns = try row(KeysPattern.allCases.map(\.name))
        let moves = try row(chords().anotherWays.map(\.move.name))
        // They do not fit the minimum in one row — which is why they are named here rather than
        // assumed — and do fit it in two: the wrap is one line, not a wall.
        for width in [patterns, moves] {
            #expect(width > room(at: minimum))
            #expect(width <= 2 * room(at: minimum))
            #expect(width <= room(at: standard))
        }
    }

    // MARK: The menu's face

    @Test("A chip's menu wears the chip's own face: a chip's height, the name and a chevron, no wider than it needs")
    func menuWearsTheChip() throws {
        FontRegistration.registerBundledFonts()
        let menu = try drawn(ChipMenu("Palladino") { Text("Palladino") })
        let chip = try drawn(FormChip("Palladino", isOn: false) {})
        #expect(menu.height == Design.Metric.chipHeight)
        #expect(menu.height == chip.height)
        // The chevron and its gap, and nothing more.
        #expect(menu.width > chip.width && menu.width < chip.width + 20)
    }
}
