import CoreGraphics
import Foundation

/// What the Record surface draws at the size it is actually handed.
///
/// Two things here are worth height and everything else is not:
///
/// * **The waveform.** It is how you pick the region you are going to promote, and you pick it by
///   eye against the downbeat marks drawn over it. 132 points was enough to see that a file has
///   audio in it and not enough to see where a bar starts.
/// * **The stem lanes.** Four of them — drums, bass, vocals, other — at `chipHeight` each was 112
///   points of a 665-point panel, and the four rows read as a list of file names rather than as the
///   four things the record was split into. Given room they become lanes you can aim at.
///
/// The readings row, the promote bar and the provenance form keep their sizes. They are forms; a
/// text field twice as tall is not a better text field.
public struct ImportLayout: Equatable, Sendable {

    /// The old fixed height, now the floor.
    public static let minimumWaveformHeight: CGFloat = 132
    public static let maximumWaveformHeight: CGFloat = 320
    public static let minimumStemLaneHeight: CGFloat = Design.Metric.chipHeight
    public static let maximumStemLaneHeight: CGFloat = 64
    public static let minimumSectionLaneHeight: CGFloat = 20
    public static let maximumSectionLaneHeight: CGFloat = 34

    public let size: CGSize
    public let contentSize: CGSize

    /// The plate the record is drawn on.
    public let waveformHeight: CGFloat
    /// One stem's row.
    public let stemLaneHeight: CGFloat
    /// The coloured bar inside a stem row: the row, less the space its label needs above and below.
    public let stemBarHeight: CGFloat
    /// One row of the sections-and-instruments strip.
    public let sectionLaneHeight: CGFloat
    public let sectionBarHeight: CGFloat
    /// The whole sections strip, for `lanes` rows.
    public let sectionStripHeight: CGFloat
    /// The drop well fills the panel rather than sitting as a 220-point box at the top of it.
    public let dropWellHeight: CGFloat
    /// The width the stem name column takes, which grows a little so "vocals" is not hyphenated.
    public let laneLabelWidth: CGFloat

    public init(size: CGSize, sectionLanes: Int = 1) {
        self.size = size
        let content = SurfaceGeometry.content(of: size)
        contentSize = content

        // Just under a third of the panel. At 460 that is the old 132; at 665 it is very nearly
        // 200, which is the difference between seeing the record and reading it.
        waveformHeight = clamped(content.height * 0.30,
                                 Self.minimumWaveformHeight, Self.maximumWaveformHeight)

        stemLaneHeight = clamped(content.height * 0.075,
                                 Self.minimumStemLaneHeight, Self.maximumStemLaneHeight)
        stemBarHeight = max(2, stemLaneHeight - 14)

        sectionLaneHeight = clamped(content.height * 0.032,
                                    Self.minimumSectionLaneHeight, Self.maximumSectionLaneHeight)
        sectionBarHeight = max(8, sectionLaneHeight - 8)
        sectionStripHeight = CGFloat(max(1, sectionLanes)) * sectionLaneHeight

        // The header is the only thing above it, so the well is everything else.
        dropWellHeight = max(220, content.height - 52)

        laneLabelWidth = clamped(content.width * 0.09, 70, 130)
    }
}
