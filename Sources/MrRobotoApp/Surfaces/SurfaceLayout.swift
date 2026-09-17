import CoreGraphics
import Foundation

/// The sizes a surface is actually drawn in, and the arithmetic every surface's own layout shares.
///
/// The frame was rebuilt so that one surface fills the bench: 907 × 665 at the default window,
/// 1269 wide with the side regions folded away, and 640 × 460 at the window's minimum
/// (`FrameLayout`, asserted in `LayoutTests`). Every surface in the catalog, though, was authored
/// when a surface got about 610 × 253 — so each of them sized itself to its content and top-aligned
/// in 665 points with dead space underneath.
///
/// The fix is not "add `maxHeight: .infinity`". Stretching a control is not the same as using the
/// room: a slider dragged out to 1233 points is *worse* than one at 400. So each surface answers the
/// question deliberately, in a plain value that a test can hold to the three real geometries:
///
/// * `ChopLaneLayout` — the plate takes the height the pads do not need, because a taller plate is a
///   more precise marker drag; the pad grid derives its column count from the real width.
/// * `ImportLayout` — the waveform and the stem lanes expand; four stems in a tall panel are
///   readable rather than four 28-point slivers.
/// * `GridLayout` — the steps take the width and the voice rows take the height.
/// * `SoundLayout` — the extra room buys a readout of the voice being edited, the A/B at a size you
///   can hit, and the parameters' real units inline. The sliders themselves are *capped*.
///
/// Keeping these as values rather than as view modifiers is the whole point: `FillLayoutTests` can
/// ask each one what it would draw at 640 × 460, 907 × 665 and 1269 × 665 without a window, so a
/// later change back to a fixed size has to walk past a failing test.
public enum SurfaceGeometry {

    /// The window's minimum: every region folded, one surface at the size the tokens say it needs.
    public static var minimum: CGSize {
        CGSize(width: FrameLayout.surfaceMinimumWidth, height: FrameLayout.surfaceMinimumHeight)
    }

    /// The default window, with the session rail folded as a first launch folds it.
    public static var standard: CGSize {
        CGSize(width: FrameLayout.surfaceWidth(inWindowOfWidth: FrameLayout.defaultWindowWidth,
                                               collapsed: FrameLayout.defaultCollapsedRegions),
               height: FrameLayout.surfaceHeight(inWindowOfHeight: FrameLayout.defaultWindowHeight,
                                                 visibleSurfaces: 1))
    }

    /// The same window with all three side regions folded away: the widest a surface gets at 1440.
    public static var wide: CGSize {
        CGSize(width: FrameLayout.surfaceWidth(inWindowOfWidth: FrameLayout.defaultWindowWidth,
                                               collapsed: Set(FrameRegion.allCases)),
               height: FrameLayout.surfaceHeight(inWindowOfHeight: FrameLayout.defaultWindowHeight,
                                                 visibleSurfaces: 1))
    }

    /// The three, in the order a test should read them: tightest first.
    public static var all: [CGSize] { [minimum, standard, wide] }

    /// A surface is handed the bench's cell; its own inset is what is left to lay out in.
    static func content(of size: CGSize, inset: CGFloat = Design.Metric.inset) -> CGSize {
        CGSize(width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
    }
}

/// `min(max(value, low), high)`, spelled once. Every layout below leans on it, and the name is the
/// intent: a surface grows *within bounds*, it does not stretch.
func clamped(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    min(max(value, low), max(low, high))
}

func clamped(_ value: Int, _ low: Int, _ high: Int) -> Int {
    min(max(value, low), max(low, high))
}
