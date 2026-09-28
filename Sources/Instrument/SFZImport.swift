import Foundation
import MusicTheory

/// The result of importing an `.sfz` file.
public struct SFZImport: Hashable, Sendable {
    public var manifest: KitManifest
    /// Everything in the file we did not honour, one entry per occurrence. Import never fails on an
    /// unknown opcode — a commercial pack is full of engine-specific ones — but nothing is dropped
    /// silently either: it all lands here so a person can see what the kit will not do.
    public var skipped: [SFZSkip]
    /// Regions seen, including any that produced no zone.
    public var regionCount: Int

    public init(manifest: KitManifest, skipped: [SFZSkip] = [], regionCount: Int = 0) {
        self.manifest = manifest
        self.skipped = skipped
        self.regionCount = regionCount
    }

    /// Distinct opcode names that were skipped, sorted — the useful summary for a person.
    public var skippedOpcodeNames: [String] {
        Array(Set(skipped.map(\.opcode))).sorted()
    }
}

/// One thing the importer did not carry across.
public struct SFZSkip: Hashable, Sendable, CustomStringConvertible {
    public enum Reason: Hashable, Sendable {
        /// The opcode is not in the supported subset.
        case unknownOpcode
        /// The opcode is supported but this value is not (or means "do not play").
        case unsupportedValue(String)
        /// The opcode belongs to a header we do not model (`<curve>`, `<effect>`…).
        case unknownHeader(String)
        /// A `<region>` that could not become a zone.
        case unusableRegion(String)
    }

    public var opcode: String
    public var value: String
    /// 1-based line in the `.sfz` file.
    public var line: Int
    public var reason: Reason

    public init(opcode: String, value: String, line: Int, reason: Reason) {
        self.opcode = opcode
        self.value = value
        self.line = line
        self.reason = reason
    }

    public var description: String {
        switch reason {
        case .unknownOpcode: return "line \(line): unsupported opcode \(opcode)=\(value)"
        case .unsupportedValue(let why): return "line \(line): \(opcode)=\(value) — \(why)"
        case .unknownHeader(let header): return "line \(line): \(opcode)=\(value) inside unsupported <\(header)>"
        case .unusableRegion(let why): return "line \(line): region dropped — \(why)"
        }
    }
}

/// Parses `.sfz` files into `KitManifest`s.
///
/// The supported opcodes are exactly the ones `KitManifest` can represent:
///
///     sample  lokey  hikey  key  pitch_keycenter  lovel  hivel
///     seq_position  seq_length  group  off_by  off_mode
///     offset  end  loop_mode  loop_start  loop_end
///     volume  pan  tune  transpose
///     ampeg_delay  ampeg_attack  ampeg_hold  ampeg_decay  ampeg_sustain  ampeg_release
///
/// plus `default_path`, `note_offset` and `octave_offset` from `<control>`. Headers `<control>`,
/// `<global>`, `<master>`, `<group>` and `<region>` are honoured with SFZ's inheritance: an opcode
/// set at an outer level applies to every region under it until a region overrides it. Any other
/// header's opcodes, and any opcode outside the list, are reported in `SFZImport.skipped`.
///
/// The preprocessor runs first: `#define $NAME value` substitutes into every line after it, and
/// `#include "file.sfz"` splices a file in, resolved against the main file's folder — how most
/// large free packs are split up.
///
/// Some opcodes decide *which* regions sound rather than how, and a sampler without them would
/// play every alternative at once. Each is reduced to what this sampler can play, and the reduction
/// is reported rather than silent:
///
/// * `trigger=release` regions (a key's release noise) are left out: this sampler plays on note-on.
/// * `lorand`/`hirand` random round robins become ordinary round robins, cycled in order.
/// * keyswitched articulations (`sw_last`) keep only the default one (`sw_default`, else the lowest).
/// * regions conditioned on a controller (`loccN`/`hiccN`) are kept when the controller's resting
///   value (`set_ccN`, else 0) is in their range — a piano's pedal-up layer, not its pedal-down one.
///
/// Unit conversions on the way in: `pan` -100…100 → -1…1, `ampeg_sustain` percent → 0…1,
/// `transpose` semitones folded into `tuneCents`, `end` (SFZ's inclusive last frame) → the
/// exclusive `sampleEnd`, and Windows separators in paths → `/`.
public enum SFZImporter {
    /// Opcodes we honour. Everything else is reported, not applied.
    public static let supportedOpcodes: Set<String> = [
        "sample", "lokey", "hikey", "key", "pitch_keycenter", "lovel", "hivel",
        "seq_position", "seq_length", "group", "off_by", "off_mode",
        "offset", "end", "loop_mode", "loop_start", "loop_end",
        "volume", "pan", "tune", "transpose",
        "ampeg_delay", "ampeg_attack", "ampeg_hold", "ampeg_decay", "ampeg_sustain", "ampeg_release",
        "default_path", "note_offset", "octave_offset",
    ]

    /// Opcodes that decide which regions sound. Read, then reduced as the type's comment says.
    static let selectionOpcodes: Set<String> = [
        "trigger", "lorand", "hirand", "sw_last", "sw_lokey", "sw_hikey", "sw_default",
        "sw_down", "sw_up", "sw_previous",
    ]

    /// `loccN`, `hiccN` and `set_ccN`.
    static func isControllerOpcode(_ name: String) -> Bool {
        for prefix in ["on_locc", "on_hicc", "locc", "hicc", "set_cc"] where name.hasPrefix(prefix) {
            let digits = name.dropFirst(prefix.count)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        return false
    }

    static let supportedHeaders: Set<String> = ["control", "global", "master", "group", "region"]

    /// Imports the `.sfz` at `url`. Sample paths stay relative, so the resulting kit works when
    /// `kit.json` is written beside the `.sfz` (the usual layout of a purchased pack).
    public static func importKit(at url: URL, name: String? = nil) throws -> SFZImport {
        let text: String
        do {
            text = try read(url)
        } catch {
            throw KitError.sfzUnreadable(path: url.path, reason: "\(error)")
        }
        let folder = url.deletingLastPathComponent()
        return parse(text, name: name ?? url.deletingPathExtension().lastPathComponent) { path in
            try? read(KitPath.resolve(KitPath.normalized(path), in: folder))
        }
    }

    private static func read(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Commercial packs are often Latin-1.
            guard let data = try? Data(contentsOf: url), let decoded = String(data: data, encoding: .isoLatin1) else {
                throw error
            }
            return decoded
        }
    }

    /// Parses SFZ text. Pure: `include` is how an `#include` reaches another file, and a caller
    /// with no files passes nothing, so it is the unit under test.
    public static func parse(_ text: String, name: String, include: (String) -> String? = { _ in nil }) -> SFZImport {
        var skipped: [SFZSkip] = []
        var defines: [String: String] = [:]
        let lines = preprocess(text, include: include, defines: &defines, depth: 0, skipped: &skipped)
        var parser = Parser(name: name)
        parser.skipped = skipped
        parser.run(lines)
        return parser.finish()
    }

    // MARK: Preprocessor

    /// Comment-free lines with `#define`s substituted and `#include`s spliced in. A line keeps its
    /// number in the file it came from; an included file's lines are numbered in that file.
    static func preprocess(_ text: String, include: (String) -> String?, defines: inout [String: String],
                           depth: Int, skipped: inout [SFZSkip]) -> [(text: String, line: Int)] {
        var out: [(text: String, line: Int)] = []
        var inBlockComment = false
        // By `isNewline`, not by "\n": in Swift "\r\n" is one Character, so a file with Windows line
        // endings — most packs made on Windows — split on "\n" is a single line.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            var cleaned = stripComments(String(rawLine), inBlockComment: &inBlockComment)
            let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#define") {
                let parts = trimmed.dropFirst("#define".count).trimmingCharacters(in: .whitespaces)
                    .split(maxSplits: 1, whereSeparator: \.isWhitespace)
                if parts.count == 2, parts[0].hasPrefix("$") {
                    defines[String(parts[0])] = substitute(String(parts[1]).trimmingCharacters(in: .whitespaces), defines)
                } else {
                    skipped.append(SFZSkip(opcode: "#define", value: trimmed, line: line,
                                           reason: .unsupportedValue("expected #define $NAME value")))
                }
                continue
            }
            if trimmed.hasPrefix("#include") {
                let path = substitute(trimmed.dropFirst("#include".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")), defines)
                if depth >= 16 {
                    skipped.append(SFZSkip(opcode: "#include", value: path, line: line,
                                           reason: .unsupportedValue("includes nested deeper than 16; not followed")))
                } else if let included = include(path) {
                    out += preprocess(included, include: include, defines: &defines, depth: depth + 1, skipped: &skipped)
                } else {
                    skipped.append(SFZSkip(opcode: "#include", value: path, line: line,
                                           reason: .unsupportedValue("file not found")))
                }
                continue
            }
            if trimmed.hasPrefix("#") {
                skipped.append(SFZSkip(opcode: String(trimmed.prefix { !$0.isWhitespace }), value: trimmed, line: line,
                                       reason: .unknownOpcode))
                continue
            }
            if !defines.isEmpty { cleaned = substitute(cleaned, defines) }
            out.append((cleaned, line))
        }
        return out
    }

    /// `$NAME`s replaced, the longest names first so `$VEL` does not eat the start of `$VELOCITY`.
    static func substitute(_ text: String, _ defines: [String: String]) -> String {
        guard text.contains("$") else { return text }
        var out = text
        for (name, value) in defines.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: name, with: value)
        }
        return out
    }

    // MARK: Parser

    struct Assignment {
        var name: String
        var value: String
        var line: Int
    }

    /// What a region said about *whether* it sounds, kept beside its zone until every region is in.
    struct Selection {
        var keyswitch: Int?
        var random: Double?
    }

    private struct Parser {
        let name: String
        var defaultPath = ""
        var control: [String: Assignment] = [:]
        var global: [String: Assignment] = [:]
        var master: [String: Assignment] = [:]
        var group: [String: Assignment] = [:]
        var region: [String: Assignment]?
        var regionLine = 0
        var currentHeader = "global"
        var zones: [Zone] = []
        var selections: [Selection] = []
        var skipped: [SFZSkip] = []
        var regionCount = 0
        var releaseRegions = 0
        var controllerRegions: [Int: Int] = [:]
        var switchedRegions = 0
        var controllerTriggered = 0
        var keyswitchDefault: Int?

        init(name: String) { self.name = name }

        mutating func run(_ lines: [(text: String, line: Int)]) {
            for (cleaned, line) in lines {
                for token in SFZImporter.tokenize(cleaned, line: line) {
                    switch token {
                    case .header(let header): begin(header: header, line: line)
                    case .assignment(let assignment): apply(assignment)
                    }
                }
            }
            flushRegion()
        }

        mutating func begin(header: String, line: Int) {
            flushRegion()
            currentHeader = header
            switch header {
            case "control":
                defaultPath = ""
                control = [:]
            case "global":
                global = [:]; master = [:]; group = [:]
            case "master":
                master = [:]; group = [:]
            case "group":
                group = [:]
            case "region":
                region = [:]
                regionLine = line
                regionCount += 1
            default:
                break  // opcodes inside it are reported as they arrive
            }
        }

        mutating func apply(_ assignment: Assignment) {
            guard SFZImporter.supportedHeaders.contains(currentHeader) else {
                skipped.append(SFZSkip(opcode: assignment.name, value: assignment.value,
                                       line: assignment.line, reason: .unknownHeader(currentHeader)))
                return
            }
            guard SFZImporter.supportedOpcodes.contains(assignment.name)
                    || SFZImporter.selectionOpcodes.contains(assignment.name)
                    || SFZImporter.isControllerOpcode(assignment.name) else {
                skipped.append(SFZSkip(opcode: assignment.name, value: assignment.value,
                                       line: assignment.line, reason: .unknownOpcode))
                return
            }
            if assignment.name == "default_path" {
                defaultPath = KitPath.normalized(assignment.value)
                if !defaultPath.isEmpty && !defaultPath.hasSuffix("/") { defaultPath += "/" }
                return
            }
            if assignment.name == "sw_default" { keyswitchDefault = SFZImporter.noteNumber(assignment.value) }
            switch currentHeader {
            case "region": region?[assignment.name] = assignment
            case "group": group[assignment.name] = assignment
            case "master": master[assignment.name] = assignment
            case "control": control[assignment.name] = assignment
            default: global[assignment.name] = assignment
            }
        }

        /// Merges the inheritance chain and turns the pending region into a zone.
        mutating func flushRegion() {
            guard let region else { return }
            self.region = nil
            var merged = control
            merged.merge(global) { _, new in new }
            merged.merge(master) { _, new in new }
            merged.merge(group) { _, new in new }
            merged.merge(region) { _, new in new }
            guard let samplePath = merged["sample"]?.value, !samplePath.isEmpty else {
                skipped.append(SFZSkip(opcode: "sample", value: "", line: regionLine,
                                       reason: .unusableRegion("no sample")))
                return
            }
            if let end = merged["end"], let value = Int(end.value.trimmingCharacters(in: .whitespaces)), value < 0 {
                skipped.append(SFZSkip(opcode: "end", value: end.value, line: end.line,
                                       reason: .unsupportedValue("negative end silences the region in SFZ; region dropped")))
                return
            }

            func int(_ key: String) -> Int? { merged[key].flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } }
            func float(_ key: String) -> Float? { merged[key].flatMap { Float($0.value.trimmingCharacters(in: .whitespaces)) } }
            let offset = (int("note_offset") ?? 0) + 12 * (int("octave_offset") ?? 0)
            func note(_ key: String) -> Int? { merged[key].flatMap { SFZImporter.noteNumber($0.value) }.map { $0 + offset } }

            // Whether it sounds at all.
            let trigger = merged["trigger"]?.value.trimmingCharacters(in: .whitespaces).lowercased() ?? "attack"
            if trigger == "release" || trigger == "release_key" {
                releaseRegions += 1
                return
            }
            for (key, value) in merged where (key.hasPrefix("locc") || key.hasPrefix("hicc")) {
                guard SFZImporter.isControllerOpcode(key), !key.hasPrefix("set_cc"),
                      let number = Int(key.dropFirst(4)), Double(value.value.trimmingCharacters(in: .whitespaces)) != nil else { continue }
                let resting = merged["set_cc\(number)"].flatMap { Double($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
                let low = merged["locc\(number)"].flatMap { Double($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
                let high = merged["hicc\(number)"].flatMap { Double($0.value.trimmingCharacters(in: .whitespaces)) } ?? 127
                if !(low...max(low, high)).contains(resting) {
                    controllerRegions[number, default: 0] += 1
                    return
                }
            }
            // A region a controller fires (a piano's pedal noise), or one on no key at all, is not a note.
            if merged.keys.contains(where: { $0.hasPrefix("on_locc") || $0.hasPrefix("on_hicc") })
                || (note("hikey") ?? note("key") ?? 0) < 0 {
                controllerTriggered += 1
                return
            }
            if merged["sw_down"] != nil || merged["sw_up"] != nil || merged["sw_previous"] != nil {
                switchedRegions += 1
                return
            }
            let random = merged["lorand"].flatMap { Double($0.value.trimmingCharacters(in: .whitespaces)) }
                ?? (merged["hirand"] != nil ? 0 : nil)

            let sample = KitPath.normalized(defaultPath + KitPath.normalized(samplePath))
            let keyOpcode = note("key")
            let low = note("lokey") ?? keyOpcode ?? 0
            let high = note("hikey") ?? keyOpcode ?? 127
            let root = note("pitch_keycenter") ?? keyOpcode
            let placement: KeyPlacement
            if low == high, root == nil || root == low {
                placement = .note(low)
            } else {
                placement = .range(min(low, high)...max(low, high), rootNote: root ?? low)
            }
            let loVelocity = max(0, min(127, int("lovel") ?? 1))
            let hiVelocity = max(0, min(127, int("hivel") ?? 127))

            var loop: Loop?
            let loopMode = merged["loop_mode"].map { $0.value.trimmingCharacters(in: .whitespaces).lowercased() }
            let loopStart = int("loop_start")
            let loopEnd = int("loop_end")
            if loopMode != nil || loopStart != nil || loopEnd != nil {
                let mode = Loop.Mode(rawValue: loopMode ?? "loop_continuous")
                if let loopMode, mode == nil {
                    skipped.append(SFZSkip(opcode: "loop_mode", value: loopMode,
                                           line: merged["loop_mode"]?.line ?? regionLine,
                                           reason: .unsupportedValue("unknown loop mode")))
                }
                loop = Loop(mode: mode ?? .loopContinuous, start: loopStart ?? 0, end: loopEnd ?? 0)
            }

            var envelope = Envelope.default
            if let v = float("ampeg_delay") { envelope.delay = v }
            if let v = float("ampeg_attack") { envelope.attack = v }
            if let v = float("ampeg_hold") { envelope.hold = v }
            if let v = float("ampeg_decay") { envelope.decay = v }
            if let v = float("ampeg_sustain") { envelope.sustain = min(1, max(0, v / 100)) }
            if let v = float("ampeg_release") { envelope.release = v }

            var offMode = OffMode.fast
            if let raw = merged["off_mode"] {
                let value = raw.value.trimmingCharacters(in: .whitespaces).lowercased()
                if let parsed = OffMode(rawValue: value) {
                    offMode = parsed
                } else {
                    skipped.append(SFZSkip(opcode: "off_mode", value: raw.value, line: raw.line,
                                           reason: .unsupportedValue("expected fast or normal")))
                }
            }

            let tune = (float("tune") ?? 0) + Float(int("transpose") ?? 0) * 100
            // SFZ `end` is the last frame to play, inclusive; `sampleEnd` is exclusive.
            let sampleEnd = int("end").map { $0 + 1 }

            zones.append(Zone(
                id: SFZImporter.zoneID(index: zones.count, sample: sample),
                sample: sample,
                key: placement,
                velocity: min(loVelocity, hiVelocity)...max(loVelocity, hiVelocity),
                seqPosition: max(1, int("seq_position") ?? 1),
                seqLength: max(1, int("seq_length") ?? 1),
                group: int("group"),
                offBy: int("off_by"),
                offMode: offMode,
                sampleStart: max(0, int("offset") ?? 0),
                sampleEnd: sampleEnd,
                gainDB: float("volume") ?? 0,
                pan: min(1, max(-1, (float("pan") ?? 0) / 100)),
                tuneCents: tune,
                envelope: envelope,
                loop: loop
            ))
            selections.append(Selection(keyswitch: note("sw_last"), random: random))
        }

        mutating func finish() -> SFZImport {
            var kept: [Zone] = []
            var keptSelections: [Selection] = []

            // One articulation: the default, or the lowest switch when the file names none.
            let switches = Set(selections.compactMap(\.keyswitch))
            let chosen = keyswitchDefault.flatMap { switches.contains($0) ? $0 : nil } ?? switches.min()
            for (zone, selection) in zip(zones, selections) {
                if let key = selection.keyswitch, key != chosen { switchedRegions += 1; continue }
                kept.append(zone)
                keptSelections.append(selection)
            }

            // Random alternatives become a round robin, in the order of their random ranges.
            struct Slot: Hashable { var key: KeyPlacement; var velocity: ClosedRange<Int> }
            var sets: [Slot: [(index: Int, random: Double)]] = [:]
            for (index, (zone, selection)) in zip(kept, keptSelections).enumerated() {
                guard let random = selection.random, zone.seqLength == 1 else { continue }
                sets[Slot(key: zone.key, velocity: zone.velocity), default: []].append((index, random))
            }
            var converted = 0
            for members in sets.values where members.count > 1 {
                for (position, member) in members.sorted(by: { $0.random < $1.random }).enumerated() {
                    kept[member.index].seqPosition = position + 1
                    kept[member.index].seqLength = members.count
                }
                converted += members.count
            }

            var skipped = self.skipped
            let line = 0
            if releaseRegions > 0 {
                skipped.append(SFZSkip(opcode: "trigger", value: "release", line: line, reason: .unsupportedValue(
                    "\(releaseRegions) release-trigger regions left out: this sampler plays on note-on")))
            }
            for (number, count) in controllerRegions.sorted(by: { $0.key < $1.key }) {
                skipped.append(SFZSkip(opcode: "locc\(number)", value: "", line: line, reason: .unsupportedValue(
                    "\(count) regions for another position of controller \(number) left out; its resting layer is kept")))
            }
            if controllerTriggered > 0 {
                skipped.append(SFZSkip(opcode: "on_locc", value: "", line: line, reason: .unsupportedValue(
                    "\(controllerTriggered) regions a controller triggers (pedal noise) or on no key left out")))
            }
            if switchedRegions > 0 {
                skipped.append(SFZSkip(opcode: "sw_last", value: chosen.map(String.init) ?? "", line: line, reason: .unsupportedValue(
                    "\(switchedRegions) keyswitched regions left out: only the default articulation is kept")))
            }
            if converted > 0 {
                skipped.append(SFZSkip(opcode: "lorand", value: "", line: line, reason: .unsupportedValue(
                    "\(converted) random alternatives play as a round robin instead")))
            }
            let manifest = KitManifest(name: name, kind: .sampled, zones: kept)
            return SFZImport(manifest: manifest, skipped: skipped, regionCount: regionCount)
        }
    }

    // MARK: Lexing

    enum Token {
        case header(String)
        case assignment(Assignment)
    }

    /// Removes `//` line comments and `/* … */` block comments, keeping the rest of the line intact.
    static func stripComments(_ line: String, inBlockComment: inout Bool) -> String {
        var out = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if inBlockComment {
                if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Splits a comment-free line into headers and `opcode=value` assignments.
    ///
    /// SFZ values may contain spaces (`sample=kick hard.wav`), so a value runs to the start of the
    /// next `opcode=` token rather than to the next space — that is the whole trick of the format,
    /// and why several opcodes can share one line.
    static func tokenize(_ line: String, line number: Int) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(line)
        var segmentStart = 0
        var i = 0

        func flushSegment(upTo end: Int) {
            guard end > segmentStart else { return }
            let segment = String(chars[segmentStart..<end])
            tokens += assignments(in: segment, line: number).map { Token.assignment($0) }
        }

        while i < chars.count {
            if chars[i] == "<", let close = chars[i...].firstIndex(of: ">") {
                flushSegment(upTo: i)
                let header = String(chars[(i + 1)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
                tokens.append(.header(header))
                i = close + 1
                segmentStart = i
                continue
            }
            i += 1
        }
        flushSegment(upTo: chars.count)
        return tokens
    }

    private static func isIdentifier(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    static func assignments(in segment: String, line: Int) -> [Assignment] {
        let chars = Array(segment)
        var marks: [(nameStart: Int, nameEnd: Int)] = []
        for i in chars.indices where chars[i] == "=" {
            var start = i
            while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
            guard start < i else { continue }
            // An opcode name starts the segment or follows whitespace; `a=b=c` is not two opcodes.
            guard start == 0 || chars[start - 1].isWhitespace else { continue }
            marks.append((start, i))
        }
        var out: [Assignment] = []
        for (index, mark) in marks.enumerated() {
            let valueStart = mark.nameEnd + 1
            let valueEnd = index + 1 < marks.count ? marks[index + 1].nameStart : chars.count
            guard valueStart <= valueEnd else { continue }
            let name = String(chars[mark.nameStart..<mark.nameEnd]).lowercased()
            let value = String(chars[valueStart..<valueEnd]).trimmingCharacters(in: .whitespaces)
            out.append(Assignment(name: name, value: value, line: line))
        }
        return out
    }

    /// A key value: a MIDI number, or a note name like `c4`, `f#3`, `bb-1` (SFZ's c4 = 60, which is
    /// what `MusicTheory.Pitch` uses too).
    static func noteNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return value }
        return Pitch(name: trimmed)?.midi
    }

    /// Deterministic, readable zone ids: position in the file plus a slug of the sample name, so
    /// re-importing the same pack produces the same ids and a diff of two kit.json files is useful.
    static func zoneID(index: Int, sample: String) -> ZoneID {
        let stem = (sample as NSString).lastPathComponent
        let base = (stem as NSString).deletingPathExtension
        let slug = String(base.map { $0.isLetter || $0.isNumber ? Character($0.lowercased()) : "_" })
        return ZoneID(String(format: "z%03d_%@", index + 1, slug))
    }
}
