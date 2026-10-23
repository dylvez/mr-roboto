import MusicTheory
import Performance
import SwiftUI

/// The chord keys on the sheet: a display of the chord struck last, the eight buttons, and an
/// octave of keys, each showing the chord it plays now in the hue of its step.
///
/// Played with the pointer — a button clicked stays held until it is clicked again, since the
/// pointer is wanted for the key — or, once the pad is clicked, from the computer's keys, laid out
/// as the Orchid lays out its own: the buttons under the left hand, Q W E R the kinds over A S D F
/// the added notes, and an octave under the right, G to ' the white keys and Y U O P [ the black.
/// A controller in Chords lights the same buttons and keys. With Record on, every chord struck is
/// written as the next bar.
struct ChordPad: View {
    let model: ChordsModel
    /// The controller, whose chord keys the pad shares. Nil in a render: the pad auditions.
    var midi: MIDIControl? = nil

    @FocusState private var hasKeys: Bool
    /// Keys the pointer is holding down, and the computer's.
    @State private var pointerDown: Set<Int> = []
    @State private var keysDown: Set<Int> = []

    private var keyboard: ChordKeyboard { midi?.chordKeys ?? Self.idle }
    /// The pad's own hands where there is no controller.
    @MainActor private static let idle = ChordKeyboard()

    /// Who holds a key: the pointer's start at 1000, the computer's at 2000, clear of a
    /// controller's notes.
    private static let pointer = 1000
    private static let computer = 2000

    static let dialKeys: [Character: Int] = ["z": -1, "x": 1]
    static let buttonKeys: [Character: ChordButton] = [
        "q": .diminished, "w": .minor, "e": .major, "r": .suspended,
        "a": .sixth, "s": .seventh, "d": .majorSeventh, "f": .ninth,
    ]
    static let rootKeys: [Character: Int] = [
        "g": 0, "y": 1, "h": 2, "u": 3, "j": 4, "k": 5, "o": 6, "l": 7, "p": 8, ";": 9, "[": 10, "'": 11,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SmallLabel("Chord keys", color: Design.Palette.inkTertiary)
                Text(hasKeys
                     ? "Keys live: Q W E R and A S D F hold the buttons, G to ' play C to B, Y U O P [ the black keys, Z and X turn the dial."
                     : "Hold a button and play a key. Click the pad to play it from the computer's keys.")
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(hasKeys ? Design.Palette.inkSecondary : Design.Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { display; buttons; dial; keys }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) { display; buttons; dial }
                    keys
                }
            }
        }
        .padding(10)
        .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous)
                .strokeBorder(hasKeys ? Design.Palette.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .focusable()
        .focused($hasKeys)
        .focusEffectDisabled()
        .onKeyPress(phases: .all) { press in typed(press) }
        .onChange(of: hasKeys) { _, live in if !live { letGoOfKeys() } }
        .help("One key a chord. With nothing held a key plays its chord in \(model.key.name); a button held changes it: "
              + "dim, min, maj and sus say what kind of chord it is, 6, 7, maj7 and 9 add a note. A controller in Chords "
              + "plays a chord on every key from middle C up and holds the buttons on the octave below, each on the note "
              + "it adds to a C chord: E♭ min, E maj, F sus, G♭ dim, A 6, B♭ 7, B maj7, D 9 — and the C and C♯ there turn "
              + "the dial. The dial turns every chord struck up or down an inversion a step. With Record on, each chord "
              + "struck is written as the next bar, turned as it was played.")
    }

    // MARK: The dial

    /// The voicing dial: up and down an inversion a step, for every chord struck from here on,
    /// and the turn it stands at.
    private var dial: some View {
        let lift = keyboard.lift
        return VStack(spacing: 2) {
            DialStep(symbol: "chevron.up", letter: "X", enabled: lift < ChordKeyboard.lifts.upperBound) { turnDial(1) }
                .help("Turn the dial up: every chord struck an inversion higher. X on the computer's keys, C♯ below middle C.")
            Text(lift == 0 ? "0" : String(format: "%+d", lift))
                .font(Design.Typography.numeric(13, weight: .semibold))
                .foregroundStyle(lift == 0 ? Design.Palette.inkSecondary : Design.Palette.accent)
                .frame(height: 16)
                .onTapGesture(count: 2) { turnDial(-lift) }
                .help("The dial's turn. Double-click to set it back to where the voicing puts each chord.")
            DialStep(symbol: "chevron.down", letter: "Z", enabled: lift > ChordKeyboard.lifts.lowerBound) { turnDial(-1) }
                .help("Turn the dial down: every chord struck an inversion lower. Z on the computer's keys, C below middle C.")
        }
        .frame(width: 46, height: 88)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voicing dial, turned \(lift)")
    }

    private func turnDial(_ steps: Int) {
        hasKeys = true
        keyboard.turn(steps)
    }

    // MARK: The display

    /// The chord struck last, as a display shows it: the symbol large, its numeral under it, and
    /// a button held that it could not take.
    private var display: some View {
        let struck = keyboard.last
        return VStack(alignment: .leading, spacing: 3) {
            Text(struck.map { $0.played.chord.symbol(in: $0.key) } ?? "—")
                .font(Design.Typography.ui(22, weight: .semibold))
                .foregroundStyle(Design.Palette.lcdInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(struck.map { numeral(of: $0) } ?? "no chord yet")
                .font(Design.Typography.numeric(11))
                .foregroundStyle(Design.Palette.lcdLabel)
                .lineLimit(1)
            if let unused = struck?.played.unused, !unused.isEmpty {
                Text("no \(unused.map(\.name).joined(separator: ", ")) on it")
                    .font(Design.Typography.ui(9.5))
                    .foregroundStyle(Design.Palette.lcdLabel)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 104, height: 88, alignment: .topLeading)
        .background(Design.Palette.plate, in: RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(struck.map { "Last chord: \($0.played.chord.symbol(in: $0.key))" } ?? "No chord yet")
    }

    private func numeral(of struck: ChordKeyboard.Struck) -> String {
        struck.key.romanNumeral(for: struck.played.chord).map { "\($0) in \(struck.key.name)" } ?? struck.key.name
    }

    // MARK: The buttons

    /// The eight, as the Orchid sets them: the kinds over the added notes.
    private var buttons: some View {
        let held = keyboard.held
        let letters = Dictionary(uniqueKeysWithValues: Self.buttonKeys.map { ($1, $0) })
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach([ChordButton.kinds.sorted(by: Self.order), ChordButton.additions.sorted(by: Self.order)], id: \.self) { row in
                GridRow {
                    ForEach(row) { button in
                        ChordButtonFace(button: button, isHeld: held.contains(button),
                                        letter: letters[button].map { String($0).uppercased() } ?? "")
                            .onTapGesture {
                                hasKeys = true
                                keyboard.toggle(button)
                            }
                            .help(button.about.prefix(1).uppercased() + button.about.dropFirst()
                                  + ". Click to hold it until it is clicked again.")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("\(button.name) button\(held.contains(button) ? ", held" : "")")
                    }
                }
            }
        }
    }

    /// Left to right as they sit on the Orchid: dim, min, maj, sus over 6, 7, maj7, 9.
    private static func order(_ a: ChordButton, _ b: ChordButton) -> Bool {
        let all = ChordButton.allCases
        return all.firstIndex(of: a)! < all.firstIndex(of: b)!
    }

    // MARK: The keys

    private static let whiteWidth: CGFloat = 50
    private static let whiteHeight: CGFloat = 88
    private static let blackWidth: CGFloat = 40
    private static let blackHeight: CGFloat = 50
    private static let gap: CGFloat = 3
    /// The white keys, and the black ones with the white key each stands after.
    private static let whites = [0, 2, 4, 5, 7, 9, 11]
    private static let blacks: [(pitchClass: Int, after: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]

    private var keys: some View {
        let context = model.chordContext
        let down = Set(keyboard.down.values.map(\.rawValue))
        let letters = Dictionary(uniqueKeysWithValues: Self.rootKeys.map { ($1, String($0).uppercased()) })
        let width = CGFloat(Self.whites.count) * (Self.whiteWidth + Self.gap) - Self.gap
        return ZStack(alignment: .topLeading) {
            ForEach(Array(Self.whites.enumerated()), id: \.element) { index, pitchClass in
                key(pitchClass, isBlack: false, context: context, isDown: down.contains(pitchClass), letter: letters[pitchClass] ?? "")
                    .offset(x: CGFloat(index) * (Self.whiteWidth + Self.gap))
            }
            ForEach(Self.blacks, id: \.pitchClass) { black in
                key(black.pitchClass, isBlack: true, context: context, isDown: down.contains(black.pitchClass),
                    letter: letters[black.pitchClass] ?? "")
                    .offset(x: CGFloat(black.after + 1) * (Self.whiteWidth + Self.gap) - Self.gap / 2 - Self.blackWidth / 2)
            }
        }
        .frame(width: width, height: Self.whiteHeight, alignment: .topLeading)
    }

    private func key(_ pitchClass: Int, isBlack: Bool, context: ChordContext, isDown: Bool, letter: String) -> some View {
        let root = PitchClass(wrapping: pitchClass)
        let chord = keyboard.chord(for: root, in: context).chord
        let id = Self.pointer + pitchClass
        return ChordKeyFace(symbol: chord.symbol(in: context.key),
                            hue: HarmonyHue.color(for: chord, in: context.key, isBlack ? .plate : .fill),
                            ink: HarmonyHue.color(for: chord, in: context.key, .ink),
                            isBlack: isBlack, isDown: isDown, letter: letter)
            .frame(width: isBlack ? Self.blackWidth : Self.whiteWidth, height: isBlack ? Self.blackHeight : Self.whiteHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pointerDown.contains(id) else { return }
                        pointerDown.insert(id)
                        hasKeys = true
                        strike(root, id: id, source: "the chord pad")
                    }
                    .onEnded { _ in
                        pointerDown.remove(id)
                        lift(id)
                    }
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Play \(chord.symbol(in: context.key))")
            .accessibilityAction { strike(root, id: id, source: "the chord pad"); lift(id) }
    }

    // MARK: Playing

    private func strike(_ root: PitchClass, id: Int, source: String) {
        if let midi {
            midi.chordDown(root, key: id, source: source, sheet: model)
        } else {
            model.audition(keyboard.chord(for: root, in: model.chordContext).chord)
        }
    }

    private func lift(_ id: Int) { midi?.chordUp(key: id) }

    /// A key on the computer's keyboard, while the pad has it: a button held, or a chord.
    /// Anything with ⌘, ⌃ or ⌥ is left to the menus, so ⌘Z still takes a chord back.
    private func typed(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        guard let character = press.key.character.lowercased().first else { return .ignored }
        if let button = Self.buttonKeys[character] {
            if press.phase != .repeat { keyboard.key(button, isDown: press.phase == .down) }
            return .handled
        }
        if let steps = Self.dialKeys[character] {
            if press.phase != .up { keyboard.turn(steps) }
            return .handled
        }
        guard let pitchClass = Self.rootKeys[character] else { return .ignored }
        let id = Self.computer + pitchClass
        switch press.phase {
        case .down where !keysDown.contains(id):
            keysDown.insert(id)
            strike(PitchClass(wrapping: pitchClass), id: id, source: "the computer's keys")
        case .up:
            keysDown.remove(id)
            lift(id)
        default:
            break
        }
        return .handled
    }

    /// The pad lost the keyboard: every key it held is let go, since the key coming up will be
    /// heard by whatever has the keyboard now.
    private func letGoOfKeys() {
        keyboard.letGoOfKeys()
        for id in keysDown { lift(id) }
        keysDown = []
    }
}

/// A step of the dial: its arrow, and the computer key that turns it.
private struct DialStep: View {
    let symbol: String
    let letter: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(letter)
                    .font(Design.Typography.numeric(9))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            .foregroundStyle(enabled ? Design.Palette.ink : Design.Palette.inkTertiary)
            .frame(width: 46, height: 32)
            .background(Design.Palette.panel, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Design.Palette.line, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// One of the eight: its name, the computer key that holds it, lit while it is held.
private struct ChordButtonFace: View {
    let button: ChordButton
    let isHeld: Bool
    let letter: String

    var body: some View {
        VStack(spacing: 1) {
            Text(button.name)
                .font(Design.Typography.ui(12.5, weight: .semibold))
                .foregroundStyle(isHeld ? Design.Palette.accent : Design.Palette.ink)
            Text(letter)
                .font(Design.Typography.numeric(9))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
        .frame(width: 46, height: 40)
        .background(isHeld ? Design.Palette.accentSoft : Design.Palette.panel,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isHeld ? Design.Palette.accent.opacity(0.5) : Design.Palette.line, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

/// A key: the chord it plays now, in its step's hue, and the computer key that plays it.
private struct ChordKeyFace: View {
    let symbol: String
    let hue: Color?
    let ink: Color?
    let isBlack: Bool
    let isDown: Bool
    let letter: String

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4, style: .continuous)
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            Text(symbol)
                .font(Design.Typography.ui(isBlack ? 10.5 : 11.5, weight: .semibold))
                .foregroundStyle(isBlack ? (hue ?? Design.Palette.lcdInk) : (ink ?? Design.Palette.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(letter)
                .font(Design.Typography.numeric(9))
                .foregroundStyle(isBlack ? Design.Palette.lcdLabel : Design.Palette.inkTertiary)
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack(alignment: .top) {
                shape.fill(isBlack ? Design.Palette.plate : Design.Palette.panel)
                if let hue {
                    shape.fill(hue.opacity(isDown ? (isBlack ? 0.55 : 0.6) : (isBlack ? 0.12 : 0.2)))
                    Rectangle().fill(hue).frame(height: 3)
                }
            }
            .clipShape(shape)
        }
        .overlay { shape.strokeBorder(isDown ? (ink ?? Design.Palette.accent) : Design.Palette.line, lineWidth: isDown ? 1.5 : 1) }
    }
}
