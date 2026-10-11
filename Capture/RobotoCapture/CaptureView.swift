import SwiftUI
import UniformTypeIdentifiers

/// One screen: the Mac folder, what the take is for, the display, the button, the last captures.
/// With the Mac folder chosen, the song and section are picked from the guides the Mac wrote,
/// the guide plays in the headphones while the take is sung, and the take goes to the Mac's
/// inbox on its own; without it, they are typed, and a capture is shared — AirDrop to the Mac
/// and the inbox takes it by its name.
///
/// Drawn in Vibrant, the Mac's palette: near-black, and an accent that is the colour of what the
/// take is for — a verse's blue, a hook's gold, an idea's green — with the display glowing in it
/// while the guide plays, as the Mac's transport does while that section plays there.
struct CaptureView: View {
    @State private var recorder = Recorder()
    @State private var choosingFolder = false
    @Environment(\.scenePhase) private var scenePhase
    /// A look at the folder every few seconds while something sent is still on its way.
    private let look = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    /// The song and section typed rather than picked: a song the Mac wrote no guides for.
    @State private var typing = false

    /// The Song picker's choice for a typed song that is not among the guides.
    private static let another = "\u{1}another"

    /// The colour of the work: what the accent, the display's glow and the take's card wear.
    private var accent: Color { CapturePalette.accent(recorder.workLane) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                macRow
                target
                display
                button
                captures
                if let error = recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(CapturePalette.danger)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CapturePalette.paper.ignoresSafeArea())
            .navigationTitle("Roboto Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CapturePalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    recorder.mac.choose(url)
                    typing = false
                }
            }
            .onReceive(look) { _ in
                if recorder.awaitingTheMac { recorder.refreshDeliveries() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Back from the Mac: the guides it wrote meanwhile, and what it took.
                if phase == .active {
                    recorder.mac.reload()
                    recorder.refreshDeliveries()
                }
            }
        }
        .tint(accent)
        // A new section picked recolours the screen as one change, not a flicker.
        .animation(.easeInOut(duration: 0.3), value: recorder.workLane)
    }

    // MARK: The Mac folder

    private var macRow: some View {
        HStack(spacing: 12) {
            Image(systemName: recorder.mac.url == nil ? "icloud.slash" : "icloud")
                .font(.title3)
                .foregroundStyle(recorder.mac.url == nil ? CapturePalette.inkTertiary : accent)
            VStack(alignment: .leading, spacing: 2) {
                if let name = recorder.mac.name {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(CapturePalette.ink)
                    Text(macDetail).font(.caption)
                        .foregroundStyle(recorder.mac.url != nil && !recorder.mac.isInCloud ? CapturePalette.warn : CapturePalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Choose the Mr. Roboto folder").font(.subheadline.weight(.semibold)).foregroundStyle(CapturePalette.ink)
                    Text(recorder.mac.problem ?? "At the top of iCloud Drive. Captures go to its Inbox on their own, and its guides play while you sing.")
                        .font(.caption)
                        .foregroundStyle(recorder.mac.problem == nil ? CapturePalette.inkSecondary : CapturePalette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(recorder.mac.url == nil ? "Choose…" : "Change") { choosingFolder = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .modifier(Card())
    }

    private var macDetail: String {
        if recorder.mac.url != nil, !recorder.mac.isInCloud {
            return "This folder is not in iCloud Drive, so the Mac never sees it. Choose Mr. Roboto under iCloud Drive."
        }
        if recorder.mac.loading { return "Reading the guides…" }
        if let problem = recorder.mac.problem { return problem }
        guard let songs = recorder.mac.manifest?.songs, !songs.isEmpty else {
            return "No guides yet. On the Mac: File ▸ Export ▸ Guides for the Phone."
        }
        return "Guides for \(songs.count) song\(songs.count == 1 ? "" : "s"). Captures go to the Inbox on their own."
    }

    // MARK: What the take is for

    /// The take's card, in the colour of what it is for: a stripe down its edge and a wash out of
    /// it, as a part's row has on the Mac.
    private var target: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let songs = recorder.mac.manifest?.songs, !songs.isEmpty, !typing {
                LabeledContent("Song") {
                    Picker("Song", selection: songChoice) {
                        Text("Idea").tag("")
                        ForEach(songs) { Text($0.title).tag($0.title) }
                        Text("Another song…").tag(Self.another)
                    }
                    .pickerStyle(.menu)
                }
                if let guided = recorder.guidedSong {
                    LabeledContent("Section") {
                        Picker("Section", selection: sectionChoice) {
                            ForEach(guided.sections) { Text($0.name).tag($0.name) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } else {
                TextField("Song (empty for an idea)", text: $recorder.song)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("Section (verse, hook…)", text: $recorder.section)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if recorder.mac.manifest?.songs.isEmpty == false {
                    Button("Pick one of the Mac's songs instead") { typing = false }
                        .font(.footnote)
                }
            }
            Text(footnote)
                .font(.footnote).foregroundStyle(CapturePalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if recorder.guide != nil {
                Toggle("Play the guide while recording", isOn: $recorder.playGuide)
                    .font(.subheadline)
            }
        }
        .foregroundStyle(CapturePalette.ink)
        .modifier(Card(hue: accent))
    }

    private var songChoice: Binding<String> {
        Binding {
            if recorder.song.isEmpty { return "" }
            return recorder.guidedSong?.title ?? Self.another
        } set: { choice in
            if choice == Self.another { typing = true; return }
            recorder.song = choice
            // The section it had, when the new song has one by that name; else the first.
            let sections = recorder.guidedSong?.sections ?? []
            recorder.section = sections.first { $0.name.caseInsensitiveCompare(recorder.section) == .orderedSame }?.name
                ?? sections.first?.name ?? ""
        }
    }

    private var sectionChoice: Binding<String> {
        Binding { recorder.guide?.name ?? recorder.section } set: { recorder.section = $0 }
    }

    private var footnote: String {
        if recorder.song.isEmpty { return "This will land in the library as an idea." }
        let what = "Take \(recorder.nextPass) of \(recorder.section.isEmpty ? "the song" : recorder.section) on \(recorder.song)"
        if recorder.willPlayGuide, let guide = recorder.guide {
            return "\(what), after \(guide.countInBars) bar\(guide.countInBars == 1 ? "" : "s") of click in your headphones."
        }
        return "\(what)."
    }

    // MARK: The display and the button

    /// The take's display: a dark plate like the Mac's transport, with the time and what the take
    /// is, and the level of what the microphone hears in the sounding orange. While the guide plays
    /// it glows in the colour of the section being sung; recording without one, it goes the
    /// recording red the Mac's display goes in the Booth.
    private var display: some View {
        let glow: Color? = recorder.guidePlaying ? accent : nil
        let recording = recorder.isRecording && glow == nil
        let ink = glow ?? (recording ? CapturePalette.lcdRecordingInk : CapturePalette.lcdInk)
        let label = glow?.opacity(0.75) ?? (recording ? CapturePalette.lcdRecordingInk.opacity(0.6) : CapturePalette.lcdLabel)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timeText)
                    .font(.system(size: 46, weight: .medium).width(.condensed).monospacedDigit())
                    .foregroundStyle(recorder.isRecording ? ink : ink.opacity(0.55))
                    .contentTransition(.numericText())
                Text("s").font(.system(size: 17, weight: .medium).width(.condensed)).foregroundStyle(label)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(state)
                        .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(label)
                    Text(takeName)
                        .font(.system(size: 15, weight: .semibold).width(.condensed))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
            }
            .shadow(color: glow?.opacity(0.8) ?? .clear, radius: 8)
            meter
            if let note = recorder.routeNote, recorder.isRecording {
                Text(note).font(.footnote).foregroundStyle(CapturePalette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(recording ? CapturePalette.lcdRecording : CapturePalette.plate, in: shape)
        .overlay(shape.strokeBorder(glow?.opacity(0.6) ?? Color.white.opacity(0.07), lineWidth: 1))
        .shadow(color: glow?.opacity(0.45) ?? .clear, radius: 18)
        .padding(.horizontal)
        .animation(.easeInOut(duration: 0.35), value: recorder.guidePlaying)
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        String(format: "%.1f", recorder.isRecording ? recorder.seconds : 0)
    }

    private var state: String {
        if recorder.fetchingGuide { return "FETCHING THE GUIDE" }
        guard recorder.isRecording else { return "READY" }
        return recorder.guidePlaying ? "GUIDE" : "RECORDING"
    }

    /// What this take is: an idea, or the pass of a section of a song.
    private var takeName: String {
        if recorder.song.isEmpty { return "Idea" }
        let section = recorder.guide?.name ?? recorder.section
        return "\(section.isEmpty ? "Take" : section) \(recorder.nextPass)"
    }

    /// The microphone's level: orange, for what is sounding; red at the top, where it clips.
    private var meter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(recorder.level > 0.9 ? CapturePalette.danger : CapturePalette.sounding)
                    .frame(width: geometry.size.width * CGFloat(recorder.level))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    /// Record: the danger red, the one control on the screen in it, and a red halo while it records.
    private var button: some View {
        Button {
            Task { await recorder.toggle() }
        } label: {
            ZStack {
                Circle().fill(CapturePalette.danger).frame(width: 112, height: 112)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 40, height: 40)
                } else {
                    Circle().fill(.white).frame(width: 46, height: 46)
                }
            }
            .background {
                Circle().stroke(CapturePalette.danger.opacity(recorder.isRecording ? 0.45 : 0), lineWidth: 6)
                    .frame(width: 128, height: 128)
            }
            .shadow(color: CapturePalette.danger.opacity(recorder.isRecording ? 0.55 : 0.2), radius: recorder.isRecording ? 18 : 6)
        }
        .buttonStyle(.plain)
        .disabled(recorder.fetchingGuide)
        .accessibilityLabel(recorder.isRecording ? "Stop" : "Record")
    }

    // MARK: The captures

    private var captures: some View {
        List {
            Section {
                if recorder.captures.isEmpty {
                    Text(recorder.mac.inbox == nil
                         ? "None yet. Press the button, sing, press it again; then share the take to your Mac."
                         : "None yet. Press the button, sing, press it again; the take goes to your Mac on its own.")
                        .font(.footnote).foregroundStyle(CapturePalette.inkSecondary)
                        .listRowBackground(CapturePalette.panel)
                }
                ForEach(recorder.captures.prefix(6)) { capture in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.title).font(.body).foregroundStyle(CapturePalette.ink)
                            Text(subtitle(capture))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(CapturePalette.inkTertiary)
                        }
                        Spacer()
                        if recorder.isSent(capture) {
                            let taken = recorder.delivery(of: capture) == .taken
                            Image(systemName: taken ? "checkmark.icloud" : "icloud")
                                .foregroundStyle(taken ? CapturePalette.ok : CapturePalette.inkTertiary)
                                .accessibilityLabel(deliveryWord(capture))
                        } else if recorder.isSending(capture) {
                            ProgressView().controlSize(.small)
                        } else if recorder.mac.inbox != nil {
                            Button { recorder.send(capture) } label: { Image(systemName: "icloud.and.arrow.up") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Put in the Mac's inbox")
                        }
                        ShareLink(item: capture.url) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                    }
                    .listRowBackground(CaptureRowGround(hue: CapturePalette.lane(capture.lane)))
                    .swipeActions { Button("Delete", role: .destructive) { recorder.delete(capture) } }
                }
            } header: {
                Text("Captures")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(CapturePalette.inkTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func subtitle(_ capture: Capture) -> String {
        var line = String(format: "%.1f s · %@", capture.seconds, capture.stamp)
        if capture.lead != nil { line += " · guide" }
        if recorder.isSent(capture) { line += " · " + deliveryWord(capture) }
        return line
    }

    /// What the folder says about a sent capture. "On the Mac" only once the Mac has moved it.
    private func deliveryWord(_ capture: Capture) -> String {
        switch recorder.delivery(of: capture) {
        case .taken: return "on the Mac"
        case .inCloud: return "in iCloud, waiting for the Mac"
        case .uploading: return "uploading"
        case .waiting: return "waiting to upload"
        case .missing, .none: return "sent"
        }
    }
}

/// A grouped area on the paper: the panel's grey with a card's corner — and, given a hue, a stripe
/// of it down the leading edge with a wash out of it, the way a part's row is drawn on the Mac.
private struct Card: ViewModifier {
    var hue: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(14)
            .padding(.leading, hue == nil ? 0 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .leading) {
                    CapturePalette.panel
                    if let hue {
                        LinearGradient(colors: [hue.opacity(0.22), hue.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        Rectangle().fill(hue).frame(width: 4)
                    }
                }
                .clipShape(shape)
            }
            .padding(.horizontal)
    }
}

/// A capture's row: its section's colour, or an idea's green, down its edge and washed out of it.
private struct CaptureRowGround: View {
    let hue: Color

    var body: some View {
        ZStack(alignment: .leading) {
            CapturePalette.panel
            LinearGradient(colors: [hue.opacity(0.18), hue.opacity(0)], startPoint: .leading, endPoint: .trailing)
            Rectangle().fill(hue).frame(width: 4)
        }
    }
}
