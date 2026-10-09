import AVFAudio
import AudioEngine
import Foundation
import SongGraph

// M5 R11: what the app does with a file from the inbox.

extension AppState {

    /// Where a capture ended up.
    public enum InboxOutcome: Equatable, Sendable {
        /// A take on the open song, in this section.
        case take(VersionID)
        /// A take on a song in the library that is not open, saved into its package.
        case takeInLibrary(SongID, VersionID)
        /// An idea in the library.
        case idea(VersionID)
        case failed(String)
    }

    /// Takes a file from the inbox: a take on the song and section its name says, else an idea.
    @discardableResult
    public func importFromInbox(_ url: URL) -> InboxOutcome {
        guard let store else { return .failed("This session has no library directory.") }
        let info: AudioFileInfo
        do { info = try AudioFileInfo.read(url) } catch { return .failed("\(url.lastPathComponent) could not be read: \(error)") }
        let name = CaptureName(fileName: url.lastPathComponent)

        // A take, when the name says which song and the song is here.
        if let title = name.song, let match = library.songs.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            // Sung to a guide, the head of the file is the count-in the phone played: off it
            // comes, so the first frame kept is the section's first beat.
            var source = url
            var info = info
            if let lead = name.lead, lead > 0 {
                do {
                    source = try Self.trimmed(url, lead: lead)
                    info = try AudioFileInfo.read(source)
                } catch {
                    return .failed("\(url.lastPathComponent) could not be trimmed of its \(String(format: "%.2f", lead)) s lead: \(error)")
                }
            }
            defer { if source != url { try? FileManager.default.removeItem(at: source) } }
            if let song, song.id == match.id {
                return takeIntoOpenSong(url, source: source, info: info, name: name, store: store)
            }
            return takeIntoLibrarySong(url, source: source, info: info, name: name, songID: match.id, store: store)
        }
        return ideaFromInbox(url, info: info, name: name, store: store)
    }

    /// The capture less its lead: a WAV among the temporary files, from `lead` seconds into the
    /// file to its end, which the caller copies into the package and then lets go. A lead as
    /// long as the file is a take with nothing in it, and is refused.
    nonisolated static func trimmed(_ url: URL, lead: Double) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let skip = min(file.length, AVAudioFramePosition((lead * format.sampleRate).rounded()))
        let left = AVAudioFrameCount(file.length - skip)
        guard left > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: left) else {
            throw InboxFailure.leadLongerThanTake(seconds: lead)
        }
        file.framePosition = skip
        try file.read(into: buffer, frameCount: left)
        let frames = Int(buffer.frameLength)
        let planar = (0..<Int(format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: frames))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto/inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: out)
        try BoothAdapter.write(planar, sampleRate: format.sampleRate, to: out)
        return out
    }

    public enum InboxFailure: Error, CustomStringConvertible {
        case leadLongerThanTake(seconds: Double)
        public var description: String {
            switch self {
            case .leadLongerThanTake(let seconds):
                return "the lead of \(String(format: "%.2f", seconds)) s is as long as the take, so nothing was sung after the count-in"
            }
        }
    }

    /// - Parameters:
    ///   - url: the file in the inbox, whose name the rail reads out.
    ///   - source: the audio that goes into the package: the file itself, or it trimmed of its lead.
    private func takeIntoOpenSong(_ url: URL, source: URL, info: AudioFileInfo, name: CaptureName, store: LibraryStore) -> InboxOutcome {
        guard let song else { return .failed("No song is open.") }
        let media: MediaRef
        do {
            if (try? store.songStore(for: song.id)) == nil { save() }
            media = try store.songStore(for: song.id).addMedia(copying: source)
        } catch { return .failed("Could not copy the capture into \(song.title): \(error)") }
        let version = Self.takeVersion(media: media, info: info, name: name, song: song, clock: clock)
        guard record(version) else { return .failed("The song would not take the capture.") }
        note(.session, "\(url.lastPathComponent) came in as \(PartLabel.title(of: version))",
             detail: name.section.map { "on \($0), from the inbox" } ?? "from the inbox")
        return .take(version.id)
    }

    private func takeIntoLibrarySong(_ url: URL, source: URL, info: AudioFileInfo, name: CaptureName, songID: SongID, store: LibraryStore) -> InboxOutcome {
        do {
            let package = try store.songStore(for: songID)
            var song = try package.load()
            let media = try package.addMedia(copying: source)
            let version = Self.takeVersion(media: media, info: info, name: name, song: song,
                                           clock: TransportClock(tempo: song.tempo, timeSignature: song.timeSignature, sampleRate: info.sampleRate))
            try song.append(version)
            try package.save(song)
            reloadLibrary()
            note(.session, "\(url.lastPathComponent) came in as \(PartLabel.title(of: version)) on \(song.title)", detail: "from the inbox")
            return .takeInLibrary(songID, version.id)
        } catch {
            return .failed("Could not put the capture on that song: \(error)")
        }
    }

    private func ideaFromInbox(_ url: URL, info: AudioFileInfo, name: CaptureName, store: LibraryStore) -> InboxOutcome {
        let media: MediaRef
        do { media = try store.addMedia(copying: url, kind: .idea) } catch { return .failed("Could not copy the capture into the library: \(error)") }
        let audio = Audio(media: media, role: .take, sampleRate: info.sampleRate, channelCount: info.channelCount, duration: info.duration)
        var provenance = "Capture from the inbox: \(url.lastPathComponent)"
        if let title = name.song { provenance += " — for \(title), which the library does not hold" }
        let idea = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: provenance)
        var updated = library
        updated.ideas.append(idea)
        guard writeLibrary(updated) else { return .failed("The library would not take the idea.") }
        note(.session, "\(url.lastPathComponent) came in as an idea", detail: provenance)
        return .idea(idea.id)
    }

    /// A take placed at its section's first bar: the phone had no transport, so the bar is the
    /// section's and the alignment is the section's start. Sung to a guide, the file was trimmed
    /// of the count-in first, so its first frame is that bar's first beat.
    static func takeVersion(media: MediaRef, info: AudioFileInfo, name: CaptureName, song: Song, clock: TransportClock) -> PartVersion {
        var section: Section?
        var startBar = 0
        if let wanted = name.section {
            var bar = 0
            for candidate in song.sections {
                if candidate.name.caseInsensitiveCompare(wanted) == .orderedSame { section = candidate; startBar = bar; break }
                bar += candidate.lengthInBars
            }
        }
        let existing = Guidance.takes(in: song).filter { Guidance.audio(of: $0)?.take?.section == section?.id }
        let pass = name.pass ?? ((existing.compactMap { Guidance.audio(of: $0)?.take?.pass }.max() ?? 0) + 1)
        let take = Take(section: section?.id, startBar: startBar, input: "Roboto Capture", pass: pass,
                        sectionStartBar: section.map { _ in startBar }, tempo: clock.tempo,
                        meter: clock.timeSignature)
        let audio = Audio(media: media, role: .take, sampleRate: info.sampleRate, channelCount: info.channelCount,
                          duration: info.duration, alignmentOffset: clock.seconds(forBar: startBar), take: take)
        let partID = existing.last?.partID ?? PartID()
        let how = name.lead != nil ? "captured on the phone, sung to the guide" : "captured on the phone"
        return PartVersion(partID: partID, kind: .audio(audio), author: .user, operation: Operation.recorded,
                           note: "Take \(pass)\(section.map { ", \($0.name)" } ?? ""), \(how)")
    }
}
