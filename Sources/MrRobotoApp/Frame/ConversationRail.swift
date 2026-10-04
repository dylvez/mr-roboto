import SwiftUI

/// The thread. Two halves, in the order you need them.
///
/// **What next**, at the top: what this song could use, derived from what it actually holds, one
/// click each. In Gate B these are the Director's proposals; in Gate A `Guidance` derives the same
/// values from the song graph, so the rail renders `[Proposal]` either way and does not get rebuilt
/// when the band arrives. Nothing appears here that does not work when clicked — `AppState.proposals`
/// filters on `canPerform`, so the list is allowed to be empty and never allowed to lie.
///
/// **Session**, below it: what happened, in order, and who said it. Four voices — you, the app, the
/// Director, a persona by name — and the two that a model wrote are marked in the accent, so "the
/// app reported this" and "the band said this" are never the same kind of line.
///
/// The composer sends. What comes back streams into the log as it arrives rather than appearing
/// whole at the end, and under the field is the one honest number a thing that spends money owes
/// you: what this session has cost.
struct ConversationRail: View {
    let app: AppState
    @FocusState private var isComposing: Bool
    /// The suggestions above the conversation fold away and take only the height you give them:
    /// the conversation is the point of this column, and nothing above it may crowd it out.
    @AppStorage("rail.next.collapsed") private var nextIsCollapsed = false
    // A question and three options: the old height was for a list, and would scroll the question.
    @AppStorage("rail.next.height.v3") private var nextHeight = 410.0
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SmallLabel("Band")
                Spacer()
                Text("\(app.log.count)")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                CollapseButton(region: .rail, app: app)
            }
            .padding(.horizontal, 28)
            .frame(height: FrameLayout.headerHeight)

            Hairline()
            nextBlock
            if !nextIsCollapsed { nextResizer } else { Hairline() }
            history
            Hairline()
            composer
        }
        .background(Design.Palette.paper)
    }

    // MARK: What next

    /// The band's question: a member asks what you want to do next, with the few things most
    /// worth doing. Always something, from launch on — it used to be a list that was empty with
    /// no song open and folded away on first launch.
    private var nextBlock: some View {
        let question = app.nextQuestion
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                nextIsCollapsed.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: nextIsCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .frame(width: 10)
                    if let emblem = Art.emblem(for: question.asker) { ArtImage(emblem, width: 22) }
                    SmallLabel("\(question.asker.label) asks")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(nextIsCollapsed ? "Show the question" : "Fold the question away, so the conversation has the column")

            if nextIsCollapsed {
                // One line, so folding it away does not hide that something is being asked.
                Text(question.question).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary).lineLimit(1)
            } else {
                ScrollsInside {
                    NextQuestionCard(app: app, question: question)
                }
                .frame(height: CGFloat(min(max(nextHeight, 64), 480)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, nextIsCollapsed ? 10 : 14)
        .background(Design.Palette.panelAlt)
    }

    /// The edge between the suggestions and the conversation: drag it to give either more room.
    private var nextResizer: some View {
        ZStack {
            Design.Palette.panelAlt
            Capsule().fill(Design.Palette.lineStrong).frame(width: 36, height: 3)
        }
        .frame(height: 9)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartHeight ?? nextHeight
                dragStartHeight = start
                nextHeight = min(max(start + Double(value.translation.height), 64), 480)
            }
            .onEnded { _ in dragStartHeight = nil })
        .help("Drag to resize the suggestions")
    }

    // MARK: The session log

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if app.log.isEmpty {
                        EmptyNote(title: "Nothing has happened yet.",
                                  detail: "Open a song from the library, or a surface from the bench. What you do shows up here.")
                    }
                    ForEach(app.log) { entry in
                        LogLine(source: entry.source, text: entry.text, detail: entry.detail)
                            .id(entry.id)
                    }
                    // The turn in flight, drawn exactly like a finished Director line and replaced
                    // by the real entry when it lands. This is the streaming: the rail fills in
                    // while the work is happening, not twenty seconds afterwards.
                    if let band = app.band, band.isWorking {
                        if band.streaming.isEmpty {
                            ArtImage("wait-band", width: 150, height: 100)
                        }
                        LogLine(source: .director,
                                text: band.streaming.isEmpty ? (band.activity ?? "Working…") : band.streaming,
                                detail: band.streaming.isEmpty ? nil : band.activity)
                            .id(Self.draftID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .onChange(of: app.log.count) {
                guard let last = app.log.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: app.band?.streaming ?? "") {
                guard app.band?.isWorking == true else { return }
                proxy.scrollTo(Self.draftID, anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The anchor the reply-in-flight scrolls to. A constant rather than a `UUID()` in the body,
    /// which would be a new identity on every render and would scroll on every keystroke.
    private static let draftID = "director.draft"

    // MARK: The composer

    /// The field that sends, and the one line under it that says what this is costing.
    @ViewBuilder
    private var composer: some View {
        if let band = app.band {
            LiveComposer(band: band, isComposing: $isComposing)
        } else {
            InertComposer()
        }
    }
}

// MARK: - One line in the log

/// A line, with who said it above it.
///
/// The accent is the whole design: a line a model wrote is drawn in the accent and a line the app
/// wrote is not, so the log can be read at a glance for the one distinction that matters. A
/// persona's line needs nothing added here — it arrives as `.persona(name)`, prints its own name,
/// and gets the accent because `isBand` is true for it.
struct LogLine: View {
    let source: SessionEntry.Source
    let text: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if let emblem = Art.emblem(for: source) { ArtImage(emblem, width: 22) }
                SmallLabel(source.label,
                           color: source.isBand ? Design.Palette.accent : Design.Palette.inkSecondary)
            }
            Text(text)
                .font(Design.Typography.prose(16))
                .foregroundStyle(Design.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The composer

/// Ask the band. Return sends, escape stops, and the field never eats what you typed.
struct LiveComposer: View {
    @Bindable var band: DirectorSession
    @FocusState.Binding var isComposing: Bool
    @State fileprivate var showsAddressing = false
    @State private var isSettingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            addressingRow
            HStack(spacing: 10) {
                TextField(band.addressed.isEmpty ? "Ask the band…" : "Ask \(askedNames)…", text: $band.composing, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(Design.Typography.prose(15))
                    .foregroundStyle(Design.Palette.ink)
                    .focused($isComposing)
                    .disabled(band.isWorking)
                    .onSubmit { band.send() }

                if band.isWorking {
                    // Stop is the only control while a turn is in flight, and it is always safe:
                    // the song graph is append-only, so whatever landed is real and the rest is
                    // simply dropped.
                    // Escape from anywhere in the window: the field is disabled while the band works,
                    // so the column's own Escape handler had nothing focused to hear it.
                    ChipButton(systemImage: "stop.fill", help: "Stop this turn (⎋)") { band.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    ChipButton(systemImage: "arrow.right",
                               help: band.canSend ? "Send (⏎)" : "Type something to send",
                               isOn: band.canSend) {
                        band.send()
                    }
                    .disabled(!band.canSend)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(band.isWorking ? Design.Palette.accent : Design.Palette.lineStrong,
                            lineWidth: Design.Metric.hairline)
            )

            // Honest and quiet: what the session has spent, in the place you spend it, at the size
            // of a footnote. Before the first turn it says whether there is a key at all, which is
            // the only other thing you would want to know from here — and, with none, the way to
            // give it one. The sentence used to name an environment variable and the keychain, two
            // places a person does not reach from inside an app.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(band.footnote)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(band.keyStatus.hasKey ? Design.Palette.inkSecondary : Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("What this session has spent, and how much of each prompt came out of the cache.")
                Spacer(minLength: 0)
                if !band.isWorking {
                    // Which model the band runs on, where what it costs is read. It is most of the
                    // bill, so it is the user's to choose and one click to change.
                    Menu {
                        ForEach(DirectorModelChoice.offered, id: \.self) { model in
                            Toggle(DirectorModelChoice.line(for: model), isOn: Binding(
                                get: { band.model == model },
                                set: { if $0 { band.choose(model) } }))
                        }
                    } label: {
                        Text(band.model.label)
                            .font(Design.Typography.ui(11.5, weight: .medium))
                            .foregroundStyle(Design.Palette.accent)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("The model the band runs on. Changing it starts the band's conversation over; the song stays as it is.")
                    Button(band.keyStatus.hasKey ? "Key…" : "Set the key…") { isSettingKey = true }
                        .buttonStyle(.plain)
                        .font(Design.Typography.ui(11.5, weight: .medium))
                        .foregroundStyle(Design.Palette.accent)
                        .help(band.keyStatus.hasKey ? "Change or forget the band's API key" : "Give the band an Anthropic API key, kept in your keychain")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .onExitCommand { band.cancel() }
        .task { await band.refreshKeyStatus() }
        .onChange(of: band.wantsFocus, initial: true) { _, wants in
            guard wants else { return }
            band.wantsFocus = false
            isComposing = true
        }
        .sheet(isPresented: $isSettingKey) { APIKeySheet(band: band) }
    }
}

/// Where the band's key is typed: once, into the keychain, and never shown again.
struct APIKeySheet: View {
    let band: DirectorSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SmallLabel("The band's key")
            Text("An Anthropic API key. It is kept in your keychain under Mr. Roboto and sent only to api.anthropic.com; the app never shows it again. \(band.keyStatus.sentence)")
                .font(Design.Typography.prose(13.5))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.numeric(13))
                .onSubmit { Task { await keep() } }
            if let problem {
                Text(problem)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if case .present(.keychain) = band.keyStatus {
                    FrameButton(title: "Forget the key", emphasis: .quiet, isEnabled: !isWorking) { Task { await forget() } }
                }
                Spacer()
                FrameButton(title: "Cancel", emphasis: .quiet, isEnabled: !isWorking) { dismiss() }
                FrameButton(title: "Keep", emphasis: .accent, isEnabled: !isWorking && ClaudeCredentials.looksLikeKey(text.trimmingCharacters(in: .whitespacesAndNewlines))) {
                    Task { await keep() }
                }
            }
        }
        .padding(Design.Metric.inset)
        .frame(width: 440)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
    }

    private func keep() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await band.storeKey(text) { problem = failure; return }
        text = ""
        dismiss()
    }

    private func forget() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await band.forgetKey() { problem = failure; return }
        dismiss()
    }
}

extension LiveComposer {
    /// Who this message is for, folded to one chip until it is wanted.
    @ViewBuilder
    fileprivate var addressingRow: some View {
        if showsAddressing || !band.addressed.isEmpty {
            addressing
        } else {
            HStack(spacing: 5) {
                BoothChip("To: everyone in the room") { showsAddressing = true }
                Spacer()
            }
            .help("Ask only some of the band for this message. You can also type a name with @.")
        }
    }

    /// Who this message is for. All lit is everyone; press names to ask only them. Guards stay on:
    /// a member left out still speaks when one of their rules refuses a move.
    fileprivate var addressing: some View {
        let room = band.room
        return FlowRow(spacing: 5) {
            BoothChip("Everyone", isOn: band.addressed.isEmpty) { band.addressed = []; showsAddressing = false }
            ForEach(room, id: \.id) { member in
                BoothChip(member.name, isOn: band.addressed.contains(member.id)) { band.toggleAddressed(member.id) }
            }
            if !band.addressed.isEmpty {
                BoothChip(band.keepsAddressing ? "Kept" : "Keep", isOn: band.keepsAddressing) { band.keepsAddressing.toggle() }
            }
        }
        .help("Ask only some of the band for this message, or type a name with @. It goes back to everyone after you send, unless kept. Guards stay on: a member you left out still speaks if one of their rules refuses a move.")
    }

    fileprivate var askedNames: String {
        let names = band.room.filter { band.addressed.contains($0.id) }.map(\.name)
        return names.count <= 2 ? names.joined(separator: " and ") : "\(names.count) of the band"
    }
}

/// What a session with no band shows: the field, obviously not usable, and the reason.
struct InertComposer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Ask the band…")
                    .font(Design.Typography.prose(15))
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline)
            )

            Text("This session has no band attached, so the field cannot send. "
                 + "The question above is still worked out from the song, and its answers still work.")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .allowsHitTesting(false)
    }
}
