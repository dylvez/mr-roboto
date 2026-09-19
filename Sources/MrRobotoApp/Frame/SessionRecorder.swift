import AppKit
import Foundation
import SongGraph

// What was said and done, kept. The rail used to live only in memory: quit the app and there was
// no way to see what you asked for, what the band answered, which tools it used or what it cost.
// Every rail entry and every Director tool call is now a line in a dated file in the library.

/// One line of a session file.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var at: Date
    /// "you", "session", "director", a persona's name, or "tool".
    public var who: String
    public var text: String
    public var detail: String?
    public var song: String?
    public var songID: String?
}

/// Appends session records to `<library>/sessions/<day>.jsonl`. Writing is off the main thread and
/// never throws at the caller: a log that cannot be written must not stop the music.
public final class SessionRecorder: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "com.mrroboto.sessions", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(libraryDirectory: URL) {
        directory = libraryDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public func file(for date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appendingPathComponent("\(formatter.string(from: date)).jsonl")
    }

    public func append(_ record: SessionRecord) {
        queue.async { [self] in
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = file(for: record.at)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// Waits for everything queued to be on disk. For a test, and for quitting.
    public func flush() { queue.sync {} }

    /// The records for a song, oldest first, from the newest files back until `limit` is reached.
    public func records(forSong id: String, limit: Int = 200) -> [SessionRecord] {
        flush()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out: [SessionRecord] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").compactMap { try? decoder.decode(SessionRecord.self, from: Data($0.utf8)) }
            out = lines.filter { $0.songID == id } + out
            if out.count >= limit { break }
        }
        return Array(out.suffix(limit))
    }
}

extension AppState {
    /// Shows the session files in Finder.
    public func revealSessions() {
        guard let recorder = sessions else { return }
        try? FileManager.default.createDirectory(at: recorder.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([recorder.file()])
    }

    /// A Director tool call, kept with the session: which tool, whether it failed, and what it said.
    public func recordTool(_ name: String, failed: Bool, message: String) {
        sessions?.append(SessionRecord(at: Date(), who: "tool", text: failed ? "\(name) failed" : name, detail: message.isEmpty ? nil : String(message.prefix(2_000)),
                                       song: song?.title, songID: song?.id.description))
    }

    /// What was said about this song before today's launch, put back at the top of the rail so a
    /// reopened song is not a blank conversation. Read-only history: the Director does not see it.
    func restoreRail(for song: Song) {
        guard let recorder = sessions, log.isEmpty || log.allSatisfy({ $0.source == .session }) else { return }
        let earlier = recorder.records(forSong: song.id.description, limit: 60).filter { $0.who != "tool" }
        guard !earlier.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var restored: [SessionEntry] = earlier.map { record in
            let source: SessionEntry.Source = record.who == "you" ? .you : record.who == "session" ? .session : record.who == "director" ? .director : .persona(record.who)
            return SessionEntry(source: source, text: record.text, detail: record.detail)
        }
        restored.append(SessionEntry(source: .session, text: "Earlier, up to \(formatter.string(from: earlier.last!.at))",
                                     detail: "What was said about \(song.title) before. The band does not remember it; it is here for you."))
        prependToLog(restored)
    }
}
