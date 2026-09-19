import SongGraph
import SwiftUI

/// Readings against the target, the spectrum, the levers, and the Engineer's lines.
struct MasterSurfaceView: View {
    @Bindable var model: MasterModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                VStack(alignment: .leading, spacing: 12) {
                    numbers
                    spectrum
                    levers
                }
                engineer
            }
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.song?.title ?? "Master").font(Design.Typography.prose(16, weight: .medium))
            Text(String(format: "target %.0f LUFS · ceiling %.1f dBTP", model.mix.master.targetLUFS, model.mix.master.ceilingDBTP))
                .font(Design.Typography.numeric(12)).foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            Button(model.isReading ? "Reading…" : "Read the bounce") { Task { await model.read() } }
                .font(Design.Typography.ui(12)).disabled(model.isReading)
        }
    }

    private var numbers: some View {
        HStack(spacing: 10) {
            number("Integrated", model.reading.map { String(format: "%.1f", $0.observation.integratedLUFS) } ?? "—", unit: "LUFS",
                   off: model.reading.map { abs($0.observation.integratedLUFS - model.mix.master.targetLUFS) > 2 } ?? false)
            number("True peak", model.reading.map { String(format: "%.1f", $0.truePeakDBTP) } ?? "—", unit: "dBTP",
                   off: model.reading.map { $0.truePeakDBTP > model.mix.master.ceilingDBTP + 0.05 } ?? false)
            number("Crest", model.reading.map { String(format: "%.1f", $0.observation.crestDB) } ?? "—", unit: "dB", off: false)
            number("Tilt", model.reading.map { String(format: "%.0f", $0.observation.tiltDB) } ?? "—", unit: "dB", off: false)
            number("Top end", model.reading.map { String(format: "%.1f", $0.observation.bandwidthHz / 1000) } ?? "—", unit: "kHz", off: false)
        }
    }

    private func number(_ label: String, _ value: String, unit: String, off: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MixLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Design.Typography.numeric(20, weight: .medium)).foregroundStyle(off ? Design.Palette.warn : Design.Palette.ink)
                Text(unit).font(Design.Typography.numeric(10)).foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .frame(width: 96, alignment: .leading)
        .padding(8)
        .background(off ? Design.Palette.warnSoft : Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private var spectrum: some View {
        VStack(alignment: .leading, spacing: 4) {
            MixLabel("Spectrum · 40 Hz – 16 kHz")
            Canvas { context, size in
                let bars = model.reading?.spectrumDB ?? []
                guard !bars.isEmpty else {
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Design.Palette.panelAlt))
                    return
                }
                let width = size.width / CGFloat(bars.count)
                for (i, dB) in bars.enumerated() {
                    let h = size.height * CGFloat(max(0, min(1, (dB + 60) / 60)))
                    let rect = CGRect(x: CGFloat(i) * width + 1, y: size.height - h, width: max(1, width - 2), height: h)
                    context.fill(Path(rect), with: .color(Design.Palette.accent.opacity(0.7)))
                }
            }
            .frame(maxWidth: 560)
            .frame(height: 110)
            .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        }
    }

    private var levers: some View {
        VStack(alignment: .leading, spacing: 8) {
            MixLabel("Levers")
            HStack(spacing: 12) {
                lever("Target", value: model.mix.master.targetLUFS, range: -30 ... -6, format: "%.0f LUFS") { model.setTarget($0) }
                    .layoutPriority(1)
                lever("Ceiling", value: model.mix.master.ceilingDBTP, range: -12...0, format: "%.1f dBTP") { model.setCeiling($0) }
                lever("Gain", value: model.mix.master.gainDB, range: -24...24, format: "%+.1f dB") { model.setGain($0) }
                if let suggested = model.suggestedGainDB {
                    Button(String(format: "Hit the target (%+.1f dB)", suggested)) { model.hitTheTarget() }
                        .font(Design.Typography.ui(12))
                }
            }
        }
    }

    private func lever(_ label: String, value: Double, range: ClosedRange<Double>, format: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkSecondary)
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in if !editing { model.endGesture() } }
                .controlSize(.small).tint(Design.Palette.accent).frame(width: 170)
            Text(String(format: format, value)).font(Design.Typography.numeric(10)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    private var engineer: some View {
        VStack(alignment: .leading, spacing: 6) {
            MixLabel("The Engineer")
            if let first = model.reading?.firstToChange {
                Text("Change first: \(first.says)")
                    .font(Design.Typography.ui(12.5, weight: .medium)).foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.reading != nil {
                Text("Nothing to change: every reading holds.").font(Design.Typography.ui(12.5, weight: .medium)).foregroundStyle(Design.Palette.accent)
            }
            ForEach(model.reading?.readings ?? []) { reading in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(reading.holds ? Design.Palette.accent : Design.Palette.warn).frame(width: 6, height: 6).padding(.top, 5)
                    Text(reading.says).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.reading == nil {
                Text("Read the bounce and the Engineer says what holds and what to change first.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
            }
        }
        .frame(minWidth: 220, maxWidth: 320, alignment: .topLeading)
    }

    @ViewBuilder
    private var footer: some View {
        if let error = model.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
        } else if let note = model.lastNote {
            Text("Kept: \(note)").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        } else {
            Text(String(format: "The target and the ceiling are %@; a lever let go of is a mix version.", model.targets.targetLUFS == -14 && model.targets.ceilingDBTP == -1 ? "the delivery defaults" : "the album's"))
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}
