import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph

// M6 X10/X11: the song's written parts as a Standard MIDI File, and a file's tracks as parts.

/// The General MIDI drum map this app's voices travel on.
public enum DrumMap {
    public static let notes: [(DrumVoice, Int)] = [
        (.kick, 36), (.snare, 38), (.clap, 39), (.rim, 37), (.closedHat, 42), (.openHat, 46),
        (.ride, 51), (.crash, 49), (.lowTom, 45), (.midTom, 47), (.highTom, 50), (.perc, 75),
    ]
    public static func note(for voice: DrumVoice) -> Int { notes.first { $0.0 == voice }?.1 ?? 75 }
    public static func voice(for note: Int) -> DrumVoice {
        if let exact = notes.first(where: { $0.1 == note }) { return exact.0 }
        switch note {
        case 35: return .kick
        case 40: return .snare
        case 44: return .closedHat
        case 41, 43: return .lowTom
        case 48: return .midTom
        case 52, 55, 57: return .crash
        case 53, 59: return .ride
        default: return .perc
        }
    }
}

public enum MIDIExport {
    public static let ticksPerBeat = 480

    /// The song as it plays: one track per written **part** — grooves on channel 10, bass lines,
    /// melodies, progressions as block chords — the tempo, the time signature, and the sections as
    /// markers on the first track.
    ///
    /// An arranged song is laid out the way the transport lays it out: each section's parts start
    /// on the section's bar and repeat to fill its length. An unarranged one has each part's newest
    /// version once, from bar 1. Either way a part appears once, as what it is now: the file used
    /// to hold every version ever made of everything, each from bar 1 on top of the others, which
    /// was the song's history, not the song.
    public static func file(for song: Song) -> MIDIFile {
        let beatsPerBar = song.timeSignature.beatsPerBar
        var file = MIDIFile(ticksPerBeat: ticksPerBeat, tempo: song.tempo, beatsPerBar: beatsPerBar, beatUnit: song.timeSignature.beatUnit, tracks: [])
        var markers: [MIDIFile.Marker] = []
        var bar = 0
        for section in song.sections {
            markers.append(.init(tick: file.ticks(beats: Double(bar * beatsPerBar)), text: section.name))
            bar += section.lengthInBars
        }

        // Where each part plays: (start bar, bars) spans, in the order the parts were first made.
        var order: [PartID] = []
        var spans: [PartID: [(startBar: Int, bars: Int)]] = [:]
        func place(_ part: PartID, at startBar: Int, bars: Int) {
            if spans[part] == nil { order.append(part) }
            spans[part, default: []].append((startBar, bars))
        }
        if song.sections.contains(where: { !$0.stitch.isEmpty }) {
            var at = 0
            for section in song.sections {
                for lane in section.stitch where song.version(playing: lane) != nil {
                    place(lane.part, at: at, bars: max(1, section.lengthInBars))
                }
                at += max(1, section.lengthInBars)
            }
        } else {
            for part in song.partIDs { place(part, at: 0, bars: 0) }
        }

        for part in order {
            // Graph order rather than `latestVersion`: versions kept in the same millisecond tie
            // on their timestamp, and the graph is the order they were made in.
            guard let version = song.versions.last(where: { $0.partID == part }), let placed = spans[part] else { continue }
            let name = PartLabel.title(of: version)
            switch version.kind {
            case .groove(let groove):
                let ticksPerStep = Double(ticksPerBeat * beatsPerBar) / Double(max(1, groove.stepsPerBar))
                let patternBars = max(1, groove.bars)
                var notes: [MIDIFile.Note] = []
                for span in placed {
                    let repeats = span.bars == 0 ? 1 : Int((Double(span.bars) / Double(patternBars)).rounded(.up))
                    for pass in 0..<repeats {
                        let offset = Double((span.startBar + pass * patternBars) * beatsPerBar * ticksPerBeat)
                        let limit = span.bars == 0 ? Double.infinity : Double((span.startBar + span.bars) * beatsPerBar * ticksPerBeat)
                        for pattern in groove.patterns {
                            for (index, tier) in pattern.steps.enumerated() where tier != .rest {
                                let start = offset + Double(index) * ticksPerStep
                                guard start < limit else { continue }
                                notes.append(.init(channel: 9, pitch: DrumMap.note(for: pattern.voice), velocity: tier.velocity,
                                                   start: Int(start.rounded()), length: max(1, Int(ticksPerStep / 2))))
                            }
                        }
                    }
                }
                file.tracks.append(.init(name: name, notes: notes))
            case .bassline(let line):
                file.tracks.append(.init(name: name, notes: tiled(line.notes, over: placed, beatsPerBar: beatsPerBar, file: file, channel: 0,
                                                            lengthInBars: line.lengthInBars), program: 33))
            case .melody(let melody):
                file.tracks.append(.init(name: name, notes: tiled(melody.notes, over: placed, beatsPerBar: beatsPerBar, file: file, channel: 1,
                                                            lengthInBars: melody.lengthInBars), program: 0))
            case .progression(let progression):
                var events: [NoteEvent] = []
                var beat = 0.0
                for bar in progression.bars {
                    for span in bar.chords {
                        for pitch in Self.pitches(of: span.chord) {
                            events.append(NoteEvent(pitch: Pitch(midi: pitch), start: beat, duration: span.beats, velocity: 80))
                        }
                        beat += span.beats
                    }
                }
                file.tracks.append(.init(name: name, notes: tiled(events, over: placed, beatsPerBar: beatsPerBar, file: file, channel: 2), program: 4))
            default:
                continue
            }
        }
        if !markers.isEmpty {
            if file.tracks.isEmpty { file.tracks.append(.init(name: "Sections", notes: [], markers: markers)) }
            else { file.tracks[0].markers = markers }
        }
        return file
    }

    /// A written line laid over every span it plays in, repeating at its own length until the span
    /// is filled, and cut at the span's end. A span of zero bars — the unarranged song — takes the
    /// line once, whole.
    ///
    /// Its own length is `lengthInBars` when the part states one, exactly as the players cycle it:
    /// a four-bar phrase whose fourth bar is a rest repeats after the rest, not after the third bar.
    /// Without one, the last note's end rounded up to whole bars.
    static func tiled(_ events: [NoteEvent], over spans: [(startBar: Int, bars: Int)], beatsPerBar: Int,
                      file: MIDIFile, channel: Int, lengthInBars: Int? = nil) -> [MIDIFile.Note] {
        guard !events.isEmpty else { return [] }
        let lengthBeats = events.map(\.end).max() ?? 0
        let cycleBars = lengthInBars.map { max(1, $0) }
            ?? max(1, Int((lengthBeats / Double(beatsPerBar)).rounded(.up)))
        var out: [MIDIFile.Note] = []
        for span in spans {
            let repeats = span.bars == 0 ? 1 : Int((Double(span.bars) / Double(cycleBars)).rounded(.up))
            let limit = span.bars == 0 ? Double.infinity : Double((span.startBar + span.bars) * beatsPerBar)
            for pass in 0..<repeats {
                let offset = Double((span.startBar + pass * cycleBars) * beatsPerBar)
                for note in events {
                    let start = offset + note.start
                    guard start < limit else { continue }
                    let duration = min(note.duration, limit - start)
                    out.append(.init(channel: channel, pitch: note.pitch.midi, velocity: note.velocity,
                                     start: file.ticks(beats: start), length: max(1, file.ticks(beats: duration))))
                }
            }
        }
        return out
    }

    /// The chord's pitches around C4.
    static func pitches(of chord: Chord) -> [Int] {
        let root = 60 + chord.root.rawValue
        return chord.quality.intervals.map { root + $0 }
    }
}

public enum MIDIImport {
    /// What a file's tracks became.
    public struct Imported: Sendable {
        public var tempo: Double
        public var parts: [(kind: PartKind, name: String)]
    }

    /// Drum tracks become grooves on a sixteenth grid, monophonic low tracks bass lines, other
    /// monophonic tracks melodies, chordal tracks progressions.
    public static func parts(from file: MIDIFile, key: Key?) -> Imported {
        var out: [(PartKind, String)] = []
        let beatsPerBar = max(1, file.beatsPerBar)
        for track in file.tracks where !track.notes.isEmpty {
            if track.isDrums {
                out.append((.groove(groove(from: track, file: file, beatsPerBar: beatsPerBar)), track.name))
                continue
            }
            let starts = Dictionary(grouping: track.notes, by: \.start)
            let chordal = starts.values.filter { $0.count >= 3 }.count > starts.count / 2
            if chordal {
                out.append((.progression(progression(from: track, file: file, beatsPerBar: beatsPerBar, key: key)), track.name))
                continue
            }
            let events = track.notes.map { note in
                NoteEvent(pitch: Pitch(midi: note.pitch), start: file.beats(ticks: note.start), duration: file.beats(ticks: note.length), velocity: note.velocity)
            }
            let median = track.notes.map(\.pitch).sorted()[track.notes.count / 2]
            let isBass = (track.program.map { (32...39).contains($0) } ?? false) || median < 52
            if isBass {
                out.append((.bassline(Bassline(notes: events, sound: "finger", key: key)), track.name))
            } else {
                out.append((.melody(Melody(notes: events)), track.name))
            }
        }
        return Imported(tempo: file.tempo, parts: out.map { (kind: $0.0, name: $0.1) })
    }

    static func groove(from track: MIDIFile.Track, file: MIDIFile, beatsPerBar: Int) -> Groove {
        let stepsPerBar = 16
        let ticksPerStep = Double(file.ticksPerBeat * beatsPerBar) / Double(stepsPerBar)
        let lastTick = track.notes.map(\.start).max() ?? 0
        let bars = max(1, Int(Double(lastTick) / (ticksPerStep * Double(stepsPerBar))) + 1)
        var patterns: [DrumVoice: [VelocityTier]] = [:]
        for note in track.notes {
            let voice = DrumMap.voice(for: note.pitch)
            let step = Int((Double(note.start) / ticksPerStep).rounded())
            guard step >= 0, step < stepsPerBar * bars else { continue }
            var steps = patterns[voice] ?? [VelocityTier](repeating: .rest, count: stepsPerBar * bars)
            steps[step] = note.velocity <= 50 ? .ghost : (note.velocity >= 110 ? .accent : .normal)
            patterns[voice] = steps
        }
        let ordered = DrumMap.notes.map(\.0).compactMap { voice in patterns[voice].map { GroovePattern(voice: voice, steps: $0) } }
        return Groove(stepsPerBar: stepsPerBar, bars: bars, swing: 0, patterns: ordered)
    }

    static func progression(from track: MIDIFile.Track, file: MIDIFile, beatsPerBar: Int, key: Key?) -> Progression {
        let byStart = Dictionary(grouping: track.notes, by: \.start).sorted { $0.key < $1.key }
        var bars: [ProgressionBar] = []
        var spans: [ChordSpan] = []
        var barBeats = 0.0
        for (index, (tick, notes)) in byStart.enumerated() {
            let pitches = notes.map(\.pitch).sorted()
            guard let lowest = pitches.first else { continue }
            let intervals = Array(Set(pitches.map { ($0 - lowest) % 12 })).sorted()
            let quality = ChordQuality(intervals: intervals) ?? (intervals.contains(3) ? .minor : .major)
            let next = index + 1 < byStart.count ? byStart[index + 1].key : tick + (notes.map(\.length).max() ?? file.ticksPerBeat)
            let beats = max(0.25, file.beats(ticks: next - tick))
            spans.append(ChordSpan(chord: Chord(PitchClass(wrapping: lowest), quality), beats: beats))
            barBeats += beats
            if barBeats >= Double(beatsPerBar) - 0.001 {
                bars.append(ProgressionBar(chords: spans)); spans = []; barBeats = 0
            }
        }
        if !spans.isEmpty { bars.append(ProgressionBar(chords: spans)) }
        return Progression(key: key ?? Key(tonic: NoteName(.c)), bars: bars)
    }
}
