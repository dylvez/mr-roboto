import MusicTheory

/// One of the eight buttons a chord key is played with: four say what kind of chord it is, four
/// add a note on top.
///
/// The Orchid's idea, and a good one: a key is a root, and a hand held on a button or two says what
/// is built on it, so a progression is played one finger at a time and heard as it is played. With
/// nothing held a key plays its chord in the key; a button held changes that chord and no other.
public enum ChordButton: String, CaseIterable, Codable, Sendable, Identifiable {
    case diminished, minor, major, suspended
    case sixth, seventh, majorSeventh, ninth

    public var id: String { rawValue }

    /// What the button is labelled.
    public var name: String {
        switch self {
        case .diminished: return "dim"
        case .minor: return "min"
        case .major: return "maj"
        case .suspended: return "sus"
        case .sixth: return "6"
        case .seventh: return "7"
        case .majorSeventh: return "maj7"
        case .ninth: return "9"
        }
    }

    /// What holding it does, for its tooltip.
    public var about: String {
        switch self {
        case .diminished: return "a diminished chord: a minor third and a flat five"
        case .minor: return "a minor chord"
        case .major: return "a major chord"
        case .suspended: return "a suspended chord: the fourth in place of the third, or the second with 9"
        case .sixth: return "the sixth on top; on a diminished chord, the diminished seventh"
        case .seventh: return "the flat seventh on top: a 7 on a major chord, an m7 on a minor one"
        case .majorSeventh: return "the major seventh on top"
        case .ninth: return "the ninth on top: add9 alone, a 9 chord with a seventh, sus2 on a sus"
        }
    }

    /// Whether it says what kind of chord the key plays, rather than adding a note to it.
    public var isKind: Bool {
        switch self {
        case .diminished, .minor, .major, .suspended: return true
        case .sixth, .seventh, .majorSeventh, .ninth: return false
        }
    }

    /// The note it is, above C: the note a C chord gains with it. A controller holds the button on
    /// that note below the split — E♭ for minor, E for major, F for sus, G♭ for diminished, A for
    /// the sixth, B♭ for the seventh, B for the major seventh, D for the ninth — so the hand that
    /// holds them is spelling the chord it wants.
    public var semitones: Int {
        switch self {
        case .diminished: return 6
        case .minor: return 3
        case .major: return 4
        case .suspended: return 5
        case .sixth: return 9
        case .seventh: return 10
        case .majorSeventh: return 11
        case .ninth: return 2
        }
    }

    /// The four kinds, in the order one wins over another when two are held.
    public static let kinds: [ChordButton] = [.diminished, .suspended, .minor, .major]
    /// The four added notes, in the order they are kept when not all of them make a chord.
    public static let additions: [ChordButton] = [.seventh, .majorSeventh, .ninth, .sixth]
}

/// The chord a key plays: its root, what the buttons held build on it, and the key it is in.
public enum ChordKeys {

    /// Where a controller's keys stop being buttons and start being chords: middle C. The octave
    /// below holds the buttons, by the note each one is (`ChordButton.semitones`); from middle C up
    /// every key is a root.
    public static let split = 60

    /// A chord as a key played it, and the buttons that were held and could not be part of it — a
    /// major seventh on a diminished chord, a second kind held under the first.
    public struct Played: Hashable, Sendable {
        public var chord: Chord
        public var unused: [ChordButton]

        public init(chord: Chord, unused: [ChordButton] = []) {
            self.chord = chord
            self.unused = unused
        }
    }

    /// The turn of the voicing dial a controller's key gives below the split: the C there down a
    /// step, the C♯ up one. Two of the four notes no button sits on.
    public static func turn(forNote note: Int) -> Int? {
        guard note < split else { return nil }
        switch PitchClass(wrapping: note).rawValue {
        case 0: return -1
        case 1: return 1
        default: return nil
        }
    }

    /// The button a controller's key holds, when it is below the split and is one of the eight.
    public static func button(forNote note: Int) -> ChordButton? {
        guard note < split else { return nil }
        let pitchClass = PitchClass(wrapping: note).rawValue
        return ChordButton.allCases.first { $0.semitones % 12 == pitchClass }
    }

    /// The chord `root` plays in `key` with `buttons` held.
    ///
    /// A kind held is the kind; with none, a root in the key plays the key's own triad on it, and a
    /// root outside it plays whichever of a diminished, a major or a minor triad has the most of its
    /// notes in the key. In C that is a passing diminished on four of the black keys — C♯°, D♯°,
    /// F♯°, G♯°, the chords between the steps — and B♭, the flat seven; in C minor it is D♭, the
    /// Neapolitan, and the diminished chords under the four, the five and the tonic. Any other is
    /// a button away.
    ///
    /// The added notes go on what the kind makes. When they do not make a chord the app can name
    /// all together, the ones that matter least go first: the sixth, then the ninth, then a seventh.
    public static func chord(root: PitchClass, in key: Key, holding buttons: Set<ChordButton>) -> Played {
        let heldKinds = ChordButton.kinds.filter(buttons.contains)
        var unused = Array(heldKinds.dropFirst())
        var additions = ChordButton.additions.filter(buttons.contains)
        var triad = triad(on: root, in: key, kind: heldKinds.first)
        // A ninth on a sus with no seventh under it is the sus with its second: sus2.
        if heldKinds.first == .suspended, additions.contains(.ninth),
           !additions.contains(.seventh), !additions.contains(.majorSeventh) {
            triad = .suspendedSecond
            additions.removeAll { $0 == .ninth }
        }
        for size in stride(from: additions.count, through: 0, by: -1) {
            for kept in combinations(of: additions, size: size) {
                let intervals = triad.intervals + kept.map { $0 == .ninth ? 14 : $0.semitones }
                guard let quality = ChordQuality(intervals: intervals, among: named) else { continue }
                unused += additions.filter { !kept.contains($0) }
                return Played(chord: Chord(root: root, quality: quality), unused: unused)
            }
        }
        return Played(chord: Chord(root: root, quality: triad), unused: unused + additions)
    }

    /// The qualities a chord key can be named: all but the elevenths. No button adds an eleventh,
    /// so a sus with a seventh and a ninth is a 9sus4, and not the 11 that has the same notes.
    static let named = ChordQuality.allCases.filter { $0 != .dominantEleventh && $0 != .minorEleventh }

    /// The triad a kind builds, or the key's on a root with no kind held.
    static func triad(on root: PitchClass, in key: Key, kind: ChordButton?) -> ChordQuality {
        switch kind {
        case .diminished: return .diminished
        case .suspended: return .suspendedFourth
        case .minor: return .minor
        case .major: return .major
        default: break
        }
        let tonic = key.tonic.pitchClass
        if let degree = key.scale.degree(of: root, root: tonic),
           let own = key.scale.diatonicChord(degree: degree, root: tonic) {
            return own.quality
        }
        let scale = Set(key.pitchClasses)
        let candidates: [ChordQuality] = [.diminished, .major, .minor]
        func inKey(_ quality: ChordQuality) -> Int {
            Chord(root: root, quality: quality).pitchClasses.filter(scale.contains).count
        }
        // The first of the most: a tie goes to the passing diminished, then to the major.
        return candidates.reduce(candidates[0]) { inKey($1) > inKey($0) ? $1 : $0 }
    }

    /// Every way of keeping `size` of `items`, the ones that keep the earlier items first.
    static func combinations<T>(of items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [[]] }
        guard size <= items.count else { return [] }
        var out: [[T]] = []
        for (index, item) in items.enumerated() {
            for rest in combinations(of: Array(items[(index + 1)...]), size: size - 1) {
                out.append([item] + rest)
            }
        }
        return out
    }
}
