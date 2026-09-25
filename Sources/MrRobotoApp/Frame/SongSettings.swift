import MusicTheory
import SongGraph
import SwiftUI

/// The song's own settings — title, artist, tempo, key, meter — in a popover off the header's
/// title and off the transport's key and tempo, which is where you look for them.
///
/// Edits land as you make them, not on a button: the tempo readout and the key in the transport
/// follow the field, so what you typed and what the clock will run at cannot disagree. Bad input
/// is said in place, next to the field, and changes nothing.
struct SongSettingsPopover: View {
    let app: AppState
    @State private var title = ""
    @State private var artist = ""
    @State private var tempoText = ""
    @State private var keyText = ""
    @State private var meterText = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, artist, tempo, key, meter }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SmallLabel("Song")
            field("Title", text: $title, focus: .title, prompt: "What the song is called") { app.setTitle(title) }
            field("Artist", text: $artist, focus: .artist, prompt: "Who it is by") { app.setArtist(artist) }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    field("Tempo", text: $tempoText, focus: .tempo, prompt: "bpm", width: 90) { applyTempo() }
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
            Text("The tempo and the meter are the clock every part plays to; the key is what the writers and the band read the song in. Nothing already written moves. A change while the song plays lands on the next press of play.")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Metric.inset)
        .frame(width: 360)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
        .onAppear(perform: load)
        .onChange(of: app.song?.id) { load() }
    }

    private func load() {
        guard let song = app.song else { return }
        title = song.title
        artist = song.artist
        tempoText = Self.tempoText(song.tempo)
        keyText = song.key?.name ?? ""
        meterText = song.timeSignature.description
        focus = .title
    }

    /// "113", or "92.5" when the tempo is not a whole number. A readout that rounds would make
    /// the field disagree with the clock by half a beat a minute.
    static func tempoText(_ tempo: Double) -> String {
        tempo.rounded() == tempo ? String(Int(tempo)) : String(format: "%.1f", tempo)
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
                       width: CGFloat? = nil, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel(label, color: Design.Palette.inkTertiary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.ui(13, weight: .regular))
                .focused($focus, equals: which)
                .onSubmit(commit)
                .onChange(of: focus) { _, now in if now != which { commit() } }
                .frame(width: width)
        }
    }
}
