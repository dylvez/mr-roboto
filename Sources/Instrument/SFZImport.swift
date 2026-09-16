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
/// plus `default_path` from `<control>`. Headers `<control>`, `<global>`, `<master>`, `<group>` and
/// `<region>` are honoured with SFZ's inheritance: an opcode set at an outer level applies to every
/// region under it until a region overrides it. Any other header's opcodes, and any opcode outside
/// the list, are reported in `SFZImport.skipped`.
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
        "default_path",
    ]

    static let supportedHeaders: Set<String> = ["control", "global", "master", "group", "region"]

    /// Imports the `.sfz` at `url`. Sample paths stay relative, so the resulting kit works when
    /// `kit.json` is written beside the `.sfz` (the usual layout of a purchased pack).
    public static func importKit(at url: URL, name: String? = nil) throws -> SFZImport {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Commercial packs are often Latin-1.
            guard let fallback = try? Data(contentsOf: url),
                  let decoded = String(data: fallback, encoding: .isoLatin1) else {
                throw KitError.sfzUnreadable(path: url.path, reason: "\(error)")
            }
            text = decoded
        }
        return parse(text, name: name ?? url.deletingPathExtension().lastPathComponent)
    }

    /// Parses SFZ text. Pure: no file system access, so it is the unit under test.
    public static func parse(_ text: String, name: String) -> SFZImport {
        var parser = Parser(name: name)
        parser.run(text)
        return parser.finish()
    }

    // MARK: Parser

    struct Assignment {
        var name: String
        var value: String
        var line: Int
    }

    private struct Parser {
        let name: String
        var defaultPath = ""
        var global: [String: Assignment] = [:]
        var master: [String: Assignment] = [:]
        var group: [String: Assignment] = [:]
        var region: [String: Assignment]?
        var regionLine = 0
        var currentHeader = "global"
        var zones: [Zone] = []
        var skipped: [SFZSkip] = []
        var regionCount = 0

        init(name: String) { self.name = name }

        mutating func run(_ text: String) {
            var inBlockComment = false
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = index + 1
                let cleaned = SFZImporter.stripComments(String(rawLine), inBlockComment: &inBlockComment)
                guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
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
            guard SFZImporter.supportedOpcodes.contains(assignment.name) else {
                skipped.append(SFZSkip(opcode: assignment.name, value: assignment.value,
                                       line: assignment.line, reason: .unknownOpcode))
                return
            }
            if assignment.name == "default_path" {
                defaultPath = KitPath.normalized(assignment.value)
                if !defaultPath.isEmpty && !defaultPath.hasSuffix("/") { defaultPath += "/" }
                return
            }
            switch currentHeader {
            case "region": region?[assignment.name] = assignment
            case "group": group[assignment.name] = assignment
            case "master": master[assignment.name] = assignment
            default: global[assignment.name] = assignment
            }
        }

        /// Merges the inheritance chain and turns the pending region into a zone.
        mutating func flushRegion() {
            guard let region else { return }
            self.region = nil
            var merged = global
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
            func note(_ key: String) -> Int? { merged[key].flatMap { SFZImporter.noteNumber($0.value) } }

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
        }

        func finish() -> SFZImport {
            let manifest = KitManifest(name: name, kind: .sampled, zones: zones)
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
