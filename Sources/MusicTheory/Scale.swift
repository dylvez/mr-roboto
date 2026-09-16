/// The seven church modes; each is a rotation of the major scale and knows its scale and key-signature offset.
public enum Mode: Int, CaseIterable, Hashable, Codable, Sendable, CustomStringConvertible {
    case ionian = 1, dorian, phrygian, lydian, mixolydian, aeolian, locrian

    /// The major mode (Ionian).
    public static let major: Mode = .ionian
    /// The natural minor mode (Aeolian).
    public static let minor: Mode = .aeolian

    public var name: String {
        switch self {
        case .ionian: return "Ionian"
        case .dorian: return "Dorian"
        case .phrygian: return "Phrygian"
        case .lydian: return "Lydian"
        case .mixolydian: return "Mixolydian"
        case .aeolian: return "Aeolian"
        case .locrian: return "Locrian"
        }
    }

    /// Semitone offsets above the modal tonic, derived by rotating the major scale.
    public var intervals: [Int] {
        let major = Scale.major.intervals
        let k = rawValue - 1
        return (0..<7).map { ((major[(k + $0) % 7] - major[k]) % 12 + 12) % 12 }
    }

    /// The scale for this mode.
    public var scale: Scale { Scale(name: name, intervals: intervals, mode: self) }

    /// True when the third degree is a minor third (Dorian, Phrygian, Aeolian, Locrian).
    public var isMinorLike: Bool { intervals[2] == 3 }

    /// Position of the modal tonic on the circle of fifths relative to the relative major (Dorian = +2, Lydian = −1).
    public var fifthsOffset: Int { NoteName(Letter.c.advanced(by: rawValue - 1)).fifths }

    public var description: String { name }
}

/// The functional name of a scale degree, Tonic through Leading Tone (or Subtonic when the seventh is flat).
public enum ScaleDegree: String, CaseIterable, Hashable, Codable, Sendable, CustomStringConvertible {
    case tonic, supertonic, mediant, subdominant, dominant, submediant, leadingTone, subtonic

    /// One-based degree number (both leading tone and subtonic are 7).
    public var number: Int {
        switch self {
        case .tonic: return 1
        case .supertonic: return 2
        case .mediant: return 3
        case .subdominant: return 4
        case .dominant: return 5
        case .submediant: return 6
        case .leadingTone, .subtonic: return 7
        }
    }

    public var name: String {
        switch self {
        case .tonic: return "Tonic"
        case .supertonic: return "Supertonic"
        case .mediant: return "Mediant"
        case .subdominant: return "Subdominant"
        case .dominant: return "Dominant"
        case .submediant: return "Submediant"
        case .leadingTone: return "Leading Tone"
        case .subtonic: return "Subtonic"
        }
    }

    public var description: String { name }
}

/// A named set of semitone offsets above a root (0 first, all below 12), with the catalog of every scale from the source projects.
public struct Scale: Hashable, Codable, Sendable, CustomStringConvertible {
    public let name: String
    /// Ascending, unique offsets in 0..<12, always starting with 0.
    public let intervals: [Int]
    /// The church mode this scale is, if any.
    public let mode: Mode?

    /// Creates a scale; offsets are wrapped into the octave, deduplicated, sorted, and 0 is added if missing.
    public init(name: String, intervals: [Int], mode: Mode? = nil) {
        self.name = name
        self.intervals = Array(Set(intervals.map { ($0 % 12 + 12) % 12 } + [0])).sorted()
        self.mode = mode
    }

    public static let major = Scale(name: "Major", intervals: [0, 2, 4, 5, 7, 9, 11], mode: .ionian)
    public static let naturalMinor = Scale(name: "Natural Minor", intervals: Mode.aeolian.intervals, mode: .aeolian)
    public static let harmonicMinor = Scale(name: "Harmonic Minor", intervals: [0, 2, 3, 5, 7, 8, 11])
    public static let melodicMinor = Scale(name: "Melodic Minor", intervals: [0, 2, 3, 5, 7, 9, 11])
    public static let ionian = Mode.ionian.scale
    public static let dorian = Mode.dorian.scale
    public static let phrygian = Mode.phrygian.scale
    public static let lydian = Mode.lydian.scale
    public static let mixolydian = Mode.mixolydian.scale
    public static let aeolian = Mode.aeolian.scale
    public static let locrian = Mode.locrian.scale
    public static let pentatonicMajor = Scale(name: "Pentatonic Major", intervals: [0, 2, 4, 7, 9])
    public static let pentatonicMinor = Scale(name: "Pentatonic Minor", intervals: [0, 3, 5, 7, 10])
    public static let blues = Scale(name: "Blues", intervals: [0, 3, 5, 6, 7, 10])
    public static let wholeTone = Scale(name: "Whole Tone", intervals: [0, 2, 4, 6, 8, 10])
    public static let chromatic = Scale(name: "Chromatic", intervals: Array(0..<12))
    public static let hirajoshi = Scale(name: "Hirajoshi", intervals: [0, 2, 3, 7, 8])
    public static let fifths = Scale(name: "Fifths", intervals: [0, 7])

    /// Every distinct scale (modes appear once; Major/Natural Minor stand in for Ionian/Aeolian).
    public static let all: [Scale] = [
        .major, .naturalMinor, .harmonicMinor, .melodicMinor,
        .dorian, .phrygian, .lydian, .mixolydian, .locrian,
        .pentatonicMajor, .pentatonicMinor, .blues, .wholeTone, .chromatic, .hirajoshi, .fifths,
    ]

    /// The seven church modes as scales, Ionian first.
    public static let modes: [Scale] = Mode.allCases.map(\.scale)

    /// Case-insensitive lookup by name ("major", "Natural Minor", "Aeolian", "whole tone").
    public static func named(_ name: String) -> Scale? {
        let wanted = name.lowercased()
        return (all + modes).first { $0.name.lowercased() == wanted }
    }

    /// Number of notes per octave.
    public var count: Int { intervals.count }

    /// True for seven-note scales, which support degree names and diatonic chords.
    public var isHeptatonic: Bool { intervals.count == 7 }

    /// True when both scales contain the same offsets, whatever their names.
    public func hasSameIntervals(as other: Scale) -> Bool { intervals == other.intervals }

    /// The pitch classes of this scale on `root`, root first.
    public func pitchClasses(root: PitchClass) -> [PitchClass] {
        intervals.map { root.transposed(by: $0) }
    }

    /// Ascending pitches from `root` across `octaves`; the closing octave is appended when `includingOctave` is true.
    public func pitches(root: Pitch, octaves: Int = 1, includingOctave: Bool = true) -> [Pitch] {
        var result: [Pitch] = []
        for o in 0..<max(0, octaves) {
            for step in intervals { result.append(root + (12 * o + step)) }
        }
        if includingOctave, octaves > 0 { result.append(root + 12 * octaves) }
        return result
    }

    /// Whether `pitchClass` belongs to the scale on `root`.
    public func contains(_ pitchClass: PitchClass, root: PitchClass) -> Bool {
        intervals.contains(root.distance(to: pitchClass))
    }

    /// Whether `pitch` belongs to the scale on `root`, in any octave.
    public func contains(_ pitch: Pitch, root: PitchClass) -> Bool {
        contains(pitch.pitchClass, root: root)
    }

    /// One-based degree of `pitchClass` in the scale on `root`, or nil when it is not a scale tone.
    public func degree(of pitchClass: PitchClass, root: PitchClass) -> Int? {
        intervals.firstIndex(of: root.distance(to: pitchClass)).map { $0 + 1 }
    }

    /// The pitch class at a one-based degree, wrapping past the top (degree 8 of a heptatonic scale is the root).
    public func pitchClass(degree: Int, root: PitchClass) -> PitchClass {
        root.transposed(by: intervals[((degree - 1) % count + count) % count])
    }

    /// The pitch at a one-based degree above `root`; degrees past the top continue into the next octave.
    public func pitch(degree: Int, root: Pitch) -> Pitch {
        let index = ((degree - 1) % count + count) % count
        let octaves = floorDivide(degree - 1, count)
        return root + (intervals[index] + 12 * octaves)
    }

    /// Functional name of a one-based degree for heptatonic scales (7 is Leading Tone at 11 semitones, otherwise Subtonic).
    public func degreeName(_ degree: Int) -> ScaleDegree? {
        guard isHeptatonic, (1...7).contains(degree) else { return nil }
        if degree == 7 { return intervals[6] == 11 ? .leadingTone : .subtonic }
        return ScaleDegree.allCases[degree - 1]
    }

    /// Degree names for all seven degrees of a heptatonic scale; empty otherwise.
    public var degreeNames: [ScaleDegree] {
        isHeptatonic ? (1...7).compactMap(degreeName) : []
    }

    /// Snaps a MIDI number to the nearest scale tone on `root`; exact ties go down.
    public func quantize(midi: Int, root: PitchClass) -> Int {
        let offset = root.distance(to: PitchClass(wrapping: midi))
        if intervals.contains(offset) { return midi }
        for delta in 1...6 {
            if intervals.contains((offset - delta + 12) % 12) { return midi - delta }
            if intervals.contains((offset + delta) % 12) { return midi + delta }
        }
        return midi
    }

    /// Snaps a pitch to the nearest scale tone on `root`; exact ties go down.
    public func quantize(_ pitch: Pitch, root: PitchClass) -> Pitch {
        Pitch(midi: quantize(midi: pitch.midi, root: root))
    }

    /// Snaps a fractional MIDI value to the nearest scale tone on `root`; exact ties go down.
    public func quantize(midiValue: Double, root: PitchClass) -> Double {
        let relative = midiValue - Double(root.rawValue)
        let octaveIndex = (relative / 12).rounded(.down)
        let within = relative - octaveIndex * 12
        var best = Double(intervals[0])
        var bestDistance = Double.infinity
        for degree in intervals {
            for candidate in [Double(degree), Double(degree + 12)] {
                let distance = abs(candidate - within)
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return Double(root.rawValue) + octaveIndex * 12 + best
    }

    /// Snaps a frequency to the nearest scale tone on `root` in equal temperament (the infinitone behaviour).
    public func quantize(frequency: Double, root: PitchClass, a4: Double = EqualTemperament.defaultA4) -> Double {
        let midi = EqualTemperament.midi(frequency: frequency, a4: a4)
        return EqualTemperament.frequency(midi: quantize(midiValue: midi, root: root), a4: a4)
    }

    /// The chord built in thirds on a one-based degree of a heptatonic scale (`size` 3 or 4), or nil if unrecognized.
    public func diatonicChord(degree: Int, root: PitchClass, size: Int = 3) -> Chord? {
        guard isHeptatonic, size >= 3 else { return nil }
        let chordRoot = pitchClass(degree: degree, root: root)
        let offsets = (0..<size).map { chordRoot.distance(to: pitchClass(degree: degree + 2 * $0, root: root)) }
        guard let quality = ChordQuality(intervals: offsets) else { return nil }
        return Chord(root: chordRoot, quality: quality)
    }

    /// The seven chords built in thirds on each degree of a heptatonic scale (triads by default, sevenths for `size` 4).
    public func diatonicChords(root: PitchClass, size: Int = 3) -> [Chord] {
        guard isHeptatonic else { return [] }
        return (1...7).compactMap { diatonicChord(degree: $0, root: root, size: size) }
    }

    /// Roman numerals of the diatonic chords relative to the scale's own degrees (i, ii°, III, iv, V …).
    public func romanNumerals(size: Int = 3) -> [RomanNumeral] {
        guard isHeptatonic else { return [] }
        return (1...7).compactMap { degree in
            diatonicChord(degree: degree, root: .c, size: size).map { RomanNumeral(degree: degree, quality: $0.quality) }
        }
    }

    public var description: String { name }
}
