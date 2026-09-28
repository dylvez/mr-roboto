import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// Starting from an idea: a song with nothing in it but a tempo, a key and a drum machine, and a
// beat written onto that machine's voices. No record, no chop, nothing borrowed.

// MARK: - start_song

public struct StartSongTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var title: String
        public var tempo: Double
        public var key: String
        public var machine: String
    }

    public struct Output: Encodable, Sendable {
        public var song: String
        public var tempo: Double
        public var key: String
        public var machine: String
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "start_song"
    public var purpose: String {
        "Start a song from an idea, with nothing imported: a title, a tempo, a key and a drum machine. An open song that is still "
        + "empty is set up in place; otherwise the open song is saved and a new one is opened. Use this when the user asks for "
        + "something new and names no record or sample — never import a record they did not ask for."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("title", Schema.string("A working title; empty keeps the open song's, or names it for the idea.")),
            ("tempo", Schema.number("Beats per minute.", minimum: 40, maximum: 240)),
            ("key", Schema.string("Like \"D minor\" or \"F# major\"; empty for none yet.")),
            ("machine", Schema.string("The drum machine the beat plays on.", enum: SynthMachine.all.map(\.id))),
        ], required: ["title", "tempo", "key", "machine"])
    }

    public func run(_ input: Input) async throws -> Output {
        let key = input.key.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Key(parsing: input.key)
        if key == nil, !input.key.trimmingCharacters(in: .whitespaces).isEmpty {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.key)\" is not a key I can read.", suggestion: "Say it like \"D minor\" or \"Bb major\", or leave it empty.")
        }
        guard let machine = SynthMachine.preset(id: input.machine) else {
            throw DirectorToolFailure(tool: name, reason: "There is no drum machine called \"\(input.machine)\".",
                                      suggestion: "Use one of: \(SynthMachine.all.map(\.id).joined(separator: ", ")).")
        }
        guard let song = await workspace.startSong(title: input.title, tempo: input.tempo, key: key, machine: machine.id) else {
            throw DirectorToolFailure(tool: name, reason: "The song could not be started here.", suggestion: "Open the app's library first.")
        }
        return Output(song: song.title, tempo: song.tempo, key: song.key?.name ?? "none", machine: machine.name,
                      detail: "\(song.title) is open at \(Int(song.tempo.rounded())) bpm\(song.key.map { " in \($0.name)" } ?? ""), on the \(machine.name). Nothing was imported.")
    }
}

// MARK: - write_groove

public struct WriteGrooveTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var feel: String
        public var bars: Int
        public var swing_percent: Double
        public var rows: [String]
        public var note: String
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var bars: Int
        public var swingPercent: Double
        public var hits: Int
        public var rows: [String]
        public var flags: [String]
        public var played: Bool
        public var detail: String
        enum CodingKeys: String, CodingKey { case version, bars, hits, rows, flags, played, detail; case swingPercent = "swing_percent" }
    }

    let workbench: DirectorWorkbench
    let workspace: any DirectorWorkspace
    public init(workbench: DirectorWorkbench, workspace: any DirectorWorkspace) {
        self.workbench = workbench
        self.workspace = workspace
    }

    public let name = "write_groove"
    public var purpose: String {
        "Write a drum groove from nothing onto the song's drum machine, record it as a groove version and play it. Start from a feel "
        + "by name (list_feels), from rows you write yourself, or from a feel with some voices rewritten. A row is a voice, a colon and "
        + "sixteen characters a bar: x a hit, X an accent, g a ghost, . a rest — \"kick: X..x..x.X..x..x.\". A row shorter than the "
        + "groove repeats. This is the way to make a beat when the user names no record; regroove_chop is only for a sample they chose."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("feel", Schema.string("A feel to start from, by name; empty to write every row yourself.")),
            ("bars", Schema.integer("How many bars. A clave is a two-bar cycle, so Latin feels want an even number.", minimum: 1, maximum: 16)),
            ("swing_percent", Schema.number("Where the off-beat sixteenth lands: 50 straight, 66.7 triplet, 75 the far end; 0 keeps the feel's own.", minimum: 0, maximum: 75)),
            ("rows", Schema.array("Rows that replace or add voices; empty keeps the feel as written.",
                                  of: Schema.string("voice: pattern. Voices: kick, snare, clap, rim, closedHat, openHat, ride, crash, lowTom, midTom, highTom, cowbell, shaker, tambourine, highConga, lowConga, highBongo, lowBongo, claves, woodblock."))),
            ("note", Schema.string("One line for the ledger saying what this beat is, in the user's language.")),
        ], required: ["feel", "bars", "swing_percent", "rows", "note"])
    }

    static let voices = ["kick", "snare", "clap", "rim", "closedHat", "openHat", "ride", "crash", "lowTom", "midTom", "highTom",
                         "cowbell", "shaker", "tambourine", "highConga", "lowConga", "highBongo", "lowBongo", "claves", "woodblock", "perc"]

    /// One row, read. Throws with the row and what is wrong with it.
    static func parse(_ row: String, steps: Int, tool: String) throws -> GroovePattern {
        let parts = row.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let voice = voices.first(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }) else {
            throw DirectorToolFailure(tool: tool, reason: "\"\(row)\" does not start with a voice I know.", suggestion: "Voices: \(voices.joined(separator: ", ")).")
        }
        let cells = parts[1].filter { !$0.isWhitespace && $0 != "|" }
        guard !cells.isEmpty, cells.allSatisfy({ "xXg.-".contains($0) }) else {
            throw DirectorToolFailure(tool: tool, reason: "\"\(row)\" has characters that are not steps.", suggestion: "Use x for a hit, X for an accent, g for a ghost and . for a rest.")
        }
        let tiers: [VelocityTier] = cells.map { $0 == "X" ? .accent : ($0 == "x" ? .normal : ($0 == "g" ? .ghost : .rest)) }
        return GroovePattern(voice: DrumVoice(voice), steps: (0..<steps).map { tiers[$0 % tiers.count] })
    }

    static func text(_ pattern: GroovePattern) -> String {
        "\(pattern.voice.rawValue): " + pattern.steps.map { $0 == .accent ? "X" : ($0 == .normal ? "x" : ($0 == .ghost ? "g" : ".")) }.joined()
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to write a beat into.", suggestion: "Call start_song first.")
        }
        let bars = max(1, min(16, input.bars))
        let steps = 16 * bars
        var patterns: [GroovePattern] = []
        var swing = 0.0
        var source = "written by hand"
        var inFeel: GrooveFeel?
        if !input.feel.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let feel = workbench.engines.feels.feel(named: input.feel) else {
                throw DirectorToolFailure(tool: name, reason: "There is no feel called \"\(input.feel)\".", suggestion: "Call list_feels to see the names, or leave feel empty and write the rows.")
            }
            guard feel.groove.stepsPerBar == 16 else {
                throw DirectorToolFailure(tool: name, reason: "\(feel.name) is not on a sixteenth grid, so it cannot be written this way.", suggestion: "Pick a 4/4 sixteenth feel, or write the rows.")
            }
            patterns = feel.groove.patterns.map { pattern in
                GroovePattern(voice: pattern.voice, steps: (0..<steps).map { pattern.steps.isEmpty ? .rest : pattern.steps[$0 % pattern.steps.count] })
            }
            swing = feel.groove.swing
            source = "from \(feel.name)"
            // The feel's pocket and jitter go with it, on a seed of this groove's own, so the same
            // feel in the next song does not breathe in the same places.
            inFeel = GrooveFeel(name: feel.name, seed: GrooveFeel.freshSeed())
        }
        for row in input.rows {
            let pattern = try Self.parse(row, steps: steps, tool: name)
            patterns.removeAll { $0.voice == pattern.voice }
            patterns.append(pattern)
        }
        guard patterns.contains(where: { $0.steps.contains { $0 != .rest } }) else {
            throw DirectorToolFailure(tool: name, reason: "That groove has no hits in it.", suggestion: "Name a feel, or write at least one row with an x in it.")
        }
        if input.swing_percent >= 50 { swing = Swing(percent: input.swing_percent).factor }
        let order = Self.voices
        patterns.sort { (order.firstIndex(of: $0.voice.rawValue) ?? 99) < (order.firstIndex(of: $1.voice.rawValue) ?? 99) }
        let groove = Groove(stepsPerBar: 16, bars: bars, swing: swing, patterns: patterns, feel: inFeel)

        let version = PartVersion(partID: PartID(), kind: .groove(groove), author: .persona("Beatmaker"), operation: Operation.written, note: input.note)
        guard await workspace.record(version) else {
            throw DirectorToolFailure(tool: name, reason: "The groove could not be recorded into the song.")
        }
        // The Beatmaker reads what was written, in its own numbers, in the rail.
        let observation = GrooveObservation(label: PartLabel.title(of: version), groove: groove,
                                            options: .stored(groove, feels: workbench.engines.feels),
                                            tempo: song.tempo, timeSignature: song.timeSignature)
        let flags = GenreLens.judge(Beatmaker(houseCalls: await workspace.houseBook.calls).read(observation), by: Beatmaker.bible,
                                    in: await workspace.genreLens).filter { !$0.holds }
        for flag in flags { await workspace.speak("Beatmaker", flag.says, detail: flag.rule) }
        let played = await workspace.hear(version)
        let hits = patterns.reduce(0) { $0 + $1.steps.filter { $0 != .rest }.count }
        let percent = (Swing(factor: swing).percent * 10).rounded() / 10
        return Output(version: version.id.description, bars: bars, swingPercent: percent, hits: hits, rows: patterns.map(Self.text),
                      flags: flags.map(\.says), played: played,
                      detail: "\(bars) bar\(bars == 1 ? "" : "s") \(source), \(hits) hits, swing \(percent)%, on the song's drum machine at \(Int(song.tempo.rounded())) bpm. "
                          + (played ? "It is playing." : "It is recorded; it did not play here.") + " Nothing was sampled.")
    }
}
