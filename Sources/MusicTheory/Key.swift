/// A key signature: a signed count on the circle of fifths (+ sharps, − flats) and which notes are altered.
public struct KeySignature: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Positive for sharp keys (G major = 1), negative for flat keys (F major = −1), 0 for C major.
    public let fifths: Int

    public init(fifths: Int) { self.fifths = fifths }

    /// The signature of the major key with this tonic (F♯ → 6, G♭ → −6).
    public init(majorTonic: NoteName) { fifths = majorTonic.fifths }

    public var sharpCount: Int { max(0, fifths) }
    public var flatCount: Int { max(0, -fifths) }
    public var isSharpKey: Bool { fifths > 0 }
    public var isFlatKey: Bool { fifths < 0 }

    private static let sharpOrder: [Letter] = [.f, .c, .g, .d, .a, .e, .b]
    private static let flatOrder: [Letter] = [.b, .e, .a, .d, .g, .c, .f]

    /// The altered notes in signature order (F♯ C♯ G♯ … or B♭ E♭ A♭ …).
    public var accidentals: [NoteName] {
        let order = isFlatKey ? KeySignature.flatOrder : KeySignature.sharpOrder
        let sign = isFlatKey ? -1 : 1
        return (0..<abs(fifths)).map { i in
            NoteName(order[i % 7], Accidental(rawValue: sign * (1 + i / 7)) ?? (isFlatKey ? .doubleFlat : .doubleSharp))
        }
    }

    /// The accidental this signature applies to a letter.
    public func accidental(for letter: Letter) -> Accidental {
        let count = accidentals.filter { $0.letter == letter }.count
        return Accidental(rawValue: isFlatKey ? -count : count) ?? (isFlatKey ? .doubleFlat : .doubleSharp)
    }

    /// Sharps for sharp keys and C, flats for flat keys.
    public var preference: SpellingPreference { isFlatKey ? .flats : .sharps }

    /// Tonic of the major key with this signature.
    public var majorTonic: NoteName { NoteName(fifths: fifths) }

    /// Tonic of the minor key with this signature.
    public var minorTonic: NoteName { NoteName(fifths: fifths + 3) }

    public var description: String {
        if fifths == 0 { return "no sharps or flats" }
        let list = accidentals.map(\.description).joined(separator: ", ")
        let kind = isFlatKey ? "flat" : "sharp"
        return "\(abs(fifths)) \(kind)\(abs(fifths) == 1 ? "" : "s") (\(list))"
    }
}

extension NoteName {
    /// Position on the circle of fifths: F = −1, C = 0, G = 1 …, shifted 7 per accidental (F♯ = 6, B♭ = −2).
    public var fifths: Int {
        NoteName.fifthsOrder.firstIndex(of: letter)! - 1 + 7 * accidental.rawValue
    }

    /// The note name at a circle-of-fifths position (6 → F♯, −5 → D♭).
    public init(fifths: Int) {
        let index = fifths + 1
        let letter = NoteName.fifthsOrder[((index % 7) + 7) % 7]
        let accidental = Accidental(rawValue: floorDivide(index, 7)) ?? (index < 0 ? .doubleFlat : .doubleSharp)
        self.init(letter, accidental)
    }

    private static let fifthsOrder: [Letter] = [.f, .c, .g, .d, .a, .e, .b]
}

/// Which scale Roman-numeral accidentals are measured against: the key's own mode, or its parallel major (♭III, ♭VII in minor).
public enum NumeralReference: String, Codable, Sendable, Hashable {
    case ownScale, parallelMajor
}

/// A seven-note scale the church modes do not have, as the music that uses it writes it: one of
/// them with a degree or two raised. Harmonic minor is the minor with its seventh raised, so a
/// song in it has the minor's signature and a leading tone; Phrygian dominant — the freygish of
/// klezmer, the hijaz of Arabic music, flamenco's mode — is the Phrygian with its third raised.
public enum ScaleColour: String, Codable, CaseIterable, Sendable, Hashable {
    case harmonicMinor = "harmonic minor"
    case melodicMinor = "melodic minor"
    case phrygianDominant = "phrygian dominant"
    case doubleHarmonic = "double harmonic"
    case hungarianMinor = "hungarian minor"
    case ukrainianDorian = "ukrainian dorian"

    /// The church mode it alters, whose signature it is written in.
    public var mode: Mode {
        switch self {
        case .harmonicMinor, .melodicMinor, .hungarianMinor: return .aeolian
        case .phrygianDominant, .doubleHarmonic: return .phrygian
        case .ukrainianDorian: return .dorian
        }
    }

    /// The degrees raised a semitone, counted from 0 at the tonic.
    public var raised: [Int] {
        switch self {
        case .harmonicMinor: return [6]
        case .melodicMinor: return [5, 6]
        case .phrygianDominant: return [2]
        case .doubleHarmonic: return [2, 6]
        case .hungarianMinor: return [3, 6]
        case .ukrainianDorian: return [3]
        }
    }

    /// Semitones above the tonic, the mode's with the raised degrees moved up.
    public var intervals: [Int] {
        var steps = mode.intervals
        for degree in raised { steps[degree] += 1 }
        return steps
    }

    /// "Harmonic minor".
    public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// What else it is called, where it is heard.
    public var aliases: [String] {
        switch self {
        case .harmonicMinor: return ["harmonic"]
        case .melodicMinor: return ["melodic", "jazz minor"]
        case .phrygianDominant: return ["freygish", "hijaz", "ahava rabbah", "spanish phrygian", "flamenco"]
        case .doubleHarmonic: return ["hijaz kar", "byzantine", "double harmonic major"]
        case .hungarianMinor: return ["gypsy minor", "hungarian"]
        case .ukrainianDorian: return ["misheberakh", "mi sheberakh", "altered dorian", "romanian minor"]
        }
    }

    /// The colour a name or an alias says, however it is cased.
    public init?(named text: String) {
        let wanted = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard let found = Self.allCases.first(where: { $0.rawValue == wanted || $0.aliases.contains(wanted) }) else { return nil }
        self = found
    }
}

/// A key: a spelled tonic plus a mode, giving a key signature, spelled scale, related keys and Roman-numeral analysis.
public struct Key: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The spelled tonic; F♯ major and G♭ major are different keys.
    public var tonic: NoteName
    public var mode: Mode
    /// A scale the mode has a degree raised in: harmonic minor, Phrygian dominant. Nil is the mode
    /// as it is, which every key was before. Omitted from a document when nil.
    public var colour: ScaleColour?

    public init(tonic: NoteName, mode: Mode = .ionian) {
        self.tonic = tonic
        self.mode = mode
        self.colour = nil
    }

    /// A key in one of the coloured scales, on the mode it alters.
    public init(tonic: NoteName, colour: ScaleColour) {
        self.tonic = tonic
        self.mode = colour.mode
        self.colour = colour
    }

    /// A key on one of the 17 Music Understanding tonics.
    public init(tonic: Tonic, mode: Mode = .ionian) {
        self.init(tonic: tonic.noteName, mode: mode)
    }

    /// A key on a pitch class, spelled conventionally (D♭ over C♯, F♯ over G♭; modal tonics follow their relative major).
    public init(tonicPitchClass: PitchClass, mode: Mode = .ionian) {
        let majorTonicClass = tonicPitchClass.transposed(by: -Scale.major.intervals[mode.rawValue - 1])
        let majorTonic = majorTonicClass.spelling(preferring: majorTonicClass == .fSharp ? .sharps : .flats)
        let major = Key(tonic: majorTonic, mode: .ionian)
        self.init(tonic: major.spelledScale[mode.rawValue - 1], mode: mode)
    }

    /// The same key moved by `semitones`, in the same mode and with the same colour: A harmonic
    /// minor up a tone is B harmonic minor.
    public func transposed(by semitones: Int) -> Key {
        var moved = Key(tonicPitchClass: tonic.pitchClass.transposed(by: semitones), mode: mode)
        moved.colour = colour
        return moved
    }

    /// Parses "C", "F# minor", "Eb major", "D dorian".
    public init?(parsing text: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, let tonic = NoteName(first) else { return nil }
        let modeText = parts.count > 1 ? parts[1].lowercased() : "major"
        if let colour = ScaleColour(named: modeText) {
            self.init(tonic: tonic, colour: colour)
            return
        }
        let mode: Mode?
        switch modeText {
        case "major", "maj", "": mode = .ionian
        case "minor", "min", "m": mode = .aeolian
        default: mode = Mode.allCases.first { $0.name.lowercased() == modeText }
        }
        guard let resolved = mode else { return nil }
        self.init(tonic: tonic, mode: resolved)
    }

    public static let cMajor = Key(tonic: NoteName(.c))
    public static let aMinor = Key(tonic: NoteName(.a), mode: .aeolian)

    /// The scale of this key's mode, or of its colour.
    public var scale: Scale {
        guard let colour else { return mode.scale }
        return Scale(name: colour.name, intervals: colour.intervals)
    }
    public var isMajor: Bool { mode == .ionian && colour == nil }
    public var isMinor: Bool { mode == .aeolian }

    /// The seven pitch classes, tonic first.
    public var pitchClasses: [PitchClass] { scale.pitchClasses(root: tonic.pitchClass) }

    /// The seven degrees spelled on consecutive letters from the tonic (D major: D E F♯ G A B C♯).
    public var spelledScale: [NoteName] {
        pitchClasses.enumerated().map { index, pitchClass in
            NoteName.spelling(of: pitchClass, letter: tonic.letter.advanced(by: index))
                ?? pitchClass.spelling(preferring: spellingPreference)
        }
    }

    /// The key signature (shared with the relative major).
    public var signature: KeySignature { KeySignature(fifths: tonic.fifths - mode.fifthsOffset) }

    /// Sharps for sharp keys and C, flats for flat keys.
    public var spellingPreference: SpellingPreference { signature.preference }

    /// The major key with the same pitch collection.
    public var relativeMajor: Key { Key(tonic: signature.majorTonic, mode: .ionian) }

    /// The natural-minor key with the same pitch collection.
    public var relativeMinor: Key { relative(.aeolian) }

    /// The key in `mode` sharing this key's pitch collection.
    public func relative(_ mode: Mode) -> Key {
        Key(tonic: relativeMajor.spelledScale[mode.rawValue - 1], mode: mode)
    }

    /// The major key on the same tonic.
    public var parallelMajor: Key { parallel(.ionian) }

    /// The minor key on the same tonic.
    public var parallelMinor: Key { parallel(.aeolian) }

    /// The key in `mode` on the same tonic.
    public func parallel(_ mode: Mode) -> Key { Key(tonic: tonic, mode: mode) }

    /// Spells a pitch class in this key: diatonic notes by the scale, naturals as naturals, the rest by key preference.
    public func spell(_ pitchClass: PitchClass) -> NoteName {
        if let index = pitchClasses.firstIndex(of: pitchClass) { return spelledScale[index] }
        if let letter = pitchClass.naturalLetter { return NoteName(letter) }
        return pitchClass.spelling(preferring: spellingPreference)
    }

    /// Name with octave for a pitch, spelled in this key ("Bb3" in F major).
    public func name(of pitch: Pitch) -> String {
        pitch.name(spelledAs: spell(pitch.pitchClass))
    }

    /// Spells a chord's tones in this key, each on the letter its step above the root names.
    ///
    /// A root on a step of the key is that step as the key writes it: the sixth of E♭ minor is C♭
    /// E♭ G♭ B♭, never B D♯ F♯ A♯. A root off the key is a step of it raised or lowered once, never
    /// a double sharp or flat itself, and of the two the one whose chord needs no double accidental
    /// and the fewest accidentals against the signature — a natural root, then the step a chord of
    /// its kind usually stands on, then the key's preference breaking a tie: ♭VII in C is B♭ D F,
    /// ♭II7 D♭ F A♭ C♭, ♯iv°7 F♯ A C E♭, the Neapolitan of E♭ minor F♭ A♭ C♭, and its leading
    /// tone's seventh D F♯ A C. Against the signature alone, a double flat on a flatted
    /// letter cost no more than a natural, and that D7 was spelled E𝄫 G♭ B𝄫 D𝄫.
    public func spell(_ chord: Chord) -> [NoteName] {
        let signature = self.signature
        func cost(_ names: [NoteName]) -> Int {
            names.reduce(0) { $0 + abs($1.accidental.rawValue - signature.accidental(for: $1.letter).rawValue) }
        }
        func weight(_ names: [NoteName]) -> Int {
            names.reduce(0) { $0 + abs($1.accidental.rawValue) }
        }
        let steps = chord.quality.letterSteps
        func tones(on rootName: NoteName) -> [NoteName]? {
            let names = zip(chord.intervals, steps).compactMap { interval, step in
                NoteName.spelling(of: chord.root.transposed(by: interval), letter: rootName.letter.advanced(by: step))
            }
            return names.count == chord.intervals.count ? names : nil
        }
        if let index = pitchClasses.firstIndex(of: chord.root), let names = tones(on: spelledScale[index]) {
            return names
        }
        var candidates = chord.root.enharmonicSpellings.compactMap(tones(on:))
        // A root off the key is a step of it raised or lowered once, and is never itself a double
        // sharp or flat; over it, a spelling with no double accidental while there is one.
        let beside = candidates.filter { names in
            let root = names[0].accidental.rawValue
            return abs(root) < 2 && abs(root - signature.accidental(for: names[0].letter).rawValue) < 2
        }
        if !beside.isEmpty { candidates = beside }
        let plain = candidates.filter { $0.allSatisfy { abs($0.accidental.rawValue) < 2 } }
        if !plain.isEmpty { candidates = plain }
        let preferSharps = spellingPreference == .sharps
        // Then a natural root before a sharp or a flat (B major in F is B, not C♭); then, off the
        // key, the step a chord of its kind usually is — a diminished chord the raised step it leads
        // up from (F♯°7 in C), any other the lowered one it is borrowed as (D♭7, the tritone's
        // substitute in C, not C♯7); then the key's way.
        let leadsUp = [.diminished, .diminishedSeventh, .halfDiminishedSeventh].contains(chord.quality)
        func side(_ names: [NoteName]) -> Int {
            let root = names[0].accidental.rawValue
            return pitchClasses.contains(chord.root) ? 0 : (leadsUp ? -root : root)
        }
        let best = candidates.min { a, b in
            let ka = (cost(a), weight(a), abs(a[0].accidental.rawValue), side(a), preferSharps ? -a[0].accidental.rawValue : a[0].accidental.rawValue)
            let kb = (cost(b), weight(b), abs(b[0].accidental.rawValue), side(b), preferSharps ? -b[0].accidental.rawValue : b[0].accidental.rawValue)
            return ka < kb
        }
        return best ?? chord.pitchClasses.map(spell)
    }

    /// Chord symbol spelled in this key ("Bb" in F major, "A#" in B major, "Bb" for ♭VII in C).
    public func symbol(of chord: Chord) -> String {
        let names = spell(chord)
        var text = names[0].description + chord.quality.symbol
        // The bass as the chord tone it is: A7 over its third is A7/C♯ in any key.
        if chord.inversion > 0 { text += "/" + names[min(chord.inversion, names.count - 1)].description }
        return text
    }

    /// The seven diatonic triads, tonic first.
    public var diatonicTriads: [Chord] { scale.diatonicChords(root: tonic.pitchClass, size: 3) }

    /// The seven diatonic seventh chords, tonic first.
    public var diatonicSevenths: [Chord] { scale.diatonicChords(root: tonic.pitchClass, size: 4) }

    /// Major and minor keys measure accidentals against their own scale; other modes against the parallel major (♭II in Phrygian).
    public var defaultNumeralReference: NumeralReference {
        mode == .ionian || mode == .aeolian ? .ownScale : .parallelMajor
    }

    private func referencePitchClasses(_ reference: NumeralReference?) -> [PitchClass] {
        switch reference ?? defaultNumeralReference {
        case .ownScale: return pitchClasses
        case .parallelMajor: return Scale.major.pitchClasses(root: tonic.pitchClass)
        }
    }

    /// The Roman numeral of any chord in this key (Chord(E♭, major) in C major → ♭III); nil only for unspellable roots.
    public func romanNumeral(for chord: Chord, reference: NumeralReference? = nil) -> RomanNumeral? {
        let rootName = spell(chord)[0]
        let degree = tonic.letter.steps(to: rootName.letter) + 1
        let difference = referencePitchClasses(reference)[degree - 1].signedDistance(to: chord.root)
        guard let accidental = Accidental(rawValue: difference) else { return nil }
        return RomanNumeral(degree: degree, quality: chord.quality, accidental: accidental)
    }

    /// The chord a Roman numeral denotes in this key.
    public func chord(for numeral: RomanNumeral, reference: NumeralReference? = nil) -> Chord {
        let root = referencePitchClasses(reference)[numeral.degree - 1].transposed(by: numeral.accidental.rawValue)
        return Chord(root: root, quality: numeral.quality)
    }

    /// Roman numerals of the diatonic triads (or sevenths): I ii iii IV V vi vii° in major, i ii° III iv v VI VII in minor.
    public func romanNumerals(sevenths: Bool = false, reference: NumeralReference? = nil) -> [RomanNumeral] {
        (sevenths ? diatonicSevenths : diatonicTriads).compactMap { romanNumeral(for: $0, reference: reference) }
    }

    /// "C major", "F♯ minor", "D Dorian", "E phrygian dominant".
    public var name: String {
        if let colour { return "\(tonic.symbolicName) \(colour.rawValue)" }
        let modeName: String
        switch mode {
        case .ionian: modeName = "major"
        case .aeolian: modeName = "minor"
        default: modeName = mode.name
        }
        return "\(tonic.symbolicName) \(modeName)"
    }

    public var description: String { name }
}
