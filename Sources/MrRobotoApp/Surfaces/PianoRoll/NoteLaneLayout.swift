import CoreGraphics
import Foundation

/// Where the Piano roll's lane draws everything: a row for every pitch of the register, the kick
/// lane under the lowest of them, the pitch names beside them, and a beat's width across.
///
/// A row was an equal share of the lane's height, held to a 9-point floor, and nothing held the
/// lane to the register. A tune's two octaves are 25 rows, 225 points at that floor; in a lane drawn
/// shorter than that, the lowest rows ran past its bottom and under the kick lane. C4's name was set
/// below "kick", and a note on C4 sat hidden under the kicks, out of reach of a click.
///
/// So the register sets the lane's floor (`minimumHeight(rows:)`): every row at the smallest row the
/// roll draws, then the kick lane. The view never draws the lane shorter, and a bench without that
/// much room scrolls the surface's work instead. The layout holds the same line on its own: handed
/// less than the floor, it draws at the floor, past its frame, rather than put a row under the kicks.
///
/// Across, a short line fills the width; a long one keeps a beat wide enough to hit a sixteenth and
/// scrolls sideways under the pitch names, rather than squeezing sixteen bars into the panel until
/// nothing can be grabbed.
///
/// That floor is a sixteenth seven points wide, which is grabbable and not much more. A line
/// doubled to eight or sixteen bars is the one you then want to vary bar by bar, so the lane can be
/// looked at closer: `beatsAcross` is how much of the line fills the width — four bars of it, two,
/// one — and the rest scrolls. Closer is never narrower than the whole line, so a level wider than
/// the line is the line itself, and zoom is only ever a wider beat.
public struct NoteLaneLayout: Equatable, Sendable {

    /// The pitch names' column, which stays put while a long line scrolls under it.
    public static let labelWidth: CGFloat = 34
    public static let kickLaneHeight: CGFloat = 18
    /// Between the lowest row and the kick lane.
    public static let kickGap: CGFloat = 4
    /// The smallest a pitch's row is drawn: a note this tall can still be grabbed.
    public static let minimumRowHeight: CGFloat = 9
    /// The narrowest a beat is drawn before the lane scrolls instead: a sixteenth at this width is
    /// still wider than the smallest note the roll draws, so every note stays grabbable.
    public static let minimumBeatWidth: CGFloat = 28
    /// The line a pitch's name, or "kick", is set on: the numeric face at its smallest size.
    public static let labelHeight: CGFloat = 12

    /// The shortest the lane is drawn for a register of `rows` pitches: each at the smallest row,
    /// then the gap and the kick lane. Two octaves are 247 points.
    public static func minimumHeight(rows: Int) -> CGFloat {
        CGFloat(max(1, rows)) * minimumRowHeight + kickGap + kickLaneHeight
    }

    /// The right edge of a note, where a drag lengthens it: the trailing third of the note, at most
    /// eight points, and none at all on a note under twenty points wide. The edge used to be the
    /// last eight points of every note, which on a long line at the floor — an eighth fourteen
    /// points wide — was most of the note, so most drags lengthened it and a drag up or down to
    /// move it did nothing. A short note is moved from anywhere on it, and lengthened zoomed in.
    public static func resizeHandle(forNoteWidth width: CGFloat) -> CGFloat {
        width >= 20 ? min(8, width / 3) : 0
    }

    public let rows: Int
    /// One pitch's row: an equal share of the rows' height, never under `minimumRowHeight`.
    public let rowHeight: CGFloat
    /// The rows, top to bottom: the register and nothing else. The kick lane starts under it.
    public let rowsHeight: CGFloat
    /// The room beside the pitch names.
    public let visibleWidth: CGFloat
    public let beatWidth: CGFloat
    /// Every beat of the line, end to end: the width the scrolled content is drawn at.
    public let gridWidth: CGFloat
    /// True when the line is wider than the room beside the names, and so scrolls sideways.
    public let scrolls: Bool

    /// - Parameters:
    ///   - beats: every beat of the line.
    ///   - beatsAcross: how many of them fill the width, or nil for all of them: the whole line
    ///     across, or scrolling at the floor once it is too long for that. Never more than the
    ///     line has, so a level wider than the line is the whole line.
    public init(size: CGSize, rows: Int, beats: Double, beatsAcross: Double? = nil) {
        self.rows = max(1, rows)
        rowsHeight = max(CGFloat(self.rows) * Self.minimumRowHeight,
                         size.height - Self.kickGap - Self.kickLaneHeight)
        rowHeight = rowsHeight / CGFloat(self.rows)
        visibleWidth = max(1, size.width - Self.labelWidth)
        let beats = CGFloat(max(1, beats))
        let across = min(beats, CGFloat(max(1, beatsAcross ?? Double(beats))))
        beatWidth = max(Self.minimumBeatWidth, visibleWidth / across)
        gridWidth = beatWidth * beats
        scrolls = gridWidth > visibleWidth + 0.5
    }

    /// The lane as drawn: the rows, the gap and the kick lane. Taller than the size it was handed
    /// only when that was under its floor.
    public var height: CGFloat { rowsHeight + Self.kickGap + Self.kickLaneHeight }

    /// Where the kick lane starts: under the lowest row, whatever the lane was handed.
    public var kickLaneTop: CGFloat { rowsHeight + Self.kickGap }

    /// Where a row starts. Row 0 is the register's highest pitch.
    public func top(ofRow row: Int) -> CGFloat { CGFloat(row) * rowHeight }

    /// The row under a point, held to the register: the lane's bottom edge is its lowest pitch, never
    /// the one under it.
    public func row(atY y: CGFloat) -> Int {
        clamped(Int((y / rowHeight).rounded(.down)), 0, rows - 1)
    }

    /// Where a pitch's name is set: at the top of its row, where a C's line is drawn.
    public func labelTop(ofRow row: Int) -> CGFloat { top(ofRow: row) - 2 }

    /// Where "kick" is set: in the kick lane, below every pitch's name.
    public var kickLabelTop: CGFloat { kickLaneTop + 2 }
}
