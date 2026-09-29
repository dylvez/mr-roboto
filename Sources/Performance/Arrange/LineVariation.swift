import Foundation
import MusicTheory
import SongGraph

/// A way of playing a bass line for a section that is not the line as written.
public enum BassTreatment: String, Sendable, CaseIterable, Codable {
    /// Half the notes, the ones on the bar and the middle of it: an intro, a bridge, an outro.
    case light
    /// The root of each chord, held: under a breakdown.
    case held
    /// Eighths on the root, louder as they go: under a build.
    case pulse

    public var word: String {
        switch self {
        case .light: return "lighter"
        case .held: return "held roots"
        case .pulse: return "pulse"
        }
    }
}

/// A way of playing a tune for a section that is not the tune as written.
public enum TuneTreatment: String, Sendable, CaseIterable, Codable {
    /// The tune, then the tune an octave up: the last hook, the drop.
    case lift
    /// The first half of it, quietly, and the rest left empty: a breakdown.
    case sparse

    public var word: String {
        switch self {
        case .lift: return "then an octave up"
        case .sparse: return "first phrase only"
        }
    }
}

/// A bass line, played another way. The line's own sound, key and hands are kept: a variation is
/// the same player, asked for less or asked to wait.
public enum BassVariation {

    /// - Parameters:
    ///   - chords: the harmony the line sits on, in beats from the top. Empty reads the roots off
    ///     the line itself: the note on each bar's first beat.
    ///   - bars: the section's length, for the pulse, which is written through it.
    public static func vary(_ line: Bassline, as treatment: BassTreatment, chords: [ChordSpan] = [],
                            bars: Int, beatsPerBar: Int) -> Bassline? {
        guard !line.notes.isEmpty else { return nil }
        let varied: Bassline?
        switch treatment {
        case .light: varied = light(line, beatsPerBar: beatsPerBar)
        case .held: varied = held(line, chords: chords, beatsPerBar: beatsPerBar)
        case .pulse: varied = pulse(line, chords: chords, bars: bars, beatsPerBar: beatsPerBar)
        }
        guard let varied, !varied.notes.isEmpty, varied.notes != line.notes else { return nil }
        return varied
    }

    /// How near a beat a note has to start to be on it. A line sits behind the kick by up to 65 ms,
    /// which at 60 bpm is a sixteenth of a beat; a quarter of one is outside any pocket.
    static let onTheBeat = 0.25

    static func light(_ line: Bassline, beatsPerBar: Int) -> Bassline? {
        let beats = Double(max(1, beatsPerBar))
        let loop = line.loopBars(beatsPerBar: beatsPerBar)
        var kept: [NoteEvent] = []
        for bar in 0..<loop {
            let start = Double(bar) * beats
            let inBar = line.notes.filter { $0.start >= start - onTheBeat && $0.start < start + beats - onTheBeat }
            guard !inBar.isEmpty else { continue }
            let keep = max(1, inBar.count / 2)
            func rank(_ note: NoteEvent) -> Int {
                let offset = note.start - start
                if abs(offset) <= onTheBeat { return 0 }
                if abs(offset - (beats / 2).rounded(.down)) <= onTheBeat { return 1 }
                if abs(offset - offset.rounded()) <= onTheBeat { return 2 }
                return 3
            }
            let chosen = inBar.enumerated().sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                if ra != rb { return ra < rb }
                if a.element.velocity != b.element.velocity { return a.element.velocity > b.element.velocity }
                return a.offset < b.offset
            }.prefix(keep).map(\.element)
            kept += chosen
        }
        var out = line
        out.notes = kept.sorted { $0.start < $1.start }
        out.lengthInBars = loop
        return out
    }

    static func held(_ line: Bassline, chords: [ChordSpan], beatsPerBar: Int) -> Bassline? {
        let roots = roots(of: line, chords: chords, beatsPerBar: beatsPerBar)
        guard !roots.isEmpty else { return nil }
        var out = line
        out.notes = roots.map { root in
            NoteEvent(pitch: Pitch(midi: root.midi), start: root.start, duration: max(0.25, root.beats - 0.1), velocity: 84)
        }
        let total = roots.map { $0.start + $0.beats }.max() ?? 0
        out.lengthInBars = max(1, Int((total / Double(max(1, beatsPerBar))).rounded(.up)))
        return out
    }

    static func pulse(_ line: Bassline, chords: [ChordSpan], bars: Int, beatsPerBar: Int) -> Bassline? {
        let roots = roots(of: line, chords: chords, beatsPerBar: beatsPerBar)
        guard !roots.isEmpty, (1...GrooveVariation.longestBars).contains(bars) else { return nil }
        let cycle = roots.map { $0.start + $0.beats }.max() ?? Double(beatsPerBar)
        let length = bars
        let total = Double(length * max(1, beatsPerBar))
        var notes: [NoteEvent] = []
        var beat = 0.0
        while beat < total - 0.001 {
            let inCycle = beat.truncatingRemainder(dividingBy: max(0.5, cycle))
            let root = roots.last { $0.start <= inCycle + 0.001 } ?? roots[0]
            let velocity = 72 + Int((beat / total) * 38)
            notes.append(NoteEvent(pitch: Pitch(midi: root.midi), start: beat, duration: 0.4, velocity: min(118, velocity)))
            beat += 0.5
        }
        var out = line
        out.notes = notes
        out.lengthInBars = length
        return out
    }

    /// The roots the line stands on, in its own register: the chords' when there are chords, else
    /// the note each bar of the line opens on.
    static func roots(of line: Bassline, chords: [ChordSpan], beatsPerBar: Int) -> [(midi: Int, start: Double, beats: Double)] {
        let pitches = line.notes.map(\.pitch.midi).sorted()
        guard !pitches.isEmpty else { return [] }
        let centre = pitches[pitches.count / 2]
        let floor = pitches[0]
        func place(_ pitchClass: PitchClass) -> Int {
            // The octave nearest the middle of the line, and never under its lowest note by more
            // than a third: a held root an octave below everything the line played is another bass.
            var midi = centre - ((centre % 12 + 12) % 12) + pitchClass.rawValue
            while midi - centre > 6 { midi -= 12 }
            while centre - midi > 5 { midi += 12 }
            if midi < floor - 4 { midi += 12 }
            return midi
        }
        if !chords.isEmpty {
            var out: [(Int, Double, Double)] = []
            var beat = 0.0
            for span in chords where span.beats > 0 {
                out.append((place(span.chord.bass), beat, span.beats))
                beat += span.beats
            }
            return out
        }
        let beats = Double(max(1, beatsPerBar))
        let loop = line.loopBars(beatsPerBar: beatsPerBar)
        var out: [(Int, Double, Double)] = []
        for bar in 0..<loop {
            let start = Double(bar) * beats
            let inBar = line.notes.filter { $0.start >= start - onTheBeat && $0.start < start + beats - onTheBeat }
            if let first = inBar.first {
                out.append((first.pitch.midi, start, beats))
            } else if let last = out.last {
                // A bar the line rests through holds the root before it.
                out[out.count - 1] = (last.0, last.1, last.2 + beats)
            }
        }
        return out
    }
}

/// A tune, played another way.
public enum TuneVariation {

    /// The highest a lifted tune goes: C7. Above it the app's instruments are all attack.
    public static let ceiling = 96
    /// The longest a lifted tune runs, in bars.
    public static let longestBars = 32

    /// - Parameter bars: the section's length. A lift is the tune and then the tune an octave up
    ///   where the section has room to say it twice, and the tune an octave up where it has not.
    public static func vary(_ tune: Melody, as treatment: TuneTreatment, bars: Int, beatsPerBar: Int) -> Melody? {
        guard !tune.notes.isEmpty else { return nil }
        let varied: Melody?
        switch treatment {
        case .lift: varied = lift(tune, bars: bars, beatsPerBar: beatsPerBar)
        case .sparse: varied = sparse(tune, beatsPerBar: beatsPerBar)
        }
        guard let varied, !varied.notes.isEmpty, varied.notes != tune.notes else { return nil }
        return varied
    }

    static func lift(_ tune: Melody, bars: Int, beatsPerBar: Int) -> Melody? {
        let loop = tune.loopBars(beatsPerBar: beatsPerBar)
        let top = tune.notes.map(\.pitch.midi).max() ?? 0
        guard top + 12 <= ceiling else { return nil }
        func raised(_ note: NoteEvent, by beats: Double) -> NoteEvent {
            NoteEvent(pitch: Pitch(midi: note.pitch.midi + 12), start: note.start + beats, duration: note.duration,
                      velocity: min(127, note.velocity + 4))
        }
        guard loop * 2 <= longestBars, bars >= loop * 2 else {
            // No room to say it twice: said once, an octave up.
            return Melody(notes: tune.notes.map { raised($0, by: 0) }, lengthInBars: loop)
        }
        let offset = Double(loop * max(1, beatsPerBar))
        return Melody(notes: tune.notes + tune.notes.map { raised($0, by: offset) }, lengthInBars: loop * 2)
    }

    static func sparse(_ tune: Melody, beatsPerBar: Int) -> Melody? {
        let loop = tune.loopBars(beatsPerBar: beatsPerBar)
        let beats = Double(loop * max(1, beatsPerBar))
        let half = loop > 1 ? Double(((loop + 1) / 2) * max(1, beatsPerBar)) : beats / 2
        let kept = tune.notes.filter { $0.start < half - 0.001 }.map { note in
            NoteEvent(pitch: note.pitch, start: note.start, duration: min(note.duration, max(0.1, half - note.start)),
                      velocity: max(1, Int((Double(note.velocity) * 0.8).rounded())))
        }
        return Melody(notes: kept, lengthInBars: loop)
    }
}
