import Foundation
import Instrument
import MusicTheory
import SongGraph

// The keys player: how a lead sheet becomes something a hand plays.
//
// A progression says which chords and for how long. Until this, one rule played every one of them
// — close root position, struck once, held to the bar line — so the harmony of every song was a
// pad under it, whatever it was voiced on, and the only way to have a piano play a rhythm was to
// write the chords out as notes and call them a tune. Two decisions were missing, and they are the
// two a player makes: where the notes of each chord sit, and when they are struck.

/// Where the notes of each chord sit.
public enum KeysVoicing: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Root position, stacked from the root: as written.
    case close
    /// Each chord in the inversion nearest the one before it, so the voices move by a step or stay.
    case led
    /// The root and its fifth low, the third, the seventh and the colours above them.
    case spread
    /// No root: the third, the seventh and what is above, for when the bass has the root.
    case rootless

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .close: return "Close"
        case .led: return "Voice-led"
        case .spread: return "Spread"
        case .rootless: return "Rootless"
        }
    }

    public var about: String {
        switch self {
        case .close: return "root position, stacked from the root, as the chord is written"
        case .led: return "each chord in the inversion nearest the last, so the voices move by a step or stay where they are"
        case .spread: return "the root and its fifth low, and the third, the seventh and the colours above them"
        case .rootless: return "the third, the seventh and what is above them, the root left to the bass"
        }
    }
}

/// When the chords are struck.
public enum KeysPattern: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Struck on the change and held to the next.
    case held
    /// A two-bar figure of short chords, on and around the off-beats: house piano.
    case stabs
    /// A short chord on the and of every beat.
    case offbeats
    /// A chord on two and on four.
    case backbeat
    /// On one, on the and of two, and the next chord a half-beat early, tied over: a Rhodes.
    case pushes
    /// The chord broken, a note every half-beat, up and back down.
    case arpeggio
    /// A chord on every beat.
    case quarters
    /// A chord on every half-beat, the beats accented.
    case eighths
    /// The low note on one and three, the chord on two and four; in three, low and two chords.
    case boomChick = "boom-chick"
    /// The two-bar bossa figure.
    case bossa

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .held: return "Held"
        case .stabs: return "Stabs"
        case .offbeats: return "Off-beats"
        case .backbeat: return "Backbeat"
        case .pushes: return "Pushes"
        case .arpeggio: return "Arpeggio"
        case .quarters: return "Quarters"
        case .eighths: return "Eighths"
        case .boomChick: return "Boom-chick"
        case .bossa: return "Bossa"
        }
    }

    /// What it is, and the music it is at home in: what the Director is told.
    public var about: String {
        switch self {
        case .held: return "struck on the change and held to the next: a pad, a bed (ambient, trap, lo-fi, a breakdown)"
        case .stabs: return "a two-bar figure of short chords on and around the off-beats (house, garage)"
        case .offbeats: return "a short chord on the and of every beat (reggae, ska, disco, cumbia, Afrobeats)"
        case .backbeat: return "a chord on two and on four (pop piano, soul, a slow reggae)"
        case .pushes: return "on one, on the and of two, and the next chord a half-beat early and tied over (soul, neo-soul, gospel, jazz)"
        case .arpeggio: return "the chord broken, a note every half-beat, up and back down (a ballad, a breakdown)"
        case .quarters: return "a chord on every beat (rock and roll piano, Motown, a blues)"
        case .eighths: return "a chord on every half-beat, the beats accented (pop, rock, synth-pop)"
        case .boomChick: return "the low note on one and three and the chord on two and four; in three, a waltz (country, folk)"
        case .bossa: return "the two-bar bossa figure: one, the and of two, four, then two and the and of three (bossa nova, samba)"
        }
    }

    /// Whether every strike is short. A pad's attack is longer than a stab, so a short pattern on
    /// a slow instrument is mostly silence.
    public var isShort: Bool { self != .held }

    /// The instrument families a short pattern can be heard on: what is struck or plucked, and an
    /// organ, which speaks at once. Strings, pads, winds and brass swell into a note.
    public static let struckFamilies: Set<String> = ["keys", "organ", "bell", "guitar", "bass", "plucked", "pluck", "chip", "lead", "imported"]

    public func suits(family: String) -> Bool { !isShort || Self.struckFamilies.contains(family) }

    /// The same for an instrument: and a short pattern suits anything with recordings of its short
    /// notes, a section of horns or strings, a trumpet with its staccato.
    public func suits(_ spec: InstrumentVoiceSpec) -> Bool { suits(family: spec.family) || spec.playsShortNotes }

    /// The pattern a genre's keys usually play, by the genre profile's id. Nil where the profiles
    /// the app ships give no reason to pick one. Inferred from the idiom of each genre, not cited:
    /// the profiles state what the drums and the bass do, and say little of the keys.
    public static func usual(inGenre id: String) -> KeysPattern? {
        switch id {
        case "house", "uk-garage", "jersey-club": return .stabs
        case "reggae", "disco", "funk", "cumbia", "reggaeton", "afrobeats", "afrobeat", "salsa": return .offbeats
        case "soul", "neo-soul", "gospel", "jazz": return .pushes
        case "pop", "synth-pop", "rock": return .eighths
        case "blues": return .quarters
        case "country", "folk": return .boomChick
        case "bossa-nova", "samba": return .bossa
        case "trap", "drill", "lo-fi-hip-hop", "boom-bap", "trip-hop", "techno", "dubstep", "drum-and-bass",
             "breakbeat", "amapiano": return .held
        default: return nil
        }
    }
}

extension ChordPlaying {
    public init(_ pattern: KeysPattern, _ voicing: KeysVoicing = .close, seed: UInt64 = 0) {
        self.init(pattern: pattern.rawValue, voicing: voicing.rawValue, seed: seed)
    }

    /// The pattern, or held for a name nobody knows: a document from a later build still plays.
    public var keysPattern: KeysPattern { KeysPattern(rawValue: pattern) ?? .held }
    public var keysVoicing: KeysVoicing { KeysVoicing(rawValue: voicing) ?? .close }

    /// "Stabs, voice-led".
    public var sentence: String { "\(keysPattern.name), \(keysVoicing.name.lowercased())" }
}

// MARK: - Voicing

extension Voicing {

    /// Where a voice-led chord may sit, and where it would rather: round middle C, low enough to
    /// stay under a tune and high enough to stay off the bass.
    static let ledRange = 45...76
    static let ledHome = 59.0
    /// The upper structure of a spread or a rootless voicing.
    static let upperRange = 52...79
    static let upperHome = 65.0
    /// Where the low note of a spread voicing sits: F2 to E3.
    static let lowRange = 41...52

    /// The pitches each chord is played on, low to high, in the order the chords come.
    public static func voicings(of chords: [Chord], as style: KeysVoicing, octave: Int = rootOctave) -> [[Int]] {
        var out: [[Int]] = []
        var previous: [Int]?
        for chord in chords {
            let voiced: [Int]
            switch style {
            case .close:
                voiced = chord.pitches(octave: octave).map(\.midi)
            case .led:
                voiced = nearest(tones(of: chord, keepingRoot: true, atMost: 5), to: previous, in: ledRange, home: ledHome,
                                 root: chord.root.rawValue)
                previous = voiced
            case .rootless:
                let upper = tones(of: chord, keepingRoot: !hasUpperStructure(chord), atMost: 4)
                voiced = nearest(upper, to: previous, in: upperRange, home: upperHome, root: chord.root.rawValue)
                previous = voiced
            case .spread:
                let root = lowRange.first { ($0 % 12 + 12) % 12 == chord.root.rawValue } ?? 48
                var low = [root]
                if chord.intervals.contains(7) { low.append(root + 7) }
                var upper = tones(of: chord, keepingRoot: false, atMost: 4).filter { $0 != (chord.root.rawValue + 7) % 12 }
                // A triad has one note left when its root and fifth are below: they go on top too.
                if upper.count < 2 { upper = tones(of: chord, keepingRoot: true, atMost: 4) }
                let above = nearest(upper, to: previous, in: max(upperRange.lowerBound, (low.last ?? root) + 2)...upperRange.upperBound,
                                    home: upperHome, root: chord.root.rawValue)
                previous = above
                voiced = low + above
            }
            out.append(voiced)
        }
        return out
    }

    /// Whether a chord has enough above its root to be played without it: a third and a seventh,
    /// or a sixth. A triad without its root is two notes, and is left whole.
    static func hasUpperStructure(_ chord: Chord) -> Bool {
        chord.intervals.count >= 4
    }

    /// The chord's notes as pitch classes, in the order the chord stacks them. When there are more
    /// than `limit`, the ones that say what it is are kept: the third and the seventh, then what
    /// is stacked above the seventh, then the root, and the fifth last — a perfect fifth is the
    /// note a voicing loses when it has too many.
    static func tones(of chord: Chord, keepingRoot: Bool, atMost limit: Int) -> [Int] {
        func rank(_ interval: Int) -> Int {
            switch interval {
            case 3, 4: return 0
            case 2 where chord.quality.isSuspended: return 0
            case 5 where chord.quality.isSuspended: return 0
            case 9, 10, 11: return 1
            case 0: return 3
            case 7: return 4
            default: return 2
            }
        }
        var intervals = chord.intervals
        if !keepingRoot { intervals.removeAll { $0 == 0 } }
        let kept = intervals.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.prefix(max(1, limit)).map(\.element).sorted()
        var seen = Set<Int>()
        return kept.map { (chord.root.rawValue + $0) % 12 }.filter { seen.insert($0).inserted }
    }

    /// These pitch classes, in the order the chord stacks them, turned over and placed in whichever
    /// inversion and octave is nearest the chord before: the top voice counted twice, because it is
    /// the one that is heard as a line. With nothing before, the stacking nearest `home`, root at
    /// the bottom when two are as near.
    ///
    /// Stacked, not folded into an octave: a ninth sits above the seventh, so a major ninth in
    /// root position is thirds all the way up and not a cluster round its root.
    static func nearest(_ classes: [Int], to previous: [Int]?, in range: ClosedRange<Int>, home: Double, root: Int) -> [Int] {
        guard !classes.isEmpty else { return [] }
        let sorted = classes
        var best: (rubs: Int, cost: Double, pitches: [Int])?
        for rotation in sorted.indices {
            let order = Array(sorted[rotation...] + sorted[..<rotation])
            for bottom in range where ((bottom % 12) + 12) % 12 == order[0] {
                var pitches = [bottom]
                for pitchClass in order.dropFirst() {
                    var next = pitches[pitches.count - 1] + 1
                    while ((next % 12) + 12) % 12 != pitchClass { next += 1 }
                    pitches.append(next)
                }
                guard let top = pitches.last, top <= range.upperBound else { continue }
                let centre = Double(pitches.reduce(0, +)) / Double(pitches.count)
                // Fewest rubs first, and only then nearest: a chord is moved as far as it takes to
                // be played without one.
                let rubs = rubs(in: pitches)
                var cost = 0.2 * abs(centre - home)
                if let previous, !previous.isEmpty {
                    let before = previous.sorted(by: >), after = pitches.sorted(by: >)
                    for index in 0..<min(before.count, after.count) {
                        cost += Double(abs(before[index] - after[index])) * (index == 0 ? 2 : 1)
                    }
                    cost += 2 * Double(abs(before.count - after.count))
                } else {
                    cost = abs(centre - home) + (order[0] == root ? 0 : 0.5)
                }
                if let held = best, (held.rubs, held.cost) <= (rubs, cost + 1e-9) { continue }
                best = (rubs, cost, pitches)
            }
        }
        return best?.pitches ?? sorted.map { 60 + $0 }
    }

    /// Voices a semitone apart, or a semitone more than an octave: the ninth of a minor ninth
    /// beside its third, a major seventh turned over so that its seventh is under its root. Heard
    /// as a wrong note rather than as a colour, so a voicing has one only when every way of
    /// playing the chord does.
    static func rubs(in pitches: [Int]) -> Int {
        var count = 0
        for (index, low) in pitches.enumerated() {
            for high in pitches[(index + 1)...] where high - low == 1 || high - low == 13 { count += 1 }
        }
        return count
    }

    // MARK: Striking

    /// One strike of a pattern: when, for how long, how hard against the rest, and which of the
    /// voicing's notes.
    struct Strike {
        enum Which { case all, low, alternate, upper }
        var beat: Double
        var length: Double
        var accent: Int = 0
        var which: Which = .all
        /// Plays the chord that is coming, not the one that is sounding: a push.
        var anticipates = false
    }

    /// The strikes of one cycle of a pattern in a bar of `beats` beats, and how many bars a cycle
    /// is. A figure written for four beats is played as the nearest plain one in any other meter.
    static func strikes(of pattern: KeysPattern, beats: Int) -> (bars: Int, strikes: [Strike]) {
        let each = (0..<max(1, beats)).map(Double.init)
        switch pattern {
        case .held, .arpeggio:
            return (1, [])
        case .quarters:
            return (1, each.map { Strike(beat: $0, length: 0.8, accent: $0 == 0 ? 4 : Int($0) * 2 == beats ? 2 : -4) })
        case .eighths:
            return (1, each.flatMap { [Strike(beat: $0, length: 0.4, accent: $0 == 0 ? 4 : 0), Strike(beat: $0 + 0.5, length: 0.4, accent: -10)] })
        case .offbeats:
            return (1, each.map { Strike(beat: $0 + 0.5, length: 0.25, accent: -2) })
        case .backbeat:
            return (1, each.filter { Int($0) % 2 == 1 }.map { Strike(beat: $0, length: 0.45) })
        case .boomChick:
            if beats % 3 == 0 {
                // In three, and in six as two threes: low, chord, chord.
                return (1, each.map { beat in
                    let place = Int(beat) % 3
                    return Strike(beat: beat, length: place == 0 ? 0.9 : 0.45, accent: place == 0 ? 2 : -6,
                                  which: place == 0 ? (Int(beat) % 6 == 0 ? .low : .alternate) : .upper)
                })
            }
            return (1, each.map { beat in
                let place = Int(beat) % 4
                return Strike(beat: beat, length: place % 2 == 0 ? 0.9 : 0.45, accent: place % 2 == 0 ? 2 : -4,
                              which: place == 0 ? .low : place == 2 ? .alternate : .upper)
            })
        case .stabs:
            guard beats == 4 else { return strikes(of: .offbeats, beats: beats) }
            return (2, [Strike(beat: 0, length: 0.35), Strike(beat: 0.75, length: 0.2, accent: -12),
                        Strike(beat: 1.5, length: 0.35, accent: -4), Strike(beat: 2.5, length: 0.35, accent: -4),
                        Strike(beat: 3.25, length: 0.2, accent: -14), Strike(beat: 4.5, length: 0.35, accent: -2),
                        Strike(beat: 5.5, length: 0.35, accent: -6), Strike(beat: 6.25, length: 0.2, accent: -14),
                        Strike(beat: 7, length: 0.35, accent: -2), Strike(beat: 7.5, length: 0.3, accent: -8)])
        case .pushes:
            guard beats == 4 else { return strikes(of: .quarters, beats: beats) }
            return (2, [Strike(beat: 0, length: 1.25, accent: 2), Strike(beat: 1.5, length: 1.75, accent: -4),
                        Strike(beat: 3.5, length: 1.9, anticipates: true),
                        Strike(beat: 5.5, length: 1.4, accent: -4), Strike(beat: 7, length: 0.9, accent: -2)])
        case .bossa:
            guard beats == 4 else { return strikes(of: .quarters, beats: beats) }
            return (2, [Strike(beat: 0, length: 1.2), Strike(beat: 1.5, length: 1.2, accent: -4), Strike(beat: 3, length: 1.2, accent: -2),
                        Strike(beat: 5, length: 1.2, accent: -4), Strike(beat: 6.5, length: 1.2, accent: -2)])
        }
    }

    /// A progression as it is played: its chords voiced and struck the way `playing` says.
    public static func notes(for progression: Progression, playing: ChordPlaying, octave: Int = rootOctave,
                             velocity: Int = velocity, hold: Double = hold) -> [NoteEvent] {
        let spans = progression.bars.flatMap(\.chords).filter { $0.beats > 0 }
        guard !spans.isEmpty else { return [] }
        let voiced = voicings(of: spans.map(\.chord), as: playing.keysVoicing, octave: octave)
        var starts: [Double] = []
        var beat = 0.0
        for span in spans { starts.append(beat); beat += span.beats }
        let total = beat
        let pattern = playing.keysPattern
        var jitter = Jitter(seed: playing.seed)
        func struck(_ pitches: [Int], at start: Double, for length: Double, accent: Int) -> [NoteEvent] {
            let hard = max(1, min(127, velocity + accent + jitter.next()))
            return pitches.map { NoteEvent(pitch: Pitch(midi: $0), start: start, duration: max(0.05, length), velocity: hard) }
        }

        var out: [NoteEvent] = []
        switch pattern {
        case .held:
            for (index, span) in spans.enumerated() {
                out += struck(voiced[index], at: starts[index], for: max(0.01, span.beats * hold), accent: 0)
            }
        case .arpeggio:
            // A note every half-beat from the bottom of the chord to the top and back, begun again
            // on every change, each ringing a little into the next.
            for (index, span) in spans.enumerated() {
                let pitches = voiced[index]
                guard !pitches.isEmpty else { continue }
                let order = pitches.count > 2 ? Array(pitches.indices) + Array(pitches.indices.dropFirst().dropLast().reversed())
                                              : Array(pitches.indices)
                var step = 0
                var at = 0.0
                while at < span.beats - 1e-9 {
                    let length = min(0.95, span.beats - at)
                    out += struck([pitches[order[step % order.count]]], at: starts[index] + at, for: length, accent: step == 0 ? 4 : -6)
                    step += 1
                    at += 0.5
                }
            }
        default:
            let beats = max(1, Int(progression.bars.first?.beats.rounded() ?? 4))
            let figure = strikes(of: pattern, beats: beats)
            let cycle = Double(figure.bars * beats)
            var from = 0.0
            while from < total - 1e-9 {
                for strike in figure.strikes {
                    let at = from + strike.beat
                    guard at < total - 1e-9 else { continue }
                    // A push plays the chord a half-beat on; past the end that is the first again.
                    let sounding = strike.anticipates ? (at + 0.5).truncatingRemainder(dividingBy: total) : at
                    guard let index = starts.lastIndex(where: { $0 <= sounding + 1e-9 }) else { continue }
                    // Let go before the chord changes under it. A push is let go before the chord
                    // it played changes, which is a bar later.
                    let changes = strike.anticipates ? at + 0.5 + spans[index].beats : starts[index] + spans[index].beats
                    let length = min(strike.length, max(0.1, changes - at - 0.05))
                    let pitches = voiced[index]
                    let chosen: [Int]
                    switch strike.which {
                    case .all: chosen = pitches
                    case .low: chosen = Array(pitches.prefix(1))
                    case .upper: chosen = pitches.count > 1 ? Array(pitches.dropFirst()) : pitches
                    case .alternate:
                        // The fifth, under the root where there is room: the other foot.
                        let root = pitches.first ?? 48
                        let fifth = spans[index].chord.intervals.contains(7) ? root + 7 : root
                        chosen = [fifth - 12 >= lowRange.lowerBound ? fifth - 12 : fifth]
                    }
                    out += struck(chosen, at: at, for: length, accent: strike.accent)
                }
                from += cycle
            }
        }
        return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.pitch.midi < $1.pitch.midi }
    }

    /// The top note of each chord as it is voiced: the line a listener hears the chords as.
    public static func topLine(of progression: Progression, as style: KeysVoicing) -> [Int] {
        voicings(of: progression.bars.flatMap(\.chords).map(\.chord), as: style).compactMap(\.last)
    }

    /// How far the voices move from chord to chord, in semitones a voice a change, as voiced.
    public static func movement(of progression: Progression, as style: KeysVoicing) -> Double {
        let voiced = voicings(of: progression.bars.flatMap(\.chords).map(\.chord), as: style)
        var moved = 0.0, counted = 0
        for (before, after) in zip(voiced, voiced.dropFirst()) {
            let a = before.sorted(by: >), b = after.sorted(by: >)
            for index in 0..<min(a.count, b.count) { moved += Double(abs(a[index] - b[index])); counted += 1 }
        }
        return counted == 0 ? 0 : moved / Double(counted)
    }

    /// A few points of velocity either way, the same every time for one seed. A seed of nought is
    /// a hand that never varies.
    struct Jitter {
        var state: UInt64
        let varies: Bool
        init(seed: UInt64) {
            state = seed &+ 0x9E37_79B9_7F4A_7C15
            varies = seed != 0
        }
        mutating func next() -> Int {
            guard varies else { return 0 }
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 11) - 5
        }
    }
}
