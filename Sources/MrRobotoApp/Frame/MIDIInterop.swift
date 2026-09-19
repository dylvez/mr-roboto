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

    /// One track per written part — grooves on channel 10, bass lines, melodies, progressions as
    /// block chords — the tempo, the time signature, and the sections as markers on the first track.
    public static func file(for song: Song) -> MIDIFile {
        let beatsPerBar = song.timeSignature.beatsPerBar
        var file = MIDIFile(ticksPerBeat: ticksPerBeat, tempo: song.tempo, beatsPerBar: beatsPerBar, beatUnit: song.timeSignature.beatUnit, tracks: [])
        var markers: [MIDIFile.Marker] = []
        var bar = 0
        for section in song.sections {
            markers.append(.init(tick: file.ticks(beats: Double(bar * beatsPerBar)), text: section.name))
            bar += section.lengthInBars
        }
        for version in song.versions {
            let name = PartLabel.title(of: version)
            switch version.kind {
            case .groove(let groove):
                let ticksPerStep = Double(ticksPerBeat * beatsPerBar) / Double(max(1, groove.stepsPerBar))
                var notes: [MIDIFile.Note] = []
                for pattern in groove.patterns {
                    for (index, tier) in pattern.steps.enumerated() where tier != .rest {
                        notes.append(.init(channel: 9, pitch: DrumMap.note(for: pattern.voice), velocity: tier.velocity,
                                           start: Int((Double(index) * ticksPerStep).rounded()), length: max(1, Int(ticksPerStep / 2))))
                    }
                }
                file.tracks.append(.init(name: name, notes: notes))
            case .bassline(let line):
                file.tracks.append(.init(name: name, notes: line.notes.map { note in
                    .init(channel: 0, pitch: note.pitch.midi, velocity: note.velocity, start: file.ticks(beats: note.start), length: max(1, file.ticks(beats: note.duration)))
                }, program: 33))
            case .melody(let melody):
                file.tracks.append(.init(name: name, notes: melody.notes.map { note in
                    .init(channel: 1, pitch: note.pitch.midi, velocity: note.velocity, start: file.ticks(beats: note.start), length: max(1, file.ticks(beats: note.duration)))
                }, program: 0))
            case .progression(let progression):
                var notes: [MIDIFile.Note] = []
                var beat = 0.0
                for bar in progression.bars {
                    for span in bar.chords {
                        for pitch in Self.pitches(of: span.chord) {
                            notes.append(.init(channel: 2, pitch: pitch, velocity: 80, start: file.ticks(beats: beat), length: max(1, file.ticks(beats: span.beats))))
                        }
                        beat += span.beats
                    }
                }
                file.tracks.append(.init(name: name, notes: notes, program: 4))
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
