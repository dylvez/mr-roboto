import Foundation
import SongGraph

// MARK: - Zone lookup

extension KitManifest {
    /// Every zone that covers (`note`, `velocity`), ordered deterministically by round-robin
    /// position and then by id. Ties (two zones with the same position covering the same point)
    /// are an authoring error — `validate` reports them — and the order here is still stable.
    public func candidates(note: Int, velocity: Int) -> [Zone] {
        zones.filter { $0.contains(note: note, velocity: velocity) }
            .sorted { ($0.seqPosition, $0.id) < ($1.seqPosition, $1.id) }
    }

    /// The zone to play for a note, velocity and round-robin counter — deterministic, so the same
    /// inputs always pick the same sample and a render can be reproduced.
    ///
    /// The counter is free-running: the caller keeps one per (kit, note) and increments it on every
    /// hit; this wraps it into the set. Selection:
    ///
    /// 1. Zones covering the note and velocity are the candidates.
    /// 2. The set length is the largest `seqLength` among them (1 when there is no round robin).
    /// 3. The wanted position is `roundRobin mod length + 1`.
    /// 4. If no candidate declares that position — a set with a hole — the nearest lower position
    ///    is used, wrapping to the highest position when there is none below. A hole therefore
    ///    repeats a sample rather than dropping a hit; `validate` reports it.
    ///
    /// - Returns: nil only when nothing covers (note, velocity).
    ///
    /// Two more choices come first in a kit that has them, and are no choice in one that does not:
    ///
    /// - `layer`, the player of a section the note was dealt to (`Zone.layer`). A note for no
    ///   player is the top one's; a player with nothing on the note gives way to any that has.
    /// - `length`, how long the note is held, in seconds. A note no longer than a short
    ///   recording's `longest` is played on it; any other, or one of unknown length — a key held
    ///   on a controller — on the held recording. Where only one of the two covers the note, it
    ///   plays.
    public func zone(note: Int, velocity: Int, roundRobin: Int = 0, layer: Int? = nil, length: Double? = nil) -> Zone? {
        var candidates = candidates(note: note, velocity: velocity)
        guard !candidates.isEmpty else { return nil }
        if candidates.contains(where: { $0.layer != nil }) {
            let player = candidates.filter { ($0.layer ?? 0) == (layer ?? 0) }
            if !player.isEmpty { candidates = player }
        }
        if candidates.contains(where: { $0.longest != nil }) {
            let short = candidates.filter { zone in zone.longest.map { limit in length.map { $0 <= limit } ?? false } ?? false }
            let held = candidates.filter { $0.longest == nil }
            candidates = !short.isEmpty ? short : (held.isEmpty ? candidates : held)
        }
        let set = max(1, candidates.map(\.seqLength).max() ?? 1)
        let wanted = (((roundRobin % set) + set) % set) + 1
        if let exact = candidates.first(where: { $0.seqPosition == wanted }) { return exact }
        if let below = candidates.last(where: { $0.seqPosition < wanted }) { return below }
        return candidates.last
    }

    /// Zone lookup addressed the way a `Groove` speaks: a drum voice and a velocity tier.
    /// Returns nil when the kit maps no note for the voice, or when the tier is `.rest`.
    public func zone(for voice: DrumVoice, tier: VelocityTier, roundRobin: Int = 0) -> Zone? {
        guard tier != .rest, let note = note(for: voice) else { return nil }
        return zone(note: note, velocity: tier.velocity, roundRobin: roundRobin)
    }

    /// Zone lookup for a drum voice at an explicit MIDI velocity.
    public func zone(for voice: DrumVoice, velocity: Int, roundRobin: Int = 0) -> Zone? {
        guard let note = note(for: voice) else { return nil }
        return zone(note: note, velocity: velocity, roundRobin: roundRobin)
    }

    /// Notes with at least one zone, ascending.
    public var mappedNotes: [Int] {
        var notes = Set<Int>()
        for zone in zones { notes.formUnion(zone.key.noteRange) }
        return notes.sorted()
    }
}

// MARK: - Validation

/// One problem found in a kit. Structured, not a string: callers decide how to present it, and
/// tests match on the case rather than on wording.
public enum KitFinding: Hashable, Sendable, CustomStringConvertible {
    /// Two zones answer the same note, velocity and round-robin position: which one plays is
    /// arbitrary from the author's point of view.
    case overlappingZones(ZoneID, ZoneID, notes: ClosedRange<Int>, velocities: ClosedRange<Int>)
    /// Notes whose velocity coverage has a hole: a hit in `missing` produces silence.
    case velocityGap(notes: ClosedRange<Int>, missing: ClosedRange<Int>)
    /// A zone names a file that is not in the kit folder.
    case missingSample(ZoneID, path: String)
    /// A round-robin set declares `seqLength` but is missing positions.
    case roundRobinHole(notes: ClosedRange<Int>, velocities: ClosedRange<Int>, seqLength: Int, missing: [Int])
    /// A sample path that would not survive moving the folder.
    case absoluteSamplePath(ZoneID, path: String)

    /// Findings that make the kit unplayable as authored are errors; the rest are warnings.
    public var severity: Severity {
        switch self {
        case .missingSample, .absoluteSamplePath: return .error
        case .overlappingZones, .velocityGap, .roundRobinHole: return .warning
        }
    }

    public enum Severity: String, Hashable, Sendable, Comparable, CaseIterable {
        case warning, error
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public var description: String {
        switch self {
        case .overlappingZones(let a, let b, let notes, let velocities):
            return "Zones \(a) and \(b) overlap on notes \(notes.lowerBound)…\(notes.upperBound) velocity \(velocities.lowerBound)…\(velocities.upperBound)."
        case .velocityGap(let notes, let missing):
            return "Notes \(notes.lowerBound)…\(notes.upperBound) have no zone for velocity \(missing.lowerBound)…\(missing.upperBound)."
        case .missingSample(let id, let path):
            return "Zone \(id) references missing sample \"\(path)\"."
        case .roundRobinHole(let notes, let velocities, let length, let missing):
            return "Round robin of \(length) on notes \(notes.lowerBound)…\(notes.upperBound) velocity \(velocities.lowerBound)…\(velocities.upperBound) is missing positions \(missing.map(String.init).joined(separator: ", "))."
        case .absoluteSamplePath(let id, let path):
            return "Zone \(id) uses the absolute path \"\(path)\"; kit samples must be relative to the kit folder."
        }
    }
}

/// The result of validating a kit.
public struct KitValidation: Hashable, Sendable {
    public var findings: [KitFinding]

    public init(findings: [KitFinding] = []) { self.findings = findings }

    public var errors: [KitFinding] { findings.filter { $0.severity == .error } }
    public var warnings: [KitFinding] { findings.filter { $0.severity == .warning } }
    /// True when nothing at all was found.
    public var isClean: Bool { findings.isEmpty }
    /// True when the kit can be loaded and played, warnings and all.
    public var isPlayable: Bool { errors.isEmpty }
}

extension KitManifest {
    /// Checks the kit for the four problems that bite in practice: overlapping zones, gaps in
    /// velocity coverage, missing sample files, and round-robin sets with holes.
    ///
    /// - Parameter folder: the kit folder to resolve sample paths against. Pass nil to skip the
    ///   file-existence checks (validating a manifest that is not on disk yet).
    public func validate(resolvingSamplesAgainst folder: URL? = nil) -> KitValidation {
        var findings: [KitFinding] = []
        findings += overlapFindings()
        findings += velocityGapFindings()
        findings += roundRobinFindings()
        findings += samplePathFindings(folder: folder)
        return KitValidation(findings: findings)
    }

    // Two zones conflict when they cover a common note and velocity *at the same round-robin
    // position*: a round-robin set is supposed to overlap, the position is what separates its members.
    private func overlapFindings() -> [KitFinding] {
        var findings: [KitFinding] = []
        let ordered = zones.sorted { $0.id < $1.id }
        for i in ordered.indices {
            for j in ordered.index(after: i)..<ordered.endIndex {
                let a = ordered[i], b = ordered[j]
                guard a.seqPosition == b.seqPosition else { continue }
                guard let notes = a.key.noteRange.intersection(b.key.noteRange),
                      let velocities = a.velocity.intersection(b.velocity) else { continue }
                findings.append(.overlappingZones(a.id, b.id, notes: notes, velocities: velocities))
            }
        }
        return findings
    }

    // Per mapped note, the velocities 1…127 no zone answers, then consecutive notes with identical
    // gaps are coalesced so a 24-key kit does not produce 24 copies of the same finding.
    private func velocityGapFindings() -> [KitFinding] {
        var gapsByNote: [Int: [ClosedRange<Int>]] = [:]
        for note in mappedNotes {
            var covered = [Bool](repeating: false, count: 128)
            for zone in zones where zone.key.contains(note) {
                for v in max(1, zone.velocity.lowerBound)...min(127, zone.velocity.upperBound) { covered[v] = true }
            }
            var gaps: [ClosedRange<Int>] = []
            var start: Int?
            for v in 1...127 {
                if covered[v] {
                    if let s = start { gaps.append(s...(v - 1)); start = nil }
                } else if start == nil {
                    start = v
                }
            }
            if let s = start { gaps.append(s...127) }
            if !gaps.isEmpty { gapsByNote[note] = gaps }
        }
        var findings: [KitFinding] = []
        for (noteRange, gaps) in coalesce(gapsByNote) {
            for gap in gaps { findings.append(.velocityGap(notes: noteRange, missing: gap)) }
        }
        return findings
    }

    // A round-robin set is the zones sharing a note and velocity region; a declared seq_length with
    // missing positions means one slot silently repeats another.
    private func roundRobinFindings() -> [KitFinding] {
        struct Region: Hashable { var notes: ClosedRange<Int>; var velocities: ClosedRange<Int> }
        var sets: [Region: [Zone]] = [:]
        for zone in zones where zone.seqLength > 1 {
            sets[Region(notes: zone.key.noteRange, velocities: zone.velocity), default: []].append(zone)
        }
        var findings: [KitFinding] = []
        for (region, members) in sets.sorted(by: { lhs, rhs in
            (lhs.key.notes.lowerBound, lhs.key.velocities.lowerBound) < (rhs.key.notes.lowerBound, rhs.key.velocities.lowerBound)
        }) {
            let length = members.map(\.seqLength).max() ?? 1
            let present = Set(members.map(\.seqPosition))
            let missing = (1...length).filter { !present.contains($0) }
            if !missing.isEmpty {
                findings.append(.roundRobinHole(notes: region.notes, velocities: region.velocities,
                                                seqLength: length, missing: missing))
            }
        }
        return findings
    }

    private func samplePathFindings(folder: URL?) -> [KitFinding] {
        var findings: [KitFinding] = []
        for zone in zones.sorted(by: { $0.id < $1.id }) {
            if KitPath.isAbsolute(zone.sample) {
                findings.append(.absoluteSamplePath(zone.id, path: zone.sample))
                continue
            }
            guard let folder else { continue }
            let url = KitPath.resolve(zone.sample, in: folder)
            if !FileManager.default.fileExists(atPath: url.path) {
                findings.append(.missingSample(zone.id, path: zone.sample))
            }
        }
        return findings
    }

    /// Merges runs of consecutive notes that have the same gap list into one note range.
    private func coalesce(_ gapsByNote: [Int: [ClosedRange<Int>]]) -> [(ClosedRange<Int>, [ClosedRange<Int>])] {
        var result: [(ClosedRange<Int>, [ClosedRange<Int>])] = []
        for note in gapsByNote.keys.sorted() {
            let gaps = gapsByNote[note]!
            if var last = result.last, last.0.upperBound + 1 == note, last.1 == gaps {
                last.0 = last.0.lowerBound...note
                result[result.count - 1] = last
            } else {
                result.append((note...note, gaps))
            }
        }
        return result
    }
}

extension ClosedRange where Bound: Comparable {
    /// The overlap of two closed ranges, or nil when they are disjoint.
    func intersection(_ other: ClosedRange) -> ClosedRange? {
        let low = Swift.max(lowerBound, other.lowerBound)
        let high = Swift.min(upperBound, other.upperBound)
        return low <= high ? low...high : nil
    }
}
