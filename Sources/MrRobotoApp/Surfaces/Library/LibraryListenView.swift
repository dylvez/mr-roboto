import SongGraph
import SwiftUI

/// Hearing the chosen item: play and stop, and where it has got to. A record also shows which of
/// it is heard — the whole record or a stem — and its shape with its bar lines: press a bar to
/// play from it, drag across bars to choose them, then loop them or bring them into the song.
struct LibraryListen: View {
    let facts: LibraryFacts
    let model: LibraryBrowserModel
    /// The bar a drag across the strip started on.
    @State private var dragFrom: Int?

    private var preview: LibraryPreview { model.preview }
    private var isRecord: Bool { facts.id.shelf == .records && preview.record?.rawValue == facts.id.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel("Listen", color: Design.Palette.inkTertiary)
            HStack(spacing: 10) {
                playButton
                status
                Spacer(minLength: 0)
            }
            if isRecord {
                if !preview.stems.isEmpty { stemChips }
                strip
                if preview.bars != nil { barsRow }
            }
        }
    }

    // MARK: Play, stop, where

    private var playButton: some View {
        let sounding = preview.isSounding(facts.id) && !loopingChosenBars
        return Button {
            Task {
                if sounding { await preview.stop() } else { await preview.play(facts.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sounding ? "stop.fill" : "play.fill").font(.system(size: 10, weight: .bold))
                Text(sounding ? "Stop" : facts.id.shelf == .songs ? "Play the song" : facts.id.shelf == .records && preview.stem != nil && isRecord
                     ? "Play the \(preview.stem!)" : "Play")
                    .font(Design.Typography.ui(12, weight: .semibold))
            }
            .foregroundStyle(Design.Palette.accent)
            .padding(.horizontal, 10)
            .frame(height: Design.Metric.chipHeight)
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.accent, lineWidth: Design.Metric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(facts.id.shelf == .songs ? "The whole song, from a preview made the first time it is asked for and kept until the song changes"
              : "From the top. The song's transport stops while it plays.")
    }

    @ViewBuilder
    private var status: some View {
        switch preview.state {
        case .preparing(let what):
            Text(what + makingShare).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkSecondary).lineLimit(1)
        case .failed(let why) where preview.soundingNow == nil:
            Text(why).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.warn).lineLimit(2)
        default:
            if facts.id.shelf == .songs, preview.making?.song.rawValue == facts.id.id {
                // Being made before anyone asked: chosen songs are made ready to hear.
                Text("Making a preview\(makingShare)").font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkTertiary).lineLimit(1)
            } else if let now = preview.soundingNow, isMine(now), now.length > 0 {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text(where_(now, at: context.date))
                        .font(Design.Typography.numeric(11.5))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// " 40%", while this song's preview is being made.
    private var makingShare: String {
        guard let making = preview.making, making.song.rawValue == facts.id.id, making.progress > 0 else { return "" }
        return " \(Int((making.progress * 100).rounded()))%"
    }

    private func isMine(_ now: LibraryPreview.Sounding) -> Bool {
        now.id == LibraryPreview.id(facts.id) || now.id.hasPrefix(LibraryPreview.id(facts.id) + ":")
    }

    /// "1:12 of 3:27", or "bar 5 of 72" for a record with bars.
    private func where_(_ now: LibraryPreview.Sounding, at date: Date) -> String {
        guard let seconds = preview.position(at: date) else { return "" }
        if isRecord, let bar = Self.bar(at: seconds, in: preview.recordBars) {
            // "bar 3 of 72, looping 3–5": the bars said as numbers, so the line fits the pane.
            let looping = now.loops ? preview.bars.map { $0.count == 1 ? ", looping it" : ", looping \($0.lowerBound + 1)–\($0.upperBound)" } ?? "" : ""
            return "bar \(bar + 1) of \(preview.recordBars.count)\(looping)"
        }
        return "\(LibraryText.duration(seconds - now.from)) of \(LibraryText.duration(now.length))"
    }

    private var loopingChosenBars: Bool { preview.soundingNow?.loops == true }

    // MARK: A record

    private var stemChips: some View {
        FlowRow(spacing: 6) {
            BoothChip("Record", isOn: preview.stem == nil) { Task { await preview.choose(stem: nil) } }
                .help("The whole record, as it was imported")
            ForEach(preview.stems, id: \.self) { stem in
                BoothChip(stem.capitalized, isOn: preview.stem == stem) { Task { await preview.choose(stem: stem) } }
                    .help("The \(stem) stem alone")
            }
        }
    }

    private var strip: some View {
        let sounding = preview.soundingNow.map(isMine) ?? false
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: !sounding)) { context in
            RecordStrip(waveform: preview.waveform, bars: preview.recordBars, chosen: preview.bars,
                        playhead: sounding ? preview.position(at: context.date) : nil)
        }
        .frame(height: 64)
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        guard let here = bar(atX: drag.location.x, width: geometry.size.width) else { return }
                        if dragFrom == nil { dragFrom = bar(atX: drag.startLocation.x, width: geometry.size.width) ?? here }
                        if abs(drag.translation.width) > 3, let from = dragFrom { preview.choose(bars: from, through: here) }
                    }.onEnded { drag in
                        defer { dragFrom = nil }
                        // A press, not a drag: play from that bar.
                        guard abs(drag.translation.width) <= 3, let here = bar(atX: drag.location.x, width: geometry.size.width) else { return }
                        preview.clearBars()
                        Task { await preview.play(facts.id, fromBar: here) }
                    })
            }
        }
        .help(preview.recordBars.isEmpty ? "Not read yet: no bars to play from" : "Press a bar to play from it; drag across bars to choose them")
    }

    private func bar(atX x: CGFloat, width: CGFloat) -> Int? {
        guard let duration = preview.waveform?.duration, duration > 0, width > 0 else { return nil }
        return Self.bar(at: Double(max(0, min(width, x)) / width) * duration, in: preview.recordBars)
    }

    /// The bar a moment falls in: the last one starting at or before it.
    static func bar(at seconds: Double, in bars: [TimeRange]) -> Int? {
        guard !bars.isEmpty else { return nil }
        return bars.lastIndex { $0.start <= seconds } ?? 0
    }

    private var barsRow: some View {
        FlowRow(spacing: 6, lineSpacing: 6) {
            BoothChip(loopingChosenBars ? "Stop the loop" : "Loop \(preview.barsName.lowercased())", isOn: loopingChosenBars) {
                Task {
                    if loopingChosenBars { await preview.stop() } else { await preview.play(facts.id, looping: true) }
                }
            }
            BoothChip("Add \(preview.barsName.lowercased()) to This Song…") { preview.addBarsToSong() }
                .disabled(model.app.song == nil)
                .opacity(model.app.song == nil ? 0.4 : 1)
                .help(model.app.song == nil ? "Open a song to bring them into" : "Sources, open on these bars of \(preview.stem.map { "the \($0) stem" } ?? "the record"), fitted to the song")
            BoothChip("Clear") { preview.clearBars() }
        }
    }
}

/// A record's shape, its bar lines, the bars chosen and where it is playing.
private struct RecordStrip: View {
    let waveform: ImportWaveform?
    let bars: [TimeRange]
    let chosen: Range<Int>?
    let playhead: Double?

    var body: some View {
        Canvas { context, size in
            let ink = Design.Palette.inkSecondary
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Design.Metric.corner),
                         with: .color(Design.Palette.panelAlt))
            guard let waveform, waveform.duration > 0 else {
                context.draw(Text("Reading…").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            func x(_ seconds: Double) -> CGFloat { CGFloat(waveform.position(ofTime: seconds)) * size.width }
            if let chosen, let first = bars[safe: chosen.lowerBound], let last = bars[safe: chosen.upperBound - 1] {
                context.fill(Path(CGRect(x: x(first.start), y: 0, width: max(2, x(last.end) - x(first.start)), height: size.height)),
                             with: .color(Design.Palette.accentSoft))
            }
            let mid = size.height / 2 + 6
            let scale = (size.height - 16) / 2
            let step = size.width / CGFloat(max(1, waveform.peaks.count))
            var shape = Path()
            for (index, peak) in waveform.peaks.enumerated() {
                let px = CGFloat(index) * step
                shape.move(to: CGPoint(x: px, y: mid - CGFloat(peak.high) * scale))
                shape.addLine(to: CGPoint(x: px, y: mid - CGFloat(peak.low) * scale + 0.5))
            }
            context.stroke(shape, with: .color(ink.opacity(0.75)), lineWidth: max(0.5, step * 0.8))
            // Bar lines, numbered where there is room: every bar, or every fourth, or every eighth.
            let every = bars.count <= 24 ? 1 : bars.count <= 64 ? 4 : 8
            for (index, bar) in bars.enumerated() {
                let bx = x(bar.start)
                let numbered = index % every == 0
                context.fill(Path(CGRect(x: bx, y: 0, width: Design.Metric.hairline, height: numbered ? size.height : 6)),
                             with: .color(Design.Palette.lineStrong))
                if numbered {
                    context.draw(Text("\(index + 1)").font(Design.Typography.numeric(9)).foregroundStyle(Design.Palette.inkTertiary),
                                 at: CGPoint(x: bx + 3, y: 6), anchor: .leading)
                }
            }
            if let playhead {
                context.fill(Path(CGRect(x: x(playhead) - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Design.Palette.accent))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The record's shape, \(bars.count) bars\(chosen.map { ", bars \($0.lowerBound + 1) to \($0.upperBound) chosen" } ?? "")")
    }
}
