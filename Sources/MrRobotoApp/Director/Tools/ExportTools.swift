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
        public var detail: String
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
        return Output(files: files.map(\.lastPathComponent), directory: directory.path,
                      detail: "\(files.count) file\(files.count == 1 ? "" : "s") in \(directory.path): \(files.map(\.lastPathComponent).joined(separator: ", ")).")
    }
}
