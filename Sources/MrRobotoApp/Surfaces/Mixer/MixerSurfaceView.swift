import SongGraph
import SwiftUI

/// Strips as rows: fader, pan, send, mute, solo, three bands, the compressor, a meter. The
/// overlay under them says where two parts share energy.
struct MixerSurfaceView: View {
    @Bindable var model: MixerModel
    /// The controller, for Learn on a fader. Nil in a render with no rig.
    var midi: MIDIControl?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            strips
            masterRow
            overlay
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
        .onAppear { model.startMetering() }
        .onDisappear { model.stopMetering() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Mixer").font(Design.Typography.prose(16, weight: .medium))
            Text("\(model.rows.count) strip\(model.rows.count == 1 ? "" : "s") · \(model.base.map { "on \(PartLabel.title(of: $0))" } ?? "at unity")")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            Button("Revert") { model.revert() }.font(Design.Typography.ui(12)).disabled(model.mix == (model.base.flatMap { if case .mix(let m) = $0.kind { m } else { nil } } ?? .unity))
        }
    }

    private var strips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MixLabel("Strip").frame(width: 120, alignment: .leading)
                MixLabel("Level").frame(width: 200, alignment: .leading)
                MixLabel("Pan").frame(width: 90, alignment: .leading)
                MixLabel("Send").frame(width: 90, alignment: .leading)
                MixLabel("EQ low · peak · high").frame(width: 250, alignment: .leading)
                MixLabel("Comp").frame(width: 60, alignment: .leading)
                MixLabel("Meter").fixedSize().frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                stripRow(row, index: index)
            }
        }
    }

    /// Inputs I7: a chip that binds the next control change moved to this fader, and says which
    /// control has it now.
    @ViewBuilder
    private func learnChip(_ target: ControlTarget) -> some View {
        if let midi {
            let bound = midi.map.controller(for: target)
            BoothChip(midi.learning == target ? "move a knob…" : (bound.map { "cc \($0)" } ?? "learn"), isOn: midi.learning == target) {
                midi.learn(midi.learning == target ? nil : target)
            }
            .help(bound.map { "Control change \($0) moves this fader. Click, then move a knob, to change it." } ?? "Click, then move a knob on the controller.")
        }
    }

    private func stripRow(_ row: MixerModel.Row, index: Int) -> some View {
        let strip = model.strip(row.part)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(Design.Typography.ui(13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    MixToggle("M", isOn: strip.isMuted, tint: Design.Palette.warn) { model.toggleMute(row.part) }
                    MixToggle("S", isOn: strip.isSoloed, tint: Design.Palette.accent) { model.toggleSolo(row.part) }
                    learnChip(.strip(index))
                }
            }
            .frame(width: 120, alignment: .leading)
            fader(value: strip.gainDB, range: -60...12, format: "%+.1f dB", width: 200) { model.setGain($0, for: row.part) }
            fader(value: strip.pan, range: -1...1, format: "%+.2f", width: 90) { model.setPan($0, for: row.part) }
            fader(value: strip.sendDB ?? -60, range: -60...0, format: "%.0f dB", width: 90) { model.setSend($0 <= -59.5 ? nil : $0, for: row.part) }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { band in
                    if strip.eq.indices.contains(band) {
                        fader(value: strip.eq[band].gainDB, range: -18...18, format: "%+.0f", width: 78) { model.setEQ(band: band, gainDB: $0, for: row.part) }
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
            MixToggle(strip.compressor == nil ? "off" : "on", isOn: strip.compressor != nil, tint: Design.Palette.accent) {
                model.setCompressor(strip.compressor == nil ? Compressor() : nil, for: row.part)
            }
            .frame(width: 60, alignment: .leading)
            MeterBar(peak: model.meters[row.part]?.peak ?? 0, rms: model.meters[row.part]?.rms ?? 0)
                .frame(minWidth: 60, maxWidth: .infinity)
                .frame(height: 10)
        }
        .padding(.vertical, 3)
    }

    private func fader(value: Double, range: ClosedRange<Double>, format: String, width: CGFloat, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if !editing { model.endGesture() }
            }
            .controlSize(.mini)
            .tint(Design.Palette.accent)
            Text(String(format: format, value)).font(Design.Typography.numeric(9.5)).foregroundStyle(Design.Palette.inkTertiary)
        }
        .frame(width: width)
    }

    private var masterRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Master").font(Design.Typography.ui(13, weight: .medium))
                learnChip(.master)
            }
            .frame(width: 120, alignment: .leading)
            fader(value: model.mix.master.gainDB, range: -24...24, format: "%+.1f dB", width: 200) { model.setMaster(gainDB: $0) }
            fader(value: model.mix.master.ceilingDBTP, range: -12...0, format: "ceiling %.1f dBTP", width: 140) { model.setMaster(ceilingDBTP: $0) }
            fader(value: model.mix.master.targetLUFS, range: -30 ... -6, format: "target %.0f LUFS", width: 140) { model.setMaster(targetLUFS: $0) }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            MixLabel("Masking overlay")
            HStack(spacing: 6) {
                ForEach(model.rows) { row in
                    BoothChip(row.label, isOn: model.overlayA == row.part || model.overlayB == row.part) {
                        if model.overlayA == row.part { model.overlayA = nil }
                        else if model.overlayB == row.part { model.overlayB = nil }
                        else if model.overlayA == nil { model.overlayA = row.part }
                        else { model.overlayB = row.part }
                    }
                }
                Button(model.isReadingOverlay ? "Reading…" : "Read") { Task { await model.readOverlay() } }
                    .font(Design.Typography.ui(12))
                    .disabled(model.overlayA == nil || model.overlayB == nil || model.isReadingOverlay)
            }
            if !model.overlay.isEmpty {
                let a = model.rows.first { $0.part == model.overlayA }?.label ?? "A"
                let b = model.rows.first { $0.part == model.overlayB }?.label ?? "B"
                HStack(spacing: 8) {
                    ForEach(model.overlay) { band in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(band.name + " Hz").font(Design.Typography.label).foregroundStyle(Design.Palette.inkTertiary)
                            Text(String(format: "%@ %.0f · %@ %.0f", a, band.aDB, b, band.bDB)).font(Design.Typography.numeric(10.5))
                            Text(String(format: "gap %.0f dB", band.gapDB))
                                .font(Design.Typography.numeric(10.5, weight: .semibold))
                                .foregroundStyle(band.gapDB < 6 ? Design.Palette.warn : Design.Palette.inkSecondary)
                        }
                        .padding(8)
                        .background(band.gapDB < 6 ? Design.Palette.warnSoft : Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var footer: some View {
        if let error = model.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
        } else if let note = model.lastNote {
            Text("Kept: \(note)").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        } else {
            Text("Every move you let go of is a mix version; revert it from the ledger. Pick two strips and Read for the overlay.")
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

struct MixLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
    }
}

struct MixToggle: View {
    let title: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void
    init(_ title: String, isOn: Bool, tint: Color, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.tint = tint; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.numeric(10, weight: .semibold))
                .foregroundStyle(isOn ? tint : Design.Palette.inkTertiary)
                .frame(width: 22, height: 16)
                .background(isOn ? tint.opacity(0.15) : Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(isOn ? tint.opacity(0.4) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}

struct MeterBar: View {
    let peak: Float
    let rms: Float
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Design.Palette.panelAlt)
                RoundedRectangle(cornerRadius: 2).fill(Design.Palette.accent.opacity(0.5)).frame(width: geometry.size.width * CGFloat(min(1, rms)))
                Rectangle().fill(peak > 0.9 ? Design.Palette.warn : Design.Palette.accent).frame(width: 2).offset(x: geometry.size.width * CGFloat(min(1, peak)))
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
    }
}
