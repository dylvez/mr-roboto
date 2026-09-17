import SongGraph
import SwiftUI

/// Play, stop, loop, the key and tempo the clock runs at, and the section strip with the active
/// section lit. The strip's blocks are proportional to each section's length in bars, as in the
/// mockups: a bridge is visibly shorter than a chorus.
struct TransportBar: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 36) {
            controls
            keyAndTempo
            sectionStrip
        }
        .padding(.horizontal, 40)
        .frame(height: FrameLayout.transportHeight)
        .background(Design.Palette.paper)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                Task { await app.toggleTransport() }
            } label: {
                Image(systemName: app.transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Design.Palette.ink)
            }
            .buttonStyle(.plain)
            .help("Play or stop (Space)")

            Button {
                Task { await app.stopTransport() }
            } label: {
                Image(systemName: "stop")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(app.transport == .stopped ? Design.Palette.inkTertiary : Design.Palette.ink)
            }
            .buttonStyle(.plain)
            .help("Stop")

            Button {
                app.toggleLoop()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(app.isLooping ? Design.Palette.accent : Design.Palette.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Loop")

            if case .unavailable(let reason) = app.transport {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Design.Palette.warn)
                    .help("The transport could not start: \(reason)")
            }
        }
    }

    private var keyAndTempo: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(app.song?.key?.name ?? "No key")
                .font(Design.Typography.ui(17, weight: .medium))
                .foregroundStyle(app.song?.key == nil ? Design.Palette.inkTertiary : Design.Palette.ink)
            Text("\(Int(app.clock.tempo.rounded())) bpm")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Text(app.clock.timeSignature.description)
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    @ViewBuilder
    private var sectionStrip: some View {
        let sections = app.song?.sections ?? []
        if sections.isEmpty {
            Text(app.song == nil ? "No song open" : "No sections yet")
                .font(Design.Typography.ui(12, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(sections) { section in
                    Button {
                        app.setActiveSection(section.id)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(app.activeSection == section.id ? Design.Palette.accent : Design.Palette.ink)
                                .frame(width: TransportBar.blockWidth(bars: section.lengthInBars), height: 10)
                            Text(section.name.uppercased())
                                .font(Design.Typography.label)
                                .tracking(1.1)
                                .foregroundStyle(app.activeSection == section.id ? Design.Palette.accent : Design.Palette.inkSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(section.name) · \(section.lengthInBars) bars")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Five points a bar, floored so a two-bar turnaround is still hittable and capped so a
    /// thirty-two-bar section does not push the strip off the window.
    nonisolated static func blockWidth(bars: Int) -> CGFloat {
        min(120, max(24, CGFloat(bars) * 5))
    }
}
