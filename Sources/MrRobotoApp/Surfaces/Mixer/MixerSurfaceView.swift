import SongGraph
import SwiftUI

/// The mix, on one surface. Strips as rows — fader, pan, send, mute, solo, three bands, the
/// compressor, a meter — with the overlay under them saying where two parts share energy; and,
/// given a Master, a second tab reading the whole song against its target with the master's levers.
///
/// They were two surfaces, each opened on its own, on a bench that draws one at a time: the Master
/// read what the Mixer set, and seeing whether a strip move helped the loudness meant swapping
/// surfaces. Now it is a tab, and both tabs move one working mix (`MasterModel.follow(_:)`).
struct MixerSurfaceView: View {
    @Bindable var model: MixerModel
    /// The controller, for Learn on a fader. Nil in a render with no rig.
    var midi: MIDIControl?
    /// The Master tab's model. Nil draws the strips alone, as the Mixer did before it had one.
    var master: MasterModel?
    /// The frame, for the Master tab's export. Nil points at the File menu instead.
    var app: AppState?

    init(model: MixerModel, midi: MIDIControl? = nil, master: MasterModel? = nil, app: AppState? = nil) {
        self.model = model
        self.midi = midi
        self.master = master
        self.app = app
        // One mix under both tabs. Idempotent, so the view being rebuilt costs nothing.
        master?.follow(model)
    }

    /// The tabs this surface offers: the Master only when there is a Master to show.
    var tabs: [MixerModel.Tab] { master == nil ? [.strips] : MixerModel.Tab.allCases }

    /// The tab drawn: the model's choice, unless it asks for a Master this view was not given.
    var shownTab: MixerModel.Tab { tabs.contains(model.tab) ? model.tab : .strips }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            MixScroll(.vertical) {
                Group {
                    switch shownTab {
                    case .strips: stripsTab
                    case .master:
                        if let master { MasterPanel(model: master) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
        // On the surface, not the strips tab: switching to the Master and back should find the
        // meters moving, not restarting from a level that was true when you left.
        .onAppear { model.startMetering() }
        .onDisappear { model.stopMetering() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Mixer").font(Design.Typography.prose(16, weight: .medium))
            Text("\(model.rows.count) strip\(model.rows.count == 1 ? "" : "s") · \(model.base.map { "on \(PartLabel.title(of: $0))" } ?? "at unity")")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // No Revert here. Every move let go of is already a version, so there is never a working
            // change to throw away; going back is done from the ledger, as the footer says.
            if tabs.count > 1 { tabPicker }
        }
    }

    /// Strips | Master.
    @ViewBuilder
    private var tabPicker: some View {
        if Design.isOffscreenRender {
            // A segmented control is AppKit's and renders as a blocked-out rectangle offscreen.
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    BoothChip(tab.rawValue, isOn: shownTab == tab) { model.tab = tab }
                }
            }
        } else {
            Picker("Show", selection: Binding(get: { shownTab }, set: { model.tab = $0 })) {
                ForEach(tabs) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Design.Palette.accent)
            .fixedSize()
            .accessibilityLabel("Mixer view")
            .help("Strips: a row per part. Master: the whole song read against its target, with the master's gain and ceiling.")
        }
    }

    /// The strips, the master row and the overlay. Each band of it keeps its natural width when
    /// the bench is wide and scrolls sideways when it is not — a strip row alone is over 900
    /// points, and the bench's minimum is 640.
    private var stripsTab: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            fitting {
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    strips
                    masterRow
                }
            }
            fitting { overlay }
        }
    }

    /// Its content at full width when that fits, else the same content in a sideways scroll.
    /// Not a scroll always: in a scroll the meters would stop stretching to the bench's width.
    private func fitting<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let content = content()
        return ViewThatFits(in: .horizontal) {
            content
            MixScroll(.horizontal) { content.padding(.bottom, 8) }
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
                    MixToggle("M", isOn: strip.isMuted, tint: Design.Palette.warn,
                              help: strip.isMuted ? "Unmute \(row.label)" : "Mute \(row.label)",
                              label: "\(strip.isMuted ? "Unmute" : "Mute") \(row.label)") { model.toggleMute(row.part) }
                    MixToggle("S", isOn: strip.isSoloed, tint: Design.Palette.accent,
                              help: strip.isSoloed ? "Unsolo \(row.label)" : "Solo \(row.label): hear it on its own",
                              label: "\(strip.isSoloed ? "Unsolo" : "Solo") \(row.label)") { model.toggleSolo(row.part) }
                    learnChip(.strip(index))
                }
            }
            .frame(width: 120, alignment: .leading)
            fader(value: strip.gainDB, range: -60...12, format: "%+.1f dB", width: 200, name: "\(row.label) level") { model.setGain($0, for: row.part) }
            fader(value: strip.pan, range: -1...1, format: "%+.2f", width: 90, name: "\(row.label) pan") { model.setPan($0, for: row.part) }
            fader(value: strip.sendDB ?? MixerModel.sendOffDB, range: MixerModel.sendOffDB...0, format: "%.0f dB", width: 90,
                  name: "\(row.label) send", readout: MixerModel.sendReadout(strip.sendDB)) { model.setSend(MixerModel.send(fromFader: $0), for: row.part) }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { band in
                    if strip.eq.indices.contains(band) {
                        fader(value: strip.eq[band].gainDB, range: -18...18, format: "%+.0f", width: 78,
                              name: "\(row.label) EQ band \(band + 1)") { model.setEQ(band: band, gainDB: $0, for: row.part) }
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
            MixToggle(strip.compressor == nil ? "off" : "on", isOn: strip.compressor != nil, tint: Design.Palette.accent,
                      help: strip.compressor == nil ? "Put a compressor on \(row.label)" : "Take the compressor off \(row.label)",
                      label: "\(row.label) compressor \(strip.compressor == nil ? "off" : "on")") {
                model.setCompressor(strip.compressor == nil ? Compressor() : nil, for: row.part)
            }
            .frame(width: 60, alignment: .leading)
            MeterBar(peak: model.meters[row.part]?.peak ?? 0, rms: model.meters[row.part]?.rms ?? 0)
                .frame(minWidth: 60, maxWidth: .infinity)
                .frame(height: 10)
        }
        .padding(.vertical, 3)
    }

    /// A slider with its value under it. `readout` overrides the formatted value where the number
    /// would lie — a send at the bottom of its travel is off, not −60 dB.
    private func fader(value: Double, range: ClosedRange<Double>, format: String, width: CGFloat, name: String,
                       readout: String? = nil, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if !editing { model.endGesture() }
            }
            .controlSize(.mini)
            .tint(Design.Palette.accent)
            .accessibilityLabel(name)
            .help("\(name): heard while held, a mix version when let go.")
            Text(readout ?? String(format: format, value)).font(Design.Typography.numeric(9.5)).foregroundStyle(Design.Palette.inkTertiary)
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
            fader(value: model.mix.master.gainDB, range: -24...24, format: "%+.1f dB", width: 200, name: "Master gain") { model.setMaster(gainDB: $0) }
            fader(value: model.mix.master.ceilingDBTP, range: -12...0, format: "ceiling %.1f dBTP", width: 140, name: "Master ceiling") { model.setMaster(ceilingDBTP: $0) }
            fader(value: model.mix.master.targetLUFS, range: -30 ... -6, format: "target %.0f LUFS", width: 140, name: "Master target") { model.setMaster(targetLUFS: $0) }
            if let master { lastReading(master) }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    /// What the Master last read, on the strips: whether the moves you are making here are
    /// landing the song on its target, without leaving the strips to find out. Pressing it opens
    /// the Master tab.
    private func lastReading(_ master: MasterModel) -> some View {
        let reading = master.reading
        let text = reading.map { String(format: "%.1f LUFS · %.1f dBTP", $0.observation.integratedLUFS, $0.truePeakDBTP) } ?? "Not read"
        return BoothChip(text, isOn: false) { model.tab = .master }
            .opacity(master.isStale ? 0.5 : 1)
            .help(reading == nil
                  ? "The whole song has not been read through this mix. Opens the Master tab."
                  : (master.isStale
                     ? "The whole song's last reading, from before the mix moved. Opens the Master tab to read it again."
                     : "The whole song's last reading against the target. Opens the Master tab."))
            .accessibilityLabel(reading == nil ? "Master not read; open the Master tab" : "Master reading \(text)\(master.isStale ? ", out of date" : ""); open the Master tab")
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
                    .help("Bounces the two chosen strips on their own and shows where they share energy.")
                if model.isReadingOverlay {
                    ProgressView().controlSize(.small).tint(Design.Palette.accent)
                        .accessibilityLabel("Reading the overlay")
                }
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
        if shownTab == .master, let master {
            MasterFooter(model: master, app: app)
        } else if let error = model.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
        } else if let note = model.lastNote {
            Text("Kept: \(note)").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        } else {
            Text("Every move you let go of is a mix version; step back from Parts. Pick two strips and Read for the overlay.")
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

/// A scroll view that steps aside in an offscreen render. `ImageRenderer` draws an NSScrollView's
/// content as nothing, so a render of a scrolling surface came out blank; there the content is
/// drawn as it is, from the top left, and clipped by the frame — which is what a render is for.
struct MixScroll<Content: View>: View {
    let axes: Axis.Set
    let content: Content
    init(_ axes: Axis.Set, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }
    var body: some View {
        if Design.isOffscreenRender {
            // Content at its full size along the scrolling axes, in a frame that takes what it is
            // offered along them and no more. The zero minimums matter: without them the frame
            // grows to the content it holds and pushes the surface's own header off the render.
            content
                .fixedSize(horizontal: axes.contains(.horizontal), vertical: axes.contains(.vertical))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: 0, maxHeight: axes.contains(.vertical) ? .infinity : nil, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axes) { content }
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

/// A one-letter switch on a strip: M, S, the compressor's on/off. Terse on the strip, so it
/// carries the whole verb in its help and its accessibility label.
struct MixToggle: View {
    let title: String
    let isOn: Bool
    let tint: Color
    let help: String
    let label: String
    let action: () -> Void
    init(_ title: String, isOn: Bool, tint: Color, help: String, label: String, action: @escaping () -> Void) {
        self.title = title; self.isOn = isOn; self.tint = tint; self.help = help; self.label = label; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.numeric(10, weight: .semibold))
                .foregroundStyle(isOn ? tint : Design.Palette.inkTertiary)
                .padding(.horizontal, 4)
                .frame(minWidth: Design.Metric.tagHeight, minHeight: Design.Metric.tagHeight)
                .background(isOn ? tint.opacity(0.15) : Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(isOn ? tint.opacity(0.4) : Design.Palette.line, lineWidth: Design.Metric.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
