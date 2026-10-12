import SongGraph
import SwiftUI

/// Play, stop, loop, the key and tempo the clock runs at, where the playhead is, and the section
/// strip with the section it is *in* lit. The strip's blocks are proportional to each section's
/// length in bars, as in the mockups: a bridge is visibly shorter than a chorus.
///
/// Everything here reports the engine rather than a flag. The play control reads `app.transport`,
/// which now only reaches `.playing` once sources have been scheduled and the transport started;
/// the position and the lit section come from `AppState`'s poll of the player's own reading; and a
/// song with nothing to sound says so in the middle of the bar instead of lighting up.
struct TransportBar: View {
    let app: AppState

    /// The glyphs, the display, what plays, the controller, and the form.
    var body: some View {
        HStack(spacing: 18) {
            StudioTransportControls(app: app)
            TransportDisplay(app: app)
            NowPlayingReadout(app: app)
            midi
            sectionStrip
        }
        .padding(.horizontal, Design.Metric.regionInset)
        .frame(height: FrameLayout.transportHeight)
        // A step up from the ground, as a toolbar is: in the dark appearance the display's plate
        // would otherwise sit on a bar only a shade lighter than itself, and vanish into it.
        .background(Design.Palette.raised)
    }

    /// Inputs I5: the controller on the kit, the bass, the keys, or nothing, and which it is.
    private var midi: some View {
        let control = SurfaceWiring.shared.midi(for: app)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                // Named, as the parts' chips beside it are: four chips under no heading read as a
                // choice about something, and nothing said what.
                SmallLabel("MIDI", color: Design.Palette.inkTertiary)
                SegmentedChoice(options: MIDIControl.Mode.allCases, selection: control.mode, title: \.title) { control.mode = $0 }
            }
            HStack(spacing: 6) {
                if control.mode != .off, app.song != nil {
                    // Play in: record the controller against the song, no microphone needed.
                    Button {
                        Task {
                            if control.isPlayingIn { await control.stopPlayIn() } else { await control.playIn() }
                        }
                    } label: {
                        Image(systemName: control.isPlayingIn ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Design.Palette.danger)
                    }
                    .buttonStyle(.plain)
                    .disabled(control.isCapturing && !control.isPlayingIn)
                    .help(control.isPlayingIn
                          ? "Stop, and keep what you played as a \(control.mode.capturedKind)"
                          : "Play in: the song from its section, a bar counted in, and what you play kept as a \(control.mode.capturedKind)")
                    .accessibilityLabel(control.isPlayingIn ? "Stop playing in" : "Play in")
                }
                Text(midiLine(control))
                    .font(Design.Typography.ui(11, weight: .regular))
                    .foregroundStyle(control.mode == .off ? Design.Palette.inkTertiary : Design.Palette.inkSecondary)
                    .lineLimit(1)
            }
        }
        // The label and four chips side by side: Off, Kit, Bass and Keys.
        .frame(width: 210, alignment: .leading)
        .help("A MIDI controller plays the song's kit, its bass or its keys now. Play in, or the Booth recording, keeps what you play as a groove, a bass line or a melody.")
    }

    private func midiLine(_ control: MIDIControl) -> String {
        if let error = control.lastError { return error }
        if control.isCapturing { return "Capturing on \(control.lastSource ?? control.sources.first ?? "MIDI")" }
        if let source = control.lastSource ?? control.sources.first { return control.mode == .off ? source : "\(source) → \(control.mode.title)" }
        return "No controller"
    }

    @ViewBuilder
    private var sectionStrip: some View {
        let sections = app.song?.sections ?? []
        if sections.isEmpty {
            Text(app.song == nil ? "No song open" : "No sections yet")
                .font(Design.Typography.ui(12, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                // One line, cut at its end: squeezed at the window's minimum it used to wrap a
                // letter at a time down the bar.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        } else {
            // The strip takes the room the bar has left and no more: each block at its own width
            // while they fit, all of them scaled down together when they do not, names cut to their
            // block. Blocks of a fixed width with whole names under them used to make the bar wider
            // than the window — an eight-section form pushed Play and Save off both edges at 1440.
            GeometryReader { geometry in
                let strip = TransportBar.strip(names: sections.map(\.name), bars: sections.map(\.lengthInBars),
                                               room: geometry.size.width)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        let width = strip.blocks[index]
                        let isLit = app.activeSection == section.id
                        let hue = SectionHue.color(for: section.name)
                        // A click lights the section; a double-click plays from it. Not a Button: a
                        // button's own tap would take the first click and the double never arrives.
                        VStack(alignment: .leading, spacing: 5) {
                            // Each section in its kind's hue, the lit one at full strength and glowing
                            // while it plays, its name in the hue as words.
                            RoundedRectangle(cornerRadius: 2)
                                .fill(hue.opacity(isLit ? 1 : 0.55))
                                .frame(width: width, height: 6)
                                .shadow(color: isLit && app.transport.isPlaying ? hue.opacity(0.9) : .clear, radius: 5)
                            Text(section.name)
                                .font(.system(size: 10, weight: isLit ? .semibold : .regular))
                                .foregroundStyle(isLit ? SectionHue.color(for: section.name, .ink) : Design.Palette.inkTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: strip.names[index], alignment: .leading)
                        }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        app.setActiveSection(section.id)
                        Task { await app.startTransport(fromSection: section.id) }
                    }
                    .onTapGesture { app.setActiveSection(section.id) }
                    .help("\(section.name) · \(section.lengthInBars) bars, from bar \((app.sectionStartBar(section.id) ?? 0) + 1). Click to light it; double-click to play from it (⇧Space).")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(section.name), \(section.lengthInBars) bars\(app.activeSection == section.id ? ", lit" : "")")
                    .accessibilityAddTraits(.isButton)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    /// Five points a bar, floored so a two-bar turnaround is still hittable and capped so a
    /// thirty-two-bar section does not push the strip off the window.
    nonisolated static func blockWidth(bars: Int) -> CGFloat {
        min(120, max(24, CGFloat(bars) * 5))
    }

    /// The strip laid into `room`: each block's width and the width its name gets. While every
    /// block and whole name fits, a name may run past its short block — "HOOK" under two bars.
    /// When they do not, names are held to their blocks, and the blocks shrink together if even
    /// they do not fit.
    ///
    /// A name is reckoned at six points a letter: the label face, in sentence case at 10 points.
    nonisolated static func strip(names: [String], bars: [Int], room: CGFloat) -> (blocks: [CGFloat], names: [CGFloat]) {
        let letterWidth: CGFloat = 6
        let spacing = CGFloat(max(0, bars.count - 1)) * 3
        let blocks = bars.map(blockWidth(bars:))
        let whole = names.map { CGFloat($0.count) * letterWidth + 2 }
        if zip(blocks, whole).map(max).reduce(0, +) + spacing <= room {
            return (blocks, zip(blocks, whole).map(max))
        }
        let total = blocks.reduce(0, +)
        let scale = total > 0 ? max(0, min(1, (room - spacing) / total)) : 1
        let scaled = blocks.map { $0 * scale }
        return (scaled, scaled)
    }
}

/// The transport's glyphs: Play as the one filled control, orange while the song sounds; Stop;
/// Loop, yellow while it cycles, as a cycle region is on every desk; and the click.
private struct StudioTransportControls: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 4) {
            glyph(app.transport.isPlaying ? "pause.fill" : "play.fill", size: 13,
                  fill: app.transport.isPlaying ? Design.Palette.sounding : Design.Palette.fill,
                  ink: app.transport.isPlaying ? Design.Palette.onSounding : Design.Palette.ink,
                  help: "Play or stop (Space)") {
                Task { await SurfaceWiring.shared.player(for: app).spaceBar() }
            }
            glyph("stop.fill", size: 11, fill: nil,
                  ink: app.transport == .stopped ? Design.Palette.inkTertiary : Design.Palette.ink,
                  help: "Stop") {
                // One Stop: the song, and anything a surface or the ledger started.
                Task {
                    await SurfaceWiring.shared.player(for: app).stopSounding()
                    await app.stopTransport()
                }
            }
            glyph("repeat", size: 12, fill: app.isLooping ? Design.Palette.solo : nil,
                  ink: app.isLooping ? Color.black.opacity(0.85) : Design.Palette.inkSecondary,
                  help: "Loop (⌘L)") { app.toggleLoop() }
            glyph("metronome", size: 12, fill: app.isClicking ? Design.Palette.selected : nil,
                  ink: app.isClicking ? Design.Palette.ink : Design.Palette.inkSecondary,
                  help: app.isClicking ? "Click on: a metronome plays with the song (⌘K)" : "Click (⌘K)") { app.toggleClick() }
                .accessibilityLabel(app.isClicking ? "Click on" : "Click off")
            if case .unavailable(let reason) = app.transport {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.Palette.danger)
                    .help("The transport could not start: \(reason)")
            }
            // Not a failure: the song simply holds nothing that can be sounded. Said quietly, with
            // the thing that would fix it in the tooltip.
            if let silence = app.transport.silence {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .help("\(silence.headline). \(silence.detail)")
            }
        }
    }

    private func glyph(_ name: String, size: CGFloat, fill: Color?, ink: Color, help: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 30, height: 30)
                .background(fill ?? .clear, in: RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The transport's display: where the playhead is, the tempo, the meter and the key, on a dark
/// plate in both appearances, in Plex's condensed width with a slashed zero — Logic's display,
/// #0E1012 with #CDE7FF figures. A lamp beside the position lights orange while anything sounds;
/// the whole plate goes red while a take or a controller is recording. Pressed, it opens the song's
/// settings, as the key and tempo did.
///
/// At rest it reads where Play would start — bar 1, or the lit section's first bar — dimmed, rather
/// than dashes, which read as a display that had broken.
struct TransportDisplay: View {
    let app: AppState
    @State private var isShowingSettings = false

    var body: some View {
        let recording = SurfaceWiring.shared.isRecording(for: app)
        // The display lights in the colour of the section playing: the figures in its hue, a glow
        // round them and round the plate — the hue at full strength, as a plate wears it in every
        // palette. Recording keeps its own red.
        let glow = recording ? nil : app.playingSectionHue.map { Design.Palette.lane($0, .plate) }
        let ink = recording ? Design.Palette.lcdRecordingInk : (glow ?? Design.Palette.lcdInk)
        let label = recording ? Design.Palette.lcdRecordingInk.opacity(0.6) : (glow?.opacity(0.7) ?? Design.Palette.lcdLabel)
        let isPlaying = app.transport.isPlaying
        Button {
            // Not `.disabled`: a disabled button greys the whole plate, and a display does not go
            // grey when there is no song; its figures go quiet.
            if app.song != nil { isShowingSettings.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(recording ? Design.Palette.danger : (isPlaying ? Design.Palette.sounding : label.opacity(0.35)))
                        .frame(width: 6, height: 6)
                    field(position, label: isPlaying ? "Bar · \(app.elapsedText)" : "Bar", size: 24,
                          ink: isPlaying ? ink : ink.opacity(0.55), labelInk: label, minWidth: 64)
                }
                field("\(Int(app.clock.tempo.rounded()))", label: "BPM", size: 17, ink: ink, labelInk: label, minWidth: 30)
                field(app.clock.timeSignature.description, label: "Time", size: 17, ink: ink, labelInk: label, minWidth: 26)
                field(app.song?.key?.name ?? "No key", label: "Key", size: 17,
                      ink: app.song?.key == nil ? ink.opacity(0.5) : ink, labelInk: label, minWidth: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .shadow(color: glow?.opacity(0.75) ?? .clear, radius: 6)
            .background(recording ? Design.Palette.lcdRecording : Design.Palette.plate,
                        in: RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous)
                    .strokeBorder(glow?.opacity(0.55) ?? Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: glow?.opacity(0.45) ?? .clear, radius: 10)
            .animation(.easeInOut(duration: 0.35), value: app.playingSectionHue)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(app.song == nil ? "The key, tempo and meter of the open song" : "Set the song's key, tempo and meter")
        .accessibilityLabel("Bar \(position). Key \(app.song?.key?.name ?? "none"), \(Int(app.clock.tempo.rounded())) beats per minute, \(app.clock.timeSignature.description). Settings")
        .popover(isPresented: $isShowingSettings, arrowEdge: .top) {
            SongSettingsPopover(app: app)
        }
        // There is no header to open the settings from: File ▸ New Song, the title's menu and the
        // band ask for them here, on the display that shows the tempo and the key.
        .onChange(of: app.wantsSongSettings, initial: true) { _, wants in
            guard wants else { return }
            app.wantsSongSettings = false
            if app.song != nil { isShowingSettings = true }
        }
    }

    /// Bar and beat while it plays; at rest, the bar Play starts from.
    private var position: String {
        if app.transport.isPlaying || app.isCountingIn { return app.positionText }
        let bar = app.activeSection.flatMap { app.sectionStartBar($0) } ?? 0
        return "\(bar + 1).1"
    }

    private func field(_ value: String, label: String, size: CGFloat, ink: Color, labelInk: Color,
                       minWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(Design.Typography.readout(size))
                .foregroundStyle(ink)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(labelInk)
                .lineLimit(1)
        }
        .frame(minWidth: minWidth, alignment: .leading)
    }
}
