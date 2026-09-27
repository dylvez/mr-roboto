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
    public static let family = "imported"

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
                  (try? KitStore.load(from: folder)) != nil else { continue }
            spec.sampledKit = folder.path
            register(spec)
            found.append(spec)
        }
        return found
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
    public static func importSFZ(at url: URL, into directory: URL) throws -> Imported {
        let fm = FileManager.default
        let parsed = try SFZImporter.importKit(at: url)
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
        var unusable: [String] = []
        var zones: [Zone] = []
        for zone in parsed.manifest.zones {
            if unusable.contains(zone.sample) { continue }
            let path: String
            if let known = copied[zone.sample] {
                path = known
            } else {
                let from = KitPath.resolve(zone.sample, in: source).standardizedFileURL
                guard fm.fileExists(atPath: from.path), (try? AVAudioFile(forReading: from)) != nil else {
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
            }
            var kept = zone
            kept.sample = path
            zones.append(kept)
        }
        guard !zones.isEmpty else { throw ImportError.noSamples(file: url.lastPathComponent, unusable: unusable) }

        var manifest = parsed.manifest
        manifest.zones = zones
        manifest.description = "Imported from \(url.lastPathComponent)."
        _ = try KitStore.save(manifest, to: staging)

        var spec = InstrumentVoiceSpec(
            id: "sfz-\(slug)", name: manifest.name, family: family, engine: .sampled,
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
        register(spec)
        return Imported(spec: spec, zones: zones.count, samples: copied.count,
                        skippedOpcodes: parsed.skippedOpcodeNames, unusable: unusable, replaced: replaced)
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
