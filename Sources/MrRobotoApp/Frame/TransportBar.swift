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
                    .foregroundStyle(Design.Palette.warn)
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
                Text("MIDI").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
                ForEach(MIDIControl.Mode.allCases, id: \.self) { mode in
                    BoothChip(mode.title, isOn: control.mode == mode) { control.mode = mode }
                }
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
                            .foregroundStyle(Design.Palette.warn)
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
            Text(app.song == nil ? "No song open" : "No sections arranged yet")
                .font(Design.Typography.ui(12, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(sections) { section in
                    // A click lights the section; a double-click plays from it. Not a Button: a
                    // button's own tap would take the first click and the double never arrives.
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Five points a bar, floored so a two-bar turnaround is still hittable and capped so a
    /// thirty-two-bar section does not push the strip off the window.
    nonisolated static func blockWidth(bars: Int) -> CGFloat {
        min(120, max(24, CGFloat(bars) * 5))
    }
}
