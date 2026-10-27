import AudioEngine
import Foundation
import Performance
import SongGraph

// Hearing one idea under another (ideas-first, Phase 7): an idea heard with another plays that
// other's parts under its own, fitted to its tempo and key as placing would fit them — a vocal sung
// over a chords idea without the two being joined. The guide is the transport's alone: it is never
// one of the idea's parts, the ledger draws it faded, and it is left behind when the idea goes
// into a song. See Demos/plans/ideas-first.md.

/// A guide's audio, rendered onto the idea it is heard under. A cache: made again whenever the
/// idea's tempo, key or length changes, and never saved.
struct GuideRender: Sendable {
    var media: MediaRef
    var url: URL
    var sampleRate: Double
    var channels: Int
    var duration: Double
}

extension AppState {

    /// The ideas the open idea can be heard with: every other idea of its own. None in a song.
    public var guideChoices: [Song] {
        guard let song, song.isIdea else { return [] }
        return library.ideaSongs.filter { $0.id != song.id }
    }

    /// The idea heard under the open one, when there is one.
    public var guideIdea: Song? {
        guard let song, song.isIdea, let id = song.guide else { return nil }
        return library.ideaSongs.first { $0.id == id && id != song.id }
    }

    /// What the guide does on its way under the open idea, in placing's words.
    public var guidePlacement: IdeaPlacement? {
        guard let song, let guide = guideIdea, let section = song.sections.first else { return nil }
        return IdeaPlacing.plan(guide, into: song, at: .section(section.id))
    }

    /// Hears another idea under the open one, or with nil nothing under it. Kept with the idea, so
    /// it is there the next time it opens. False in a song, or when nothing changed.
    @discardableResult
    public func hearWith(_ guide: SongID?, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = song, current.isIdea else {
            note(.session, "Only an idea is heard with another", detail: "A song puts an idea in a section instead: Add to This Song….")
            return false
        }
        if let guide, guide == current.id || !library.ideaSongs.contains(where: { $0.id == guide }) { return false }
        guard current.guide != guide else { return false }
        updateSong { $0.guide = guide }
        if let song { library.upsert(song) }
        if let found = guideIdea, let plan = guidePlacement {
            let moves = plan.placeable.map(\.sentence).joined(separator: " ")
            note(source, "Hearing \(found.title) under \(current.title)",
                 detail: "\(moves) It is heard and not kept: not one of the idea's parts, and it stays behind when the idea goes into a song.")
        } else {
            note(source, "Nothing heard under \(current.title)")
        }
        return true
    }

    /// The song as the transport plays it. An idea heard with another has the guide's parts in its
    /// one section, moved onto it — written parts by arithmetic, audio once it is rendered — under
    /// the guide's own ids, so they are never mistaken for the idea's. Anything else as it is.
    func heard(_ song: Song) -> Song {
        guard song.isIdea, let id = song.guide, id != song.id,
              let guide = library.ideaSongs.first(where: { $0.id == id }), let section = song.sections.first,
              let plan = IdeaPlacing.plan(guide, into: song, at: .section(section.id)) else { return song }
        var heard = song
        for piece in plan.placeable {
            let kind: PartKind
            switch piece.version.kind {
            case .progression(let progression): kind = .progression(MergeRender.progression(progression, move: piece.move))
            case .bassline(let line): kind = .bassline(MergeRender.bassline(line, move: piece.move))
            case .melody(let melody): kind = .melody(IdeaPlacing.melody(melody, move: piece.move))
            case .audio(let audio):
                guard let url = try? store?.mediaURL(for: audio.media, song: guide.id),
                      let job = IdeaPlacing.job(for: piece, in: plan, song: song, url: url) else { continue }
                let key = "\(piece.version.id)|\(job.move.semitones)|\(job.move.ratio)|\(job.sectionSeconds)"
                guard let rendered = guideRenders[key] else {
                    renderGuide(job, key: key)
                    continue
                }
                let take = Take(section: section.id, startBar: 0, input: "The idea \(guide.title)", pass: 1, sectionStartBar: 0,
                                tempo: song.tempo, meter: song.timeSignature)
                kind = .audio(Audio(media: rendered.media, role: .take, sampleRate: rendered.sampleRate, channelCount: rendered.channels,
                                    duration: rendered.duration, alignmentOffset: 0, take: take))
            default:
                kind = piece.version.kind
            }
            let version = PartVersion(id: piece.version.id, partID: piece.version.partID, kind: kind, createdAt: piece.version.createdAt,
                                      author: piece.version.author, operation: Operation.adopted,
                                      note: "\(piece.title) of \(guide.title): heard under \(song.title)")
            guard (try? heard.append(version)) != nil else { continue }
            if version.type != .audio, StructureModel.plays(version) {
                heard.sections[0].stitch.append(Lane(part: version.partID))
            }
            if let sound = IdeaPlacing.sound(for: piece.version, in: guide, into: song) {
                try? heard.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: sound, forPart: version.partID)),
                                              author: piece.version.author, operation: Operation.written))
            }
        }
        return heard
    }

    /// Where the transport finds a medium: a guide's render, the open song's package, the
    /// library's folders, or the package of the idea heard under it.
    func playbackMediaURL(_ ref: MediaRef) -> URL? {
        if let url = guideMedia[ref] { return url }
        guard let store else { return nil }
        if let url = try? store.mediaURL(for: ref, song: song?.id) { return url }
        return song?.guide.flatMap { try? store.mediaURL(for: ref, song: $0) }
    }

    /// Renders a guide's audio onto the open idea off the main actor, once a fit, and plays it
    /// from the next refresh.
    private func renderGuide(_ job: IdeaPlacing.RenderJob, key: String) {
        guard !guidesRendering.contains(key) else { return }
        guidesRendering.insert(key)
        Task { [weak self] in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto/guides", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
            let info = try? await Task.detached(priority: .userInitiated) { try IdeaPlacing.render(job, to: url) }.value
            guard let self else { return }
            self.guidesRendering.remove(key)
            guard let info, let data = try? Data(contentsOf: url) else { return }
            let media = MediaRef(hash: ContentHash(of: data), fileExtension: "wav")
            self.guideRenders[key] = GuideRender(media: media, url: url, sampleRate: info.sampleRate, channels: info.channels,
                                                 duration: info.duration)
            self.guideMedia[media] = url
            self.refreshPlayback()
        }
    }

    /// Waits for the guide renders under way. Tests wait on it.
    func guidesSettled() async {
        while !guidesRendering.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
