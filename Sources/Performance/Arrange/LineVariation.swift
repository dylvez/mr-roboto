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
    /// The tune twice, the second time ending somewhere else: left open the first time and
    /// brought home the second. A question, and then its answer.
    case answered
    /// The notes that land on a bar line pulled an eighth early and tied over it.
    case pushed
    /// The opening figure again on another degree of the key, where what followed it was.
    case sequenced

    public var word: String {
        switch self {
        case .lift: return "then an octave up"
        case .sparse: return "first phrase only"
        case .answered: return "twice, with a second ending"
        case .pushed: return "pushed over the bar lines"
        case .sequenced: return "its opening again on another degree"
        }
    }

    /// What it does, for a picker and for a tool's schema.
    public var about: String {
        switch self {
        case .lift: return "the tune, then the tune an octave up"
        case .sparse: return "its first phrase only, quietly, and the rest left empty"
        case .answered: return "the tune twice, left open the first time and brought home the second"
        case .pushed: return "the notes that land on a bar line pulled an eighth early and tied over it"
        case .sequenced: return "the opening figure again on another degree of the key, where what followed it was"
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
    ///   - key: the key the tune is in, for the treatments that move a note to a degree of it.
    ///     Nil reads home off the tune: the note it starts on.
    ///   - chords: the harmony under the tune, in beats from its top, for a sequence to land on.
    public static func vary(_ tune: Melody, as treatment: TuneTreatment, bars: Int, beatsPerBar: Int,
                            key: Key? = nil, chords: [ChordSpan] = []) -> Melody? {
        guard !tune.notes.isEmpty else { return nil }
        let varied: Melody?
        switch treatment {
        case .lift: varied = lift(tune, bars: bars, beatsPerBar: beatsPerBar)
        case .sparse: varied = sparse(tune, beatsPerBar: beatsPerBar)
        case .answered: varied = answered(tune, beatsPerBar: beatsPerBar, key: key)
        case .pushed: varied = pushed(tune, beatsPerBar: beatsPerBar)
        case .sequenced: varied = sequenced(tune, beatsPerBar: beatsPerBar, key: key, chords: chords)
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

    // MARK: A second ending

    /// The tune twice. Where it ends away from home, the second time it ends at home and stays
    /// there; where it already ends at home, the first time is left open a step above. Either way
    /// the listener hears the same phrase finish two ways, which is what makes it a phrase.
    static func answered(_ tune: Melody, beatsPerBar: Int, key: Key?) -> Melody? {
        let loop = tune.loopBars(beatsPerBar: beatsPerBar)
        guard loop * 2 <= longestBars else { return nil }
        let ordered = tune.notes.sorted { $0.start < $1.start }
        guard ordered.count >= 3, let last = ordered.last else { return nil }
        let beats = Double(loop * max(1, beatsPerBar))
        let home = key?.tonic.pitchClass ?? ordered[0].pitch.pitchClass
        func nearest(_ pitchClass: PitchClass, to midi: Int) -> Int {
            let up = Pitch(midi: midi).pitchClass.distance(to: pitchClass)
            return up <= 6 ? midi + up : midi + up - 12
        }
        var first = ordered
        var second = ordered.map { NoteEvent(pitch: $0.pitch, start: $0.start + beats, duration: $0.duration, velocity: $0.velocity) }
        if last.pitch.pitchClass == home {
            // Home already: the first time stops a step short of it, on the second degree.
            let open = key.map { $0.pitchClasses.count > 1 ? $0.pitchClasses[1] : home.transposed(by: 2) } ?? home.transposed(by: 2)
            first[first.count - 1] = NoteEvent(pitch: Pitch(midi: nearest(open, to: last.pitch.midi)), start: last.start,
                                               duration: last.duration, velocity: last.velocity)
        } else {
            // Brought home, and held to the end of the phrase: the last word.
            let landed = nearest(home, to: last.pitch.midi)
            let held = max(last.duration, min(Double(max(1, beatsPerBar)), beats - last.start - 0.25))
            second[second.count - 1] = NoteEvent(pitch: Pitch(midi: landed), start: last.start + beats, duration: held,
                                                 velocity: last.velocity)
        }
        return Melody(notes: first + second, lengthInBars: loop * 2)
    }

    // MARK: Pushed

    /// Every note that lands on a bar line, but the tune's first, comes in an eighth early and is
    /// held over the line; the note before it gives up the room. The tune is the same notes over
    /// the same chords, leaning forward.
    static func pushed(_ tune: Melody, beatsPerBar: Int) -> Melody? {
        let bar = Double(max(1, beatsPerBar))
        var notes = tune.notes.sorted { $0.start < $1.start }
        guard notes.count >= 3 else { return nil }
        var moved = 0
        for index in notes.indices.dropFirst() {
            let note = notes[index]
            let inBar = note.start.truncatingRemainder(dividingBy: bar)
            guard inBar < 0.01, note.start >= bar - 0.01 else { continue }
            let early = note.start - 0.5
            let before = notes[index - 1]
            // Room for it: the note before has to have started well before the push.
            guard before.start <= early - 0.25 else { continue }
            if before.start + before.duration > early {
                notes[index - 1] = NoteEvent(pitch: before.pitch, start: before.start, duration: max(0.1, early - before.start),
                                             velocity: before.velocity)
            }
            notes[index] = NoteEvent(pitch: note.pitch, start: early, duration: note.duration + 0.5,
                                     velocity: min(127, note.velocity + 6))
            moved += 1
        }
        guard moved > 0 else { return nil }
        return Melody(notes: notes, lengthInBars: tune.lengthInBars ?? tune.loopBars(beatsPerBar: beatsPerBar))
    }

    // MARK: A sequence

    /// The opening figure — the tune's first unit, two bars of a tune of four or more — said again
    /// on another degree of the key in place of the unit after it. Which degree is the one that
    /// sits best on the chords under it: a step up when nothing says otherwise.
    static func sequenced(_ tune: Melody, beatsPerBar: Int, key: Key?, chords: [ChordSpan]) -> Melody? {
        let loop = tune.loopBars(beatsPerBar: beatsPerBar)
        guard loop >= 2 else { return nil }
        let unit = Double((loop >= 4 ? 2 : 1) * max(1, beatsPerBar))
        let ordered = tune.notes.sorted { $0.start < $1.start }
        let figure = ordered.filter { $0.start < unit - 0.001 }
        guard figure.count >= 3 else { return nil }
        let scale = key?.pitchClasses ?? []

        /// A pitch moved by scale steps, a note outside the key keeping its distance above the
        /// degree below it. With no key, a tone a step.
        func moved(_ midi: Int, by steps: Int) -> Int {
            guard scale.count == 7, let tonic = scale.first else { return midi + 2 * steps }
            let above = tonic.distance(to: Pitch(midi: midi).pitchClass)
            let offsets = scale.map { tonic.distance(to: $0) }
            guard let degree = offsets.lastIndex(where: { $0 <= above }) else { return midi + 2 * steps }
            let chromatic = above - offsets[degree]
            let target = degree + steps
            let octave = Int((Double(target) / 7).rounded(.down))
            let index = ((target % 7) + 7) % 7
            return midi - above + offsets[index] + 12 * octave + chromatic
        }
        func chord(at beat: Double) -> Chord? {
            guard !chords.isEmpty else { return nil }
            let total = chords.reduce(0) { $0 + $1.beats }
            var at = beat.truncatingRemainder(dividingBy: max(total, 0.001))
            for span in chords {
                if at < span.beats - 1e-9 { return span.chord }
                at -= span.beats
            }
            return chords.last?.chord
        }
        func restated(_ steps: Int) -> [NoteEvent] {
            figure.map { NoteEvent(pitch: Pitch(midi: moved($0.pitch.midi, by: steps)), start: $0.start + unit,
                                   duration: min($0.duration, unit - $0.start), velocity: $0.velocity) }
        }
        /// How much of a restatement, by length, sits on the chords under it.
        func fit(_ notes: [NoteEvent]) -> Double {
            var landed = 0.0, judged = 0.0
            for note in notes {
                guard let under = chord(at: note.start) else { continue }
                judged += note.duration
                if under.pitchClasses.contains(note.pitch.pitchClass) { landed += note.duration }
            }
            return judged > 0 ? landed / judged : 0
        }
        // A step up first: on a tie it is the one a listener expects least to be surprised by.
        let candidates = [1, -1, 2, -2].map(restated)
        guard let best = candidates.enumerated().max(by: { a, b in
            let fa = fit(a.element), fb = fit(b.element)
            return fa == fb ? a.offset > b.offset : fa < fb
        })?.element else { return nil }
        let top = best.map(\.pitch.midi).max() ?? 0
        guard top <= ceiling else { return nil }
        let kept = ordered.filter { $0.start < unit - 0.001 || $0.start >= unit * 2 - 0.001 }
        return Melody(notes: (kept + best).sorted { $0.start < $1.start }, lengthInBars: loop)
    }

    // MARK: An answering line

    /// A second line that answers the tune where it rests: the last notes of each phrase said
    /// again an octave away, in the gap after them. Not the tune played another way — the tune
    /// goes on under it — so it is a line of its own, for another player.
    ///
    /// Nil when the tune leaves no gap of two beats to answer in: an answer is two notes at least.
    public static func answers(to tune: Melody, beatsPerBar: Int) -> Melody? {
        let loop = tune.loopBars(beatsPerBar: beatsPerBar)
        let beats = Double(loop * max(1, beatsPerBar))
        let ordered = tune.notes.sorted { $0.start < $1.start }
        guard ordered.count >= 3 else { return nil }
        let top = ordered.map(\.pitch.midi).max() ?? 0
        let shift = top + 12 <= ceiling ? 12 : -12
        var out: [NoteEvent] = []
        for (index, note) in ordered.enumerated() {
            let end = note.start + note.duration
            let next = index + 1 < ordered.count ? ordered[index + 1].start : beats
            let gap = next - end
            guard gap >= 2 else { continue }
            // Where the answer comes in: the next eighth after the phrase stops, and a breath.
            let entry = ((end + 0.5) * 2).rounded(.up) / 2
            let room = next - entry - 0.25
            // The phrase's last notes, as many as fit, three at most.
            var echoed: [NoteEvent] = []
            for count in stride(from: min(3, index + 1), through: 2, by: -1) {
                let tail = Array(ordered[(index + 1 - count)...index])
                let span = (tail.last!.start + min(tail.last!.duration, 1)) - tail.first!.start
                if span <= room { echoed = tail; break }
            }
            guard let first = echoed.first else { continue }
            for source in echoed {
                let start = entry + (source.start - first.start)
                out.append(NoteEvent(pitch: Pitch(midi: source.pitch.midi + shift), start: start,
                                     duration: min(source.duration, 1, next - start - 0.1),
                                     velocity: max(1, Int((Double(source.velocity) * 0.75).rounded()))))
            }
        }
        guard out.count >= 2 else { return nil }
        return Melody(notes: out.sorted { $0.start < $1.start }, lengthInBars: loop)
    }
}
