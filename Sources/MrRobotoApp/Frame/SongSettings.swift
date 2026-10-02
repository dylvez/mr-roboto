import MusicTheory
import SongGraph
import SwiftUI

/// The song's own settings — title, artist, brief, tempo, key, meter — in a popover off the header's
/// title and off the transport's key and tempo, which is where you look for them.
///
/// Edits land as you make them, not on a button: the tempo readout and the key in the transport
/// follow the field, so what you typed and what the clock will run at cannot disagree. Bad input
/// is said in place, next to the field, and changes nothing.
struct SongSettingsPopover: View {
    let app: AppState
    @State private var title = ""
    @State private var artist = ""
    @State private var brief = ""
    @State private var tempoText = ""
    @State private var keyText = ""
    @State private var meterText = ""
    @FocusState private var focus: Field?
    /// The settings as they were when the popover opened, for Put back.
    @State private var opened: Settings?
    @State private var taps = TapTempo()
    /// Applies the tapped tempo once the tapping stops, so the rail gets one line, not one a tap.
    @State private var tapSettles: Task<Void, Never>?

    private enum Field: Hashable { case title, artist, brief, tempo, key, meter }

    /// The settings, together, so a change to any of them can be put back as one.
    struct Settings: Equatable {
        var title: String
        var artist: String
        var brief: String
        var tempo: Double
        var key: Key?
        var meter: TimeSignature
        var fills: Bool
        var genre: String?

        init(_ song: Song) {
            title = song.title
            artist = song.artist
            brief = song.brief ?? ""
            tempo = song.tempo
            key = song.key
            meter = song.timeSignature
            fills = song.playsFills
            genre = song.genre
        }

        /// "92 bpm, D minor, 4/4": what Put back would return to, the parts that differ from now.
        func differences(from now: Settings) -> String {
            var parts: [String] = []
            if title != now.title { parts.append("“\(title)”") }
            if artist != now.artist { parts.append(artist.isEmpty ? "no artist" : artist) }
            if brief != now.brief { parts.append(brief.isEmpty ? "no brief" : "the brief as it was") }
            if tempo != now.tempo { parts.append("\(SongSettingsPopover.tempoText(tempo)) bpm") }
            if key != now.key { parts.append(key?.name ?? "no key") }
            if meter != now.meter { parts.append(meter.description) }
            if fills != now.fills { parts.append(fills ? "fills" : "no fills") }
            if genre != now.genre { parts.append(genre.flatMap { GenreBook.standard.profile(named: $0)?.name } ?? "genre guessed") }
            return parts.joined(separator: ", ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SmallLabel("Song")
            field("Title", text: $title, focus: .title, prompt: "What the song is called") { app.setTitle(title) }
            field("Artist", text: $artist, focus: .artist, prompt: "Who it is by") { app.setArtist(artist) }
            VStack(alignment: .leading, spacing: 4) {
                field("Brief", text: $brief, focus: .brief, prompt: "What the song is about, in a sentence", lines: 1...3) { applyBrief() }
                problem(briefProblem)
            }
            .help("The Producer holds every part to the brief, and says so until there is one")
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 6) {
                        field("Tempo", text: $tempoText, focus: .tempo, prompt: "bpm", width: 90) { applyTempo() }
                        FrameButton(title: "Tap", emphasis: .quiet) { tap() }
                            .help("Tap the beat, four times or more; the tempo is set when you stop")
                    }
                    problem(tempoProblem)
                }
                VStack(alignment: .leading, spacing: 4) {
                    field("Meter", text: $meterText, focus: .meter, prompt: "4/4", width: 70) { applyMeter() }
                    problem(meterProblem)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                field("Key", text: $keyText, focus: .key, prompt: "D major, F# minor, or blank") { applyKey() }
                problem(keyProblem)
            }
            GenrePicker(app: app)
            Toggle(isOn: Binding(get: { app.song?.playsFills ?? true }, set: { app.setFills($0) })) {
                Text("Fills into each section")
                    .font(Design.Typography.ui(12.5, weight: .regular))
            }
            .toggleStyle(.checkbox)
            .help("The drums play a fill in a section's last bar and a crash on the next one's first beat")
            Text("The tempo and the meter are the clock every part plays to; the key is what the writers and the band read the song in. Nothing already written moves. A change while the song plays lands on the next press of play.")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // The song's settings are not a part, so ⌘Z — which steps back the surface in front —
            // does not reach them. This does: everything changed since the popover opened, as one.
            if let opened, let song = app.song, Settings(song) != opened {
                HStack(spacing: 8) {
                    FrameButton(title: "Put back", emphasis: .quiet) { putBack(opened) }
                    Text(opened.differences(from: Settings(song)))
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help("The settings as they were when you opened this")
            }
        }
        .padding(Design.Metric.inset)
        .frame(width: 360)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
        .onAppear(perform: load)
        .onChange(of: app.song?.id) { opened = nil; load() }
    }

    private func load() {
        guard let song = app.song else { return }
        if opened == nil { opened = Settings(song) }
        title = song.title
        artist = song.artist
        brief = song.brief ?? ""
        tempoText = Self.tempoText(song.tempo)
        keyText = song.key?.name ?? ""
        meterText = song.timeSignature.description
        focus = .title
    }

    /// One tap: the field shows the tempo the taps make, and a moment after the last one it is the
    /// song's.
    private func tap() {
        guard let bpm = taps.tap(at: Date()) else { return }
        let clamped = min(AppState.tempoRange.upperBound, max(AppState.tempoRange.lowerBound, bpm))
        tempoText = Self.tempoText(clamped.rounded())
        tapSettles?.cancel()
        tapSettles = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TapTempo.forgetAfter))
            guard !Task.isCancelled else { return }
            applyTempo()
        }
    }

    /// Every setting back to what it was when the popover opened, each through its own setter so
    /// the rail says what moved.
    private func putBack(_ settings: Settings) {
        app.setTitle(settings.title)
        app.setArtist(settings.artist)
        app.setBrief(settings.brief)
        app.setTempo(settings.tempo)
        app.setKey(settings.key)
        app.setTimeSignature(settings.meter)
        app.setFills(settings.fills)
        app.setGenre(settings.genre)
        load()
    }

    /// "113", or "92.5" when the tempo is not a whole number. A readout that rounds would make
    /// the field disagree with the clock by half a beat a minute.
    static func tempoText(_ tempo: Double) -> String {
        tempo.rounded() == tempo ? String(Int(tempo)) : String(format: "%.1f", tempo)
    }

    private func applyBrief() {
        if app.setBrief(brief), let song = app.song { brief = song.brief ?? "" }
    }

    private func applyTempo() {
        guard let bpm = Double(tempoText.trimmingCharacters(in: .whitespaces)) else { return }
        if app.setTempo(bpm), let song = app.song { tempoText = Self.tempoText(song.tempo) }
    }

    private func applyKey() {
        if app.setKey(parsing: keyText), let song = app.song { keyText = song.key?.name ?? "" }
    }

    private func applyMeter() {
        guard let signature = AppState.timeSignature(parsing: meterText) else { return }
        if app.setTimeSignature(signature), let song = app.song { meterText = song.timeSignature.description }
    }

    // MARK: What is wrong with a field, said next to it

    /// The Producer's limits, said here before the Producer says them: the brief is kept either way.
    private var briefProblem: String? {
        let words = brief.split(whereSeparator: \.isWhitespace).count
        if words > 0, words < SetSongTool.briefWords.lowerBound { return "The Producer reads fewer than three words as no brief." }
        if words > SetSongTool.briefWords.upperBound { return "\(words) words. The Producer wants one sentence, forty words at most." }
        return nil
    }

    private var tempoProblem: String? {
        let text = tempoText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let bpm = Double(text) else { return "A number, in beats per minute." }
        guard AppState.tempoRange.contains(bpm) else {
            return "Between \(Int(AppState.tempoRange.lowerBound)) and \(Int(AppState.tempoRange.upperBound))."
        }
        return nil
    }

    private var keyProblem: String? {
        let text = keyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, Key(parsing: text) == nil else { return nil }
        return "Not a key I know. Try “D major”, “F# minor” or “Eb”."
    }

    private var meterProblem: String? {
        let text = meterText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, AppState.timeSignature(parsing: text) == nil else { return nil }
        return "Beats over a beat unit, like 4/4 or 7/8."
    }

    @ViewBuilder
    private func problem(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, focus which: Field, prompt: String,
                       width: CGFloat? = nil, lines: ClosedRange<Int> = 1...1, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel(label, color: Design.Palette.inkTertiary)
            TextField(prompt, text: text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
                .lineLimit(lines)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.ui(13, weight: .regular))
                .focused($focus, equals: which)
                .onSubmit(commit)
                .onChange(of: focus) { _, now in if now != which { commit() } }
                .frame(width: width)
        }
    }
}

/// Tap tempo: the beat as tapped, averaged over the last few taps. A pause longer than
/// `forgetAfter` starts a new count, so a stray tap from a minute ago does not drag the tempo.
struct TapTempo: Equatable {
    static let forgetAfter: Double = 2
    /// How many intervals are averaged: enough to steady a hand, few enough to follow a change.
    static let window = 4
    private(set) var times: [Date] = []

    /// Records a tap. The tempo the taps make, from the second tap on; nil for the first.
    mutating func tap(at time: Date) -> Double? {
        if let last = times.last, time.timeIntervalSince(last) > Self.forgetAfter { times = [] }
        times.append(time)
        if times.count > Self.window + 1 { times.removeFirst(times.count - Self.window - 1) }
        guard times.count >= 2, let first = times.first, let last = times.last else { return nil }
        let interval = last.timeIntervalSince(first) / Double(times.count - 1)
        return interval > 0 ? 60 / interval : nil
    }
}

/// The song's genre: the profiles by family, or left to be guessed from the grooves. Under it, what
/// the genre is in a sentence, and the tempo it runs at when the song is outside it.
struct GenrePicker: View {
    let app: AppState

    private var families: [(String, [GenreProfile])] {
        Dictionary(grouping: GenreBook.standard.profiles, by: \.family)
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        let reading = app.genre
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Genre")
            Menu {
                Button("Guess from the grooves") { app.setGenre(nil) }
                Button("None — the band's own numbers") { app.setGenre(GenreBook.none) }
                Divider()
                ForEach(families, id: \.0) { family, profiles in
                    Section(family.capitalized) {
                        ForEach(profiles) { profile in
                            Button(profile.name) { app.setGenre(profile.id) }
                        }
                    }
                }
            } label: {
                Text(reading?.description ?? (app.song?.genre == GenreBook.none ? "None — the band's own numbers" : "None yet — guessed from the grooves"))
                    .font(Design.Typography.ui(12.5, weight: .regular))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The band judges the song by its genre's numbers — loudness, hook time, swing, pocket — and says both its own and the genre's")
            if let profile = reading?.profile {
                Text(profile.summary)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                if let tempo = profile.tempo, let song = app.song, !profile.fits(tempo: song.tempo, meter: song.timeSignature) {
                    Text("\(profile.name) runs at \(tempo.span); this song is at \(SongSettingsPopover.tempoText(song.tempo)).")
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(Design.Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
