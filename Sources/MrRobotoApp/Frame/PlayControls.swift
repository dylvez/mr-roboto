import SongGraph
import SwiftUI

// The same play control everywhere: a surface's header, a row of the parts ledger, and what is
// sounding in the transport bar. They all ask one `PartPlayer`.

/// In a surface's header: plays what the surface is about, and says what that is.
struct SurfacePlayControl: View {
    let item: BenchItem
    let app: AppState

    var body: some View {
        let player = SurfaceWiring.shared.player(for: app)
        if let audition = SurfaceWiring.shared.audition(for: item, app: app) {
            let isPlaying = player.isPlaying(audition.id)
            Button {
                if isPlaying { player.stop() } else { Task { await audition.play(player) } }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .medium))
                    Text(isPlaying ? "Stop" : "Play \(audition.label)")
                        .font(Design.Typography.ui(11.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 9)
                .frame(height: Design.Metric.chipHeight)
                .foregroundStyle(isPlaying ? Design.Palette.panel : Design.Palette.accent)
                .background(isPlaying ? Design.Palette.accent : Design.Palette.accentSoft, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.accent.opacity(0.45), lineWidth: Design.Metric.hairline))
            }
            .buttonStyle(.plain)
            .help("Play \(audition.label) (⌥Space for the surface in front). Space plays the whole song.")
        } else if ![SurfaceKind.album, .cast, .compare, .check].contains(item.kind) {
            // The same place on every surface, even before there is anything to hear.
            HStack(spacing: 5) {
                Image(systemName: "play.fill").font(.system(size: 9, weight: .medium))
                Text("Nothing to play yet").font(Design.Typography.ui(11.5)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 9)
            .frame(height: Design.Metric.chipHeight)
            .foregroundStyle(Design.Palette.inkTertiary)
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
            .help("This surface plays from here once it holds something: a painted step, a note, a chord, a selection.")
        }
    }
}

/// On a row of the ledger: plays that version.
struct PartPlayButton: View {
    let version: PartVersion
    let app: AppState
    var size: CGFloat = 9

    var body: some View {
        if PartPlayer.canPlay(version) {
            let player = SurfaceWiring.shared.player(for: app)
            let isPlaying = player.isPlaying(version)
            Button { player.toggle(version) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: size, weight: .medium))
                    .frame(width: size + 11, height: size + 11)
                    .foregroundStyle(isPlaying ? Design.Palette.panel : Design.Palette.accent)
                    .background(isPlaying ? Design.Palette.accent : Design.Palette.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop" : "Play \(PartLabel.title(of: version)) — \(player.mode == .alone ? "alone" : "in the song")")
        }
    }
}

/// In the transport bar: what is sounding, one Stop for it, and whether a part plays alone or in the song.
struct NowPlayingReadout: View {
    let app: AppState

    var body: some View {
        let player = SurfaceWiring.shared.player(for: app)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("PARTS PLAY").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
                ForEach(PartPlayer.Mode.allCases, id: \.self) { mode in
                    BoothChip(mode.title, isOn: player.mode == mode) { player.mode = mode }
                }
            }
            HStack(spacing: 6) {
                if let playing = player.nowPlaying {
                    Button { player.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(Design.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Stop \(playing.label)")
                    Text(playing.label).font(Design.Typography.ui(11, weight: .medium)).foregroundStyle(Design.Palette.accent).lineLimit(1)
                } else {
                    Text(player.lastError ?? "Nothing auditioning").font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(player.lastError == nil ? Design.Palette.inkTertiary : Design.Palette.warn).lineLimit(1)
                }
            }
        }
        .frame(width: 230, alignment: .leading)
        .help("A play button on a surface or a part plays it alone, or starts the song so you hear it in place. This says what is sounding.")
    }
}
