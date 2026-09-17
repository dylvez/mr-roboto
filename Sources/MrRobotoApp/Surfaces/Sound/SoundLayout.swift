import CoreGraphics
import Foundation

/// What the Sound surface does with room it did not ask for.
///
/// Sound is the surface most likely to look bad stretched, and it is worth saying why: it is a
/// column of five or six sliders. A slider gains nothing past about 400 points — the value under
/// your cursor is already finer than the thing it controls — and six sliders drawn at 1233 points
/// wide with 400 points of white beside each is not a fuller panel, it is a broken one. So the
/// answer here is deliberately *not* "let the controls grow".
///
/// What earns the extra room, in order:
///
/// 1. **A readout of the voice being edited.** The surface's whole argument is that you are
///    checking a 909's sweep against a 909 by ear, and "0.62" is not something you can check. With
///    height to spend, the voice gets a plate at the top: its name set large, the machine and preset
///    it came from, and the two prominent knobs' values *in their real units* — `DECAY 900 ms`,
///    `TUNE 49.4 Hz` — at a size you can read from where you are sitting rather than at 12 points
///    beside a slider.
/// 2. **The A/B.** `Dry` is a true bypass and is the single most useful control on the panel, and it
///    was two 28-point chips in a corner. In the readout it is a pair of full-height controls.
/// 3. **The parameters' real units, inline.** A quiet control's `honestly` line — "sets the pitch
///    sweep's length, not the pitch" — was a tooltip, which is to say invisible. With width to
///    spend it is drawn under the control that needs it.
/// 4. **A third column of quiet controls**, and only at 1269: the nine-stage chain in two columns
///    is a tall list, in three it is a panel.
///
/// The sliders themselves are capped at `maximumControlWidth` and stay there. That is the point.
public struct SoundLayout: Equatable, Sendable {

    /// A slider past this is not more precise, only longer.
    public static let maximumControlWidth: CGFloat = 480
    public static let minimumControlWidth: CGFloat = 260

    /// The height at which the voice readout earns its place. Below it the panel is a column of
    /// controls and adding a banner would take room from the controls to say less.
    public static let readoutThreshold: CGFloat = 520
    /// The width at which the quiet grid takes a third column.
    public static let thirdColumnThreshold: CGFloat = 1_080
    /// The width at which the prominent controls sit side by side rather than stacked.
    public static let twoUpThreshold: CGFloat = 820

    public let size: CGSize
    public let contentSize: CGSize

    /// Whether the voice readout plate is drawn.
    public let showsVoiceReadout: Bool
    public let readoutHeight: CGFloat
    /// The voice's name, in points. 0 when there is no readout.
    public let readoutNameSize: CGFloat
    /// The prominent knobs' real units inside the readout.
    public let readoutValueSize: CGFloat

    /// Columns in the prominent block: one lever per row at the minimum, two side by side above it.
    public let prominentColumns: Int
    /// Columns in the quiet grid.
    public let quietColumns: Int
    /// The width one control row takes — capped, always.
    public let controlWidth: CGFloat
    /// Whether a quiet control draws its `honestly` line rather than hiding it in a tooltip.
    public let showsInlineUnits: Bool
    /// Whether the A/B is drawn as full-height controls in the readout instead of header chips.
    public var showsLargeMonitorSwitch: Bool { showsVoiceReadout }

    public init(size: CGSize) {
        self.size = size
        let content = SurfaceGeometry.content(of: size)
        contentSize = content

        showsVoiceReadout = content.height >= Self.readoutThreshold
        readoutHeight = showsVoiceReadout ? clamped(content.height * 0.16, 88, 132) : 0
        readoutNameSize = showsVoiceReadout ? clamped(content.height * 0.042, 22, 30) : 0
        readoutValueSize = showsVoiceReadout ? clamped(content.height * 0.026, 15, 19) : 0

        prominentColumns = content.width >= Self.twoUpThreshold ? 2 : 1
        quietColumns = content.width >= Self.thirdColumnThreshold ? 3 : 2

        let share = content.width / CGFloat(prominentColumns) - Design.Metric.gutter
        controlWidth = clamped(share, Self.minimumControlWidth, Self.maximumControlWidth)

        showsInlineUnits = showsVoiceReadout || content.width >= Self.thirdColumnThreshold
    }
}
