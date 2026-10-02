import Foundation
import Synchronization

/// A drum kit of recordings, listed beside the machines as one of them.
///
/// The machines are synthesized, and however they are tuned they sound like machines: a kit
/// somebody hit with sticks in a room is a different thing, and the only way to have one is to
/// record it. A recorded kit is brought in from an SFZ in General MIDI layout — a kick on 36, a
/// snare on 38, hats on 42 and 46 — and its recordings take the place of those voices in a kit
/// built from a machine the app already has. That machine, the kit's `base`, does two jobs: it
/// plays whatever the recordings do not cover (a kit with no ride still has one), and it sets the
/// balance, because every recording is brought to the loudness of the voice it replaces.
///
/// Hand percussion is not taken from a kit. Past the cymbals General MIDI's keys are where packs
/// differ most — a brush kit has stirs where the congas would be — and the app has recordings of
/// hand percussion of its own (`RecordedPercussion`), which a recorded kit plays like any other.
///
/// On disk, under the directory the app keeps them in:
///
///     <directory>/<slug>/machine.json      the kit: its name, its base, which key plays which voice
///     <directory>/<slug>/kit.json          the zones, from the SFZ
///     <directory>/<slug>/samples/…         copies of the pack's audio
///
/// The registry is process-wide, because `SynthMachine.preset(id:)` is: a song names its machine
/// by id, and every place that plays one looks it up the same way.
public struct RecordedKit: Codable, Hashable, Sendable, Identifiable {
    /// `"kit-<slug>"`: what a song names.
    public var id: String
    public var name: String
    /// One line for a kit browser.
    public var summary: String
    /// The machine that plays what the recordings do not, and whose balance they are levelled to.
    public var base: String
    /// Which of the kit's keys plays which voice. `source` is the kit's own folder.
    public var assignments: [RecordedPercussion.Assignment]

    public init(id: String, name: String, summary: String, base: String, assignments: [RecordedPercussion.Assignment]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.base = base
        self.assignments = assignments
    }
}

public enum RecordedKits {
    public static let fileName = "machine.json"
    /// What a recorded kit's id starts with, so nothing else has to be asked whether an id is one.
    public static let prefix = "kit-"
    /// The machine a kit is built on when nobody says: an acoustic kit with nothing odd about it.
    public static let defaultBase = "studio"

    struct Entry: Sendable {
        var kit: RecordedKit
        var recordings: LoadedKit
    }

    private static let registry = Mutex<[Entry]>([])

    /// Every recorded kit, in the order it was registered.
    public static var all: [RecordedKit] { registry.withLock { $0.map(\.kit) } }

    public static func kit(id: String) -> RecordedKit? {
        registry.withLock { entries in entries.first { $0.kit.id == id }?.kit }
    }

    /// The kit as a machine: its base's voices under the kit's own id and name. The voices are what
    /// the recordings are levelled against and what plays where there is no recording.
    public static func machine(id: String) -> SynthMachine? {
        guard let kit = kit(id: id) else { return nil }
        let base = SynthMachine.all.first { $0.id == kit.base } ?? .studio
        return SynthMachine(id: kit.id, name: kit.name, summary: kit.summary, voices: base.voices)
    }

    public static var machines: [SynthMachine] { all.compactMap { machine(id: $0.id) } }

    static func register(_ entry: Entry) {
        registry.withLock { entries in
            if let index = entries.firstIndex(where: { $0.kit.id == entry.kit.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
    }

    public static func unregister(id: String) {
        registry.withLock { entries in entries.removeAll { $0.kit.id == id } }
    }

    // MARK: Into a kit

    /// The recordings `machine`'s kit is built with: a recorded kit's own, and the hand percussion
    /// in use for the voices it leaves; for any other machine, the hand percussion in use.
    static func recordings(for machine: SynthMachine, beside percussion: RecordedPercussion.Resolved?) -> RecordedPercussion.Resolved? {
        let shared = percussion?.for(machine.id)
        guard let entry = registry.withLock({ entries in entries.first { $0.kit.id == machine.id } }) else { return shared }
        var assignments = entry.kit.assignments
        var kits = [entry.recordings.folder.lastPathComponent: entry.recordings]
        for assignment in shared?.set.assignments ?? [] where !assignments.contains(where: { $0.kind == assignment.kind }) {
            guard let kit = shared?.kits[assignment.source] else { continue }
            // A kit and a percussion recording could share a folder's name; theirs gets a prefix.
            var placed = assignment
            placed.source = "percussion-\(assignment.source)"
            kits[placed.source] = kit
            assignments.append(placed)
        }
        let set = RecordedPercussion(name: entry.kit.name, assignments: assignments, keepSynthesized: [])
        return RecordedPercussion.Resolved(set: set, kits: kits,
                                           fingerprint: KitFingerprint.of(assignments, salt: "recorded-kit-2"))  // bump when how a kit is built changes
    }

    /// The voices of `machine` a recording plays rather than the synthesizer, each with what the
    /// recording is called: a recorded kit's own pieces, and the hand percussion in use. A voice
    /// that is not here is synthesized, and its knobs are the synthesizer's.
    public static func recordedVoices(of machine: SynthMachine,
                                      beside percussion: RecordedPercussion.Resolved? = RecordedPercussion.inUse) -> [SynthVoiceKind: String] {
        guard let resolved = recordings(for: machine, beside: percussion) else { return [:] }
        var out: [SynthVoiceKind: String] = [:]
        for spec in machine.voices {
            if let recording = RecordedPercussion.recording(for: spec.kind, in: resolved) {
                out[spec.kind] = recording.assignment.label
            }
        }
        return out
    }

    // MARK: On disk

    /// Registers every kit in `directory` and returns them. A folder that does not load is skipped.
    @discardableResult
    public static func load(from directory: URL) -> [RecordedKit] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        var found: [RecordedKit] = []
        for name in names where !name.hasPrefix(".") {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
                  let kit = try? JSONDecoder().decode(RecordedKit.self, from: data),
                  let recordings = try? KitStore.load(from: folder) else { continue }
            register(Entry(kit: kit, recordings: recordings))
            found.append(kit)
        }
        return found
    }

    /// What an import did, for the person who asked for it.
    public struct Imported: Sendable, Hashable {
        public var kit: RecordedKit
        public var samples: Int
        /// The voices the recordings play, in the kit's order.
        public var recorded: [SynthVoiceKind]
        /// The voices left to the base machine.
        public var synthesized: [SynthVoiceKind]
        public var unusable: [String]
        public var replaced: Bool
    }

    public enum ImportError: Error, Hashable, Sendable, CustomStringConvertible {
        case notAKit(file: String)

        public var description: String {
            switch self {
            case .notAKit(let file):
                return "\(file) has nothing on the keys a drum kit is laid out on: a kick on 36, a snare on 38, hats on 42 and 46."
            }
        }
    }

    /// The keys General MIDI puts each piece of a kit on, the usual one first.
    static let generalMIDI: [(kind: SynthVoiceKind, keys: [Int], label: String)] = [
        (.kick, [36, 35], "kick"),
        (.snare, [38, 40], "snare"),
        (.rim, [37], "side stick"),
        (.closedHat, [42], "closed hat"),
        (.openHat, [46], "open hat"),
        (.crash, [49, 57], "crash"),
        (.ride, [51, 59], "ride"),
    ]
    /// Where the toms are, low to high. A kit with three has them on three of these.
    static let tomKeys = [41, 43, 45, 47, 48, 50]

    /// Which of `keys` plays which voice.
    static func assignments(forKeys keys: Set<Int>, source: String, name: String) -> [RecordedPercussion.Assignment] {
        var out: [RecordedPercussion.Assignment] = []
        for piece in generalMIDI {
            guard let key = piece.keys.first(where: keys.contains) else { continue }
            out.append(.init(kind: piece.kind, source: source, note: key, label: "\(name) \(piece.label)"))
        }
        let toms = tomKeys.filter(keys.contains)
        if let low = toms.first, let high = toms.last {
            let mid = toms[toms.count / 2]
            out.append(.init(kind: .lowTom, source: source, note: low, label: "\(name) low tom"))
            out.append(.init(kind: .midTom, source: source, note: mid, label: "\(name) mid tom"))
            out.append(.init(kind: .highTom, source: source, note: high, label: "\(name) high tom"))
        }
        return out
    }

    /// Imports the `.sfz` at `url` into `directory` as a kit and registers it.
    ///
    /// - Parameters:
    ///   - name: what the kit is called; the SFZ's own name when nil.
    ///   - base: the machine that plays what the recordings do not. One the app does not have is
    ///     the Studio Kit.
    public static func importSFZ(at url: URL, into directory: URL, name: String? = nil,
                                 base: String = RecordedKits.defaultBase) throws -> Imported {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: directory.path, reason: "\(error)")
        }
        // A look before anything is copied: an instrument's SFZ is not a kit.
        let parsed = try SFZImporter.importKit(at: url, name: name)
        let keys = Set(parsed.manifest.zones.flatMap { zone in
            zone.key.noteRange.count == 1 ? [zone.key.noteRange.lowerBound] : []
        })
        let kitName = name ?? parsed.manifest.name
        guard !assignments(forKeys: keys, source: "", name: kitName).isEmpty else {
            throw ImportError.notAKit(file: url.lastPathComponent)
        }

        let imported = try ImportedInstruments.importSFZ(at: url, into: directory, register: false, name: name)
        let folder = URL(fileURLWithPath: imported.spec.sampledKit ?? "", isDirectory: true)
        let recordings = try KitStore.load(from: folder)
        let usable = Set(recordings.manifest.zones.flatMap { zone in
            zone.key.noteRange.count == 1 ? [zone.key.noteRange.lowerBound] : []
        })
        let placed = assignments(forKeys: usable, source: folder.lastPathComponent, name: kitName)
        let known = SynthMachine.all.contains { $0.id == base } ? base : defaultBase
        let machine = SynthMachine.all.first { $0.id == known } ?? .studio
        let recorded = placed.map(\.kind)
        let synthesized = machine.voices.map(\.kind).filter { kind in
            !recorded.contains(kind) && !SynthVoiceKind.handPercussion.contains(kind)
        }
        let kit = RecordedKit(
            id: "\(prefix)\(folder.lastPathComponent)", name: kitName,
            summary: summary(recorded: recorded, synthesized: synthesized, base: machine.name, file: url.lastPathComponent),
            base: known, assignments: placed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(kit).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw KitError.writeFailed(path: fileName, reason: "\(error)")
        }
        register(Entry(kit: kit, recordings: recordings))
        return Imported(kit: kit, samples: imported.samples, recorded: recorded, synthesized: synthesized,
                        unusable: imported.unusable, replaced: imported.replaced)
    }

    /// Takes a recorded kit out of the app: its folder, copies and all.
    public static func remove(id: String, from directory: URL) throws {
        guard let kit = kit(id: id), id.hasPrefix(prefix) else { return }
        let folder = directory.appendingPathComponent(String(id.dropFirst(prefix.count)), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path) {
            try FileManager.default.removeItem(at: folder)
        }
        unregister(id: kit.id)
    }

    /// "Recorded, from Kit.sfz: kick, snare, side stick and hats. The Studio Kit plays the crash and the ride."
    static func summary(recorded: [SynthVoiceKind], synthesized: [SynthVoiceKind], base: String, file: String) -> String {
        func words(_ kinds: [SynthVoiceKind]) -> String {
            var names: [String] = []
            for kind in kinds {
                switch kind {
                case .closedHat, .openHat: if !names.contains("hats") { names.append("hats") }
                case .lowTom, .midTom, .highTom: if !names.contains("toms") { names.append("toms") }
                case .rim: names.append("side stick")
                default: names.append(kind.rawValue)
                }
            }
            guard let last = names.popLast() else { return "" }
            return names.isEmpty ? last : "\(names.joined(separator: ", ")) and \(last)"
        }
        var line = "Recorded, from \(file): \(words(recorded))."
        if !synthesized.isEmpty { line += " The \(base) plays the \(words(synthesized))." }
        return line
    }
}
