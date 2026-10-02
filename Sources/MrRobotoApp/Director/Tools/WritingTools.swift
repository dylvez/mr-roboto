import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// Writing, appended after `write_groove`: a tune and words written on the Melodist's and the
// Lyricist's behalf and read back by them, the song's own settings, the instrument a part plays
// on, the takes comped bar by bar, and another song opened.
//
// Every parameter is required and plain — an empty string or a zero is "leave it" — so none of
// the six spends the API's optional budget (`DirectorToolboxTests` quotes its refusal), and every
// schema is a constant.

// MARK: - write_melody

/// Writes a tune from a line of notes and records it as the Melodist's, with the Melodist's
/// reading of it riding on the result and its flags said in the rail in its own name.
public struct WriteMelodyTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var notes: String
        public var bars: Int
        public var instrument: String
        public var parent: String
        public var note: String
        /// Which writing of the tune this is, 1 to 3. Nil — a caller from before drafts — is the
        /// last, which is kept as it is.
        public var draft: Int?

        public init(notes: String, bars: Int, instrument: String, parent: String, note: String, draft: Int? = nil) {
            self.notes = notes
            self.bars = bars
            self.instrument = instrument
            self.parent = parent
            self.note = note
            self.draft = draft
        }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var noteCount: Int
        public var bars: Int
        /// Lowest to highest, spelled in the key: "D4–A5, 19 semitones".
        public var range: String
        /// The key the Melodist read it in.
        public var key: String
        /// The chords it was read over, or that there were none.
        public var chords: String
        /// The preset it now plays on, when one was named.
        public var instrument: String?
        /// Every reading the Melodist made, holds and flags alike, in its own words.
        public var readings: [String]
        /// The readings that did not hold.
        public var flags: [String]
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case version, part, bars, range, key, chords, instrument, readings, flags, recorded, detail
            case noteCount = "note_count"
        }
    }

    let workspace: any DirectorWorkspace
    let desk: DraftDesk?

    public init(workspace: any DirectorWorkspace, desk: DraftDesk? = nil) {
        self.workspace = workspace
        self.desk = desk
    }

    /// Every tune is the Melodist's, whoever holds the toolbox: the Director writes it on the
    /// Melodist's behalf, and the Melodist reads it back.
    public static let author = "Melodist"

    /// The draft that is kept whatever the Melodist flags in it: two rewrites, and then the tune
    /// is the user's to judge.
    public static let lastDraft = 3

    public let name = "write_melody"
    public var purpose: String {
        "Write a tune and record it as a melody version signed by the Melodist, who reads it back: range, leaps, steps, "
        + "landing on the chords, a figure that returns. Notes are a line: \"D4 0 1, F4 1 0.5, A4 1.5 1.5\" — a pitch "
        + "with its octave, the beat it starts on (0 is the downbeat of bar 1), and how many beats it lasts. Rests are "
        + "the gaps. Name a parent to rewrite a melody as its next version. A first or second draft that fights the "
        + "chords, or in which nothing comes back, is not kept: what was read comes back, and you write it again. The "
        + "third draft is kept as it is. A draft after one that was kept is that tune's next version."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("notes", Schema.string(
                "The tune, notes separated by commas: pitch with octave (C4 is middle C; F#4, Bb3), start beat from 0, "
                + "length in beats, and optionally a velocity 1 to 127 — \"D4 0 1, F4 1 0.5, A4 1.5 1.5 110\".")),
            ("bars", Schema.integer("How many bars one pass of the tune covers, rests at the end included; 0 rounds the notes up to the bar.",
                                    minimum: 0, maximum: 64)),
            ("instrument", Schema.string("A preset for this tune to play on, or empty to keep the song's.",
                                         enum: [""] + InstrumentVoiceSpec.available.map(\.id))),
            ("parent", Schema.string("A melody version id this rewrites, so it becomes that part's next version; empty for a new part.")),
            ("note", Schema.string("A few words naming the tune for the ledger, in the user's language; empty names it by its range.")),
            ("draft", Schema.integer("Which writing of this tune this is: 1 the first time, 2 and 3 when you write the same tune "
                                     + "again after the Melodist flagged the one before. Another tune starts at 1.", minimum: 1, maximum: 3)),
        ], required: ["notes", "bars", "instrument", "parent", "note", "draft"])
    }

    /// What every refusal of a note shows, so the next call is written right.
    static let format = "Write each note as its pitch with octave, the beat it starts on and how many beats it lasts, "
        + "commas between notes: \"D4 0 1, F4 1 0.5, A4 1.5 1.5\". Beats count from 0, the downbeat of bar 1."

    /// The line, read. Throws naming the note that did not parse and why.
    static func parse(_ text: String, tool: String) throws -> [NoteEvent] {
        let items = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else {
            throw DirectorToolFailure(tool: tool, reason: "There are no notes in that.", suggestion: format)
        }
        var notes: [NoteEvent] = []
        for (index, item) in items.enumerated() {
            func refuse(_ why: String) -> DirectorToolFailure {
                DirectorToolFailure(tool: tool, reason: "Note \(index + 1), \"\(item)\", \(why).", suggestion: format)
            }
            let fields = item.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 3 || fields.count == 4 else {
                throw refuse("is not a pitch, a start and a length")
            }
            guard let pitch = Self.pitch(fields[0]) else { throw refuse("does not start with a pitch like D4 or F#3") }
            guard (0...127).contains(pitch.midi) else { throw refuse("is outside the MIDI range") }
            guard let start = Self.number(fields[1]), start >= 0 else { throw refuse("needs a start beat of 0 or more") }
            guard let length = Self.number(fields[2]), length > 0 else { throw refuse("needs a length of more than 0 beats") }
            var velocity = 100
            if fields.count == 4 {
                guard let value = Int(fields[3]), (1...127).contains(value) else { throw refuse("has a velocity that is not 1 to 127") }
                velocity = value
            }
            notes.append(NoteEvent(pitch: pitch, start: start, duration: length, velocity: velocity))
        }
        return notes.sorted { $0.start < $1.start }
    }

    /// "D4", "F#3", "B♭2", or a bare MIDI number.
    static func pitch(_ text: String) -> Pitch? {
        if let midi = Int(text) { return Pitch(midi: midi) }
        return Pitch(name: text)
    }

    /// "1.5", or a fraction for a triplet: "1/3", "2/3".
    static func number(_ text: String) -> Double? {
        if let value = Double(text), value.isFinite { return value }
        let parts = text.split(separator: "/")
        guard parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom != 0 else { return nil }
        let value = top / bottom
        return value.isFinite ? value : nil
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to write a tune into.",
                                      suggestion: "Call start_song, or open_song for one in the library.")
        }
        let notes = try Self.parse(input.notes, tool: name)
        let beatsPerBar = song.timeSignature.beatsPerBar
        guard (0...64).contains(input.bars) else {
            throw DirectorToolFailure(tool: name, reason: "\(input.bars) bars is not a length a tune can be.",
                                      suggestion: "1 to 64, or 0 to round the notes up to the bar.")
        }
        if input.bars > 0, let late = notes.first(where: { $0.start >= Double(input.bars * beatsPerBar) - 1e-9 }) {
            throw DirectorToolFailure(
                tool: name,
                reason: "A note starts on beat \(Schema.figure(late.start)), past the end of \(input.bars) bar\(input.bars == 1 ? "" : "s") of \(song.timeSignature).",
                suggestion: "Say more bars, or 0 to round the notes up to the bar.")
        }
        let instrument = input.instrument.trimmingCharacters(in: .whitespaces)
        let preset = instrument.isEmpty ? nil : InstrumentVoiceSpec.preset(id: instrument)
        if !instrument.isEmpty, preset == nil {
            throw DirectorToolFailure(tool: name, reason: "There is no instrument called \"\(instrument)\".",
                                      suggestion: "One of: \(InstrumentVoiceSpec.available.map(\.id).joined(separator: ", ")); or empty for the song's.")
        }
        let draft = max(1, input.draft ?? Self.lastDraft)
        var parent = try resolveParent(input.parent, in: song)
        // The next draft of the tune kept a moment ago, when nobody says which tune it rewrites.
        if parent == nil, let before = await desk?.rewritten(by: name, draft: draft), let kept = song.version(before), kept.type == .melody {
            parent = song.latestVersion(of: kept.partID) ?? kept
        }

        let melody = Melody(notes: notes, lengthInBars: input.bars > 0 ? input.bars : nil)
        let key = song.key ?? Guidance.analysis(in: song)?.dominantKey ?? Key.cMajor
        let progression = Guidance.progressions(in: song).last.flatMap { version -> Progression? in
            if case .progression(let p) = version.kind { return p }
            return nil
        }
        let bars = melody.loopBars(beatsPerBar: beatsPerBar)
        let low = notes.map(\.pitch).min()!, high = notes.map(\.pitch).max()!
        let spelling = key.spellingPreference
        let span = high.midi - low.midi
        let range = "\(low.name(preferring: spelling))–\(high.name(preferring: spelling)), \(span) semitone\(span == 1 ? "" : "s")"
        let named = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = named.isEmpty ? "Tune, \(bars) bar\(bars == 1 ? "" : "s"), \(low.name(preferring: spelling))–\(high.name(preferring: spelling))" : named

        let author: Author = .persona(Self.author)
        let version = parent.map { $0.deriving(.melody(melody), by: author, operation: Operation.written, note: note) }
            ?? PartVersion(partID: PartID(), kind: .melody(melody), author: author, operation: Operation.written, note: note)

        let observation = MelodyObservation.of(melody, label: note, key: key, progression: progression, beatsPerBar: beatsPerBar)
        let readings = GenreLens.judge(Melodist().read(observation), by: Melodist.bible, in: await workspace.genreLens)
        let flags = readings.filter { !$0.holds }
        let chords = progression.map { "read over \($0.symbols(preferring: spelling))" } ?? "none stated, so it was read against the key alone"

        // Rewritten before it is handed over: a draft the Melodist flags goes back to be written
        // again, with what was flagged, and is not kept. The band used to keep every draft and
        // say its flags to the user — six tunes in six, each arriving with "nothing comes back".
        let sentBack = flags.filter { Melodist.rewrittenFor.contains($0.rule) }
        if !sentBack.isEmpty, draft < Self.lastDraft {
            await desk?.sentBack(draft: draft, by: name)
            return Output(version: "", part: parent?.partID.description ?? "", noteCount: notes.count, bars: bars,
                          range: range, key: key.name, chords: chords, instrument: nil,
                          readings: readings.map(\.says), flags: flags.map(\.says), recorded: false,
                          detail: "Not kept. Draft \(max(1, draft)) goes back for this: "
                              + sentBack.map(\.says).joined(separator: " ")
                              + " Write it again answering that and call write_melody with draft \(max(1, draft) + 1)"
                              + (parent.map { " and the same parent, \($0.id.description)" } ?? "")
                              + ". Nothing of this draft is in the song, and the user is not told of it.")
        }

        let recorded = await workspace.record(version)
        var playsOn: String?
        if recorded {
            await desk?.kept(version.id, draft: draft, by: name)
            for flag in flags { await workspace.speak(Self.author, flag.says, detail: flag.rule) }
            if let preset {
                await workspace.setInstrument(preset.id, for: version.partID)
                playsOn = preset.name
            }
        }
        var detail = recorded
            ? "\(notes.count) note\(notes.count == 1 ? "" : "s") over \(bars) bar\(bars == 1 ? "" : "s") in \(key.name), signed by the Melodist"
            : "No song would take it, so it was not recorded"
        if recorded {
            detail += parent.map { ", as the next version of \(PartLabel.title(of: $0))." } ?? ", as a new part."
            detail += flags.isEmpty ? " The Melodist has nothing to flag." : " The Melodist flags \(flags.count): its words are in the rail."
            // Said where it is read: the first live run answered a flag with a second tune.
            if !flags.isEmpty, draft < Self.lastDraft {
                detail += " To answer a flag, write it again with parent \(version.id.description) and draft \(draft + 1): "
                    + "that is this tune's next version. With no parent it would be a second tune in the song."
            }
            detail += " Open the Piano roll on \(version.id.description) to see it and play it."
        } else {
            detail += "."
        }
        return Output(version: version.id.description, part: version.partID.description, noteCount: notes.count, bars: bars,
                      range: range, key: key.name, chords: chords, instrument: playsOn,
                      readings: readings.map(\.says), flags: flags.map(\.says), recorded: recorded, detail: detail)
    }

    private func resolveParent(_ id: String, in song: Song) throws -> PartVersion? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let versionID = VersionID(uuidString: trimmed), let found = song.version(versionID) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(trimmed)\" is not a version in this song.",
                                      suggestion: "Take a melody's id from read_song, or leave parent empty for a new part.")
        }
        guard found.type == .melody else {
            throw DirectorToolFailure(tool: name, reason: "\(PartLabel.title(of: found)) is a \(found.type.rawValue), not a melody.",
                                      suggestion: "Name a melody version to rewrite, or leave parent empty.")
        }
        return found
    }
}

// MARK: - write_lyrics

/// Words, written on the Lyricist's behalf and read back by it: the shape of the lines, the rhyme
/// scheme of each stanza, the images against the house's voice — and, when asked, set to a tune.
public struct WriteLyricsTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var text: String
        public var alignTo: String

        enum CodingKeys: String, CodingKey {
            case text
            case alignTo = "align_to"
        }
    }

    public struct Output: Encodable, Sendable {
        public struct Stanza: Encodable, Sendable {
            /// The "[Hook]" written above it, when one was.
            public var label: String?
            public var lines: Int
            /// "ABAB". Nil for a one-line stanza, which has nothing to rhyme with.
            public var scheme: String?
        }
        public var version: String
        public var part: String
        public var lines: Int
        public var stanzas: [Stanza]
        public var syllables: Int
        /// Syllables with a note of the melody under them.
        public var syllablesSet: Int
        /// The melody version the words were set to, when they were.
        public var melody: String?
        public var melodyNotes: Int?
        public var readings: [String]
        public var flags: [String]
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case version, part, lines, stanzas, syllables, melody, readings, flags, recorded, detail
            case syllablesSet = "syllables_set"
            case melodyNotes = "melody_notes"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    /// Every lyric is the Lyricist's, whoever holds the toolbox.
    public static let author = "Lyricist"

    public let name = "write_lyrics"
    public var purpose: String {
        "Write the song's words and record them as a lyric signed by the Lyricist, who reads them back: whether the lines "
        + "share a shape, the rhyme scheme of each stanza, a line longer than a breath, an image this house has worn out. "
        + "A song has one lyric, so new words are the next version of it. align_to sets the syllables to a melody's notes, "
        + "one a note."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("text", Schema.string(
                "The words, one sung line per line, a blank line between stanzas, and a stanza's section written above it "
                + "on its own line: \"[Verse]\", \"[Hook]\".")),
            ("align_to", Schema.string(
                "\"newest\" to set the words to the song's newest melody, a melody version id for another, or empty to leave them unset.")),
        ], required: ["text", "align_to"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to write words into.",
                                      suggestion: "Call start_song, or open_song for one in the library.")
        }
        var lyric = Lyricist.lyric(from: input.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard lyric.lines.contains(where: { !$0.syllables.isEmpty }) else {
            throw DirectorToolFailure(tool: name, reason: "There are no words to sing in that.",
                                      suggestion: "A line per sung line, a blank line between stanzas, \"[Hook]\" above a stanza to name it.")
        }
        let melody = try resolveMelody(input.alignTo, in: song)
        var tune: Melody?
        if let melody, case .melody(let notes) = melody.kind {
            lyric = lyric.aligned(to: notes, version: melody.id)
            tune = notes
        }

        // With the tune it is set to, the Lyricist also reads where the stresses land on the beat.
        let corpus = await workspace.voice
        let observation = LyricObservation.of(lyric, label: "Lyric", corpus: corpus, title: song.title,
                                              melody: tune, beatsPerBar: song.timeSignature.beatsPerBar)
        let readings = GenreLens.judge(Lyricist().read(observation), by: Lyricist.bible, in: await workspace.genreLens)
        let flags = readings.filter { !$0.holds }
        let stanzas = Self.stanzas(of: lyric, schemes: observation.schemes)
        let note = Self.note(for: lyric, lines: observation.lineCount, schemes: observation.schemes)

        // One lyric a song: the Booth and the Lyrics surface read the newest, so new words are its
        // next version rather than a second lyric beside it.
        let author: Author = .persona(Self.author)
        let previous = song.versions.last { $0.type == .lyric }
        let version = previous.map { $0.deriving(.lyric(lyric), by: author, operation: Operation.written, note: note) }
            ?? PartVersion(partID: PartID(), kind: .lyric(lyric), author: author, operation: Operation.written, note: note)
        let recorded = await workspace.record(version)
        if recorded {
            for flag in flags { await workspace.speak(Self.author, flag.says, detail: flag.rule) }
        }

        let noteCount = tune?.notes.count
        var detail = recorded
            ? "\(observation.lineCount) line\(observation.lineCount == 1 ? "" : "s") in \(stanzas.count) stanza\(stanzas.count == 1 ? "" : "s"), signed by the Lyricist"
                + (previous == nil ? ", as the song's lyric." : ", as the next version of the song's lyric.")
            : "No song would take them, so they were not recorded."
        if let melody, let noteCount {
            detail += " Set to \(PartLabel.title(of: melody)): \(lyric.setSyllableCount) of \(lyric.syllableCount) syllables have a note"
            if lyric.syllableCount > noteCount {
                detail += "; the tune has \(noteCount) notes, so the last \(lyric.syllableCount - noteCount) syllables have none."
            } else if noteCount > lyric.syllableCount {
                detail += "; the last \(noteCount - lyric.syllableCount) notes carry no new syllable."
            } else {
                detail += ", one each."
            }
        }
        detail += flags.isEmpty ? " The Lyricist has nothing to flag." : " The Lyricist flags \(flags.count): its words are in the rail."
        return Output(version: version.id.description, part: version.partID.description, lines: observation.lineCount,
                      stanzas: stanzas, syllables: lyric.syllableCount,
                      syllablesSet: melody == nil ? 0 : lyric.setSyllableCount,
                      melody: melody?.id.description, melodyNotes: noteCount,
                      readings: readings.map(\.says), flags: flags.map(\.says), recorded: recorded, detail: detail)
    }

    private func resolveMelody(_ target: String, in song: Song) throws -> PartVersion? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let found: PartVersion
        if trimmed.lowercased() == "newest" {
            // Graph order, not timestamps: two versions kept in the same millisecond tie on time.
            guard let newest = Guidance.melodies(in: song).last else {
                throw DirectorToolFailure(tool: name, reason: "\(song.title) has no melody to set the words to.",
                                          suggestion: "Write one with write_melody first, or leave align_to empty.")
            }
            found = newest
        } else {
            guard let id = VersionID(uuidString: trimmed), let version = song.version(id) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(trimmed)\" is not a version in this song.",
                                          suggestion: "Say \"newest\", a melody's id from read_song, or leave align_to empty.")
            }
            guard version.type == .melody else {
                throw DirectorToolFailure(tool: name, reason: "\(PartLabel.title(of: version)) is a \(version.type.rawValue), not a melody.",
                                          suggestion: "Words are set to a tune: name a melody, or say \"newest\".")
            }
            found = version
        }
        guard case .melody(let tune) = found.kind, !tune.notes.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "\(PartLabel.title(of: found)) has no notes to set words to.",
                                      suggestion: "Write the tune with write_melody first, or leave align_to empty.")
        }
        return found
    }

    /// The stanzas as the Lyricist counts them, each with the section written above it and its
    /// scheme. A one-line stanza has no scheme; the rest take the observation's in order.
    static func stanzas(of lyric: Lyric, schemes: [String]) -> [Output.Stanza] {
        let runs = LyricObservation.stanzas(of: lyric).filter { !$0.isEmpty }
        var next = 0
        var previousEnd = -1
        return runs.map { run in
            let names = (lyric.labels ?? []).filter { $0.line > previousEnd && $0.line <= run[run.count - 1] }.map(\.name)
            previousEnd = run[run.count - 1]
            var scheme: String?
            if run.count >= 2, next < schemes.count {
                scheme = schemes[next]
                next += 1
            }
            return Output.Stanza(label: names.isEmpty ? nil : names.joined(separator: " / "), lines: run.count, scheme: scheme)
        }
    }

    /// The ledger's name for the words: the sections they are for, or the first line.
    static func note(for lyric: Lyric, lines: Int, schemes: [String]) -> String {
        var sections: [String] = []
        for label in lyric.labels ?? [] where !sections.contains(where: { $0.caseInsensitiveCompare(label.name) == .orderedSame }) {
            sections.append(label.name)
        }
        let head: String
        if sections.isEmpty {
            let first = lyric.lines.first { !$0.syllables.isEmpty }?.text ?? "Words"
            head = first.count > 40 ? String(first.prefix(39)) + "…" : first
        } else if sections.count == 1 {
            head = sections[0]
        } else {
            head = sections.dropLast().joined(separator: ", ") + " and " + sections[sections.count - 1]
        }
        let body = "\(lines) line\(lines == 1 ? "" : "s")"
        return schemes.isEmpty ? "\(head), \(body)" : "\(head), \(body) · \(schemes.joined(separator: " / "))"
    }
}

// MARK: - set_song

/// The song's title, artist, tempo, key and meter, each through the frame's own setter.
public struct SetSongTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var title: String
        public var artist: String
        public var tempo: Double
        public var key: String
        public var timeSignature: String
        /// What the song is about, in a sentence; empty keeps it, "none" clears it.
        public var brief: String

        enum CodingKeys: String, CodingKey {
            case title, artist, tempo, key, brief
            case timeSignature = "time_signature"
        }

        public init(title: String, artist: String, tempo: Double, key: String, timeSignature: String, brief: String = "") {
            self.title = title
            self.artist = artist
            self.tempo = tempo
            self.key = key
            self.timeSignature = timeSignature
            self.brief = brief
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            artist = try values.decode(String.self, forKey: .artist)
            tempo = try values.decode(Double.self, forKey: .tempo)
            key = try values.decode(String.self, forKey: .key)
            timeSignature = try values.decode(String.self, forKey: .timeSignature)
            // Absent in every call written before the song's brief could be set here.
            brief = try values.decodeIfPresent(String.self, forKey: .brief) ?? ""
        }
    }

    public struct Output: Encodable, Sendable {
        public struct Refusal: Encodable, Sendable {
            public var field: String
            public var value: String
            public var reason: String
        }
        /// "tempo 120 → 92 bpm", one per setting that moved.
        public var changed: [String]
        /// Settings asked for that were already so.
        public var unchanged: [String]
        public var refused: [Refusal]
        public var title: String
        public var artist: String?
        public var tempo: Double
        public var key: String?
        public var timeSignature: String
        public var brief: String?
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case changed, unchanged, refused, title, artist, tempo, key, brief, detail
            case timeSignature = "time_signature"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_song"
    public var purpose: String {
        "Set the open song's title, artist, tempo, key, meter or brief — any of them, the rest left as they are. Nothing already "
        + "written moves: a key or a meter is what the next part is written to, and a tempo only changes how fast the beats "
        + "go by — sung takes follow it, stretched with their pitch kept. The brief is what the song is about, in one "
        + "sentence of the user's: the Producer holds every part to it and flags a song with none. Write it down when the "
        + "user says what the song is about; do not invent one. Says what changed and what was refused."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("title", Schema.string("The song's new title, or empty to keep it.")),
            ("artist", Schema.string("Who the song is by, or empty to keep it.")),
            ("tempo", Schema.number("Beats per minute, 20 to 300; 0 keeps it.", minimum: 0, maximum: 300)),
            ("key", Schema.string("Like \"D minor\", \"Bb major\", \"F# dorian\" or \"Am\"; \"none\" clears it; empty keeps it.")),
            ("time_signature", Schema.string("Like \"4/4\", \"3/4\", \"6/8\" or \"7/8\"; empty keeps it.")),
            ("brief", Schema.string("What the song is about, in one sentence, three to forty words; \"none\" clears it; empty keeps it.")),
        ], required: ["title", "artist", "tempo", "key", "time_signature", "brief"])
    }

    /// A key as a person or a lead sheet writes it: "D minor", "E♭ major", "F# dorian", "Am".
    static func key(parsing text: String) -> Key? {
        let plain = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
        if let key = Key(parsing: plain) { return key }
        if plain.count >= 2, plain.hasSuffix("m"), let key = Key(parsing: String(plain.dropLast()) + " minor") { return key }
        return nil
    }

    public func run(_ input: Input) async throws -> Output {
        try await apply(input)
    }

    /// On the main actor throughout: the song, the frame's ranges and parsers, and its setters.
    @MainActor
    private func apply(_ input: Input) throws -> Output {
        guard let before = workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to set.",
                                      suggestion: "start_song makes one with a tempo and a key; open_song opens one from the library.")
        }
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = input.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyText = input.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let meterText = input.timeSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        let briefText = input.brief.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty || !artist.isEmpty || input.tempo != 0 || !keyText.isEmpty || !meterText.isEmpty || !briefText.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "Nothing was asked to change.",
                                      suggestion: "Give a title, an artist, a tempo, a key, a time signature or a brief; the rest can be empty or 0.")
        }
        var changed: [String] = []
        var unchanged: [String] = []
        var refused: [Output.Refusal] = []

        if !title.isEmpty {
            if title == before.title { unchanged.append("title") }
            else if workspace.setTitle(title) { changed.append("title \"\(before.title)\" → \"\(title)\"") }
            else { refused.append(.init(field: "title", value: title, reason: "The song would not take that title.")) }
        }
        if !artist.isEmpty {
            if artist == before.artist { unchanged.append("artist") }
            else if workspace.setArtist(artist) { changed.append(before.artist.isEmpty ? "artist \"\(artist)\"" : "artist \"\(before.artist)\" → \"\(artist)\"") }
            else { refused.append(.init(field: "artist", value: artist, reason: "The song would not take that artist.")) }
        }
        if !briefText.isEmpty {
            let words = briefText.split(separator: " ").count
            if ["none", "no brief", "clear"].contains(briefText.lowercased()) {
                if before.brief == nil { unchanged.append("brief") }
                else if workspace.setBrief("") { changed.append("brief cleared") }
            } else if briefText == before.brief {
                unchanged.append("brief")
            } else if words < Self.briefWords.lowerBound || words > Self.briefWords.upperBound {
                refused.append(.init(field: "brief", value: briefText,
                                     reason: words < Self.briefWords.lowerBound
                                         ? "A brief of \(words) word\(words == 1 ? "" : "s") does not say what the song is about; the Producer wants a sentence."
                                         : "A brief of \(words) words is past the Producer's forty: cut it to one sentence."))
            } else if workspace.setBrief(briefText) {
                changed.append("brief \"\(briefText)\"")
            } else {
                refused.append(.init(field: "brief", value: briefText, reason: "The song would not take that brief."))
            }
        }
        if !keyText.isEmpty {
            let clearing = ["none", "no key", "clear"].contains(keyText.lowercased())
            if clearing {
                if before.key == nil { unchanged.append("key") }
                else if workspace.setKey(nil) { changed.append("key \(before.key!.name) → none") }
            } else if let key = Self.key(parsing: keyText) {
                if key == before.key { unchanged.append("key") }
                else if workspace.setKey(key) { changed.append("key \(before.key?.name ?? "none") → \(key.name)") }
                else { refused.append(.init(field: "key", value: keyText, reason: "The song would not take that key.")) }
            } else {
                refused.append(.init(field: "key", value: keyText,
                                     reason: "\"\(keyText)\" is not a key I can read. Say it like \"D minor\", \"Bb major\" or \"F# dorian\"."))
            }
        }
        if !meterText.isEmpty {
            if let meter = AppState.timeSignature(parsing: meterText) {
                if meter == before.timeSignature { unchanged.append("time signature") }
                else if workspace.setTimeSignature(meter) { changed.append("meter \(before.timeSignature) → \(meter)") }
                else { refused.append(.init(field: "time_signature", value: meterText, reason: "The song would not take \(meter).")) }
            } else {
                refused.append(.init(field: "time_signature", value: meterText,
                                     reason: "\"\(meterText)\" is not a meter. Two numbers over a slash, the lower one 1, 2, 4, 8 or 16: \"4/4\", \"6/8\", \"7/8\"."))
            }
        }
        if input.tempo != 0 {
            let range = AppState.tempoRange
            if !input.tempo.isFinite || !range.contains(input.tempo) {
                refused.append(.init(field: "tempo", value: Schema.figure(input.tempo),
                                     reason: "\(Schema.figure(input.tempo)) bpm is outside \(Schema.figure(range.lowerBound)) to \(Schema.figure(range.upperBound))."))
            } else if abs(input.tempo - before.tempo) <= 0.001 {
                unchanged.append("tempo")
            } else if workspace.setTempo(input.tempo) {
                changed.append("tempo \(Schema.figure(before.tempo)) → \(Schema.figure(input.tempo)) bpm")
            } else {
                refused.append(.init(field: "tempo", value: Schema.figure(input.tempo), reason: "The song would not take that tempo."))
            }
        }

        let after = workspace.song ?? before
        var sentences: [String] = []
        if !changed.isEmpty { sentences.append("Changed: " + changed.joined(separator: "; ") + ".") }
        if !refused.isEmpty { sentences.append("Refused: " + refused.map(\.reason).joined(separator: " ")) }
        if changed.isEmpty, refused.isEmpty { sentences.append("Nothing moved: the song already was that.") }
        if changed.contains(where: { $0.hasPrefix("key") || $0.hasPrefix("meter") }) {
            sentences.append("Nothing already written moved; the next part is written to it.")
        }
        if changed.contains(where: { $0.hasPrefix("tempo") }) {
            // What was sung is audio: it follows the tempo stretched, and says so, since a stretch
            // far from where it was sung is something to hear before keeping.
            let sung = (Guidance.takes(in: after) + Guidance.comps(in: after)).compactMap(Guidance.audio(of:))
            let stretched = sung.filter { $0.stretch(in: after) != 1 }
            let unknown = sung.filter { ($0.take?.tempo ?? $0.comp?.tempo) == nil }
            if !stretched.isEmpty {
                let far = stretched.map { abs($0.stretch(in: after) - 1) }.max() ?? 0
                let what = stretched.count == 1 ? "The sung take plays" : "The \(stretched.count) sung takes and comps play"
                sentences.append(what + " stretched to \(Schema.figure(after.tempo)) bpm, pitch kept"
                    + (far > 0.15 ? String(format: " — up to %.0f%% from the tempo they were sung at, so listen before keeping more.", far * 100) : "."))
            }
            if !unknown.isEmpty {
                sentences.append(unknown.count == 1 ? "One take was sung before tempos were kept and is not stretched: it may not sit on the new beat."
                    : "\(unknown.count) takes were sung before tempos were kept and are not stretched: they may not sit on the new beat.")
            }
            if let record = (Guidance.stems(in: after).first ?? Guidance.take(in: after)),
               SongPlayback.recordStretch(of: record, in: after) != 1 {
                sentences.append("The record plays stretched to it too, as its chops do.")
            }
        }
        return Output(changed: changed, unchanged: unchanged, refused: refused, title: after.title,
                      artist: after.artist.isEmpty ? nil : after.artist, tempo: after.tempo, key: after.key?.name,
                      timeSignature: "\(after.timeSignature)", brief: after.brief, detail: sentences.joined(separator: " "))
    }

    /// The Producer's own limits on a brief: three words is one, past forty is not a sentence.
    static let briefWords = 3...40
}

// MARK: - set_instrument

/// The preset a part plays on — the chords on a pad, the tune on a lead — or the song's own.
public struct SetInstrumentTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var instrument: String
        public var part: String
    }

    public struct Output: Encodable, Sendable {
        public var instrument: String
        public var name: String
        public var family: String
        /// What was set: a part by its name, or the song's own.
        public var target: String
        /// Every pitched part that now plays on it.
        public var plays: [String]
        public var changed: Bool
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_instrument"
    public var purpose: String {
        "Put a part on an instrument — the chords on a pad, the tune on a lead — or set the song's own, which every chord "
        + "and melody part that names none plays on. Recorded as a sound version, so it can be gone back to. Bass lines and "
        + "grooves have their own sounds and are not set here."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("instrument", Schema.string("The preset.", enum: InstrumentVoiceSpec.available.map(\.id))),
            ("part", Schema.string("A melody or progression, by version or part id from read_song; empty sets the song's own.")),
        ], required: ["instrument", "part"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song or open_song first.")
        }
        guard let spec = InstrumentVoiceSpec.preset(id: input.instrument.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw DirectorToolFailure(tool: name, reason: "There is no instrument called \"\(input.instrument)\".",
                                      suggestion: "One of: " + InstrumentVoiceSpec.available.map { "\($0.id) (\($0.name))" }.joined(separator: ", ") + ".")
        }
        let part = try resolvePart(input.part, in: song)
        let target = part.flatMap { id in song.versions.last { $0.partID == id } }.map(PartLabel.title(of:)) ?? "the song"
        let changed = await workspace.setInstrument(spec.id, for: part)
        let now = await workspace.song ?? song
        guard SongPlayback.instrumentID(for: part, in: now) == spec.id else {
            throw DirectorToolFailure(tool: name, reason: "The song would not take \(spec.name) for \(target).")
        }
        let plays = Self.pitchedParts(in: now)
            .filter { SongPlayback.instrumentID(for: $0.partID, in: now) == spec.id }
            .map(PartLabel.title(of:))
        var detail = changed ? "\(target == "the song" ? "The song" : target) plays on the \(spec.name) now"
                             : "\(target == "the song" ? "The song" : target) was already on the \(spec.name)"
        detail += plays.isEmpty ? "; no chords or melody are written yet, so the next one will." : ": " + plays.joined(separator: ", ") + "."
        return Output(instrument: spec.id, name: spec.name, family: spec.family, target: target, plays: plays,
                      changed: changed, detail: detail)
    }

    /// The newest version of every chord and melody part, in the order the parts began.
    static func pitchedParts(in song: Song) -> [PartVersion] {
        song.partIDs.compactMap { id in song.versions.last { $0.partID == id } }
            .filter { $0.type == .melody || $0.type == .progression }
    }

    private func resolvePart(_ text: String, in song: Song) throws -> PartID? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let uuid = UUID(uuidString: trimmed) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(trimmed)\" is not an id.",
                                      suggestion: "A version or part id from read_song, or empty for the song's own.")
        }
        let newest: PartVersion
        if let version = song.version(VersionID(rawValue: uuid)) {
            newest = song.versions.last { $0.partID == version.partID } ?? version
        } else if let version = song.versions.last(where: { $0.partID == PartID(rawValue: uuid) }) {
            newest = version
        } else {
            throw DirectorToolFailure(tool: name, reason: "This song has no version or part \(trimmed).",
                                      suggestion: "Call read_song to see what it holds.")
        }
        guard newest.type == .melody || newest.type == .progression else {
            throw DirectorToolFailure(tool: name, reason: "\(PartLabel.title(of: newest)) is a \(newest.type.rawValue); only chords and melodies play on these.",
                                      suggestion: "A bass line plays on its own bass sound and a groove on the drum machine.")
        }
        return newest.partID
    }
}

// MARK: - comp_takes

/// Which take each bar of a comp comes from, decided from what the critics found. Pure: bars and
/// counts in, choices out, so the rule can be read and tested apart from any audio.
public enum CompPlanner {

    /// One take, as the planner weighs it.
    public struct Candidate: Sendable, Equatable {
        public var take: VersionID
        /// How many flags the critics raised on each song bar (0-based).
        public var flags: [Int: Int]
        /// Bars the take sang a note in.
        public var sung: Set<Int>
        /// Bars the take's audio covers at least half of.
        public var covers: Set<Int>

        public init(take: VersionID, flags: [Int: Int], sung: Set<Int>, covers: Set<Int>) {
            self.take = take
            self.flags = flags
            self.sung = sung
            self.covers = covers
        }
    }

    /// For each bar, the take the critics flag least on it. Candidates come oldest pass first, and
    /// a tie goes to the later pass — the one the Takes surface plays by default.
    ///
    /// A take is only in the running for a bar it sang in. A take that fell silent where another
    /// sang has no flags there because it has no notes there, and a comp that picked the silence
    /// would be clean and empty; only a bar nobody sang falls back to the takes that cover it.
    public static func choose(bars: Range<Int>, from candidates: [Candidate]) -> [Int: VersionID] {
        var choices: [Int: VersionID] = [:]
        for bar in bars {
            let sang = candidates.filter { $0.sung.contains(bar) }
            let covering = candidates.filter { $0.covers.contains(bar) }
            let pool = !sang.isEmpty ? sang : (!covering.isEmpty ? covering : candidates)
            let best = pool.enumerated().min { a, b in
                let fa = a.element.flags[bar] ?? 0, fb = b.element.flags[bar] ?? 0
                return fa != fb ? fa < fb : a.offset > b.offset
            }
            if let best { choices[bar] = best.element.take }
        }
        return choices
    }

    /// The choices as a plan: runs of bars from the same take, merged, as the Takes surface does.
    public static func plan(_ choices: [Int: VersionID], bars: Range<Int>) -> CompPlan {
        var spans: [CompPlan.Span] = []
        for bar in bars {
            guard let take = choices[bar] else { continue }
            if var last = spans.last, last.take == take, last.endBar == bar {
                last.endBar = bar + 1
                spans[spans.count - 1] = last
            } else {
                spans.append(.init(startBar: bar, endBar: bar + 1, take: take))
            }
        }
        return CompPlan(spans: spans)
    }

    /// "bars 1–2 Take 3", "bar 3 Take 1": song bars as a person counts them.
    public static func describe(_ plan: CompPlan, name: (VersionID) -> String) -> [String] {
        plan.spans.map { span in
            let who = name(span.take)
            return span.endBar - span.startBar == 1 ? "bar \(span.startBar + 1) \(who)" : "bars \(span.startBar + 1)–\(span.endBar) \(who)"
        }
    }
}

/// Comps a part's takes bar by bar from the critics' flags, renders it as the Takes surface does,
/// and records it with every take it drew from as a parent. Nothing is done to a take.
public struct CompTakesTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var takes: String
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var section: String?
        /// The bars the comp spans, as a person counts them.
        public var bars: String
        public var plan: [String]
        /// Each take weighed, with how many flags it carried across the bars.
        public var takes: [String]
        public var flagsAvoided: [String]
        public var flagsKept: [String]
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case version, part, section, bars, plan, takes, recorded, detail
            case flagsAvoided = "flags_avoided"
            case flagsKept = "flags_kept"
        }
    }

    let workspace: any DirectorWorkspace
    let board: CriticBoard
    /// Who signs the comp: the Director, or the persona a scoped session speaks as. Never the
    /// user — the user sang the takes; the band chose between them.
    let acting: String

    public init(workspace: any DirectorWorkspace, board: CriticBoard = .standard,
                acting: String = CreatePartVersionTool.director) {
        self.workspace = workspace
        self.board = board
        self.acting = acting
    }

    public let name = "comp_takes"
    public var purpose: String {
        "Comp the takes of one part: for every bar, the take the critics flag least there (a tie goes to the later pass), "
        + "rendered with the seams crossfaded and recorded as a comp with the takes as its parents. Returns the plan and the "
        + "flags it avoided. Needs two takes or more with their audio; no take is changed."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("takes", Schema.string(
                "Which takes: a section's name (\"Verse\"), a take's or a comp's version id, or a part id; empty for the part of the newest take.")),
        ], required: ["takes"])
    }

    /// How many flags to count a take at most. The critics' own limit is the four worst, which is
    /// right for a Check and wrong for choosing: a bar's fifth flag is still a flag.
    static let everyFlag = 10_000

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Open a song first.")
        }
        let (all, sectionName) = try Self.takes(for: input.takes, in: song, tool: name)
        let label = sectionName.map { "the \($0)" } ?? "that part"
        guard all.count >= 2 else {
            throw DirectorToolFailure(tool: name, reason: "There is only one take of \(label); a comp needs two or more.",
                                      suggestion: "The user sings another in the Booth: open_surface on Booth with nothing bound.")
        }
        // Oldest pass first, so a tie goes to the later one.
        let ordered = all.enumerated().sorted { a, b in
            let pa = Guidance.audio(of: a.element)?.take?.pass ?? 0, pb = Guidance.audio(of: b.element)?.take?.pass ?? 0
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        var audio: [VersionID: Comp.TakeAudio] = [:]
        var missing: [String] = []
        for take in ordered {
            if let placed = await workspace.takeAudio(of: take), placed.sampleRate > 0, !(placed.planar.first?.isEmpty ?? true) {
                audio[take.id] = placed
            } else {
                missing.append(PartLabel.title(of: take))
            }
        }
        let takes = ordered.filter { audio[$0.id] != nil }
        guard takes.count >= 2 else {
            throw DirectorToolFailure(
                tool: name,
                reason: "The audio of \(missing.joined(separator: ", ")) could not be read, which leaves \(takes.count) take\(takes.count == 1 ? "" : "s") of \(label) to comp.",
                suggestion: "Nothing was comped. A take whose file is missing has to be sung again.")
        }

        let clock = await workspace.clock
        let bars = Self.bars(of: takes, audio: audio, song: song, clock: clock)
        var findings: [VersionID: [Finding]] = [:]
        var candidates: [CompPlanner.Candidate] = []
        for take in takes {
            let placed = audio[take.id]!
            let analysis = TakeAnalysis.of(placed.planar, sampleRate: placed.sampleRate, alignmentSeconds: placed.alignmentSeconds,
                                           key: song.key, clock: clock, label: PartLabel.title(of: take))
            let found = board.review(TakeReview(analysis: analysis, limit: Self.everyFlag)).filter { $0.locus.bar.map(bars.contains) ?? false }
            findings[take.id] = found
            var perBar: [Int: Int] = [:]
            for finding in found { if let bar = finding.locus.bar { perBar[bar, default: 0] += 1 } }
            candidates.append(CompPlanner.Candidate(take: take.id, flags: perBar, sung: Set(analysis.notes.map(\.bar)),
                                                    covers: Self.covered(bars, by: placed, clock: clock)))
        }
        let choices = CompPlanner.choose(bars: bars, from: candidates)
        let plan = CompPlanner.plan(choices, bars: bars)
        let used = takes.filter { plan.takes.contains($0.id) }
        let titles = Dictionary(uniqueKeysWithValues: takes.map { ($0.id, PartLabel.title(of: $0)) })
        let lines = CompPlanner.describe(plan, name: { titles[$0] ?? "?" })

        let rendered: Comp.Rendered
        do {
            rendered = try Comp.render(plan, takes: audio.filter { plan.takes.contains($0.key) }, clock: clock)
        } catch {
            throw DirectorToolFailure(tool: name, reason: "The comp could not be rendered: \(error)",
                                      suggestion: "Nothing was comped; the takes are as they were.")
        }
        // Seconds of work have passed: a comp of this song's takes is not kept into another song.
        guard await workspace.song?.id == song.id else {
            throw DirectorToolFailure(tool: name, reason: "The song changed while the comp was being made.",
                                      suggestion: "Nothing was comped. Open \(song.title) and comp again.")
        }
        guard let media = await workspace.keepAudio(rendered.planar, sampleRate: rendered.sampleRate) else {
            throw DirectorToolFailure(tool: name, reason: "There is nowhere to keep the comp's audio.",
                                      suggestion: "Nothing was comped. Save the song into a library first.")
        }
        let duration = Double(rendered.planar.first?.count ?? 0) / rendered.sampleRate
        let comp = Audio(media: media, role: .take, sampleRate: rendered.sampleRate, channelCount: rendered.planar.count,
                         duration: duration, alignmentOffset: rendered.alignmentSeconds,
                         comp: BoothAdapter.placed(plan, takes: used, in: song))
        let note = "Comp of \(used.count) take\(used.count == 1 ? "" : "s"): " + lines.joined(separator: ", ")
        let version = PartVersion(partID: takes[0].partID, kind: .audio(comp), author: .persona(acting),
                                  parents: used.map(\.id), operation: Operation.comped, note: note)
        let recorded = await workspace.record(version)

        var avoided: [String] = []
        var kept: [String] = []
        for take in takes {
            for finding in findings[take.id] ?? [] {
                guard let bar = finding.locus.bar else { continue }
                let line = "\(titles[take.id] ?? "?"): \(finding.headline)"
                if choices[bar] == take.id { kept.append(line) } else { avoided.append(line) }
            }
        }
        let weighed = takes.map { take -> String in
            let count = findings[take.id]?.count ?? 0
            return "\(titles[take.id] ?? "?"): \(count) flag\(count == 1 ? "" : "s")"
        }
        let span = bars.count == 1 ? "bar \(bars.lowerBound + 1)" : "bars \(bars.lowerBound + 1)–\(bars.upperBound)"
        if recorded {
            await workspace.note("Comped \(label): " + lines.joined(separator: ", "),
                                 detail: "\(avoided.count) flag\(avoided.count == 1 ? "" : "s") left out, \(kept.count) kept. Every take is still there.")
        }
        var detail = recorded
            ? "The comp of \(label) over \(span) is recorded as \(PartLabel.title(of: version)), with \(used.count) take\(used.count == 1 ? "" : "s") as its parents"
            : "The comp was rendered but no song would take it"
        if avoided.isEmpty, kept.isEmpty {
            detail += "; no take had a flag on these bars."
        } else {
            detail += "; it leaves out \(avoided.count) flag\(avoided.count == 1 ? "" : "s") and keeps \(kept.count)."
        }
        if !missing.isEmpty { detail += " \(missing.joined(separator: ", ")) had no audio and was left out." }
        detail += " No take was changed."
        return Output(version: version.id.description, part: version.partID.description, section: sectionName, bars: span,
                      plan: lines, takes: weighed, flagsAvoided: avoided, flagsKept: kept, recorded: recorded, detail: detail)
    }

    /// The takes of one part, in graph order, and the section they were sung to.
    static func takes(for query: String, in song: Song, tool: String) throws -> ([PartVersion], String?) {
        let all = Guidance.takes(in: song)
        guard let newest = all.last else {
            throw DirectorToolFailure(tool: tool, reason: "\(song.title) has no takes yet.",
                                      suggestion: "The user sings them in the Booth: open_surface on Booth with nothing bound.")
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let part: PartID
        if trimmed.isEmpty {
            part = newest.partID
        } else if let uuid = UUID(uuidString: trimmed) {
            if let version = song.version(VersionID(rawValue: uuid)) {
                guard let audio = Guidance.audio(of: version), audio.take != nil || audio.comp != nil else {
                    throw DirectorToolFailure(tool: tool, reason: "\(PartLabel.title(of: version)) is not a take.",
                                              suggestion: "Name a take or a comp from read_song, or a section by name.")
                }
                part = version.partID
            } else if all.contains(where: { $0.partID.rawValue == uuid }) {
                part = PartID(rawValue: uuid)
            } else {
                throw DirectorToolFailure(tool: tool, reason: "This song has no take or part \(trimmed).",
                                          suggestion: "Name a section, or pass an empty string for the newest take's part.")
            }
        } else {
            let sections = song.sections.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            let sung = Set(all.compactMap { Guidance.audio(of: $0)?.take?.section })
            guard !sections.isEmpty else {
                var names: [String] = []
                for section in song.sections where sung.contains(section.id) && !names.contains(section.name) { names.append(section.name) }
                throw DirectorToolFailure(tool: tool, reason: "\(song.title) has no section called \"\(trimmed)\".",
                                          suggestion: names.isEmpty ? "Pass an empty string for the newest take's part."
                                                                    : "Takes were sung to: \(names.joined(separator: ", ")).")
            }
            let ids = Set(sections.map(\.id))
            guard let latest = all.last(where: { Guidance.audio(of: $0)?.take?.section.map(ids.contains) ?? false }) else {
                throw DirectorToolFailure(tool: tool, reason: "Nothing has been sung to the \(sections[0].name) yet; a comp needs two takes.",
                                          suggestion: "The user sings it in the Booth: open_surface on Booth with nothing bound.")
            }
            part = latest.partID
        }
        let takes = all.filter { $0.partID == part }
        let section = takes.compactMap { Guidance.audio(of: $0)?.take?.section }.first
            .flatMap { id in song.sections.first { $0.id == id }?.name }
        return (takes, section)
    }

    /// The bars the takes span: the section they were sung to, or, sung to the whole song, from the
    /// first one's first bar to where the last one's audio ends. The Takes surface draws the same.
    static func bars(of takes: [PartVersion], audio: [VersionID: Comp.TakeAudio], song: Song, clock: TransportClock) -> Range<Int> {
        if let section = takes.compactMap({ Guidance.audio(of: $0)?.take?.section }).first,
           let index = song.sections.firstIndex(where: { $0.id == section }) {
            let start = song.sections.prefix(index).map(\.lengthInBars).reduce(0, +)
            return start..<(start + song.sections[index].lengthInBars)
        }
        let first = takes.compactMap { Guidance.audio(of: $0)?.take?.startBar }.min() ?? 0
        let last = takes.compactMap { take -> Int? in
            guard let placed = audio[take.id], placed.sampleRate > 0 else { return nil }
            let end = placed.alignmentSeconds + Double(placed.planar.first?.count ?? 0) / placed.sampleRate
            return Int((end / clock.secondsPerBar).rounded(.up))
        }.max() ?? first + 1
        return first..<max(first + 1, last)
    }

    /// The bars a take's audio covers at least half of.
    static func covered(_ bars: Range<Int>, by placed: Comp.TakeAudio, clock: TransportClock) -> Set<Int> {
        guard placed.sampleRate > 0 else { return [] }
        let start = placed.alignmentSeconds
        let end = start + Double(placed.planar.first?.count ?? 0) / placed.sampleRate
        return Set(bars.filter { bar in
            let from = clock.seconds(forBar: bar), to = clock.seconds(forBar: bar + 1)
            return min(end, to) - max(start, from) >= (to - from) / 2
        })
    }
}

// MARK: - open_song

/// Another song from the library, by its title, opened and read.
public struct OpenSongTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var title: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "open_song"
    public var purpose: String {
        "Open another song from the library by its title — any case, and the closest title when only one is close — keeping "
        + "the open one first. Returns the song as read_song reads it. An ambiguous or unknown title is refused with the "
        + "candidates."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("title", Schema.string("The song's title as read_library lists it, or its id when two share a title.")),
        ], required: ["title"])
    }

    /// What a title search found.
    enum Match: Equatable {
        case one(SongID)
        case several([SongID])
        case none
    }

    /// Lowercased, accents and punctuation gone, spaces collapsed: "Night Bus (Demo)" → "night bus demo".
    static func normalised(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let kept = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// An id; else the exact title; else the one title containing it (or contained in it); else the
    /// one title clearly closest by spelling. Two equally good answers are never guessed between.
    static func match(_ query: String, in songs: [(id: SongID, title: String)]) -> Match {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = SongID(uuidString: trimmed), songs.contains(where: { $0.id == id }) { return .one(id) }
        let wanted = normalised(trimmed)
        guard !wanted.isEmpty else { return .none }
        let titled = songs.map { (id: $0.id, title: normalised($0.title)) }

        func decide(_ found: [SongID]) -> Match? {
            switch found.count {
            case 0: return nil
            case 1: return .one(found[0])
            default: return .several(found)
            }
        }
        if let exact = decide(titled.filter { $0.title == wanted }.map(\.id)) { return exact }
        if let within = decide(titled.filter { containsWords($0.title, wanted) || containsWords(wanted, $0.title) }.map(\.id)) {
            return within
        }
        let scored = titled.map { (id: $0.id, score: similarity($0.title, wanted)) }
            .filter { $0.score >= 0.6 }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return .none }
        if scored.count == 1 || best.score - scored[1].score >= 0.1 { return .one(best.id) }
        return .several(scored.filter { best.score - $0.score < 0.1 }.map(\.id))
    }

    /// Whether `needle`'s words appear together, whole, in `haystack`: "arrival" in "arrival demo",
    /// never "go" in "good morning".
    static func containsWords(_ haystack: String, _ needle: String) -> Bool {
        let h = haystack.split(separator: " "), n = needle.split(separator: " ")
        guard !n.isEmpty, n.count <= h.count else { return false }
        return (0...(h.count - n.count)).contains { Array(h[$0..<($0 + n.count)]) == n }
    }

    /// 1 − edit distance over the longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    public func run(_ input: Input) async throws -> ReadSongTool.Output {
        let library = await workspace.library
        let open = await workspace.song
        // The open song as it is now, not as it was last saved: a title set a moment ago counts.
        var songs = library.songs.map { (id: $0.id, title: $0.title) }
        if let open {
            if let index = songs.firstIndex(where: { $0.id == open.id }) { songs[index].title = open.title }
            else { songs.append((open.id, open.title)) }
        }
        guard !songs.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "The library has no songs yet.", suggestion: "start_song makes one.")
        }
        let titles = Dictionary(songs.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let listed = songs.prefix(12).map { "\"\($0.title)\"" }.joined(separator: ", ") + (songs.count > 12 ? " and \(songs.count - 12) more" : "")
        switch Self.match(input.title, in: songs) {
        case .none:
            throw DirectorToolFailure(tool: name, reason: "No song in the library is called \"\(input.title)\".",
                                      suggestion: "The library has \(listed).")
        case .several(let ids):
            let named = ids.map { id in "\"\(titles[id] ?? "?")\" (\(id.description))" }.joined(separator: ", ")
            throw DirectorToolFailure(tool: name, reason: "\"\(input.title)\" could be any of \(ids.count) songs: \(named).",
                                      suggestion: "Say the whole title, or the id when two share one.")
        case .one(let id):
            if open?.id == id {
                var read = try await ReadSongTool(workspace: workspace).run(.init())
                read.note = "\(open?.title ?? "It") was already open."
                return read
            }
            guard await workspace.openSong(id) != nil else {
                throw DirectorToolFailure(tool: name, reason: "\(titles[id] ?? "That song") could not be opened.",
                                          suggestion: "Call read_library to see what the library holds now.")
            }
            var read = try await ReadSongTool(workspace: workspace).run(.init())
            read.note = "Opened \(read.title ?? titles[id] ?? "it")." + (open.map { " \($0.title) was kept first." } ?? "")
                + " The versions below are this song's; ids from the song that was open mean nothing here."
            return read
        }
    }
}
