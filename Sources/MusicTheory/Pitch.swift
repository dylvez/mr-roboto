/// A pitch identified by its MIDI note number (middle C = 60, A4 = 69), with spelling, keyboard and frequency helpers.
public struct Pitch: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// MIDI note number; 0...127 is the MIDI range but any integer is representable.
    public var midi: Int

    public init(midi: Int) { self.midi = midi }
    public init(_ midi: Int) { self.midi = midi }

    /// Builds a pitch from a spelled name and scientific octave (C4 = 60, B♯3 = 60, C♭4 = 59).
    public init(_ noteName: NoteName, octave: Int) {
        midi = (octave + 1) * 12 + noteName.letter.semitones + noteName.accidental.rawValue
    }

    /// Builds a pitch from a pitch class and scientific octave (C4 = 60).
    public init(_ pitchClass: PitchClass, octave: Int) {
        midi = (octave + 1) * 12 + pitchClass.rawValue
    }

    /// Parses "C4", "C#4", "Db-1", "F##5".
    public init?(name: String) {
        guard let splitIndex = name.firstIndex(where: { $0.isNumber || $0 == "-" }) else { return nil }
        guard let noteName = NoteName(String(name[..<splitIndex])),
              let octave = Int(name[splitIndex...]) else { return nil }
        self.init(noteName, octave: octave)
    }

    /// The equal-tempered pitch nearest to `frequency`; nil for non-positive frequencies.
    public init?(frequency: Double, a4: Double = EqualTemperament.defaultA4) {
        guard frequency > 0, a4 > 0 else { return nil }
        midi = Int(EqualTemperament.midi(frequency: frequency, a4: a4).rounded())
    }

    /// Middle C (MIDI 60).
    public static let middleC = Pitch(midi: 60)
    /// Concert A (MIDI 69).
    public static let a4 = Pitch(midi: 69)

    /// The chromatic pitch class (0...11) of this pitch.
    public var pitchClass: PitchClass { PitchClass(wrapping: midi) }

    /// Scientific octave number: MIDI 60 → 4, 21 → 0.
    public var octave: Int { floorDivide(midi, 12) - 1 }

    public var isBlackKey: Bool { pitchClass.isBlackKey }
    public var isWhiteKey: Bool { pitchClass.isWhiteKey }

    /// Spelled note name using the given preference for black keys.
    public func noteName(preferring preference: SpellingPreference = .sharps) -> NoteName {
        pitchClass.spelling(preferring: preference)
    }

    /// Name with octave, e.g. "C#4" or "Db4".
    public func name(preferring preference: SpellingPreference = .sharps) -> String {
        "\(noteName(preferring: preference))\(octave)"
    }

    /// Name with octave for a specific spelling; the octave follows the letter, so MIDI 60 as B♯ is "B#3".
    public func name(spelledAs noteName: NoteName) -> String {
        let letterMidi = midi - noteName.accidental.rawValue
        return "\(noteName)\(floorDivide(letterMidi, 12) - 1)"
    }

    /// Sharp-spelled name with octave, e.g. "C#4".
    public var description: String { name() }

    /// Frequency in hertz under 12-tone equal temperament tuned to `a4`.
    public func frequency(a4: Double = EqualTemperament.defaultA4) -> Double {
        EqualTemperament.frequency(midi: Double(midi), a4: a4)
    }

    /// How far `frequency` lies above (+) or below (−) this pitch, in cents.
    public func cents(to frequency: Double, a4: Double = EqualTemperament.defaultA4) -> Double {
        EqualTemperament.cents(from: self.frequency(a4: a4), to: frequency)
    }

    /// The nearest pitch to `frequency` together with the signed cents deviation from it.
    public static func nearest(frequency: Double, a4: Double = EqualTemperament.defaultA4) -> (pitch: Pitch, cents: Double)? {
        guard let pitch = Pitch(frequency: frequency, a4: a4) else { return nil }
        return (pitch, pitch.cents(to: frequency, a4: a4))
    }

    /// This pitch moved by `semitones`.
    public func transposed(by semitones: Int) -> Pitch { Pitch(midi: midi + semitones) }

    /// Snaps down to the C at or below this pitch.
    public var snappedToC: Pitch { Pitch(midi: midi - pitchClass.rawValue) }

    public static func < (lhs: Pitch, rhs: Pitch) -> Bool { lhs.midi < rhs.midi }
    public static func + (lhs: Pitch, rhs: Int) -> Pitch { lhs.transposed(by: rhs) }
    public static func - (lhs: Pitch, rhs: Int) -> Pitch { lhs.transposed(by: -rhs) }
    /// Signed semitone difference.
    public static func - (lhs: Pitch, rhs: Pitch) -> Int { lhs.midi - rhs.midi }
}

/// Integer division rounding toward negative infinity.
@inline(__always)
func floorDivide(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}
