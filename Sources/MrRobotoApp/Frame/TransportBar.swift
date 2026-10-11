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
    @State private var isShowingSettings = false

    var body: some View {
        if Design.style.lcdTransport {
            studio
        } else {
            cool
        }
    }

    /// Studio's bar: the glyphs, the display, what plays, the controller, and the form.
    private var studio: some View {
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

    private var cool: some View {
        // 28 between groups, not 36: at the narrowest window the groups' own widths nearly fill
        // the bar, and the key was what gave — "D major" broke into "D maj or".
        HStack(spacing: 28) {
            controls
            keyAndTempo
            position
            NowPlayingReadout(app: app)
            midi
            sectionStrip
        }
        .padding(.horizontal, 40)
        .frame(height: FrameLayout.transportHeight)
        .background(Design.Palette.paper)
    }

    /// Where the playhead is, and what is sounding. Quiet while stopped — a transport that has not
    /// been started should not claim a position — and the plan's own summary while it plays.
    private var position: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.transport == .stopped ? "—.—" : app.positionText)
                .font(Design.Typography.numeric(17))
                .foregroundStyle(app.transport.isPlaying ? Design.Palette.accent : Design.Palette.inkTertiary)
            Text(playingLine)
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .lineLimit(1)
        }
        // The one group that may give a little: its second line is a single truncating line.
        .frame(minWidth: 120, idealWidth: 150, maxWidth: 150, alignment: .leading)
        .help(app.transport.silence?.detail ?? "Bar and beat, and what the transport is playing")
    }

    private var playingLine: String {
        if let silence = app.transport.silence { return silence.headline }
        if app.transport.isPlaying { return "\(app.elapsedText) · \(app.playback.summary)" }
        return app.playback.summary
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                Task { await SurfaceWiring.shared.player(for: app).spaceBar() }
            } label: {
                Image(systemName: app.transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Design.Palette.ink)
            }
            .buttonStyle(.plain)
            .help("Play or stop (Space)")

            Button {
                // One Stop: the song, and anything a surface or the ledger started.
                Task {
                    await SurfaceWiring.shared.player(for: app).stopSounding()
                    await app.stopTransport()
                }
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
            .help("Loop (⌘L)")

            Button {
                app.toggleClick()
            } label: {
                Image(systemName: "metronome")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(app.isClicking ? Design.Palette.accent : Design.Palette.inkTertiary)
            }
            .buttonStyle(.plain)
            .help(app.isClicking ? "Click on: a metronome plays with the song (⌘K)" : "Click (⌘K)")
            .accessibilityLabel(app.isClicking ? "Click on" : "Click off")

            if case .unavailable(let reason) = app.transport {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Design.Palette.danger)
                    .help("The transport could not start: \(reason)")
            }
            // Not a failure: the song simply holds nothing that can be sounded. Said quietly, with
            // the thing that would fix it in the tooltip.
            if let silence = app.transport.silence {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .help("\(silence.headline). \(silence.detail)")
            }
        }
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

    /// The key, the tempo and the meter — and, pressed, the place to change them. They are read
    /// here more than anywhere, so this is where a person reaches to set them.
    private var keyAndTempo: some View {
        Button {
            isShowingSettings.toggle()
        } label: {
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
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.song == nil)
        .help(app.song == nil ? "The key, tempo and meter of the open song" : "Set the song's key, tempo and meter")
        .accessibilityLabel("Key \(app.song?.key?.name ?? "none"), \(Int(app.clock.tempo.rounded())) beats per minute, \(app.clock.timeSignature.description). Settings")
        .popover(isPresented: $isShowingSettings, arrowEdge: .top) {
            SongSettingsPopover(app: app)
        }
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
                let hued = Design.style.laneColours
                let strip = TransportBar.strip(names: sections.map(\.name), bars: sections.map(\.lengthInBars),
                                               room: geometry.size.width, letterWidth: hued ? 6 : 8)
                HStack(alignment: .bottom, spacing: hued ? 3 : 6) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        let width = strip.blocks[index]
                        let isLit = app.activeSection == section.id
                        // A click lights the section; a double-click plays from it. Not a Button: a
                        // button's own tap would take the first click and the double never arrives.
                        VStack(alignment: hued ? .leading : .center, spacing: hued ? 5 : 6) {
                            if hued {
                                // Studio: each section in its kind's hue, the lit one at full strength.
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(SectionHue.color(for: section.name).opacity(isLit ? 1 : 0.45))
                                    .frame(width: width, height: 6)
                                Text(section.name)
                                    .font(.system(size: 10, weight: isLit ? .semibold : .regular))
                                    .foregroundStyle(isLit ? Design.Palette.ink : Design.Palette.inkTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: strip.names[index], alignment: .leading)
                            } else {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isLit ? Design.Palette.accent : Design.Palette.ink)
                                    .frame(width: width, height: 10)
                                Text(section.name.uppercased())
                                    .font(Design.Typography.label)
                                    .tracking(1.1)
                                    .foregroundStyle(isLit ? Design.Palette.accent : Design.Palette.inkSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: strip.names[index], alignment: .leading)
                            }
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
    /// `letterWidth` is the label face's: about eight points a letter for Cool's tracked capitals,
    /// six for Studio's sentence case.
    nonisolated static func strip(names: [String], bars: [Int], room: CGFloat,
                                  letterWidth: CGFloat = 8) -> (blocks: [CGFloat], names: [CGFloat]) {
        let spacing = CGFloat(max(0, bars.count - 1)) * (letterWidth < 8 ? 3 : 6)
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

/// Studio's transport glyphs: Play as the one filled control, orange while the song sounds; Stop;
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
        let ink = recording ? Design.Palette.lcdRecordingInk : Design.Palette.lcdInk
        let label = recording ? Design.Palette.lcdRecordingInk.opacity(0.6) : Design.Palette.lcdLabel
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
            .background(recording ? Design.Palette.lcdRecording : Design.Palette.plate,
                        in: RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(app.song == nil ? "The key, tempo and meter of the open song" : "Set the song's key, tempo and meter")
        .accessibilityLabel("Bar \(position). Key \(app.song?.key?.name ?? "none"), \(Int(app.clock.tempo.rounded())) beats per minute, \(app.clock.timeSignature.description). Settings")
        .popover(isPresented: $isShowingSettings, arrowEdge: .top) {
            SongSettingsPopover(app: app)
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
