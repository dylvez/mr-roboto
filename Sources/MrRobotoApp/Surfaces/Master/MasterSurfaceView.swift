import SongGraph
import SwiftUI

/// The Master on its own: the song's title and targets over the same panel the Mixer's Master tab
/// draws. The Director opens this one by name; the Mixer carries the Master as a tab, working on
/// the Mixer's own mix.
struct MasterSurfaceView: View {
    @Bindable var model: MasterModel
    /// The frame, when the registry hands one over: what an export needs. A view built from its
    /// model alone (a render, a test) has none, and points at the menu instead.
    var app: AppState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Scrolls rather than clips: at the bench's minimum the Engineer drops under the
            // numbers, and what it says is the point of reading at all.
            MixScroll(.vertical) {
                MasterPanel(model: model)
            }
            MasterFooter(model: model, app: app)
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.song?.title ?? "Master").font(Design.Typography.prose(16, weight: .medium))
                .lineLimit(1)
            Text(String(format: "target %.0f LUFS · ceiling %.1f dBTP", model.mix.master.targetLUFS, model.mix.master.ceilingDBTP))
                .font(Design.Typography.numeric(12)).foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
