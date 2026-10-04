import AVFoundation
import Foundation
import Synchronization

/// Instruments brought in from an SFZ pack, as the rest of the app sees them: specs with the
/// `sampled` engine, found by id beside the presets, played from a kit of their own recordings.
///
/// Each lives in a folder of its own under the directory the app keeps them in:
///
///     <directory>/<slug>/instrument.json   the spec, without its folder
///     <directory>/<slug>/kit.json          the zones, from the SFZ
///     <directory>/<slug>/samples/…         copies of the pack's audio
///
/// The samples are **copied**: a pack moved or deleted after importing does not take the
/// instrument with it, and the kit never reaches outside its own folder.
///
/// The registry is process-wide, because `InstrumentVoiceSpec.preset(id:)` is: a song names its
/// instrument by id, and every place that plays one looks it up the same way.
public enum ImportedInstruments {
    public static let specFileName = "instrument.json"
    /// The family of an import nobody could place: what every import was before they were placed.
    public static let family = "imported"

    /// What a recording is, from what it is called: a cello is a string instrument wherever it
    /// came from, and is looked for among the strings. The first word that says so decides, so
    /// "Violin Section Pizzicato" is plucked, "Bass Guitar" is a bass and "Bass Clarinet" is a
    /// wind. `family` when nothing in the name says.
    public static func family(named name: String) -> String {
        let words = name.lowercased()
        let kinds: [(family: String, words: [String])] = [
            ("bass", ["bass guitar", "electric bass", "jazz bass", "precision bass", "fretless bass", "bass vi", "upright bass",
                      "double bass pizz"]),
            ("guitar", ["guitar", "ganjo"]),
            ("plucked", ["pizz", "harp", "banjo", "koto", "mandolin", "zither", "ukulele", "lute", "dulcimer",
                         "psaltery", "cithara", "lyre", "strumstick", "dan tranh", "tagelharpa"]),
            ("organ", ["organ", "harmonium", "accordion", "melodica"]),
            ("keys", ["piano", "upright", "grand", "rhodes", "wurlitzer", "clav", "harpsichord", "celesta", "e-piano", "electric piano", "tx81z"]),
            ("bell", ["vibraphone", "vibes", "marimba", "xylophone", "glockenspiel", "bells", "bell", "chimes", "kalimba", "mbira",
                      "steel drum", "balafon", "timpani", "music box", "wine glass", "nyunga"]),
            ("brass", ["trumpet", "horn", "trombone", "tuba", "flugel", "cornet", "euphonium"]),
            ("wind", ["flute", "piccolo", "oboe", "clarinet", "bassoon", "sax", "recorder", "ocarina", "whistle", "harmonica", "pipes",
                      "didgeridoo", "shofar"]),
            ("strings", ["violin", "viola", "cello", "contrabass", "double bass", "strings", "erhu", "fiddle", "bass"]),
            ("pad", ["choir", "voice", "vocal", "oohs", "aahs"]),
        ]
        for kind in kinds where kind.words.contains(where: words.contains) { return kind.family }
        return family
    }

    private static let registry = Mutex<[InstrumentVoiceSpec]>([])

    /// Everything imported, in the order it was registered.
    public static var all: [InstrumentVoiceSpec] { registry.withLock { $0 } }

    public static func spec(id: String) -> InstrumentVoiceSpec? {
        registry.withLock { specs in specs.first { $0.id == id } }
    }

    /// Adds `spec`, or replaces the one with its id.
    public static func register(_ spec: InstrumentVoiceSpec) {
        registry.withLock { specs in
            if let index = specs.firstIndex(where: { $0.id == spec.id }) {
                specs[index] = spec
            } else {
                specs.append(spec)
            }
        }
    }

    public static func unregister(id: String) {
        registry.withLock { specs in specs.removeAll { $0.id == id } }
        ranges.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// The keys each imported instrument's recordings reach, noted as its kit is read at load, so
    /// a list of them says their ranges without reading every kit again.
    private static let ranges = Mutex<[String: ClosedRange<Int>]>([:])

    /// The keys an imported instrument's recordings reach: noted at load, else read from its kit
    /// once. Nil for an instrument with no recordings, or a kit that does not load.
    public static func range(of spec: InstrumentVoiceSpec) -> ClosedRange<Int>? {
        if let known = ranges.withLock({ $0[spec.id] }) { return known }
        guard let low = lowestNote(of: spec), let high = highestNote(of: spec), low <= high else { return nil }
        ranges.withLock { $0[spec.id] = low...high }
        return low...high
    }

    static func noteRange(of manifest: KitManifest) -> ClosedRange<Int>? {
        guard let low = manifest.zones.map(\.key.noteRange.lowerBound).min(),
              let high = manifest.zones.map(\.key.noteRange.upperBound).max(), low <= high else { return nil }
        return low...high
    }

    // MARK: On disk

    /// Registers every instrument in `directory` and returns them. A folder that does not load is
    /// skipped, not fatal: one broken import must not cost the rest.
    @discardableResult
    public static func load(from directory: URL) -> [InstrumentVoiceSpec] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        var found: [InstrumentVoiceSpec] = []
        for name in names where !name.hasPrefix(".") {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(specFileName)),
                  var spec = try? JSONDecoder().decode(InstrumentVoiceSpec.self, from: data),
                  spec.engine == .sampled,
                  let kit = try? KitStore.load(from: folder) else { continue }
            // Imported before instruments were levelled, or under another levelling: level it now.
            if !isLevelled(folder) {
                _ = try? KitStore.save(KitLevel.levelled(kit.manifest, in: folder), to: folder)
                try? markLevelled(folder)
            }
            spec.sampledKit = folder.path
            // Brought in before imports were placed: placed now, by name, and only in memory.
            if spec.family == family { spec.family = family(named: spec.name) }
            register(spec)
            if let range = noteRange(of: kit.manifest) { ranges.withLock { $0[spec.id] = range } }
            found.append(spec)
        }
        return found
    }

    /// Beside a kit: the levelling it was given (`levelVersion`).
    static let levelFileName = "level.json"
    /// Bump when `KitLevel.levelled` changes: every imported kit is levelled again on load. Its
    /// own, not `KitLevel.version`, which would render every synthesized kit again for nothing.
    public static let levelVersion = "imported-level-3"

    static func isLevelled(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(levelFileName)),
              let stamp = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return stamp["version"] == levelVersion
    }

    static func markLevelled(_ folder: URL) throws {
        do {
            try JSONEncoder().encode(["version": levelVersion])
                .write(to: folder.appendingPathComponent(levelFileName), options: .atomic)
        } catch {
            throw KitError.writeFailed(path: levelFileName, reason: "\(error)")
        }
    }

    /// What an import did, for the person who asked for it.
    public struct Imported: Sendable, Hashable {
        public var spec: InstrumentVoiceSpec
        public var zones: Int
        public var samples: Int
        /// The SFZ's opcodes the kit does not honour (filters, LFOs, crossfades…), by name.
        public var skippedOpcodes: [String]
        /// Samples the SFZ names that were not there, or could not be read as audio.
        public var unusable: [String]
        /// Whether it replaced an earlier import of the same name.
        public var replaced: Bool
    }

    public enum ImportError: Error, Hashable, Sendable, CustomStringConvertible {
        case noRegions(file: String)
        case noSamples(file: String, unusable: [String])

        public var description: String {
            switch self {
            case .noRegions(let file):
                return "\(file) has no regions an instrument can play."
            case .noSamples(let file, let unusable):
                let named = unusable.prefix(3).joined(separator: ", ")
                return "None of \(file)'s samples could be read (\(named)\(unusable.count > 3 ? "…" : ""))."
            }
        }
    }

    /// Imports the `.sfz` at `url` into `directory` and registers it.
    ///
    /// Samples that are missing or are not audio this Mac can decode (Ogg Vorbis, most often) are
    /// left out with their zones, and named in the result; an SFZ none of whose samples survive is
    /// an error. Building happens in a hidden folder beside the others and is moved into place
    /// only when it is whole, so a failed import never leaves half an instrument behind.
    /// - Parameter register: false for a recording that is not played as an instrument — hand
    ///   percussion brought in for `RecordedPercussion`, which kits use and the picker never shows.
    /// - Parameters:
    ///   - name: what it is called; the SFZ's own name when nil.
    ///   - family: where a picker lists it; what its name says it is when nil.
    public static func importSFZ(at url: URL, into directory: URL, register: Bool = true, name: String? = nil,
                                 family: String? = nil) throws -> Imported {
        let fm = FileManager.default
        let parsed = try SFZImporter.importKit(at: url, name: name)
        guard !parsed.manifest.zones.isEmpty else { throw ImportError.noRegions(file: url.lastPathComponent) }

        let slug = slug(of: parsed.manifest.name)
        let folder = directory.appendingPathComponent(slug, isDirectory: true)
        let staging = directory.appendingPathComponent(".\(slug)-importing", isDirectory: true)
        try? fm.removeItem(at: staging)
        let samplesFolder = staging.appendingPathComponent("samples", isDirectory: true)
        do {
            try fm.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: samplesFolder.path, reason: "\(error)")
        }
        defer { try? fm.removeItem(at: staging) }

        let source = url.deletingLastPathComponent()
        var copied: [String: String] = [:]
        var rates: [String: Double] = [:]
        var unusable: [String] = []
        var zones: [Zone] = []
        for zone in parsed.manifest.zones {
            if unusable.contains(zone.sample) { continue }
            let path: String
            if let known = copied[zone.sample] {
                path = known
            } else {
                let from = KitPath.resolve(zone.sample, in: source).standardizedFileURL
                guard fm.fileExists(atPath: from.path), let audio = try? AVAudioFile(forReading: from) else {
                    unusable.append(zone.sample)
                    continue
                }
                let file = "\(copied.count + 1)-\(from.lastPathComponent)"
                do {
                    try fm.copyItem(at: from, to: samplesFolder.appendingPathComponent(file))
                } catch {
                    throw KitError.writeFailed(path: file, reason: "\(error)")
                }
                path = "samples/\(file)"
                copied[zone.sample] = path
                rates[zone.sample] = audio.fileFormat.sampleRate
            }
            var kept = atPlayingRate(zone, recordedAt: rates[zone.sample] ?? playingRate)
            kept.sample = path
            zones.append(kept)
        }
        guard !zones.isEmpty else { throw ImportError.noSamples(file: url.lastPathComponent, unusable: unusable) }

        var manifest = parsed.manifest
        manifest.zones = zones
        manifest.description = "Imported from \(url.lastPathComponent)."
        // As loud as the instruments the app makes, root by root, the pack's dynamics kept.
        manifest = KitLevel.levelled(manifest, in: staging)
        _ = try KitStore.save(manifest, to: staging)
        try markLevelled(staging)

        var spec = InstrumentVoiceSpec(
            id: "sfz-\(slug)", name: manifest.name, family: family ?? Self.family(named: manifest.name), engine: .sampled,
            summary: summary(of: zones, samples: copied.count, file: url.lastPathComponent))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(spec).write(to: staging.appendingPathComponent(specFileName), options: .atomic)
        } catch {
            throw KitError.writeFailed(path: specFileName, reason: "\(error)")
        }

        let replaced = fm.fileExists(atPath: folder.path)
        if replaced { try? fm.removeItem(at: folder) }
        do {
            try fm.moveItem(at: staging, to: folder)
        } catch {
            throw KitError.writeFailed(path: folder.path, reason: "\(error)")
        }
        spec.sampledKit = folder.path
        if register { self.register(spec) }
        return Imported(spec: spec, zones: zones.count, samples: copied.count,
                        skippedOpcodes: parsed.skippedOpcodeNames, unusable: unusable, replaced: replaced)
    }

    /// The rate recordings are decoded to and played at. A zone's offset, end and loop points are
    /// frames of the decoded audio.
    static let playingRate: Double = 48_000

    /// `zone` with the places an SFZ counts in the recording's own frames — where it starts, where
    /// it ends, where it loops — counted in frames at the rate it is played at. A loop written for
    /// a 44.1 kHz recording and read against the same recording at 48 kHz turns a tenth early, and
    /// is heard.
    static func atPlayingRate(_ zone: Zone, recordedAt rate: Double) -> Zone {
        guard rate > 0, rate != playingRate else { return zone }
        func moved(_ frame: Int) -> Int { Int((Double(frame) * playingRate / rate).rounded()) }
        var zone = zone
        zone.sampleStart = moved(zone.sampleStart)
        zone.sampleEnd = zone.sampleEnd.map(moved)
        if let loop = zone.loop {
            zone.loop = Loop(mode: loop.mode, start: moved(loop.start), end: moved(loop.end))
        }
        return zone
    }

    /// The lowest key any of an instrument's recordings plays, or nil when its kit does not load.
    public static func lowestNote(of spec: InstrumentVoiceSpec) -> Int? {
        guard let folder = spec.sampledKit,
              let kit = try? KitStore.load(from: URL(fileURLWithPath: folder, isDirectory: true)) else { return nil }
        return kit.manifest.zones.map(\.key.noteRange.lowerBound).min()
    }

    /// The highest key any of an instrument's recordings plays, or nil when its kit does not load.
    public static func highestNote(of spec: InstrumentVoiceSpec) -> Int? {
        guard let folder = spec.sampledKit,
              let kit = try? KitStore.load(from: URL(fileURLWithPath: folder, isDirectory: true)) else { return nil }
        return kit.manifest.zones.map(\.key.noteRange.upperBound).max()
    }

    /// Takes an imported instrument out of the app: its folder, copies and all. The pack it came
    /// from is not touched.
    public static func remove(id: String) throws {
        guard let spec = spec(id: id), let folder = spec.sampledKit else { return }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: folder, isDirectory: true))
        unregister(id: id)
    }

    // MARK: Helpers

    /// A folder name from a pack's name: lowercase letters, digits and dashes.
    static func slug(of name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "instrument" : String(collapsed.prefix(48))
    }

    /// "Sampled, from Upright.sfz: 88 zones from 30 recordings, A0–C8."
    static func summary(of zones: [Zone], samples: Int, file: String) -> String {
        let low = zones.map(\.key.noteRange.lowerBound).min() ?? 0
        let high = zones.map(\.key.noteRange.upperBound).max() ?? 127
        let span = low == high ? noteName(low) : "\(noteName(low))–\(noteName(high))"
        return "Sampled, from \(file): \(zones.count) zone\(zones.count == 1 ? "" : "s") from \(samples) recording\(samples == 1 ? "" : "s"), \(span)."
    }

    static func noteName(_ midi: Int) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return "\(names[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }
}
