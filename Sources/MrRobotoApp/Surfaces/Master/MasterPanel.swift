import SongGraph
import SwiftUI

// What the Master shows, drawn wherever the Master is: on the Master surface, and as the Mixer's
// Master tab. One view for both, so the two can never read differently — they used to be one
// surface's body, and a second copy for the tab would have been two sets of numbers to keep level.

/// The reading against the target, the spectrum, the levers and the Engineer's lines.
///
/// Lays itself out for the width it is given: the Engineer beside the numbers when there is room,
/// under them when there is not — at the bench's minimum the numbers alone take nearly all of it.
struct MasterPanel: View {
    @Bindable var model: MasterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readBar
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Design.Metric.gutter) {
                    measures
                    engineer.frame(minWidth: 220, idealWidth: 240, maxWidth: 320, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    measures
                    engineer.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: What was read, and reading it

    /// Which stretch the numbers describe, whether they still describe the mix, and the Read.
    private var readBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            scopeLine
            Spacer(minLength: 8)
            if let line = model.progressLine {
                ProgressView().controlSize(.small).tint(Design.Palette.accent)
                    .accessibilityLabel(line)
                Text(line)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(model.isReading ? "Reading…" : (model.reading == nil ? "Read the bounce" : "Read again")) {
                Task { await model.read() }
            }
            .font(Design.Typography.ui(12))
            .disabled(model.isReading)
            .help(readHelp)
            .fixedSize()
        }
    }

    /// What Read will measure, said before it is pressed.
    private var readHelp: String {
        "Bounces the whole song (\(model.scope.detail)) through the mix and reads it. A long song takes a moment."
    }

    @ViewBuilder
    private var scopeLine: some View {
        if let reading = model.reading {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MixLabel(reading.scope.label)
                Text("\(reading.scope.detail) · \(Self.duration(reading.seconds))")
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
                if model.isStale {
                    Text("· the mix moved since; read again")
                        .font(Design.Typography.ui(11))
                        .foregroundStyle(Design.Palette.warn)
                        .lineLimit(1)
                }
            }
            .help(model.isStale
                  ? "The numbers are of the whole song through the mix as it was when read. Something that changes the sound has moved since."
                  : "The numbers are of the whole song, every section in order: the loudness it will be delivered at.")
        } else if !model.isReading {
            Text("Not read yet. Read bounces the whole song, \(model.scope.detail).")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .lineLimit(1)
        }
    }

    /// "1:04", "0:31".
    static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: The numbers, the spectrum, the levers

    private var measures: some View {
        VStack(alignment: .leading, spacing: 12) {
            numbers
            spectrum
            levers
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
        // Dimmed once the mix has moved: still true of the mix they were read from, not of this one.
        .opacity(model.isStale ? 0.5 : 1)
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
        .accessibilityElement(children: .combine)
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
            .opacity(model.isStale ? 0.5 : 1)
            .accessibilityLabel("Spectrum of the last reading")
        }
    }

    private var levers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MixLabel("Levers")
                // Beside the label rather than after the sliders: three sliders already take the
                // width of the bench at its minimum.
                if let suggested = model.suggestedGainDB, abs(suggested - model.mix.master.gainDB) >= 0.05 {
                    Button(String(format: "Hit the target (%+.1f dB)", suggested)) { model.hitTheTarget() }
                        .font(Design.Typography.ui(12))
                        .help("Sets the master gain to what puts the last reading on the target, and keeps it.")
                }
            }
            HStack(spacing: 12) {
                lever("Target", value: model.mix.master.targetLUFS, range: -30 ... -6, format: "%.0f LUFS") { model.setTarget($0) }
                    .layoutPriority(1)
                lever("Ceiling", value: model.mix.master.ceilingDBTP, range: -12...0, format: "%.1f dBTP") { model.setCeiling($0) }
                lever("Gain", value: model.mix.master.gainDB, range: -24...24, format: "%+.1f dB") { model.setGain($0) }
            }
            ending
        }
    }

    /// How the song ends. Songs used to stop dead on the last bar's downbeat, in the transport and
    /// in the export alike; a fade is the ending most songs reach for.
    private var ending: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Ending").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkSecondary)
            HStack(spacing: 4) {
                BoothChip("Stop", isOn: model.mix.master.fadeOutBars == nil) { model.setFadeOut(bars: nil) }
                    .help("The song stops on its last bar")
                ForEach(FadeOut.choices, id: \.self) { bars in
                    BoothChip("Fade \(bars) bars", isOn: model.mix.master.fadeOutBars == bars) { model.setFadeOut(bars: bars) }
                        .help("The last \(bars) bars of the form fade to silence, as it plays to its end and in the master. A loop never ends, so it never fades.")
                }
            }
        }
    }

    private func lever(_ label: String, value: Double, range: ClosedRange<Double>, format: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkSecondary)
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in if !editing { model.endGesture() } }
                .controlSize(.small).tint(Design.Palette.accent).frame(width: 170)
                .accessibilityLabel("Master \(label.lowercased())")
                .help("\(label): heard while held, a mix version when let go.")
            Text(String(format: format, value)).font(Design.Typography.numeric(10)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    // MARK: The Engineer

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
                        .accessibilityHidden(true)
                    Text(reading.says).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(reading.holds ? "Holds" : "Change"): \(reading.says)")
            }
            if model.reading == nil {
                Text("Read the bounce and the Engineer says what holds and what to change first.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(model.isStale ? 0.6 : 1)
    }
}

/// The Master's last line: what was kept, or why not, and the export.
///
/// Apart from `MasterPanel` so a host can pin it under a scrolling panel, where the export stays
/// in reach however far down the Engineer runs.
struct MasterFooter: View {
    let model: MasterModel
    /// The frame, when the registry hands one over: what an export needs. A view built from its
    /// model alone (a render, a test) has none, and points at the menu instead.
    var app: AppState?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let error = model.lastError {
                    Text(error).foregroundStyle(Design.Palette.warn)
                } else if let note = model.lastNote {
                    Text("Kept: \(note)").foregroundStyle(Design.Palette.inkTertiary)
                } else {
                    Text("The target and the ceiling are \(model.targets.targetLUFS == -14 && model.targets.ceilingDBTP == -1 ? "the delivery defaults" : "the album's"); a lever let go of is a mix version.")
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
            }
            .font(Design.Typography.ui(11))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The export, from the surface that reads the master: the same call the File menu
            // makes. A view built from its model alone has no frame to ask and points at the menu.
            if let app {
                // The primary here: the master is what this tab exists to send somewhere.
                FrameButton(title: "Export master…", emphasis: .accent, isEnabled: app.song != nil && app.busy == nil) {
                    MrRobotoApp.export(app, what: "Exporting the master…") { try await Export.master(app, to: $0).wav }
                }
                .help("The whole song through the mix, limited at the ceiling, as a 24-bit WAV beside a report. Asks where first.")
                .fixedSize()
            } else {
                Text("Export from File ▸ Export ▸ Master…")
                    .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize()
            }
        }
    }
}
