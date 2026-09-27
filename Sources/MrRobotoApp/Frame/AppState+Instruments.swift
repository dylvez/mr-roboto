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
        guard let spec = ImportedInstruments.spec(id: id) else { return false }
        do {
            try ImportedInstruments.remove(id: id)
        } catch {
            note(.session, "Could not remove \(spec.name)", detail: "\(error)")
            return false
        }
        importedInstruments.removeAll { $0.id == id }
        note(.you, "Removed \(spec.name) from the library", detail: "The pack it came from is untouched.")
        return true
    }
}
