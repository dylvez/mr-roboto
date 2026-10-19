import Foundation
import MusicTheory
import Performance
import SongGraph

// M6's three, appended after `read_take`: the mix read, one strip moved, the master set.

/// The strip a tool names: by part id, or by a label (case-insensitive, then as a prefix) that only
/// one strip has. Two bass lines written to compare share a label; the first used to be moved
/// without a word, so a name two strips answer to is refused with their ids.
private enum StripMatch {
    case one((part: PartID, label: String))
    case several([(part: PartID, label: String)])
    case none
}

private func findStrip(_ named: String, in strips: [(part: PartID, label: String)]) -> StripMatch {
    if let byID = strips.first(where: { $0.part.description == named }) { return .one(byID) }
    for matches in [strips.filter { $0.label.caseInsensitiveCompare(named) == .orderedSame },
                    strips.filter { $0.label.lowercased().hasPrefix(named.lowercased()) }] where !matches.isEmpty {
        return matches.count == 1 ? .one(matches[0]) : .several(matches)
    }
    return .none
}

// MARK: - The whole song, section by section

/// The whole song bounced once through the mix and read section by section, as the Master reads
/// it: what read_mix and master say beside their own numbers. Every bands_db is the five bands of
/// `bands_hz`, dB against the whole song's energy, so the rows share one scale; the whole song's
/// own row and the reference's are their balances.
public struct WholeSongEntry: Encodable, Sendable {
    public struct Row: Encodable, Sendable {
        public var section: String
        /// Where it starts, "0:30": the Peer's clock.
        public var at: String
        public var integratedLUFS: Double?
        public var crestDB: Double?
        /// How far its 3-second loudness moves, LU.
        public var spreadLU: Double?
        public var bandsDB: [Double]
        enum CodingKeys: String, CodingKey {
            case section, at; case integratedLUFS = "integrated_lufs"; case crestDB = "crest_db"; case spreadLU = "spread_lu"; case bandsDB = "bands_db"
        }
    }
    public struct Reference: Encodable, Sendable {
        public var name: String
        /// "record" or "song".
        public var kind: String
        public var integratedLUFS: Double?
        public var bandsDB: [Double]
        enum CodingKeys: String, CodingKey { case name, kind; case integratedLUFS = "integrated_lufs"; case bandsDB = "bands_db" }
    }
    public var bandsHz: [String]
    public var integratedLUFS: Double?
    public var truePeakDBTP: Double
    public var crestDB: Double?
    public var spreadLU: Double?
    public var bandsDB: [Double]
    public var sections: [Row]
    public var reference: Reference?
    /// The Engineer on the balance against the reference, band by band. Empty with no reference.
    public var balance: [String]
    /// The Peer on whether each hook lifts off the verse before it.
    public var peer: [String]
    enum CodingKeys: String, CodingKey {
        case sections, reference, balance, peer
        case bandsHz = "bands_hz"; case integratedLUFS = "integrated_lufs"; case truePeakDBTP = "true_peak_dbtp"
        case crestDB = "crest_db"; case spreadLU = "spread_lu"; case bandsDB = "bands_db"
    }

    init(_ whole: WholeSongReading, reference: ReferenceReading?, genre: GenreLens?) {
        func r(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        let song = whole.sheet.whole
        bandsHz = SectionMeter.bands.map(\.name)
        integratedLUFS = song.integratedLUFS.map(r)
        truePeakDBTP = r(whole.truePeakDBTP)
        crestDB = song.crestDB.map(r)
        spreadLU = song.spreadLU.map(r)
        bandsDB = song.bandsDB.map(r)
        sections = whole.sheet.sections.map {
            Row(section: $0.name, at: Peer.clock($0.startSeconds), integratedLUFS: $0.integratedLUFS.map(r), crestDB: $0.crestDB.map(r),
                spreadLU: $0.spreadLU.map(r), bandsDB: $0.bandsDB.map(r))
        }
        self.reference = reference.map {
            Reference(name: $0.name, kind: $0.kind.rawValue, integratedLUFS: $0.sheet.whole.integratedLUFS.map(r), bandsDB: $0.sheet.whole.bandsDB.map(r))
        }
        let bands = whole.balanceReadings(against: reference, genre: genre), lifts = whole.liftReadings
        balance = bands.map(\.says)
        peer = lifts.map(\.says)
        flags = (bands + lifts).filter { !$0.holds }.map(\.says)
    }

    /// The lines that do not hold: the bands off the reference and the hooks that do not lift.
    /// Said in the detail; not a field of its own, as each is already in `balance` or `peer`.
    let flags: [String]

    /// "whole song -11.4 LUFS, true peak -1.3 dBTP, 8 sections read off the same bounce against
    /// Mirror Ball, 1923".
    var summary: String {
        var line = (integratedLUFS.map { String(format: "whole song %.1f LUFS", $0) } ?? "whole song silent")
            + String(format: ", true peak %.1f dBTP", truePeakDBTP)
        if !sections.isEmpty { line += ", \(sections.count) section\(sections.count == 1 ? "" : "s") read off the same bounce" }
        if let reference { line += " against \(reference.name)" }
        return line
    }
}

// MARK: - read_mix

/// The strips, the master, the last bounce's readings and the masking pairs.
public struct ReadMixTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// A section by name, or empty for the first (or the whole song when not arranged).
        public var section: String
        /// What to read the balance against, by title: a record in the crate or another song.
        /// Empty, or absent, keeps the one picked; "none" clears it.
        public var reference: String?
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
            /// What it plays through: "rotating speaker, slow (its instrument's own)", "amp, crunch".
            public var insert: String?
            public var echoDB: Double?
            /// The rest of its chain, in signal order: "a wah, rocked every eighth", "a chorus",
            /// "a low-pass, open", "pumping 6 dB on the kick". Nil when there is none.
            public var effects: [String]? = nil
            enum CodingKeys: String, CodingKey {
                case part, label, pan, muted, soloed, eq, insert, effects
                case gainDB = "gain_db"; case sendDB = "send_db"; case echoDB = "echo_db"
            }
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
        public struct SectionLevel: Encodable, Sendable {
            public var section: String
            public var strip: String
            public var gainDB: Double
            enum CodingKeys: String, CodingKey { case section, strip; case gainDB = "gain_db" }
        }
        public var mixVersion: String?
        public var strips: [StripEntry]
        /// A strip's level in one section, where it is not the strip's own.
        public var sectionLevels: [SectionLevel]
        /// The two returns: "reverb plate; echo every dotted eighth, feedback 35%".
        public var returns: String
        /// What a section does to a strip's effects: "Organ: speaker fast in Chorus".
        public var sectionEffects: [String]
        public var master: MasterEntry
        public var reading: Reading?
        public var masking: [Pair]
        public var flags: [Flag]
        public var engineer: [String]
        /// The whole song bounced once and read section by section, against the reference when one
        /// is picked. Nil for a song with no form and no reference, whose reading above is already
        /// the whole song.
        public var wholeSong: WholeSongEntry? = nil
        public var detail: String
        enum CodingKeys: String, CodingKey {
            case strips, master, reading, masking, flags, engineer, detail, returns
            case mixVersion = "mix_version"; case sectionLevels = "section_levels"; case sectionEffects = "section_effects"
            case wholeSong = "whole_song"
        }
    }

    let workspace: any DirectorWorkspace
    let board: CriticBoard

    public init(workspace: any DirectorWorkspace, board: CriticBoard = .standard) {
        self.workspace = workspace
        self.board = board
    }

    public let name = "read_mix"
    public var purpose: String {
        "Read the mix: every strip's level, pan, EQ, send, echo, insert and other effects (pedal, modulation, filter, pump), its level and effects in any section where they differ, the "
        + "reverb's space and the echo's time, the master's gain, "
        + "ceiling and target, and the song bounced "
        + "through it — integrated LUFS, true peak, crest, tilt — with every strip bounced apart for the masking pairs and the "
        + "Engineer's flags. A chop that is quiet at its source is flagged first, and is answered with level_chop, not with "
        + "the master. With a form, whole_song is the whole song bounced once and read section by section — each section's "
        + "LUFS, crest, short-term spread and five bands against the whole — with the Peer on whether each hook lifts off "
        + "the verse before it, and the balance beside the reference the user picked (reference names another: a record "
        + "in the crate or a song in the library), the Engineer flagging any band more than 3 dB off it. Nothing in the "
        + "mix is changed. Read before a move; read again after."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("section", Schema.string("A section by name to bounce, or empty for the first.")),
            ("reference", Schema.string("A record in the crate or a song in the library to read the balance against, by title; empty keeps the one picked; \"none\" clears it.")),
        ], required: ["section", "reference"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Open a song first.")
        }
        let asked = (input.reference ?? "").trimmingCharacters(in: .whitespaces)
        if !asked.isEmpty {
            if asked.lowercased() == "none" {
                _ = await workspace.setMixReference(named: asked)
            } else if await workspace.setMixReference(named: asked) == nil {
                let choices = await workspace.referenceChoices.map(\.title)
                throw DirectorToolFailure(tool: name, reason: "\"\(asked)\" is neither a record in the crate nor another song in the library.",
                                          suggestion: choices.isEmpty ? "The library holds nothing to read against."
                                              : "One of: \(choices.prefix(24).joined(separator: ", ")); or empty to keep the one picked.")
            }
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
            let findings = board.review(MixReview(observation: observation, master: mix.master, quietChops: ChopLevel.quiet(in: plan)))
            flags = findings.map { Output.Flag(critic: $0.criticName, headline: $0.headline, offered: $0.fixes.first?.title ?? "", otherwise: $0.fixes.dropFirst().first?.title ?? "") }
            engineer = GenreLens.judge(Engineer().read(observation), by: Engineer.bible, in: await workspace.genreLens).map(\.says)
            detail += String(format: ", bounced: %.1f LUFS against %.0f, true peak %.1f against %.1f; %d masking pair%@, %d flag%@.",
                             observation.integratedLUFS, mix.master.targetLUFS, observation.truePeakDBTP ?? observation.peakDBFS, mix.master.ceilingDBTP,
                             pairs.count, pairs.count == 1 ? "" : "s", flags.count, flags.count == 1 ? "" : "s")
        } else {
            detail += "; nothing to bounce, so no reading."
        }
        // The whole song, once, section by section: what a form's sections and a reference need.
        // A song with neither has had its whole bounce read above already.
        var wholeSong: WholeSongEntry?
        var reference: ReferenceReading?
        do { reference = try await workspace.mixReference() } catch { detail += " The reference could not be read: \(error)." }
        if plan.isArranged || reference != nil {
            do {
                if let whole = try await workspace.wholeSong() {
                    let entry = WholeSongEntry(whole, reference: reference, genre: await workspace.genreLens)
                    wholeSong = entry
                    detail += " Read whole: \(entry.summary)" + (entry.flags.isEmpty ? "." : "; \(entry.flags.count) to say: " + entry.flags.joined(separator: " "))
                }
            } catch {
                detail += " The whole song could not be bounced to read it section by section: \(error)."
            }
        }
        let inserts = plan.instrumentInserts
        let entries = strips.map { strip -> Output.StripEntry in
            let s = mix.strip(for: strip.part, label: strip.label)
            let insert = mix.insert(for: strip.part, in: nil, instrument: inserts[strip.part])
                .flatMap { $0.kind == .off ? nil : $0.words + (s.insert == nil ? " (its instrument's own)" : "") }
            let rest = SetEffectsTool.chainWords(mix, part: strip.part, section: nil, plan: plan)
                .filter { !$0.hasPrefix("an amp") && !$0.hasPrefix("a rotating speaker") }
            return Output.StripEntry(part: strip.part.description, label: strip.label, gainDB: s.gainDB, pan: s.pan, muted: s.isMuted, soloed: s.isSoloed,
                                     eq: s.eq.map { ["hz": $0.frequency, "db": $0.gainDB] }, sendDB: s.sendDB, insert: insert, echoDB: s.echoDB,
                                     effects: rest.isEmpty ? nil : rest)
        }
        let labels = Dictionary(strips.map { ($0.part, $0.label) }, uniquingKeysWith: { a, _ in a })
        let levels = mix.sectionGains.compactMap { gain -> Output.SectionLevel? in
            guard let name = song.sections.first(where: { $0.id == gain.section })?.name else { return nil }
            return Output.SectionLevel(section: name, strip: labels[gain.part] ?? gain.part.description, gainDB: gain.gainDB)
        }
        let returns = "reverb \(mix.roomSetting.name.lowercased()); echo\(mix.echoSettings.isTape ? " on tape" : "") every \(mix.echoSettings.timeName), "
            + String(format: "feedback %.0f%%", mix.echoSettings.feedback * 100)
        let effects = (mix.sectionEffects ?? []).compactMap { effect -> String? in
            guard let name = song.sections.first(where: { $0.id == effect.section })?.name else { return nil }
            var said: [String] = []
            if let fast = effect.fast { said.append("speaker \(fast ? "fast" : "slow")") }
            if let db = effect.echoDB { said.append(String(format: "echo %.0f dB", db)) }
            if let words = effect.filterWords(mix.strip(for: effect.part)?.filter?.kind ?? .lowPass) { said.append(words) }
            if let db = effect.pumpDB { said.append(db == 0 ? "no pump" : String(format: "pumping %.0f dB", db)) }
            return "\(labels[effect.part] ?? effect.part.description): \(said.joined(separator: ", ")) in \(name)"
        }
        return Output(mixVersion: plan.mixVersion?.description, strips: entries, sectionLevels: levels, returns: returns, sectionEffects: effects,
                      master: Output.MasterEntry(gainDB: mix.master.gainDB, ceilingDBTP: mix.master.ceilingDBTP, targetLUFS: mix.master.targetLUFS, fadeOutBars: mix.master.fadeOutBars),
                      reading: reading, masking: pairs, flags: flags, engineer: engineer, wholeSong: wholeSong, detail: detail)
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
        /// A section by name: the gain is then the strip's level in that section only, as the
        /// Mixer's section picker sets it. Empty, or absent, for the strip in every section.
        public var section: String?
        enum CodingKeys: String, CodingKey { case part, reason, section; case gainDB = "gain_db"; case bandHz = "band_hz"; case bandDB = "band_db" }
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
        "Move one strip: its gain by gain_db, or its peak band to band_hz by band_db — one thing per call. With a section "
        + "named, the gain moves the strip's level in that section only (\"the bass down in the intro\"), from where it is "
        + "there; a move that lands back on the strip's own level lets the section go. EQ is the strip's in every section. "
        + "The Engineer checks the move first (cut before boost, at most 6 dB, one move at a time) and refuses with a "
        + "counter; a move that passes is a mix version whose note carries the move and your reason. Read the mix again after."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("part", Schema.string("The strip's label as read_mix printed it, or its part id.")),
            ("gain_db", Schema.number("Gain change in dB; 0 for none.", minimum: -24, maximum: 24)),
            ("band_hz", Schema.number("The peak band's frequency in Hz; 0 for no EQ move.", minimum: 0, maximum: 20_000)),
            ("band_db", Schema.number("The EQ change in dB at that band; 0 for none. A cut is negative.", minimum: -18, maximum: 18)),
            ("reason", Schema.string("The reading that asked for the move, in dB and Hz.")),
            ("section", Schema.string("A section by name to move the strip's level in that section only; empty for every section.")),
        ], required: ["part", "gain_db", "band_hz", "band_db", "reason", "section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.")
        }
        let plan = await workspace.playback
        let strips = await MixReader.strips(of: plan, song: song)
        let strip: (part: PartID, label: String)
        switch findStrip(input.part, in: strips) {
        case .one(let found):
            strip = found
        case .several(let matches):
            throw DirectorToolFailure(tool: name, reason: "\(matches.count) strips answer to \"\(input.part)\".",
                                      suggestion: "Name one by its part id: " + matches.map { "\($0.label) \($0.part)" }.joined(separator: ", ") + ".")
        case .none:
            throw DirectorToolFailure(tool: name, reason: "\"\(input.part)\" is not a strip in this song.",
                                      suggestion: "One of: \(strips.map(\.label).joined(separator: ", ")). Read the mix first.")
        }
        let named = (input.section ?? "").trimmingCharacters(in: .whitespaces)
        var section: Section?
        if !named.isEmpty {
            guard let found = song.sections.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(named)\" is not a section of this song.",
                                          suggestion: song.sections.isEmpty ? "The song has no form yet: leave section empty to move the strip everywhere."
                                              : "One of: \(song.sections.map(\.name).joined(separator: ", ")), or empty for every section.")
            }
            if input.bandDB != 0 {
                throw DirectorToolFailure(tool: name, reason: "EQ is the strip's in every section; a section takes only a level.",
                                          suggestion: "Move the band with section empty, or the level in \(found.name) with band_db 0.")
            }
            section = found
        }
        let asked = PersonaProposal.moveStrip(part: strip.label, gainDB: input.gainDB, bandHz: input.bandHz, bandDB: input.bandDB)
        let verdict = GenreLens.judge(engineer.consider(asked), on: asked, by: Engineer.bible, in: await workspace.genreLens)
        if case .refuse(let rule, let because, let counter) = verdict {
            throw DirectorToolFailure(tool: name, reason: "The Engineer refuses (\(rule)): \(because)", suggestion: counter)
        }
        var mix = plan.mix ?? .unity
        let before = mix
        if let section {
            // From the level it has there, as the Mixer's fader in that section starts from it; a
            // move that lands on the strip's own level is no section level at all.
            let own = mix.strip(for: strip.part)?.gainDB ?? 0
            let level = max(-60, min(12, mix.gainDB(for: strip.part, in: section.id) + input.gainDB))
            mix.sectionGains.removeAll { $0.section == section.id && $0.part == strip.part }
            if input.gainDB != 0, abs(level - own) > 0.05 {
                mix.sectionGains.append(SectionGain(section: section.id, part: strip.part, gainDB: level))
            }
        } else {
            var moved = mix.strip(for: strip.part, label: strip.label)
            if input.gainDB != 0 { moved.gainDB = max(-60, min(12, moved.gainDB + input.gainDB)) }
            if input.bandHz > 0, input.bandDB != 0, moved.eq.indices.contains(1) {
                moved.eq[1].frequency = input.bandHz
                moved.eq[1].gainDB = max(-18, min(18, moved.eq[1].gainDB + input.bandDB))
            }
            mix.set(moved)
        }
        guard mix != before else {
            throw DirectorToolFailure(tool: name, reason: "Nothing moved: gain_db and band_db are both 0.")
        }
        let move = MixerModel.describe(from: before, to: mix, labels: Dictionary(strips.map { ($0.part, $0.label) }, uniquingKeysWith: { a, _ in a }),
                                       sections: Dictionary(song.sections.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
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
        /// The whole song bounced through the master as it now stands, read section by section, as
        /// the Master surface reads it. Nil where nothing can be bounced.
        public var wholeSong: WholeSongEntry? = nil
        public var detail: String
        enum CodingKeys: String, CodingKey { case version, note, verdict, detail; case wholeSong = "whole_song" }
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
        + "keeps the ending it has. The whole song is then bounced through it once, as the Master reads it: whole_song "
        + "carries its integrated LUFS and true peak — the gap to the target is read from these, not from one section — "
        + "each section's numbers, the Peer on the hooks and the balance against the reference."
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
        let master = PersonaProposal.setMaster(targetLUFS: input.targetLUFS, ceilingDBTP: input.ceilingDBTP)
        let verdict = GenreLens.judge(engineer.consider(master), on: master, by: Engineer.bible, in: await workspace.genreLens)
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
        var detail = "Recorded as \(PartLabel.title(of: version)). The ceiling is over every bounce and export."
        var wholeSong: WholeSongEntry?
        // Bounced once through the master as it now stands, as the Master surface reads it. A reading
        // that cannot be made leaves the setting kept and says so.
        do {
            if let whole = try await workspace.wholeSong() {
                var reference: ReferenceReading?
                do { reference = try await workspace.mixReference() } catch { detail += " The reference could not be read: \(error)." }
                let entry = WholeSongEntry(whole, reference: reference, genre: await workspace.genreLens)
                wholeSong = entry
                let gap = entry.integratedLUFS.map { mix.master.targetLUFS - $0 }
                detail += " Read whole: \(entry.summary)"
                    + (gap.map { abs($0) <= 0.5 ? String(format: ", on the target") : String(format: ", %.1f LU %@ the target", abs($0), $0 > 0 ? "under" : "over") } ?? "")
                    + (entry.flags.isEmpty ? "." : "; \(entry.flags.count) to say: " + entry.flags.joined(separator: " "))
            } else {
                detail += " Read the mix to see the loudness land."
            }
        } catch {
            detail += " The whole song could not be bounced to read it: \(error)."
        }
        return Output(version: version.id.description, note: note, verdict: verdict.spoken, wholeSong: wholeSong, detail: detail)
    }
}

// MARK: - level_chop

/// A chop given a level of its own, or put back as recorded.
public struct LevelChopTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// The chop: its part id, a version id of it, or its name as read_song and read_mix print it.
        public var part: String
        public var asRecorded: Bool
        enum CodingKeys: String, CodingKey { case part; case asRecorded = "as_recorded" }
    }

    public struct Output: Encodable, Sendable {
        public var part: String
        public var gainDB: Double
        public var detail: String
        enum CodingKeys: String, CodingKey { case part, detail; case gainDB = "gain_db" }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "level_chop"
    public var purpose: String {
        "Give a chop a level of its own. Its bar is measured and brought up to where an instrument sits, as the chop's next "
        + "version, so its loop, its pads and every groove on its slices come up together wherever they are heard, and the "
        + "mix does not move. This is the answer when read_mix flags a chop as quiet at its source, or the user cannot hear "
        + "a chop or the groove on it: never the master, which makes everything added afterwards too loud. as_recorded "
        + "true puts it back. A chop cut from now on is levelled as it is cut, so this is for one that was not."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("part", Schema.string("The chop: its part id, a version id of it, or its name as read_song prints it.")),
            ("as_recorded", Schema.boolean("True to play it as its recording has it again; false to measure the bar and level it.")),
        ], required: ["part", "as_recorded"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.")
        }
        let chops = song.partIDs.compactMap { song.latestVersion(of: $0) }.filter { $0.type == .sample }
        let asked = input.part.trimmingCharacters(in: .whitespaces)
        let found = chops.first { $0.partID.description == asked }
            ?? VersionID(uuidString: asked).flatMap(song.version).flatMap { version in chops.first { $0.partID == version.partID } }
            ?? chops.last { PartLabel.title(of: $0).caseInsensitiveCompare(asked) == .orderedSame }
        guard let chop = found else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.part)\" is not a chop in this song.",
                                      suggestion: chops.isEmpty ? "The song holds no chop." : "One of: " + chops.map { "\(PartLabel.title(of: $0)) \($0.partID)" }.joined(separator: ", ") + ".")
        }
        guard let level = await workspace.levelChop(chop.partID, asRecorded: input.asRecorded) else {
            throw DirectorToolFailure(tool: name, reason: input.asRecorded ? "\(PartLabel.title(of: chop)) already plays as recorded."
                                          : "\(PartLabel.title(of: chop)) did not move: it is loud enough as recorded, it is already levelled, or its audio could not be read.",
                                      suggestion: "Read the mix: if the song is still under its target, that is the master's.")
        }
        return Output(part: chop.partID.description, gainDB: level,
                      detail: level == 0 ? "\(PartLabel.title(of: chop)) plays as recorded again."
                          : "\(PartLabel.title(of: chop)) plays \(ChopLevel.spoken(level)) at its source: its loop and every groove on its slices. Read the mix again; the master may now be over.")
    }
}

// MARK: - set_effects

/// A strip's insert and echo send, a section's speaker speed and echo, and the two returns: the
/// reverb's space and the echo's time and feedback. Recorded as a mix version, like set_mix.
public struct SetEffectsTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// The strip, by label or part id; empty to set only the returns.
        public var part: String
        /// "keep", "own" (the instrument's own), or one of `StripInsert.named`.
        public var insert: String
        /// "keep", "off", or the send in dB, "-12".
        public var echo: String
        /// A section by name: the speaker's speed and the echo send there alone. Empty for the strip
        /// in every section.
        public var section: String
        /// "keep" or a `Room`.
        public var room: String
        /// "keep" or one of `Echo.times`' names.
        public var echoTime: String
        /// 0…0.85, or -1 to keep.
        public var echoFeedback: Double
        public var reason: String
        /// "keep", "off", or one of `StripPedal.named`. Nil keeps.
        public var pedal: String?
        /// "keep", "own", or one of `StripModulation.named`. Nil keeps.
        public var modulation: String?
        /// "keep", "off", "low-pass" or "high-pass"; with a section, "own" puts the section back to
        /// the strip's corner. Nil keeps.
        public var filter: String?
        /// The strip's corner; with a section, where the section's filter starts (and stays, with no
        /// `filterToHz`).
        public var filterHz: Double?
        /// With a section: swept to this corner by the section's last beat.
        public var filterToHz: Double?
        public var filterResonance: Double?
        /// "keep", "off", "kick" or "beat"; with a section, "off" is no pump there and "own" as
        /// everywhere. Nil keeps.
        public var pump: String?
        public var pumpDB: Double?
        /// Not offered to the model — the API's limit on parameters — but read when given.
        public var pumpReleaseBeats: Double?
        /// "keep", "tape" or "clean". Nil keeps.
        public var echoTape: String?

        /// The numbers as asked, -1 (keep) read as nothing asked.
        var filterCorner: Double? { filterHz.flatMap { $0 > 0 ? $0 : nil } }
        var filterTarget: Double? { filterToHz.flatMap { $0 > 0 ? $0 : nil } }
        var resonance: Double? { filterResonance.flatMap { $0 >= 0 ? $0 : nil } }
        var pumpDepth: Double? { pumpDB.flatMap { $0 > 0 ? $0 : nil } }
        var pumpRelease: Double? { pumpReleaseBeats.flatMap { $0 > 0 ? $0 : nil } }
        enum CodingKeys: String, CodingKey {
            case part, insert, echo, section, room, reason, pedal, modulation, filter, pump
            case echoTime = "echo_time"
            case echoFeedback = "echo_feedback"
            case filterHz = "filter_hz"
            case filterToHz = "filter_to_hz"
            case filterResonance = "filter_resonance"
            case pumpDB = "pump_db"
            case pumpReleaseBeats = "pump_release_beats"
            case echoTape = "echo_tape"
        }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var note: String
        /// What the strip plays through now, and its echo send.
        public var strip: String?
        public var returns: String
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_effects"
    public var purpose: String {
        "Put effects on a strip, or change the two every strip sends to. A strip's signal meets, in order: a pedal (a wah "
        + "rocked in time, wah-sixteenths/eighths/quarters; an envelope filter, the funk clavinet's); the insert — an amp "
        + "(amp-clean, amp-crunch, amp-lead) for an electric guitar, or a rotating speaker (rotary-slow, rotary-fast) for an "
        + "organ; off takes it away, own puts back the instrument's own; a modulation (chorus — the Juno's, chorus-wide, "
        + "phaser, flanger — the jet, vibrato); a filter, low-pass or high-pass, at filter_hz; and a pump, the strip ducked on "
        + "the kick's own steps (kick) or every beat (beat) by pump_db: the sidechain of house, techno, afrobeats and lo-fi, "
        + "for pads, chords and bass. echo is the strip's send to a tempo-synced echo, in dB. With a section named: the "
        + "insert sets the speaker's speed there alone, echo the send there alone (a dub throw), filter_hz where the filter "
        + "sits there and filter_to_hz where it has swept to by the section's end — a build opening, 300 to 20000 — "
        + "(filter own puts the section back), and pump off or pump_db how hard it pumps there. room is the reverb's space: "
        + Room.allCases.map { "\($0.rawValue) (\($0.about))" }.joined(separator: "; ")
        + ". echo_time is how far apart the repeats are, in the song's beats: " + Echo.times.map(\.name).joined(separator: ", ")
        + "; echo_tape puts the echo on tape (wow, darker repeats that saturate: dub). Recorded as a mix version; read the mix after."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("part", Schema.string("The strip's label as read_mix printed it, or its part id; empty to set only the returns.")),
            ("insert", Schema.string("What the strip plays through.", enum: ["keep", "own"] + StripInsert.named.map(\.id))),
            ("echo", Schema.string("The strip's echo send: keep, off, or dB from -60 to 0, like \"-12\".")),
            ("section", Schema.string("A section by name, to set the speaker's speed and the echo send there alone; empty for every section.")),
            ("room", Schema.string("The reverb's space.", enum: ["keep"] + Room.allCases.map(\.rawValue))),
            ("echo_time", Schema.string("The echo's time.", enum: ["keep"] + Echo.times.map(\.name))),
            ("echo_feedback", Schema.number("How much of each repeat comes round again, 0 to 0.85; -1 keeps it.", minimum: -1, maximum: 0.85)),
            ("reason", Schema.string("Why, in the music's terms.")),
            ("pedal", Schema.string("The pedal before the insert: keep, off, or one.", enum: ["keep", "off"] + StripPedal.named.map(\.id))),
            ("modulation", Schema.string("The modulation after the insert: keep, own (the instrument's), or one.",
                                         enum: ["keep", "own"] + StripModulation.named.map(\.id))),
            ("filter", Schema.string("The filter; with a section, own puts the section back to the strip's corner.",
                                     enum: ["keep", "off", "own", "low-pass", "high-pass"])),
            ("filter_hz", Schema.number("The filter's corner, 20 to 20000 Hz; with a section, where it sits from the section's first beat. -1 keeps.")),
            ("filter_to_hz", Schema.number("With a section: where the filter has swept to by its last beat, 20 to 20000 Hz. -1 holds it at filter_hz.")),
            ("pump", Schema.string("The pump; with a section, off is none there and own as everywhere.", enum: ["keep", "off", "own", "kick", "beat"])),
            ("pump_db", Schema.number("How far the pump ducks, 1 to 24 dB; with a section, there alone. -1 keeps.")),
            ("echo_tape", Schema.string("The echo on tape or clean.", enum: ["keep", "tape", "clean"])),
        ], required: ["part", "insert", "echo", "section", "room", "echo_time", "echo_feedback", "reason", "pedal", "modulation",
                      "filter", "filter_hz", "filter_to_hz", "pump", "pump_db", "echo_tape"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.")
        }
        let plan = await workspace.playback
        let strips = await MixReader.strips(of: plan, song: song)
        var mix = plan.mix ?? .unity
        let before = mix
        let named = input.part.trimmingCharacters(in: .whitespaces)
        var strip: (part: PartID, label: String)?
        if !named.isEmpty {
            switch findStrip(named, in: strips) {
            case .one(let found): strip = found
            case .several(let matches):
                throw DirectorToolFailure(tool: name, reason: "\(matches.count) strips answer to \"\(named)\".",
                                          suggestion: "Name one by its part id: " + matches.map { "\($0.label) \($0.part)" }.joined(separator: ", ") + ".")
            case .none:
                throw DirectorToolFailure(tool: name, reason: "\"\(named)\" is not a strip in this song.",
                                          suggestion: "One of: \(strips.map(\.label).joined(separator: ", ")). Read the mix first.")
            }
        }
        let sectionName = input.section.trimmingCharacters(in: .whitespaces)
        var section: Section?
        if !sectionName.isEmpty {
            guard let found = song.sections.first(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(sectionName)\" is not a section of this song.",
                                          suggestion: song.sections.isEmpty ? "The song has no form yet: leave section empty."
                                              : "One of: \(song.sections.map(\.name).joined(separator: ", ")), or empty.")
            }
            section = found
        }
        let own = strip.flatMap { plan.instrumentInserts[$0.part] }

        // The strip.
        if let strip {
            let insert = input.insert.trimmingCharacters(in: .whitespaces).lowercased()
            let echo = input.echo.trimmingCharacters(in: .whitespaces).lowercased()
            var echoDB: Double??
            switch echo {
            case "", "keep": echoDB = .none
            case "off": echoDB = .some(nil)
            default:
                guard let db = Double(echo.replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces)) else {
                    throw DirectorToolFailure(tool: name, reason: "\"\(input.echo)\" is not an echo send.", suggestion: "keep, off, or dB like \"-12\".")
                }
                echoDB = .some(max(-60, min(0, db)))
            }
            if let section {
                var effect = mix.sectionEffects?.first { $0.section == section.id && $0.part == strip.part }
                    ?? SectionEffect(section: section.id, part: strip.part)
                switch insert {
                case "keep": break
                case "rotary-fast", "rotary-slow":
                    guard mix.insert(for: strip.part, in: nil, instrument: own)?.kind == .rotary else {
                        throw DirectorToolFailure(tool: name, reason: "\(strip.label) has no rotating speaker for a section to speed up.",
                                                  suggestion: "Put one on it everywhere first: section empty, insert rotary-slow.")
                    }
                    effect.fast = insert == "rotary-fast"
                case "own": effect.fast = nil
                default:
                    throw DirectorToolFailure(tool: name, reason: "A section sets the speaker's speed, not what the strip plays through.",
                                              suggestion: "rotary-fast or rotary-slow for \(section.name), own for the strip's speed there; or the insert with section empty.")
                }
                if let echoDB { effect.echoDB = echoDB }
                try sectionMoves(input, strip: strip, section: section, effect: &effect, mix: &mix)
                mix.setSectionEffect(effect)
            } else {
                var moved = mix.strip(for: strip.part, label: strip.label)
                switch insert {
                case "keep": break
                case "own": moved.insert = nil
                default:
                    guard let named = StripInsert.named.first(where: { $0.id == insert }) else {
                        throw DirectorToolFailure(tool: name, reason: "\"\(input.insert)\" is not an insert.",
                                                  suggestion: "keep, own, or one of: \(StripInsert.named.map(\.id).joined(separator: ", ")).")
                    }
                    moved.insert = named.insert
                }
                if let echoDB { moved.echoDB = echoDB }
                try stripMoves(input, strip: &moved)
                mix.set(moved)
            }
        }

        // The returns.
        let room = input.room.trimmingCharacters(in: .whitespaces).lowercased()
        if room != "keep", !room.isEmpty {
            guard let space = Room(rawValue: room) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(input.room)\" is not a room.", suggestion: Room.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            mix.room = space == .room ? nil : space
        }
        var echo = mix.echoSettings
        let time = input.echoTime.trimmingCharacters(in: .whitespaces).lowercased()
        if time != "keep", !time.isEmpty {
            guard let found = Echo.times.first(where: { $0.name == time }) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(input.echoTime)\" is not an echo time.", suggestion: Echo.times.map(\.name).joined(separator: ", ") + ".")
            }
            echo.beats = found.beats
        }
        if input.echoFeedback >= 0 { echo.feedback = min(0.85, input.echoFeedback) }
        switch input.echoTape?.lowercased() {
        case "tape": echo.tape = true
        case "clean": echo.tape = nil
        default: break
        }
        mix.echo = echo == .standard ? nil : echo

        guard mix != before else {
            throw DirectorToolFailure(tool: name, reason: "Nothing changed: everything asked for is as it already was, or kept.")
        }
        let labels = Dictionary(strips.map { ($0.part, $0.label) }, uniquingKeysWith: { a, _ in a })
        let move = MixerModel.describe(from: before, to: mix, labels: labels,
                                       sections: Dictionary(song.sections.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        let note = "\(move) (\(input.reason))"
        guard let version = await workspace.recordMix(mix, note: note) else {
            throw DirectorToolFailure(tool: name, reason: "The move could not be kept.")
        }
        let now = strip.map { strip -> String in
            let chain = Self.chainWords(mix, part: strip.part, section: section?.id, plan: plan, markOwn: false)
            let echo = mix.echoDB(for: strip.part, in: section?.id).map { String(format: "echo send %.0f dB", $0) } ?? "no echo"
            var said = "\(strip.label)\(section.map { " in \($0.name)" } ?? ""): through \(chain.isEmpty ? "nothing" : chain.joined(separator: ", ")), \(echo)"
            if let section, let effect = mix.sectionEffect(for: strip.part, in: section.id) {
                if let words = effect.filterWords(mix.strip(for: strip.part)?.filter?.kind ?? .lowPass) { said += "; the \(words) across it" }
                if let db = effect.pumpDB { said += db == 0 ? "; no pump there" : String(format: "; pumping %.0f dB there", db) }
            }
            if mix.strip(for: strip.part)?.pump?.trigger == .kick, !plan.mixTimeline.sections.contains(where: { !$0.kicks.isEmpty }) {
                said += ". No groove in the song has a kick for the pump to follow, so it does nothing: pump beat pumps every beat instead"
            }
            return said
        }
        let returns = "reverb \(mix.roomSetting.name.lowercased()); echo\(mix.echoSettings.isTape ? " on tape" : "") every \(mix.echoSettings.timeName) at \(Int(plan.tempo)) BPM, "
            + String(format: "feedback %.0f%%", mix.echoSettings.feedback * 100)
        return Output(version: version.id.description, note: note, strip: now, returns: returns,
                      detail: "Recorded as \(PartLabel.title(of: version)): \(move).\(now.map { " \($0)." } ?? "") Returns: \(returns).")
    }

    /// A strip's pedal, modulation, filter and pump as the input moves them, everywhere.
    private func stripMoves(_ input: Input, strip: inout Strip) throws {
        switch input.pedal?.lowercased() ?? "keep" {
        case "keep", "": break
        case "off": strip.pedal = nil
        case let id:
            guard let found = StripPedal.named.first(where: { $0.id == id }) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(id)\" is not a pedal.", suggestion: StripPedal.named.map(\.id).joined(separator: ", ") + ".")
            }
            strip.pedal = found.pedal
        }
        switch input.modulation?.lowercased() ?? "keep" {
        case "keep", "": break
        case "own": strip.modulation = nil
        case let id:
            guard let found = StripModulation.named.first(where: { $0.id == id }) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(id)\" is not a modulation.", suggestion: StripModulation.named.map(\.id).joined(separator: ", ") + ".")
            }
            strip.modulation = found.modulation
        }
        switch input.filter?.lowercased() ?? "keep" {
        case "keep", "", "own": break
        case "off": strip.filter = nil
        case "low-pass", "high-pass":
            let kind: StripFilter.Kind = input.filter?.lowercased() == "low-pass" ? .lowPass : .highPass
            strip.filter = StripFilter(kind: kind, cutoffHz: input.filterCorner ?? (strip.filter?.kind == kind ? strip.filter?.cutoffHz : nil),
                                       resonance: input.resonance ?? strip.filter?.resonance ?? 0.3)
        default:
            throw DirectorToolFailure(tool: name, reason: "\"\(input.filter ?? "")\" is not a filter.", suggestion: "keep, off, low-pass or high-pass.")
        }
        if input.filter == nil || input.filter?.lowercased() == "keep", var filter = strip.filter {
            if let hz = input.filterCorner { filter.cutoffHz = min(20_000, max(20, hz)) }
            if let resonance = input.resonance { filter.resonance = min(1, max(0, resonance)) }
            strip.filter = filter
        }
        switch input.pump?.lowercased() ?? "keep" {
        case "keep", "", "own": break
        case "off": strip.pump = nil
        case "kick", "beat":
            let trigger: StripPump.Trigger = input.pump?.lowercased() == "kick" ? .kick : .beat
            strip.pump = StripPump(trigger: trigger, depthDB: input.pumpDepth ?? strip.pump?.depthDB ?? 6,
                                   releaseBeats: input.pumpRelease ?? strip.pump?.releaseBeats ?? 0.5)
        default:
            throw DirectorToolFailure(tool: name, reason: "\"\(input.pump ?? "")\" is not a pump.", suggestion: "keep, off, kick or beat.")
        }
        if input.pump == nil || input.pump?.lowercased() == "keep", var pump = strip.pump {
            if let db = input.pumpDepth { pump.depthDB = min(24, max(1, db)) }
            if let beats = input.pumpRelease { pump.releaseBeats = min(2, max(0.125, beats)) }
            strip.pump = pump
        }
    }

    /// What a section does to a strip's filter and pump, as the input moves them. A section that
    /// moves a filter the strip does not have puts an open one on the strip.
    private func sectionMoves(_ input: Input, strip: (part: PartID, label: String), section: Section, effect: inout SectionEffect,
                              mix: inout Mix) throws {
        if input.pedal.map({ !["keep", ""].contains($0.lowercased()) }) == true
            || input.modulation.map({ !["keep", ""].contains($0.lowercased()) }) == true {
            throw DirectorToolFailure(tool: name, reason: "A section moves the filter, the pump, the speaker and the echo, not the pedal or the modulation.",
                                      suggestion: "Set those with section empty.")
        }
        let filter = input.filter?.lowercased() ?? "keep"
        if filter == "own" || filter == "off" {
            effect.filterFromHz = nil
            effect.filterToHz = nil
        } else if let from = input.filterCorner {
            var moved = mix.strip(for: strip.part, label: strip.label)
            if filter == "low-pass" || filter == "high-pass" {
                let kind: StripFilter.Kind = filter == "low-pass" ? .lowPass : .highPass
                if moved.filter?.kind != kind { moved.filter = StripFilter(kind: kind, resonance: input.resonance ?? 0.3) }
            } else if moved.filter == nil {
                moved.filter = StripFilter(kind: .lowPass, resonance: input.resonance ?? 0.3)
            }
            mix.set(moved)
            effect.filterFromHz = min(20_000, max(20, from))
            effect.filterToHz = input.filterTarget.map { min(20_000, max(20, $0)) }
        } else if input.filterTarget != nil {
            throw DirectorToolFailure(tool: name, reason: "A sweep needs where it starts.", suggestion: "filter_hz with filter_to_hz: 300 and 20000 opens a low-pass across the section.")
        }
        switch input.pump?.lowercased() ?? "keep" {
        case "keep", "": if let db = input.pumpDepth { effect.pumpDB = min(24, max(1, db)) }
        case "off": effect.pumpDB = 0
        case "own": effect.pumpDB = nil
        default:
            guard mix.strip(for: strip.part)?.pump != nil else {
                throw DirectorToolFailure(tool: name, reason: "\(strip.label) has no pump for a section to set.",
                                          suggestion: "Put one on it everywhere first: section empty, pump kick.")
            }
            effect.pumpDB = input.pumpDepth.map { min(24, max(1, $0)) }
        }
    }

    /// "an amp, crunch", "a chorus", "a low-pass at 800 Hz", "pumping 6 dB on the kick": what a
    /// strip plays through, in signal order.
    static func chainWords(_ mix: Mix, part: PartID, section: SectionID?, plan: SongPlayback, markOwn: Bool = true) -> [String] {
        let strip = mix.strip(for: part)
        var words: [String] = []
        let own = markOwn ? " (its instrument's own)" : ""
        if let pedal = strip?.pedal { words.append("a \(pedal.words)") }
        if let insert = mix.insert(for: part, in: section, instrument: plan.instrumentInserts[part]), insert.kind != .off {
            words.append(insert.phrase + (strip?.insert == nil ? own : ""))
        }
        if let modulation = mix.modulation(for: part, instrument: plan.instrumentModulations[part]) {
            words.append("a \(modulation.words)" + (strip?.modulation == nil ? own : ""))
        }
        if let filter = strip?.filter { words.append("a \(filter.words)") }
        if let pump = strip?.pump { words.append(pump.words) }
        return words
    }

}
