import SwiftUI
import UniformTypeIdentifiers

/// One screen: the Mac folder, what the take is for, the button, the level, the last captures.
/// With the Mac folder chosen, the song and section are picked from the guides the Mac wrote,
/// the guide plays in the headphones while the take is sung, and the take goes to the Mac's
/// inbox on its own; without it, they are typed, and a capture is shared — AirDrop to the Mac
/// and the inbox takes it by its name.
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                macRow
                target
                button
                level
                captures
                Spacer(minLength: 0)
                if let error = recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .padding(.top, 8)
            .navigationTitle("Roboto Capture")
            .navigationBarTitleDisplayMode(.inline)
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
    }

    // MARK: The Mac folder

    private var macRow: some View {
        HStack(spacing: 12) {
            Image(systemName: recorder.mac.url == nil ? "icloud.slash" : "icloud")
                .font(.title3)
                .foregroundStyle(recorder.mac.url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                if let name = recorder.mac.name {
                    Text(name).font(.subheadline)
                    Text(macDetail).font(.caption)
                        .foregroundStyle(recorder.mac.url != nil && !recorder.mac.isInCloud ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Choose the Mr. Roboto folder").font(.subheadline)
                    Text(recorder.mac.problem ?? "At the top of iCloud Drive. Captures go to its Inbox on their own, and its guides play while you sing.")
                        .font(.caption)
                        .foregroundStyle(recorder.mac.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(recorder.mac.url == nil ? "Choose…" : "Change") { choosingFolder = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal)
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

    private var target: some View {
        VStack(spacing: 8) {
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
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if recorder.guide != nil {
                Toggle("Play the guide while recording", isOn: $recorder.playGuide)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal)
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

    // MARK: The button and the level

    private var button: some View {
        Button {
            Task { await recorder.toggle() }
        } label: {
            ZStack {
                Circle().fill(recorder.isRecording ? Color.red : Color.red.opacity(0.85)).frame(width: 128, height: 128)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 44, height: 44)
                } else {
                    Circle().fill(.white).frame(width: 52, height: 52)
                }
            }
            .shadow(radius: recorder.isRecording ? 12 : 4)
        }
        .buttonStyle(.plain)
        .disabled(recorder.fetchingGuide)
        .accessibilityLabel(recorder.isRecording ? "Stop" : "Record")
    }

    private var level: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(recorder.level > 0.9 ? Color.red : Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(recorder.level))
                }
            }
            .frame(height: 10)
            Text(status)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if let note = recorder.routeNote, recorder.isRecording {
                Text(note).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 32)
    }

    private var status: String {
        if recorder.fetchingGuide { return "Fetching the guide…" }
        guard recorder.isRecording else { return "Ready" }
        let time = String(format: "%.1f s", recorder.seconds)
        return recorder.guidePlaying ? "\(time) · guide" : time
    }

    // MARK: The captures

    private var captures: some View {
        List {
            Section("Captures") {
                if recorder.captures.isEmpty {
                    Text(recorder.mac.inbox == nil
                         ? "None yet. Press the button, sing, press it again; then share the take to your Mac."
                         : "None yet. Press the button, sing, press it again; the take goes to your Mac on its own.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(recorder.captures.prefix(6)) { capture in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.title).font(.body)
                            Text(subtitle(capture))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recorder.isSent(capture) {
                            Image(systemName: recorder.delivery(of: capture) == .taken ? "checkmark.icloud" : "icloud")
                                .foregroundStyle(.secondary)
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
                    .swipeActions { Button("Delete", role: .destructive) { recorder.delete(capture) } }
                }
            }
        }
        .listStyle(.insetGrouped)
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
