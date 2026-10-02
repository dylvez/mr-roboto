import AVFoundation
import Foundation
import Synchronization

/// Recordings that stand in for the synthesized hand percussion in every kit.
///
/// A kit's congas, shaker and claves are synthesized (`SynthMachine+Percussion.swift`) unless a
/// set of recordings is switched on. Then each voice the set assigns plays that recording instead,
/// in every kit, on every machine: `SynthesizedKit.build` copies the recording's zones — all its
/// velocity layers and round robins — into the kit in the voice's place.
///
/// Each layer is brought to the loudness of the synthesized voice it replaces, as the synthesized
/// layers are: the kit's velocity curve applies the level once, on playback, and what is left in a
/// layer is how a soft stroke differs from a hard one. So a kit keeps the balance its machine set,
/// whichever congas are in it.
///
/// On disk, under the directory the app keeps them in:
///
///     <directory>/recorded.json        the set: which recording plays which voice, and whether it is on
///     <directory>/<slug>/kit.json      a recording, imported from its SFZ (`ImportedInstruments.importSFZ`)
///     <directory>/<slug>/samples/…
///
/// The set is process-wide, like the imported instruments: every place that builds a kit asks
/// `SynthesizedKit.build`, and a kit's folder name carries the set's fingerprint, so switching it
/// on or off builds kits afresh rather than playing the ones from before.
public struct RecordedPercussion: Codable, Hashable, Sendable {
    /// One voice, played by one key of one recording.
    public struct Assignment: Codable, Hashable, Sendable {
        public var kind: SynthVoiceKind
        /// The recording's folder under the percussion directory.
        public var source: String
        /// The key of the recording that is this voice.
        public var note: Int
        /// What it is, for a person: "VCSL quinto, open tone".
        public var label: String

        public init(kind: SynthVoiceKind, source: String, note: Int, label: String) {
            self.kind = kind
            self.source = source
            self.note = note
            self.label = label
        }
    }

    public static let fileName = "recorded.json"

    public var name: String
    public var isOn: Bool
    public var assignments: [Assignment]
    /// Machines, by id, that keep their synthesized percussion with the set on: an 808's congas
    /// are its own tom circuits, and part of why it sounds like an 808.
    public var keepSynthesized: [String]

    /// The machines whose percussion is modelled on their own circuits (`handPercussion(electronic:)`).
    public static let defaultKeepSynthesized = ["tr808", "cr78", "tr606"]

    public init(name: String, isOn: Bool = true, assignments: [Assignment],
                keepSynthesized: [String] = RecordedPercussion.defaultKeepSynthesized) {
        self.name = name
        self.isOn = isOn
        self.assignments = assignments
        self.keepSynthesized = keepSynthesized
    }

    private enum CodingKeys: String, CodingKey { case name, isOn, assignments, keepSynthesized }

    /// A set saved before machines could keep their own percussion keeps the default ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isOn = try c.decode(Bool.self, forKey: .isOn)
        assignments = try c.decode([Assignment].self, forKey: .assignments)
        keepSynthesized = try c.decodeIfPresent([String].self, forKey: .keepSynthesized) ?? Self.defaultKeepSynthesized
    }

    /// Whether `machine` plays the recordings rather than its own percussion.
    public func applies(to machine: String) -> Bool { isOn && !keepSynthesized.contains(machine) }

    // MARK: The set in use

    /// A set with its recordings loaded: what a kit is built with.
    public struct Resolved: Sendable, Hashable {
        public var set: RecordedPercussion
        var kits: [String: LoadedKit]
        /// Salts a kit's fingerprint, so a kit with recordings in it is a different kit.
        public var fingerprint: String

        init(set: RecordedPercussion, kits: [String: LoadedKit], fingerprint: String) {
            self.set = set
            self.kits = kits
            self.fingerprint = fingerprint
        }

        /// This set for `machine`: itself, or nil when the machine keeps its synthesized percussion.
        public func `for`(_ machine: String) -> Resolved? { set.applies(to: machine) ? self : nil }
    }

    private static let active = Mutex<Resolved?>(nil)

    /// The set kits are built with, when one is on.
    public static var current: RecordedPercussion? { active.withLock { $0?.set } }

    /// The set in use, loaded — `SynthesizedKit.build`'s default.
    public static var inUse: Resolved? { active.withLock { $0 } }

    /// `set` with its recordings from `directory`, or nil when it is off or none of them loads. An
    /// assignment whose recording does not load is left out.
    public static func resolve(_ set: RecordedPercussion?, in directory: URL) -> Resolved? {
        guard let set, set.isOn else { return nil }
        var kits: [String: LoadedKit] = [:]
        for source in Set(set.assignments.map(\.source)) {
            if let kit = try? KitStore.load(from: directory.appendingPathComponent(source, isDirectory: true)) {
                kits[source] = kit
            }
        }
        var usable = set
        usable.assignments = set.assignments.filter { kits[$0.source] != nil }
        guard !usable.assignments.isEmpty else { return nil }
        return Resolved(set: usable, kits: kits, fingerprint: KitFingerprint.of(usable.assignments, salt: "recorded-3"))  // bump when how recordings go into a kit changes
    }

    /// Puts `set` in use with its recordings from `directory`, or takes the one in use away (nil,
    /// or a set that is off).
    public static func activate(_ set: RecordedPercussion?, in directory: URL) {
        let resolved = resolve(set, in: directory)
        active.withLock { $0 = resolved }
    }

    /// Reads the set in `directory` and puts it in use if it is on. Returns it, on or off.
    @discardableResult
    public static func load(from directory: URL) -> RecordedPercussion? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let set = try? JSONDecoder().decode(RecordedPercussion.self, from: data) else {
            activate(nil, in: directory)
            return nil
        }
        activate(set, in: directory)
        return set
    }

    /// Writes the set to `directory` and puts it in use (or out of use, when it is off).
    public static func save(_ set: RecordedPercussion, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(set).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw KitError.writeFailed(path: fileName, reason: "\(error)")
        }
        activate(set, in: directory)
    }

    /// The recording playing `kind` in `resolved`: its kit and the zones on its key.
    static func recording(for kind: SynthVoiceKind, in resolved: Resolved) -> (kit: LoadedKit, zones: [Zone], assignment: Assignment)? {
        guard let assignment = resolved.set.assignments.first(where: { $0.kind == kind }),
              let kit = resolved.kits[assignment.source] else { return nil }
        let zones = kit.manifest.zones.filter { $0.key.noteRange.contains(assignment.note) }
        return zones.isEmpty ? nil : (kit, zones, assignment)
    }

    // MARK: Into a kit

    /// `kind`'s recorded zones for a kit being built in `folder`, each layer at `loudness` (the
    /// synthesized voice's, as the kit plays it) and on `note`. The samples are copied into the kit,
    /// so a kit never reaches outside its own folder. Nil when no recording plays `kind`.
    ///
    /// - Parameter dust: the voice's own chain, when it has one. The recording is put through it
    ///   at the level the kit plays it and written into the kit as it comes out.
    static func zones(for kind: SynthVoiceKind, from resolved: Resolved, note: Int, loudness: Double,
                      dust: DegradeSettings? = nil, in folder: URL) throws -> [Zone]? {
        guard let recording = recording(for: kind, in: resolved) else { return nil }
        let fm = FileManager.default
        var out: [Zone] = []
        for (index, zone) in recording.zones.enumerated() {
            let from = KitPath.resolve(zone.sample, in: recording.kit.folder)
            var relative = "samples/recorded/\(recording.assignment.source)/\((from.path as NSString).lastPathComponent)"
            // Every layer to the voice's loudness, as the synthesized layers are; never over the
            // kit's ceiling.
            var gain: Float = 1
            if let file = KitLevel.heard(from) {
                let own = KitLevel.loudness(file.mono, sampleRate: file.rate)
                let peak = Double(file.peak)
                if own > 1e-6, peak > 0 {
                    gain = Float(min(loudness / own, pow(10, KitLevel.ceilingDBFS / 20) / peak))
                }
            }
            if let dust, !dust.isBypass {
                // Through the chain at the level it is played at, and the level written into the
                // file: a quiet recording crushed to twelve bits and raised afterwards is the
                // converter's noise raised with it, which is not what the chain sounds like on a drum.
                relative = "samples/recorded/\(recording.assignment.source)/\(from.deletingPathExtension().lastPathComponent).dust.wav"
                let to = KitPath.resolve(relative, in: folder)
                if !fm.fileExists(atPath: to.path) {
                    let decoded = try SampleCache.decodeFile(from, ImportedInstruments.playingRate)
                    let played = decoded.channels.map { channel in channel.map { $0 * gain } }
                    try SynthesizedKit.writeWAV(planar: try SynthesizedKit.dusted(played, through: dust, sampleRate: decoded.sampleRate),
                                                to: to, sampleRate: decoded.sampleRate)
                }
                gain = 1
            } else {
                let to = KitPath.resolve(relative, in: folder)
                if !fm.fileExists(atPath: to.path) {
                    do {
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: from, to: to)
                    } catch {
                        throw KitError.writeFailed(path: relative, reason: "\(error)")
                    }
                }
            }
            var placed = zone
            placed.id = ZoneID("\(kind.fileStem)_recorded_\(index + 1)")
            placed.sample = relative
            // Played at the pitch it was recorded at, on the kit's key for the voice.
            placed.tuneCents += Float(recording.assignment.note - zone.key.rootNote) * 100
            placed.key = .note(note)
            // Instead of the recording's own volume, not on top of it: the gain above already
            // brings the file itself to the voice's loudness, and packs like VCSL raise quiet
            // recordings 12 to 30 dB with `volume` — counted twice, a conga was 25 dB over the kit.
            placed.gainDB = 20 * log10(max(gain, 1e-6))
            // One pair of hats, recorded or not: either cuts the other. Nothing else chokes.
            let isHat = kind == .closedHat || kind == .openHat
            placed.group = isHat ? SynthesizedKit.hatChokeGroup : nil
            placed.offBy = isHat ? SynthesizedKit.hatChokeGroup : nil
            placed.loop = nil
            out.append(placed)
        }
        return out
    }

    // MARK: VCSL

    /// The Versilian Community Sample Library's hand percussion (CC0), by file and key: the open
    /// tones of the quinto and tumba for the congas, the open hits of the bongos, the small
    /// shaker's down-stroke, a tambourine hit and the claves. VCSL has no woodblock.
    /// <https://github.com/sgossner/VCSL>
    public static let vcsl: [(kind: SynthVoiceKind, file: String, note: Int, label: String)] = [
        (.highConga, "Membranophones/Struck Membranophones/Conga.sfz", 63, "VCSL quinto, open tone"),
        (.lowConga, "Membranophones/Struck Membranophones/Conga.sfz", 65, "VCSL tumba, open tone"),
        (.highBongo, "Membranophones/Struck Membranophones/Bongos.sfz", 60, "VCSL bongo, macho"),
        (.lowBongo, "Membranophones/Struck Membranophones/Bongos.sfz", 63, "VCSL bongo, hembra"),
        (.shaker, "Idiophones/Struck Idiophones/Shaker, Small.sfz", 64, "VCSL small shaker, down-stroke"),
        (.tambourine, "Idiophones/Struck Idiophones/Tambourine 1.sfz", 60, "VCSL tambourine, hit"),
        (.claves, "Idiophones/Struck Idiophones/Claves.sfz", 60, "VCSL claves"),
    ]

    /// Imports VCSL's hand percussion from the library's checkout at `root` into `directory`,
    /// saves the set and puts it in use. A file VCSL's checkout lacks leaves its voices
    /// synthesized; none at all is an error.
    @discardableResult
    public static func importVCSL(from root: URL, into directory: URL) throws -> RecordedPercussion {
        var sources: [String: String] = [:]
        var assignments: [Assignment] = []
        for entry in vcsl {
            let file = root.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            if sources[entry.file] == nil {
                let imported = try ImportedInstruments.importSFZ(at: file, into: directory, register: false)
                sources[entry.file] = URL(fileURLWithPath: imported.spec.sampledKit ?? "").lastPathComponent
            }
            if let source = sources[entry.file], !source.isEmpty {
                assignments.append(Assignment(kind: entry.kind, source: source, note: entry.note, label: entry.label))
            }
        }
        guard !assignments.isEmpty else {
            throw ImportedInstruments.ImportError.noRegions(file: root.lastPathComponent)
        }
        let set = RecordedPercussion(name: "VCSL", assignments: assignments)
        try save(set, to: directory)
        return set
    }
}
