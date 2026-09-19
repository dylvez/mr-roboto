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
            if let song, song.id == match.id {
                return takeIntoOpenSong(url, info: info, name: name, store: store)
            }
            return takeIntoLibrarySong(url, info: info, name: name, songID: match.id, store: store)
        }
        return ideaFromInbox(url, info: info, name: name, store: store)
    }

    private func takeIntoOpenSong(_ url: URL, info: AudioFileInfo, name: CaptureName, store: LibraryStore) -> InboxOutcome {
        guard let song else { return .failed("No song is open.") }
        let media: MediaRef
        do {
            if (try? store.songStore(for: song.id)) == nil { save() }
            media = try store.songStore(for: song.id).addMedia(copying: url)
        } catch { return .failed("Could not copy the capture into \(song.title): \(error)") }
        let version = Self.takeVersion(media: media, info: info, name: name, song: song, clock: clock)
        guard record(version) else { return .failed("The song would not take the capture.") }
        note(.session, "\(url.lastPathComponent) came in as \(PartLabel.title(of: version))",
             detail: name.section.map { "on \($0), from the inbox" } ?? "from the inbox")
        return .take(version.id)
    }

    private func takeIntoLibrarySong(_ url: URL, info: AudioFileInfo, name: CaptureName, songID: SongID, store: LibraryStore) -> InboxOutcome {
        do {
            let package = try store.songStore(for: songID)
            var song = try package.load()
            let media = try package.addMedia(copying: url)
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
    /// section's and the alignment is the section's start.
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
        let take = Take(section: section?.id, startBar: startBar, input: "Roboto Capture", pass: pass)
        let audio = Audio(media: media, role: .take, sampleRate: info.sampleRate, channelCount: info.channelCount,
                          duration: info.duration, alignmentOffset: clock.seconds(forBar: startBar), take: take)
        let partID = existing.last?.partID ?? PartID()
        return PartVersion(partID: partID, kind: .audio(audio), author: .user, operation: Operation.recorded,
                           note: "Take \(pass)\(section.map { ", \($0.name)" } ?? ""), captured on the phone")
    }
}
