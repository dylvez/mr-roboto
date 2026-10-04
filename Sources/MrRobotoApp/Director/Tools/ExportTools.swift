import Foundation
import SongGraph

// M6 X10: the door, by name. One tool, four things it can write.

public struct ExportTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// "master", "stems", "midi" or "lyrics".
        public var what: String
    }

    public struct Output: Encodable, Sendable {
        public var files: [String]
        public var directory: String
        /// What a master reads, from the report written beside it: this print, not a bounce taken
        /// before the song last changed.
        public var integratedLUFS: Double?
        public var truePeakDBTP: Double?
        public var targetLUFS: Double?
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case files, directory, detail
            case integratedLUFS = "integrated_lufs"
            case truePeakDBTP = "true_peak_dbtp"
            case targetLUFS = "target_lufs"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "export"
    public var purpose: String {
        "Write the song out: master (the whole song through the mix, limited at the ceiling, as a 24-bit WAV beside a JSON "
        + "report of its loudness, true peak, crest, target and clearances), stems (one WAV per strip, dry of the master), "
        + "or midi (one Standard MIDI File of the written parts: grooves on the drum channel, bass lines, melodies, "
        + "progressions as block chords, sections as markers), or lyrics (the words as a text sheet, stanza labels "
        + "kept). Files land in the song's export folder; say where."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("what", Schema.string("What to write.", enum: ["master", "stems", "midi", "lyrics"])),
        ], required: ["what"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard await workspace.song != nil else { throw DirectorToolFailure(tool: name, reason: "No song is open.") }
        let files: [URL]
        do {
            files = try await workspace.export(input.what)
        } catch let failure as DirectorToolFailure {
            throw failure
        } catch {
            throw DirectorToolFailure(tool: name, reason: "\(error)")
        }
        guard let first = files.first else { throw DirectorToolFailure(tool: name, reason: "Nothing was written.") }
        let directory = first.deletingLastPathComponent()
        var detail = "\(files.count) file\(files.count == 1 ? "" : "s") in \(directory.path): \(files.map(\.lastPathComponent).joined(separator: ", "))."
        // The prompt asks for the loudness the report carries, so the report is read here: left to
        // remember one, the model gives the last number it saw, from before the song changed.
        let report = input.what == "master" ? Self.report(among: files) : nil
        if let report {
            detail += String(format: " This master reads %.1f LUFS, true peak %.1f dBTP, for a target of %.1f LUFS. Say these; a reading from before it is not this print's.",
                             report.integratedLUFS, report.truePeakDBTP, report.targetLUFS)
        }
        func tenth(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
        return Output(files: files.map(\.lastPathComponent), directory: directory.path,
                      integratedLUFS: tenth(report?.integratedLUFS), truePeakDBTP: tenth(report?.truePeakDBTP),
                      targetLUFS: tenth(report?.targetLUFS), detail: detail)
    }

    /// The master's report, read back from where it was written.
    static func report(among files: [URL]) -> Export.MasterReport? {
        guard let url = files.first(where: { $0.pathExtension.lowercased() == "json" }),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Export.MasterReport.self, from: data)
    }
}
