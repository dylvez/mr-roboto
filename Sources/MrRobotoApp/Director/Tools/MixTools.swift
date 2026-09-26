import Foundation
import MusicTheory
import Performance
import SongGraph

// M6's three, appended after `read_take`: the mix read, one strip moved, the master set.

/// The strip a tool names: by label (case-insensitive) or by part id.
private func findStrip(_ named: String, in strips: [(part: PartID, label: String)]) -> (part: PartID, label: String)? {
    if let byLabel = strips.first(where: { $0.label.caseInsensitiveCompare(named) == .orderedSame }) { return byLabel }
    if let byPrefix = strips.first(where: { $0.label.lowercased().hasPrefix(named.lowercased()) }) { return byPrefix }
    return strips.first { $0.part.description == named }
}

// MARK: - read_mix

/// The strips, the master, the last bounce's readings and the masking pairs.
public struct ReadMixTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// A section by name, or empty for the first (or the whole song when not arranged).
        public var section: String
    }

    public struct Output: Encodable, Sendable {
        public struct StripEntry: Encodable, Sendable {
            public var part: String
            public var label: String
            public var gainDB: Double
            public var pan: Double
            public var muted: Bool
            public var soloed: Bool
            public var eq: [[String: Double]]
            public var sendDB: Double?
            enum CodingKeys: String, CodingKey { case part, label, pan, muted, soloed, eq; case gainDB = "gain_db"; case sendDB = "send_db" }
        }
        public struct MasterEntry: Encodable, Sendable {
            public var gainDB: Double
            public var ceilingDBTP: Double
            public var targetLUFS: Double
            /// How the song ends: a fade over its last this-many bars, or nil — it stops on its last bar.
            public var fadeOutBars: Int? = nil
            enum CodingKeys: String, CodingKey { case gainDB = "gain_db"; case ceilingDBTP = "ceiling_dbtp"; case targetLUFS = "target_lufs"; case fadeOutBars = "fade_out_bars" }
        }
        public struct Reading: Encodable, Sendable {
            public var integratedLUFS: Double
            public var truePeakDBTP: Double?
            public var crestDB: Double
            public var tiltDB: Double
            public var bandwidthHz: Double
            enum CodingKeys: String, CodingKey { case integratedLUFS = "integrated_lufs"; case truePeakDBTP = "true_peak_dbtp"; case crestDB = "crest_db"; case tiltDB = "tilt_db"; case bandwidthHz = "bandwidth_hz" }
        }
        public struct Pair: Encodable, Sendable {
            public var a: String
            public var b: String
            public var band: String
            public var gapDB: Double
            public var louder: String
            enum CodingKeys: String, CodingKey { case a, b, band, louder; case gapDB = "gap_db" }
        }
        public struct Flag: Encodable, Sendable {
            public var critic: String
            public var headline: String
            public var offered: String
            public var otherwise: String
        }
        public var mixVersion: String?
        public var strips: [StripEntry]
        public var master: MasterEntry
        public var reading: Reading?
        public var masking: [Pair]
        public var flags: [Flag]
        public var engineer: [String]
        public var detail: String
        enum CodingKeys: String, CodingKey { case strips, master, reading, masking, flags, engineer, detail; case mixVersion = "mix_version" }
    }

    let workspace: any DirectorWorkspace
    let board: CriticBoard

    public init(workspace: any DirectorWorkspace, board: CriticBoard = .standard) {
        self.workspace = workspace
        self.board = board
    }

    public let name = "read_mix"
    public var purpose: String {
        "Read the mix: every strip's level, pan, EQ and send, the master's gain, ceiling and target, and the song bounced "
        + "through it — integrated LUFS, true peak, crest, tilt — with every strip bounced apart for the masking pairs and the "
        + "Engineer's flags. Nothing is changed. Read before a move; read again after."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("section", Schema.string("A section by name to bounce, or empty for the first.")),
        ], required: ["section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Open a song first.")
        }
        let plan = await workspace.playback
        let mix = plan.mix ?? .unity
        let strips = await MixReader.strips(of: plan, song: song)
        let section = input.section.isEmpty ? song.sections.first?.id : song.sections.first { $0.name.caseInsensitiveCompare(input.section) == .orderedSame }?.id
        var reading: Output.Reading?
        var pairs: [Output.Pair] = []
        var flags: [Output.Flag] = []
        var engineer: [String] = []
        var detail = "\(strips.count) strip\(strips.count == 1 ? "" : "s")"
        if let observation = try await workspace.mixObservation(section: section) {
            reading = Output.Reading(integratedLUFS: (observation.integratedLUFS * 10).rounded() / 10, truePeakDBTP: observation.truePeakDBTP.map { ($0 * 10).rounded() / 10 },
                                     crestDB: (observation.crestDB * 10).rounded() / 10, tiltDB: observation.tiltDB.rounded(), bandwidthHz: observation.bandwidthHz.rounded())
            pairs = observation.masking.map { Output.Pair(a: $0.aLabel, b: $0.bLabel, band: $0.bandName + " Hz", gapDB: ($0.gapDB * 10).rounded() / 10, louder: $0.louderLabel) }
            let findings = board.review(MixReview(observation: observation, master: mix.master))
            flags = findings.map { Output.Flag(critic: $0.criticName, headline: $0.headline, offered: $0.fixes.first?.title ?? "", otherwise: $0.fixes.dropFirst().first?.title ?? "") }
            engineer = Engineer().read(observation).map(\.says)
            detail += String(format: ", bounced: %.1f LUFS against %.0f, true peak %.1f against %.1f; %d masking pair%@, %d flag%@.",
                             observation.integratedLUFS, mix.master.targetLUFS, observation.truePeakDBTP ?? observation.peakDBFS, mix.master.ceilingDBTP,
                             pairs.count, pairs.count == 1 ? "" : "s", flags.count, flags.count == 1 ? "" : "s")
        } else {
            detail += "; nothing to bounce, so no reading."
        }
        let entries = strips.map { strip -> Output.StripEntry in
            let s = mix.strip(for: strip.part, label: strip.label)
            return Output.StripEntry(part: strip.part.description, label: strip.label, gainDB: s.gainDB, pan: s.pan, muted: s.isMuted, soloed: s.isSoloed,
                                     eq: s.eq.map { ["hz": $0.frequency, "db": $0.gainDB] }, sendDB: s.sendDB)
        }
        return Output(mixVersion: plan.mixVersion?.description, strips: entries,
                      master: Output.MasterEntry(gainDB: mix.master.gainDB, ceilingDBTP: mix.master.ceilingDBTP, targetLUFS: mix.master.targetLUFS, fadeOutBars: mix.master.fadeOutBars),
                      reading: reading, masking: pairs, flags: flags, engineer: engineer, detail: detail)
    }
}

// MARK: - set_mix

/// One strip move, put to the Engineer first, recorded as a mix version.
public struct SetMixTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// The strip: its label as read_mix printed it, or the part id.
        public var part: String
        /// dB, 0 for none.
        public var gainDB: Double
        /// Hz of the peak band to move, 0 for none.
        public var bandHz: Double
        /// dB at that band, 0 for none. A cut is negative.
        public var bandDB: Double
        /// Why, in the Engineer's numbers: the reading that asked for it.
        public var reason: String
        enum CodingKeys: String, CodingKey { case part, reason; case gainDB = "gain_db"; case bandHz = "band_hz"; case bandDB = "band_db" }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var note: String
        public var verdict: String
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    let engineer = Engineer()

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_mix"
    public var purpose: String {
        "Move one strip: its gain by gain_db, or its peak band to band_hz by band_db — one thing per call. The Engineer "
        + "checks the move first (cut before boost, at most 6 dB, one move at a time) and refuses with a counter; a move that "
        + "passes is a mix version whose note carries the move and your reason. Read the mix again after."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("part", Schema.string("The strip's label as read_mix printed it, or its part id.")),
            ("gain_db", Schema.number("Gain change in dB; 0 for none.", minimum: -24, maximum: 24)),
            ("band_hz", Schema.number("The peak band's frequency in Hz; 0 for no EQ move.", minimum: 0, maximum: 20_000)),
            ("band_db", Schema.number("The EQ change in dB at that band; 0 for none. A cut is negative.", minimum: -18, maximum: 18)),
            ("reason", Schema.string("The reading that asked for the move, in dB and Hz.")),
        ], required: ["part", "gain_db", "band_hz", "band_db", "reason"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.")
        }
        let plan = await workspace.playback
        let strips = await MixReader.strips(of: plan, song: song)
        guard let strip = findStrip(input.part, in: strips) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.part)\" is not a strip in this song.",
                                      suggestion: "One of: \(strips.map(\.label).joined(separator: ", ")). Read the mix first.")
        }
        let verdict = engineer.consider(.moveStrip(part: strip.label, gainDB: input.gainDB, bandHz: input.bandHz, bandDB: input.bandDB))
        if case .refuse(let rule, let because, let counter) = verdict {
            throw DirectorToolFailure(tool: name, reason: "The Engineer refuses (\(rule)): \(because)", suggestion: counter)
        }
        var mix = plan.mix ?? .unity
        var moved = mix.strip(for: strip.part, label: strip.label)
        if input.gainDB != 0 { moved.gainDB = max(-60, min(12, moved.gainDB + input.gainDB)) }
        if input.bandHz > 0, input.bandDB != 0, moved.eq.indices.contains(1) {
            moved.eq[1].frequency = input.bandHz
            moved.eq[1].gainDB = max(-18, min(18, moved.eq[1].gainDB + input.bandDB))
        }
        let before = mix
        mix.set(moved)
        guard mix != before else {
            throw DirectorToolFailure(tool: name, reason: "Nothing moved: gain_db and band_db are both 0.")
        }
        let move = MixerModel.describe(from: before, to: mix, labels: Dictionary(strips.map { ($0.part, $0.label) }, uniquingKeysWith: { a, _ in a }))
        let note = "\(move) (\(input.reason))"
        guard let version = await workspace.recordMix(mix, note: note) else {
            throw DirectorToolFailure(tool: name, reason: "The move could not be kept.")
        }
        return Output(version: version.id.description, note: note, verdict: verdict.spoken,
                      detail: "Recorded as \(PartLabel.title(of: version)): \(move). Read the mix again to see what it did.")
    }
}

// MARK: - master

/// The master's target, ceiling and gain, put to the Engineer first, recorded as a mix version.
public struct MasterTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var targetLUFS: Double
        public var ceilingDBTP: Double
        /// Gain change before the limiter, dB; 0 for none. Use the gap read_mix reported.
        public var gainDB: Double
        public var reason: String
        /// How the song ends: -1 (or absent) keeps the ending it has, 0 stops on the last bar, N
        /// fades over the last N bars.
        public var fadeOutBars: Int?
        enum CodingKeys: String, CodingKey { case reason; case targetLUFS = "target_lufs"; case ceilingDBTP = "ceiling_dbtp"; case gainDB = "gain_db"; case fadeOutBars = "fade_out_bars" }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var note: String
        public var verdict: String
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    let engineer = Engineer()

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "master"
    public var purpose: String {
        "Set the master: the loudness target in LUFS, the limiter's ceiling in dBTP, and a gain change before the limiter. "
        + "The Engineer checks it (ceiling at or under −0.5, target inside −20…−8) and refuses with a counter; a setting that "
        + "passes is a mix version. The ceiling is applied over every bounce and export. The ending too: fade_out_bars fades "
        + "the form's last bars to silence, as the song plays to its end and in the master; 0 stops on the last bar, -1 "
        + "keeps the ending it has. Read the mix after to see it land."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("target_lufs", Schema.number("Integrated loudness target, LUFS.", minimum: -30, maximum: -6)),
            ("ceiling_dbtp", Schema.number("The limiter's ceiling, dBTP.", minimum: -12, maximum: 0)),
            ("gain_db", Schema.number("Gain change before the limiter, dB; 0 for none.", minimum: -24, maximum: 24)),
            ("reason", Schema.string("The reading that asked for it.")),
            ("fade_out_bars", Schema.integer("The ending: bars to fade over, 0 to stop on the last bar, -1 to keep it as it is.", minimum: -1, maximum: 16)),
        ], required: ["target_lufs", "ceiling_dbtp", "gain_db", "reason", "fade_out_bars"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard await workspace.song != nil else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.")
        }
        let verdict = engineer.consider(.setMaster(targetLUFS: input.targetLUFS, ceilingDBTP: input.ceilingDBTP))
        if case .refuse(let rule, let because, let counter) = verdict {
            throw DirectorToolFailure(tool: name, reason: "The Engineer refuses (\(rule)): \(because)", suggestion: counter)
        }
        let plan = await workspace.playback
        var mix = plan.mix ?? .unity
        let before = mix
        mix.master.targetLUFS = input.targetLUFS
        mix.master.ceilingDBTP = input.ceilingDBTP
        if input.gainDB != 0 { mix.master.gainDB = max(-24, min(24, mix.master.gainDB + input.gainDB)) }
        if let fade = input.fadeOutBars, fade >= 0 { mix.master.fadeOutBars = fade == 0 ? nil : min(16, fade) }
        let move = MixerModel.describe(from: before, to: mix, labels: [:])
        let note = mix == before ? "Master confirmed at \(Int(input.targetLUFS)) LUFS / \(input.ceilingDBTP) dBTP (\(input.reason))" : "\(move) (\(input.reason))"
        guard let version = await workspace.recordMix(mix, note: note) else {
            throw DirectorToolFailure(tool: name, reason: "The master could not be kept.")
        }
        return Output(version: version.id.description, note: note, verdict: verdict.spoken,
                      detail: "Recorded as \(PartLabel.title(of: version)). The ceiling is over every bounce and export; read the mix to see the loudness land.")
    }
}
