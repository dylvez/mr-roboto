import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// The lead sheet: a line of symbols in, bars with Roman numerals out, each bar playable.
struct ChordsSurfaceView: View {
    @Bindable var model: ChordsModel
    /// The controller, for Record. Nil where there is none to record — a render, a preview.
    var midi: MIDIControl? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            // The sheet scrolls inside the surface: with the pickers under it, the bars and the
            // Harmonist's reading were below the edge of a window at its minimum.
            MixScroll(.vertical) { sheet }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                model.statusBar
                if !model.isTouched, model.base == nil, model.isDefault {
                    Text("Not in the song until you type.")
                        .font(Design.Typography.ui(11.5))
                        .foregroundStyle(Design.Palette.inkTertiary)
                    FrameButton(title: "Add to song", emphasis: .accent) { model.useTheseChords() }
                        .help("Put the key's I–IV–V–I into the song as its chords. Typing does the same.")
                }
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }
}

extension ChordsSurfaceView {
    /// Everything but the status line: the title and key, the line, what voices it, how it is
    /// played, the bars and the reading of them.
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.title).font(Design.Typography.prose(16, weight: .medium))
                if let midi {
                    TakeButton(midi: midi, target: model,
                               help: "Record: each chord played is written as the next bar, named and spelled in the key. "
                                   + "Strike it on the chord keys below, from the computer's keys, or on a controller in "
                                   + "Chords; a controller in any other mode plays chords whole, written when your hand "
                                   + "comes off the keys, the lowest key its bass. Nothing needs to play. Press again to "
                                   + "stop; ⌘Z takes a chord back.",
                               line: model.isTaking ? model.takeLine : nil)
                }
                Spacer()
                SoundShelfMenu(model: model)
                KeyField(model: model)
            }
            ChordsControls(model: model)
            ChordPad(model: model, midi: midi)
            if let progression = model.progression {
                // How each chord is voiced, for the notes drawn beside it, and the span of all of
                // them, so a voice that climbs is seen to climb from one bar to the next.
                let voiced = Voicing.voicings(of: progression.spans, as: model.voicing)
                let notes = voiced.flatMap { $0 }
                let range = notes.min().flatMap { low in notes.max().map { low...$0 } }
                VStack(alignment: .leading, spacing: 6) {
                    // A typo leaves the last good parse on screen. Dimmed and labelled, so the
                    // bars are never mistaken for the line that is in the field now.
                    if model.barsAreStale {
                        Label("These bars are the last line that read, not what is typed. Fix the line above and they follow.",
                              systemImage: "exclamationmark.triangle")
                            .font(Design.Typography.ui(11.5, weight: .regular))
                            .foregroundStyle(Design.Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Eight bars are wider than a bench at its narrowest; they scroll, with the
                    // scroller showing so a row cut at the edge says there is more.
                    MixScroll(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(progression.bars.enumerated()), id: \.offset) { index, bar in
                                let first = progression.bars.prefix(index).reduce(0) { $0 + $1.chords.count }
                                BarCard(index: index, first: first, bar: bar, model: model,
                                        voiced: Array(voiced.dropFirst(first).prefix(bar.chords.count)), range: range)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .opacity(model.barsAreStale ? 0.4 : 1)
                    .accessibilityHint(model.barsAreStale ? "Stale: the last line that read" : "")
                    if !model.barsAreStale { ChordTurner(model: model) }
                }
                HarmonistReadings(model: model)
                    .opacity(model.barsAreStale ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The sheet's controls, above the bars: the line of chords, what voices it and how it is
/// played. Its own view so a layout test can measure what the bars sit under.
struct ChordsControls: View {
    @Bindable var model: ChordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Chords", color: Design.Palette.inkTertiary)
            Group {
                if Design.isOffscreenRender {
                    RenderedField(text: model.text, placeholder: "Dm7 G7 | Cmaj7 | Am7 | Fmaj7", font: Design.Typography.ui(14))
                } else {
                    TextField("Dm7 G7 | Cmaj7 | Am7 | Fmaj7", text: $model.text)
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.ui(14))
                }
            }
            .frame(maxWidth: 520)
            // The typo, if there is one, with its mark; the way the line reads otherwise. Once
            // something is typed that is the primer's line, said here only where primers are.
            if model.problem != nil || model.isDefault {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.problem != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Design.Palette.warn)
                    }
                    Text(model.problem ?? (model.isDefault
                            ? "Nothing typed: the key's I–IV–V–I, a bar each. Bars are separated by |, chords in a bar share it."
                            : "Bars are separated by |; chords in a bar share its beats. Click a bar to hear it."))
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(model.problem == nil ? Design.Palette.inkSecondary : Design.Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The genre's own progressions, in the sheet's key, a press away.
            let offered = model.genreProgressions
            if !offered.isEmpty {
                HStack(spacing: 6) {
                    SmallLabel(offered[0].genre, color: Design.Palette.inkTertiary)
                    ForEach(offered, id: \.roman) { entry in
                        FormChip(entry.roman, isOn: model.text == entry.text) { model.use(progression: entry.text) }
                            .help("\(entry.text) — \(entry.about)")
                    }
                }
                .padding(.top, 2)
            }
            // The same sheet said another way, a move a press away: what the Harmonist's
            // "nothing of its own" points at.
            let ways = model.anotherWays
            if !ways.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SmallLabel("Another way", color: Design.Palette.inkTertiary)
                    FlowRow(spacing: 4) {
                        ForEach(ways, id: \.move) { way in
                            FormChip(way.move.name, isOn: false) { model.use(way: way) }
                                .help("\(way.progression.symbols()) — \(way.says) ⌘Z puts it back.")
                                .accessibilityLabel("Another way: \(way.move.name)")
                        }
                    }
                }
                .padding(.top, 2)
            }
            // What voices them. Chords used to play on the bass sampler, an octave below where
            // they were written; now they go through whatever this names.
            InstrumentPicker(selected: model.instrument, choose: { model.setInstrument($0) }, label: "Voiced on")
                .padding(.top, 4)
            // How they are played: the two things a player decides that a lead sheet does not.
            PlayingPicker(model: model)
                .padding(.top, 4)
        }
    }
}

/// How the chords are played: the rhythm they are struck in and where their notes sit, each a row
/// of chips that wraps, with the line the top of the chords makes under them.
private struct PlayingPicker: View {
    let model: ChordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Played") {
                // One Arpeggio among the strikes, lit for any way of breaking the chord; the ways
                // are a row of their own under it while one is chosen.
                ForEach(KeysPattern.row) { pattern in
                    let isOn = pattern == .arpeggio ? model.pattern.isBroken : model.pattern == pattern
                    FormChip(pattern.name, isOn: isOn) { if !(pattern == .arpeggio && isOn) { model.setPattern(pattern) } }
                        .help(pattern.about.prefix(1).uppercased() + pattern.about.dropFirst())
                        .accessibilityLabel("Played \(pattern.name)")
                }
            }
            if model.pattern.isBroken {
                row("Broken") {
                    ForEach(KeysPattern.broken) { pattern in
                        FormChip(pattern.brokenName, isOn: model.pattern == pattern) { model.setPattern(pattern) }
                            .help(pattern.about.prefix(1).uppercased() + pattern.about.dropFirst())
                            .accessibilityLabel("Broken \(pattern.brokenName)")
                    }
                }
            }
            // Where the notes sit, and how a strike lets go of them: the hand's two decisions, on
            // one row while it fits, so the bars stay as high on the sheet as they were.
            row("Voiced") {
                ForEach(KeysVoicing.allCases) { voicing in
                    FormChip(voicing.name, isOn: model.voicing == voicing) { model.setVoicing(voicing) }
                        .help(voicing.about.prefix(1).uppercased() + voicing.about.dropFirst())
                        .accessibilityLabel("Voiced \(voicing.name)")
                }
                // A chip's height, the label centred in it: the row sets its items at their tops,
                // and a label alone sat above the chips' words.
                ZStack(alignment: .leading) {
                    FormChip("Struck", isOn: false) {}.hidden().frame(width: 0)
                    Text("Struck")
                        .font(Design.Typography.label)
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Struck")
                ForEach(KeysRoll.allCases) { roll in
                    FormChip(roll.name, isOn: model.roll == roll) { model.setRoll(roll) }
                        .help(roll.about.prefix(1).uppercased() + roll.about.dropFirst())
                        .accessibilityLabel("Struck \(roll.name)")
                }
                FormChip("Slop", isOn: model.isSloppy) { model.setSlop(!model.isSloppy) }
                    .help("Each strike a little off the grid, differently each time, as a loose hand plays: from a thirtieth of a beat early to a twentieth late")
                    .accessibilityLabel(model.isSloppy ? "Slop, on" : "Slop, off")
                    .padding(.leading, 6)
            }
            if !model.topLine.isEmpty, !model.barsAreStale {
                Text(String(format: "On top: %@. Voiced %@, the hand travels %.1f semitones a change.",
                            model.topLine, model.voicing.name.lowercased(), model.movement))
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution = model.patternCaution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Chips: View>(_ label: String, @ViewBuilder chips: () -> Chips) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Design.Typography.label)
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: 58, alignment: .leading)
            FlowRow(spacing: 4) { chips() }
        }
    }
}

/// The Harmonist on the surface: its reading of the bars, under them, as the Bassist's sits under
/// the Piano roll. What did not hold comes first, in the warning colour, because that is what it
/// would say first; what holds follows, quieter. Refreshed on every parse, so it answers the line
/// as it is typed rather than after it is kept.
private struct HarmonistReadings: View {
    let model: ChordsModel

    var body: some View {
        let hue = MemberHue.color(forPersona: "Harmonist")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emblem = Art.emblem(forPersona: "Harmonist") { MemberEmblem(name: emblem, hue: hue, width: 18) }
                SmallLabel("The Harmonist", color: hue ?? Design.Palette.inkTertiary)
            }
            ForEach(model.orderedReadings) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: reading.holds ? "checkmark" : "exclamationmark.triangle")
                        .font(Design.Typography.ui(9, weight: .bold))
                        .foregroundStyle(reading.holds ? Design.Palette.ok : Design.Palette.warn)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(reading.says)
                        .font(Design.Typography.prose(12.5))
                        .foregroundStyle(reading.holds ? Design.Palette.inkSecondary : Design.Palette.findingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(reading.holds ? reading.says : "Flag: \(reading.says)")
            }
        }
        .padding(.top, 4)
    }
}

/// The kept sounds, a press away: the one the chords are playing named on the chip; choosing one
/// puts its instrument, the way it is played and its strip on the chords; and the chords' own
/// sound saved under a name, for the next song.
private struct SoundShelfMenu: View {
    let model: ChordsModel
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let inUse = model.soundInUse
        let saved = Set(model.shelf.saved.map(\.name))
        let sounds = model.sounds
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SmallLabel("Sound", color: Design.Palette.inkTertiary)
            ChipMenu(inUse?.name ?? "Your own") {
                Section("Starters") {
                    ForEach(sounds.filter { !saved.contains($0.name) }) { sound in
                        MenuChoice(sound.name, isOn: inUse?.name == sound.name, help: sound.summary) { model.use(sound) }
                    }
                }
                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(sounds.filter { saved.contains($0.name) }) { sound in
                            MenuChoice(sound.name, isOn: inUse?.name == sound.name, help: sound.summary) { model.use(sound) }
                        }
                    }
                }
                Divider()
                Button("Save This Sound…") {
                    name = inUse?.name ?? model.suggestedSoundName
                    naming = true
                }
                if !saved.isEmpty {
                    Menu("Forget") {
                        ForEach(saved.sorted(), id: \.self) { kept in Button(kept) { model.forgetSound(named: kept) } }
                    }
                }
            }
            .help("A sound kept by name across songs: the instrument, the way the chords are played and what their strip does — "
                  + "the amp or rotating speaker, the chorus or phaser, the room and the echo. Choose one to put it on these chords; "
                  + "Save This Sound keeps theirs for the next song.")
            .popover(isPresented: $naming, arrowEdge: .bottom) { saving }
        }
    }

    /// Naming the chords' sound before it is kept, with what will be kept said under the name.
    private var saving: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep these chords' sound")
                .font(Design.Typography.ui(13, weight: .semibold))
            Text(model.currentSound(named: name).summary)
                .font(Design.Typography.ui(11.5))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if model.shelf.saved.contains(where: { $0.name == name.trimmingCharacters(in: .whitespaces) }) {
                Text("A sound is kept under this name: saving replaces it.")
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.warn)
            }
            HStack {
                Spacer()
                Button("Cancel") { naming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.saveSound(named: name)
        naming = false
    }
}

/// The key, as a line you type: "D major", "F# minor", "E dorian". Read on Return or when the
/// field loses focus, not on every keystroke — "F" alone is F major, and a field that re-spelled
/// itself to "F major" while you were still typing "F# minor" would be fighting you.
private struct KeyField: View {
    @Bindable var model: ChordsModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SmallLabel("Key", color: Design.Palette.inkTertiary)
            Group {
                if Design.isOffscreenRender {
                    RenderedField(text: text.isEmpty ? model.key.name : text, placeholder: "D major")
                } else {
                    TextField("D major", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.ui(12.5))
                }
            }
                .frame(width: 130)
                .focused($isFocused)
                .onSubmit { read() }
                .onChange(of: isFocused) { _, focused in if !focused { read() } }
                .help("The key the chords are read in: D major, F# minor, E dorian. Return applies it.")
                .accessibilityLabel("Key")
            if let problem = model.keyProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .lineLimit(1)
                    .accessibilityLabel("Key not read: \(problem)")
            }
        }
        .onAppear { text = model.key.name }
        // A key set from elsewhere — a bound progression's own — shows in the field too.
        .onChange(of: model.key) { _, key in text = key.name }
    }

    private func read() {
        // Nothing typed differently from the key that stands, and no problem to clear: leave it.
        guard text.trimmingCharacters(in: .whitespaces) != model.key.name || model.keyProblem != nil else { return }
        if model.setKey(parsing: text) { text = model.key.name }
    }
}

private struct BarCard: View {
    let index: Int
    /// The place on the line of the bar's first chord.
    let first: Int
    let bar: ProgressionBar
    let model: ChordsModel
    /// Each chord's notes as voiced.
    var voiced: [[Int]] = []
    var range: ClosedRange<Int>? = nil

    var body: some View {
        let hues = bar.chords.map { HarmonyHue.color(for: $0.chord, in: model.key) }
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index + 1)")
                .font(Design.Typography.numeric(10))
                .foregroundStyle(Design.Palette.inkTertiary)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(bar.chords.enumerated()), id: \.offset) { position, span in
                    // A click hears the chord as it is voiced and turned, and chooses it for the
                    // dial and the bass under the bars.
                    Button { model.select(chordAt: first + position) } label: {
                        ChordFace(span: span, model: model,
                                  voiced: position < voiced.count ? voiced[position] : [], range: range,
                                  isSelected: model.selected?.index == first + position)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 96, alignment: .leading)
        .modifier(BarCell(hues: hues.compactMap { $0 }))
    }
}

/// One chord of a bar: its symbol, its numeral and how long it lasts. The numeral is in the colour
/// of its step, a chord from outside the key says it is borrowed, and the notes it is voiced on
/// stand beside it on a small plate with the top one in the display's white — the line the Played
/// row's caption spells out, seen moving from bar to bar.
private struct ChordFace: View {
    let span: ChordSpan
    let model: ChordsModel
    let voiced: [Int]
    let range: ClosedRange<Int>?
    var isSelected = false

    var body: some View {
        let hue = HarmonyHue.color(for: span.chord, in: model.key, .ink)
        let tick = HarmonyHue.color(for: span.chord, in: model.key, .plate)
        let borrowed = hue != nil && HarmonyHue.reading(of: span.chord, in: model.key)?.inKey == false
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.symbol(of: span.chord))
                    .font(Design.Typography.ui(17, weight: .semibold))
                    .foregroundStyle(Design.Palette.ink)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.numeral(of: span.chord))
                        .font(Design.Typography.numeric(11, weight: hue == nil ? .regular : .semibold))
                        .foregroundStyle(hue ?? Design.Palette.emphasis)
                    if borrowed {
                        Text("borrowed")
                            .font(Design.Typography.ui(9.5, weight: .medium))
                            .foregroundStyle(hue ?? Design.Palette.inkSecondary)
                            .help("Not all of its notes are in \(model.key.name): borrowed from outside the key")
                    }
                }
                HStack(spacing: 5) {
                    Text(String(format: "%g beats", span.beats))
                        .font(Design.Typography.numeric(9.5))
                        .foregroundStyle(Design.Palette.inkTertiary)
                    // A chord the dial turned says how far, so a line of them reads as it plays.
                    if let lift = span.lift {
                        Text(lift > 0 ? "↑\(lift)" : "↓\(-lift)")
                            .font(Design.Typography.numeric(9.5, weight: .semibold))
                            .foregroundStyle(Design.Palette.accent)
                            .help("Turned \(lift > 0 ? "up" : "down") \(abs(lift)) from where it is voiced")
                    }
                }
            }
            if let tick, let range, !voiced.isEmpty {
                VoicedNotes(notes: voiced, range: range, hue: tick)
                    .help("Voiced \(model.voicing.name.lowercased()): " + voiced.map { model.key.name(of: Pitch(midi: $0)) }.joined(separator: " · "))
            }
        }
        .padding(4)
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? Design.Palette.accent : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
    }
}

/// The chosen chord, turned: the dial, up or down an inversion a step, and the note under it —
/// the root, or any of its own notes, written as the chord over it. A click on a chord's card
/// chooses it; with none chosen, the row says how.
private struct ChordTurner: View {
    let model: ChordsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SmallLabel("Turn", color: Design.Palette.inkTertiary)
            if let (index, span) = model.selected {
                let lift = span.lift ?? 0
                Text("\(model.symbol(of: span.chord)), chord \(index + 1)")
                    .font(Design.Typography.ui(12.5, weight: .semibold))
                    .foregroundStyle(Design.Palette.ink)
                HStack(spacing: 4) {
                    FormChip("Down", isOn: false) { model.turn(chordAt: index, by: -1) }
                        .help("Turn it down an inversion: its highest note an octave down")
                        .disabled(lift <= ChordKeyboard.lifts.lowerBound)
                    Text(lift == 0 ? "as voiced" : lift > 0 ? "up \(lift)" : "down \(-lift)")
                        .font(Design.Typography.numeric(11.5))
                        .foregroundStyle(lift == 0 ? Design.Palette.inkSecondary : Design.Palette.accent)
                        .frame(minWidth: 60)
                    FormChip("Up", isOn: false) { model.turn(chordAt: index, by: 1) }
                        .help("Turn it up an inversion: its lowest note an octave up")
                        .disabled(lift >= ChordKeyboard.lifts.upperBound)
                }
                SmallLabel("Bass", color: Design.Palette.inkTertiary)
                    .padding(.leading, 6)
                // Its notes as the key spells the chord, in the order it stacks them.
                let names = model.key.spell(span.chord)
                HStack(spacing: 4) {
                    ForEach(Array(span.chord.pitchClasses.enumerated()), id: \.offset) { place, note in
                        let name = place < names.count ? names[place].description : model.key.spell(note).description
                        FormChip(name, isOn: span.chord.inversion == place) { model.setBass(note, forChordAt: index) }
                            .help(place == 0 ? "The root under it" : "\(name) under it: written as the chord over it, and the bass plays it")
                    }
                }
            } else {
                Text("Click a chord to turn it up or down an inversion, or to put another of its notes under it.")
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }
}

/// A chord's notes as they are voiced, drawn as a keyboard turned on its side: one tick a note at
/// its height in the progression's whole span, on a plate, the top note in the display's white.
private struct VoicedNotes: View {
    let notes: [Int]
    let range: ClosedRange<Int>
    let hue: Color

    var body: some View {
        Canvas { context, size in
            let span = CGFloat(max(1, range.upperBound - range.lowerBound + 2))
            let step = size.height / span
            let top = notes.max()
            for note in notes {
                let y = size.height - CGFloat(note - range.lowerBound + 1) * step
                let rect = CGRect(x: 0, y: y - 1.5, width: size.width, height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(note == top ? Design.Palette.lcdInk : hue))
            }
        }
        .frame(width: 12, height: 50)
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(Design.Palette.plate, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A bar's cell: a soft fill with no edge, a cell among cells, washed in the hues of its chords,
/// deepest at the top under a cap of the hue itself. The wash lies over the palette's tint ground,
/// so a numeral in its chord's colour reads on it on charcoal as on black and on white.
private struct BarCell: ViewModifier {
    var hues: [Color] = []

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous)
        if hues.isEmpty {
            content.background(Design.Palette.fill, in: shape)
        } else {
            content
                .background {
                    ZStack(alignment: .top) {
                        shape.fill(Design.Palette.tintGround)
                        LinearGradient(colors: hues.map { $0.opacity(0.34) }, startPoint: .leading, endPoint: .trailing)
                            .mask(LinearGradient(colors: [.black, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                        LinearGradient(colors: hues.count == 1 ? [hues[0], hues[0]] : hues,
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 3)
                    }
                    .clipShape(shape)
                }
        }
    }
}
