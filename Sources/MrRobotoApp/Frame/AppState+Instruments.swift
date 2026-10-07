import Foundation
import Instrument
import SongGraph

// Instruments brought in from SFZ packs. They live in the library, beside the songs, because they
// are the person's own — not a cache the app could render again — and a song names one by id the
// way it names a preset.

extension AppState {
    /// `<library>/Instruments`. Nil with no library to keep them in.
    public var instrumentsDirectory: URL? {
        store?.directoryURL.appendingPathComponent("Instruments", isDirectory: true)
    }

    /// `<library>/Percussion`: recordings the kits' hand percussion can play on.
    public var percussionDirectory: URL? {
        store?.directoryURL.appendingPathComponent("Percussion", isDirectory: true)
    }

    /// Puts the library's recorded percussion in use, if it has some and it is on.
    func loadRecordedPercussion() {
        guard let directory = percussionDirectory else { return }
        recordedPercussion = RecordedPercussion.load(from: directory)
    }

    /// File ▸ Import VCSL Percussion…: the Versilian library's congas, bongos, shaker, tambourine
    /// and claves copied into the library and switched on, so every kit plays them in place of
    /// its synthesized ones.
    @discardableResult
    public func importVCSLPercussion(from root: URL) -> Bool {
        guard let directory = percussionDirectory else {
            note(.session, "No library to bring the percussion into")
            return false
        }
        do {
            let set = try RecordedPercussion.importVCSL(from: root, into: directory)
            recordedPercussion = set
            if let service = SurfaceWiring.shared.service { Task { await service.drumKitsChanged() } }
            note(.you, "Every kit's hand percussion is recorded now",
                 detail: set.assignments.map(\.label).joined(separator: ", ")
                    + ". Turn it off in the Grid's machine menu to go back to the synthesized ones.")
            return true
        } catch {
            note(.session, "Could not bring in VCSL's percussion", detail: "\(error). Choose the VCSL folder, the one holding Membranophones and Idiophones.")
            return false
        }
    }

    /// Switches the recorded hand percussion on or off in every kit.
    @discardableResult
    public func setRecordedPercussion(_ on: Bool) -> Bool {
        guard var set = recordedPercussion, set.isOn != on, let directory = percussionDirectory else { return false }
        set.isOn = on
        do {
            try RecordedPercussion.save(set, to: directory)
        } catch {
            note(.session, "Could not switch the recorded percussion \(on ? "on" : "off")", detail: "\(error)")
            return false
        }
        recordedPercussion = set
        if let service = SurfaceWiring.shared.service { Task { await service.drumKitsChanged() } }
        note(.you, on ? "Hand percussion: \(set.name) recordings" : "Hand percussion: synthesized")
        return true
    }

    /// Whether `machine` keeps its synthesized hand percussion while the recordings are on.
    @discardableResult
    public func setKeepsSynthesizedPercussion(_ machine: SynthMachine, _ keep: Bool) -> Bool {
        guard var set = recordedPercussion, set.keepSynthesized.contains(machine.id) != keep,
              let directory = percussionDirectory else { return false }
        if keep { set.keepSynthesized.append(machine.id) } else { set.keepSynthesized.removeAll { $0 == machine.id } }
        do {
            try RecordedPercussion.save(set, to: directory)
        } catch {
            note(.session, "Could not change \(machine.name)'s percussion", detail: "\(error)")
            return false
        }
        recordedPercussion = set
        if let service = SurfaceWiring.shared.service { Task { await service.drumKitsChanged() } }
        note(.you, keep ? "\(machine.name) keeps its own hand percussion" : "\(machine.name) plays the \(set.name) recordings")
        return true
    }

    /// `<library>/Kits`: drum kits of recordings, each a machine of its own.
    public var kitsDirectory: URL? {
        store?.directoryURL.appendingPathComponent("Kits", isDirectory: true)
    }

    /// Registers the library's recorded kits, so a song that plays on one finds it.
    func loadRecordedKits() {
        guard let directory = kitsDirectory else { return }
        recordedKits = RecordedKits.load(from: directory)
    }

    /// File ▸ Import Drum Kit…: an SFZ laid out as General MIDI lays a kit out, copied into the
    /// library and listed beside the machines. What the recordings do not cover the base machine
    /// plays, and says so.
    @discardableResult
    public func importDrumKit(from url: URL, named name: String? = nil, base: String = RecordedKits.defaultBase) -> RecordedKit? {
        guard let directory = kitsDirectory else {
            note(.session, "No library to import \(url.lastPathComponent) into")
            return nil
        }
        do {
            let result = try RecordedKits.importSFZ(at: url, into: directory, name: name, base: base)
            recordedKits = RecordedKits.load(from: directory)
            if let service = SurfaceWiring.shared.service { Task { await service.drumKitsChanged() } }
            var detail = [result.kit.summary]
            if !result.unusable.isEmpty {
                let named = result.unusable.prefix(3).joined(separator: ", ")
                detail.append("Left out \(result.unusable.count) sample\(result.unusable.count == 1 ? "" : "s") that could not be read: \(named)\(result.unusable.count > 3 ? "…" : "").")
            }
            note(.you, "\(result.replaced ? "Re-imported" : "Imported") \(result.kit.name): it is in the Grid's machine menu, under Recorded kits",
                 detail: detail.joined(separator: " "))
            return result.kit
        } catch {
            note(.session, "Could not import \(url.lastPathComponent) as a drum kit", detail: "\(error)")
            return nil
        }
    }

    /// Takes a recorded kit out of the library. A song that played on it falls back to the song's
    /// machine, or the TR-808, as it would for any machine it does not know.
    @discardableResult
    public func removeRecordedKit(id: String) -> Bool {
        guard let kit = RecordedKits.kit(id: id), let directory = kitsDirectory else { return false }
        do {
            try RecordedKits.remove(id: id, from: directory)
        } catch {
            note(.session, "Could not remove \(kit.name)", detail: "\(error)")
            return false
        }
        recordedKits.removeAll { $0.id == id }
        if let service = SurfaceWiring.shared.service { Task { await service.drumKitsChanged() } }
        note(.you, "Removed \(kit.name) from the library", detail: "The pack it came from is untouched.")
        return true
    }

    /// Registers what is already imported, so a song that plays one finds it. Called when the
    /// library is read.
    func loadImportedInstruments() {
        guard let directory = instrumentsDirectory else { return }
        importedInstruments = ImportedInstruments.load(from: directory)
    }

    /// File ▸ Import Instrument…: the pack's samples copied into the library and its regions made
    /// a kit. What the kit cannot do — filters, LFOs, crossfades — and any sample that could not be
    /// read are said, not dropped silently.
    @discardableResult
    public func importInstrument(from url: URL) -> InstrumentVoiceSpec? {
        guard let directory = instrumentsDirectory else {
            note(.session, "No library to import \(url.lastPathComponent) into")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try ImportedInstruments.importSFZ(at: url, into: directory)
            importedInstruments = ImportedInstruments.load(from: directory)
            var detail = [result.spec.summary]
            if !result.unusable.isEmpty {
                let named = result.unusable.prefix(3).joined(separator: ", ")
                detail.append("Left out \(result.unusable.count) sample\(result.unusable.count == 1 ? "" : "s") that could not be read: \(named)\(result.unusable.count > 3 ? "…" : "").")
            }
            if !result.skippedOpcodes.isEmpty {
                let named = result.skippedOpcodes.prefix(6).joined(separator: ", ")
                detail.append("Not carried over: \(named)\(result.skippedOpcodes.count > 6 ? "…" : "").")
            }
            note(.you, "\(result.replaced ? "Re-imported" : "Imported") \(result.spec.name): it is in the instrument picker, under Imported",
                 detail: detail.joined(separator: " "))
            return result.spec
        } catch {
            note(.session, "Could not import \(url.lastPathComponent)", detail: "\(error)")
            return nil
        }
    }

    /// Takes an imported instrument out of the library. A song that played it falls back to the
    /// song's own instrument, as it would for any id it does not know.
    @discardableResult
    public func removeImportedInstrument(id: String) -> Bool {
        guard let spec = ImportedInstruments.spec(id: id), !spec.isEnsemble else { return false }
        do {
            try ImportedInstruments.remove(id: id)
        } catch {
            note(.session, "Could not remove \(spec.name)", detail: "\(error)")
            return false
        }
        importedInstruments.removeAll { $0.id == id }
        // A section that sat it, and a held recording it was the short notes of, are made again
        // from what is left.
        loadImportedInstruments()
        note(.you, "Removed \(spec.name) from the library", detail: "The pack it came from is untouched.")
        return true
    }
}
