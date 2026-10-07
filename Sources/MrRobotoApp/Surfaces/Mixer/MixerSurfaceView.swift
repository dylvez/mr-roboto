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
            Text("\(model.rows.count) strip\(model.rows.count == 1 ? "" : "s") · \(model.base.map { "on \(PartLabel.title(of: $0))" } ?? "at unity")")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if shownTab == .strips, !model.sections.isEmpty { levelPicker }
            // No Revert here. Every move let go of is already a version, so there is never a working
            // change to throw away; going back is done from the ledger, as the footer says.
            if tabs.count > 1 { tabPicker }
        }
    }

    /// Which section the level faders set: every section, or one.
    private var levelPicker: some View {
        let picked = model.levelSection.flatMap { id in model.sections.first { $0.id == id }?.name }
        return Menu {
            Button("Every section") { model.levelSection = nil }
            Divider()
            ForEach(model.sections) { section in
                Button(section.name) { model.levelSection = section.id }
            }
        } label: {
            Text(picked.map { "Level in \($0)" } ?? "Level in every section")
                .font(Design.Typography.ui(12))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Which section the level faders set. Pick one to change a strip's level there alone — the bass out of the Intro — and leave the rest of the song as it is.")
        .accessibilityLabel(picked.map { "Levels for \($0)" } ?? "Levels for every section")
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
            // The full table when the bench is wide enough for it; each strip's EQ on a line of its
            // own when it is not; and only past even that, a sideways scroll. At the bench's
            // smaller widths the meters used to be a scroll away from every strip.
            ViewThatFits(in: .horizontal) {
                table(compact: false)
                table(compact: true)
                MixScroll(.horizontal) { table(compact: true).padding(.bottom, 8) }
            }
            fitting { overlay }
        }
    }

    private func table(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            strips(compact: compact)
            masterRow(compact: compact)
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

    private func strips(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MixLabel("Strip").frame(width: 120, alignment: .leading)
                MixLabel("Level").frame(width: 160, alignment: .leading)
                MixLabel("Pan").frame(width: 90, alignment: .leading)
                MixLabel("Send").frame(width: 90, alignment: .leading)
                MixLabel("Echo").frame(width: 90, alignment: .leading)
                if !compact { MixLabel("EQ low · peak · high").frame(width: 230, alignment: .leading) }
                MixLabel("Comp").frame(width: 60, alignment: .leading)
                MixLabel("Insert").frame(width: 112, alignment: .leading)
                MixLabel("Meter").fixedSize().frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                stripRow(row, index: index, compact: compact)
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

    private func stripRow(_ row: MixerModel.Row, index: Int, compact: Bool) -> some View {
        let strip = model.strip(row.part)
        return VStack(alignment: .leading, spacing: 2) {
            stripLine(row, strip: strip, index: index, compact: compact)
            if compact {
                // The EQ under the level, pan and send, so the row fits the bench and the meter
                // stays beside its strip.
                HStack(spacing: 8) {
                    MixLabel("EQ").frame(width: 120, alignment: .trailing)
                    eqFaders(row, strip: strip)
                }
            }
        }
    }

    private func eqFaders(_ row: MixerModel.Row, strip: Strip) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { band in
                if strip.eq.indices.contains(band) {
                    fader(value: strip.eq[band].gainDB, range: -18...18, format: "%+.0f", width: 72,
                          name: "\(row.label) EQ band \(band + 1)") { model.setEQ(band: band, gainDB: $0, for: row.part) }
                }
            }
        }
    }

    private func stripLine(_ row: MixerModel.Row, strip: Strip, index: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
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
            // 160 and 230, not 200 and 250: the row used to be 926 points, a little wider than the
            // bench at a 1440 window, so the meters were one sideways scroll away on the most
            // common size there is.
            levelFader(row)
            fader(value: strip.pan, range: -1...1, format: "%+.2f", width: 90, name: "\(row.label) pan") { model.setPan($0, for: row.part) }
            fader(value: strip.sendDB ?? MixerModel.sendOffDB, range: MixerModel.sendOffDB...0, format: "%.0f dB", width: 90,
                  name: "\(row.label) send", readout: MixerModel.sendReadout(strip.sendDB)) { model.setSend(MixerModel.send(fromFader: $0), for: row.part) }
            fader(value: strip.echoDB ?? MixerModel.sendOffDB, range: MixerModel.sendOffDB...0, format: "%.0f dB", width: 90,
                  name: "\(row.label) echo", readout: MixerModel.sendReadout(strip.echoDB)) { model.setEcho(MixerModel.send(fromFader: $0), for: row.part) }
            if !compact {
                eqFaders(row, strip: strip)
                    .frame(width: 230, alignment: .leading)
            }
            MixToggle(strip.compressor == nil ? "off" : "on", isOn: strip.compressor != nil, tint: Design.Palette.accent,
                      help: strip.compressor == nil ? "Put a compressor on \(row.label)" : "Take the compressor off \(row.label)",
                      label: "\(row.label) compressor \(strip.compressor == nil ? "off" : "on")") {
                model.setCompressor(strip.compressor == nil ? Compressor() : nil, for: row.part)
            }
            .frame(width: 60, alignment: .leading)
            insertMenu(row)
                .frame(width: 112, alignment: .leading)
            MeterBar(peak: model.meters[row.part]?.peak ?? 0, rms: model.meters[row.part]?.rms ?? 0)
                .frame(minWidth: 60, maxWidth: .infinity)
                .frame(height: 10)
        }
        .padding(.vertical, 3)
    }

    /// The strip's insert: the instrument's own, nothing, an amp or a rotating speaker; and with a
    /// section picked, the speaker's speed there.
    private func insertMenu(_ row: MixerModel.Row) -> some View {
        let strip = model.strip(row.part)
        let own = model.instrumentInsert(for: row.part)
        let playing = model.insert(for: row.part)
        let section = model.levelSection.flatMap { id in model.sections.first { $0.id == id }?.name }
        let title: String = {
            guard let playing, playing.kind != .off else { return "None" }
            return Self.short(playing) + (strip.insert == nil ? " ·" : "")
        }()
        return Menu {
            if let own {
                Button("The instrument's own: \(own.words)") { model.setInsert(nil, for: row.part) }
                Divider()
            }
            ForEach(StripInsert.named, id: \.id) { entry in
                Button(entry.insert.kind == .off ? "None" : entry.insert.words.prefix(1).uppercased() + entry.insert.words.dropFirst()) {
                    model.setInsert(entry.insert, for: row.part)
                }
            }
            if let section, playing?.kind == .rotary {
                Divider()
                Button("Fast in \(section)") { model.setFast(true, for: row.part) }
                Button("Slow in \(section)") { model.setFast(false, for: row.part) }
                Button("As everywhere in \(section)") { model.setFast(nil, for: row.part) }
            }
        } label: {
            Text(title).font(Design.Typography.ui(11)).lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
        .help(playing.map { "\(row.label) plays through \($0.phrase)" + (strip.insert == nil && own != nil ? ", its instrument's own." : ".") }
              ?? "Put an amp or a rotating speaker on \(row.label)")
        .accessibilityLabel("\(row.label) insert: \(playing?.words ?? "nothing")")
    }

    static func short(_ insert: StripInsert) -> String {
        switch insert.kind {
        case .off: return "None"
        case .amp: return insert.drive < 0.25 ? "Amp clean" : insert.drive < 0.65 ? "Amp crunch" : "Amp lead"
        case .rotary: return insert.fast ? "Speaker fast" : "Speaker slow"
        }
    }

    /// The level: the strip's own, or — with a section picked — its level there, which says so and
    /// can be put back to the strip's own.
    private func levelFader(_ row: MixerModel.Row) -> some View {
        let own = model.hasSectionLevel(for: row.part)
        let section = model.levelSection.flatMap { id in model.sections.first { $0.id == id }?.name }
        return ZStack(alignment: .bottomTrailing) {
            fader(value: model.level(for: row.part), range: -60...12, format: "%+.1f dB", width: 160,
                  name: section.map { "\(row.label) level in \($0)" } ?? "\(row.label) level",
                  readout: section.map { name in
                      String(format: "%+.1f dB", model.level(for: row.part)) + (own ? " in \(name)" : ", as everywhere")
                  }) { model.setLevel($0, for: row.part) }
            if own {
                Button("Reset") { model.clearSectionLevel(for: row.part) }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(9.5))
                    .foregroundStyle(Design.Palette.accent)
                    .help("Put \(row.label) back to its own level in \(section ?? "this section")")
            }
        }
        .frame(width: 160)
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

    private func masterRow(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            masterLine(compact: compact)
            returnsRow(compact: compact)
        }
    }

    private func masterLine(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 6) {
                Text("Master").font(Design.Typography.ui(13, weight: .medium))
                learnChip(.master)
            }
            .frame(width: 120, alignment: .leading)
            fader(value: model.mix.master.gainDB, range: -24...24, format: "%+.1f dB", width: 160, name: "Master gain") { model.setMaster(gainDB: $0) }
            fader(value: model.mix.master.ceilingDBTP, range: -12...0, format: "ceiling %.1f dBTP", width: compact ? 110 : 140, name: "Master ceiling") { model.setMaster(ceilingDBTP: $0) }
            fader(value: model.mix.master.targetLUFS, range: -30 ... -6, format: "target %.0f LUFS", width: compact ? 110 : 140, name: "Master target") { model.setMaster(targetLUFS: $0) }
            if let master { lastReading(master) }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    /// The two returns every strip sends to: the reverb's space and the echo's time and feedback.
    private func returnsRow(compact: Bool) -> some View {
        let echo = model.mix.echoSettings
        return HStack(spacing: compact ? 8 : 12) {
            Text("Returns").font(Design.Typography.ui(13, weight: .medium))
                .frame(width: 120, alignment: .leading)
            Menu {
                ForEach(Room.allCases, id: \.self) { room in
                    Button("\(room.name): \(room.about)") { model.setRoom(room) }
                }
            } label: {
                Text("Reverb: \(model.mix.roomSetting.name)").font(Design.Typography.ui(11))
            }
            .menuStyle(.button)
            .fixedSize()
            .help("The space the send goes to: \(model.mix.roomSetting.about).")
            Menu {
                ForEach(Echo.times, id: \.name) { time in
                    Button("Every \(time.name)") { model.setEcho(beats: time.beats); model.endGesture() }
                }
            } label: {
                Text("Echo: every \(echo.timeName)").font(Design.Typography.ui(11))
            }
            .menuStyle(.button)
            .fixedSize()
            .help("How far apart the echo's repeats are, in the song's beats: they follow the tempo.")
            fader(value: echo.feedback, range: 0...0.85, format: "feedback %.2f", width: 120, name: "Echo feedback",
                  readout: String(format: "%.0f%% comes round again", echo.feedback * 100)) { model.setEcho(feedback: $0) }
            Spacer(minLength: 0)
        }
    }

    /// What the Master last read, on the strips: whether the moves you are making here are
    /// landing the song on its target, without leaving the strips to find out. Pressing it opens
    /// the Master tab.
    private func lastReading(_ master: MasterModel) -> some View {
        let reading = master.reading
        let text = reading.map { String(format: "%.1f LUFS · %.1f dBTP", $0.observation.integratedLUFS, $0.truePeakDBTP) } ?? "Loudness not measured"
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
                Button(model.isReadingOverlay ? "Measuring…" : "Compare") { Task { await model.readOverlay() } }
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
            Text("Every move you let go of is a mix version; step back from Parts. Pick two strips and Compare to see where they share energy.")
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
            // Shown while still: a strip row or a master panel cut off at the edge says there is
            // more rather than looking finished.
            ScrollView(axes) { content }
                .scrollIndicators(.visible)
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
