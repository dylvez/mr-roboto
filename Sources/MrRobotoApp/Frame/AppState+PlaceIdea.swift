import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// Putting an idea in a song (ideas-first, Phase 4): its parts into one section of the open song —
// or into a new section after the last, as long as the idea — moved onto the song's key and tempo
// by the merge's rules. A written part moves by arithmetic, at no cost to its sound; a groove comes
// as it is; audio (a take, a comp, a capture) is shifted and stretched the way Sources moves a
// record, rendered into the song's own package, and goes round to fill the section as it went
// round in the idea. Placing copies: the song never reads the idea again, and the idea is left as
// it was. See Demos/plans/ideas-first.md.

/// Where an idea goes in the open song.
public enum IdeaSpot: Hashable, Sendable {
    /// A section the song has. The idea's chords, bass line or groove play there in place of the
    /// section's own.
    case section(SectionID)
    /// A new section after the last, as long as the idea and named after it.
    case end
}

/// One part of an idea, and what putting it in the song would do to it.
public struct IdeaPiece: Identifiable, Hashable, Sendable {
    /// The idea's version that comes in: the part's newest, or a sung part's comp.
    public var version: PartVersion
    public var title: String
    /// How it moves: semitones by the keys, and for audio the stretch onto the song's bars.
    public var move: MergeMove
    public var sentence: String
    public var flags: [String]
    public var verdict: LibraryFit.Verdict
    /// The section's own parts of the same kind it takes the place of there, by name.
    public var replaces: [String]
    public var id: PartID { version.partID }
    /// Past seven semitones, which the Sampler will not call the same recording: not placed.
    public var isRefused: Bool { verdict == .refused }
}

/// The idea's words, and whether they come.
public struct IdeaWords: Hashable, Sendable {
    public var version: PartVersion
    public var sentence: String
    /// False when the section has words of its own, which are not written over.
    public var comes: Bool
}

/// What putting an idea in the open song would do, worked out before anything is done.
public struct IdeaPlacement: Sendable {
    public var idea: Song
    public var spot: IdeaSpot
    public var pieces: [IdeaPiece]
    public var words: IdeaWords?
    public var sectionName: String
    /// How long the section is, or will be.
    public var sectionBars: Int
    /// The idea's length in the song's bars: its own, doubled or halved when its audio is.
    public var ideaBars: Int
    /// The song bar, 0-based, the section starts on.
    public var startBar: Int
    /// What is said about where it goes: a new section, or how the idea fills the one it goes in.
    public var sentences: [String]
    /// About how many bytes of audio are rendered into the song's package.
    public var audioBytes: Int

    /// The pieces that can come: everything but what is too far to move.
    public var placeable: [IdeaPiece] { pieces.filter { !$0.isRefused } }
}

/// Why an idea was not put in the song.
public enum IdeaPlacingError: Error, CustomStringConvertible, Equatable {
    case noSong
    case noLibrary
    case noSuchIdea
    case itself
    case inAnIdea
    case sectionGone
    case nothingChosen
    case missingMedia(String)

    public var description: String {
        switch self {
        case .noSong: "No song is open to put the idea in."
        case .noLibrary: "There is no library to write the song's audio into."
        case .noSuchIdea: "That idea is not in the library any more."
        case .itself: "That is the idea that is open."
        case .inAnIdea: "An idea is one section: its parts can go in that one, not in a new one after it."
        case .sectionGone: "That section is not in the song any more."
        case .nothingChosen: "Nothing was chosen to put in."
        case .missingMedia(let what): "The audio of \(what) is not in the idea's package."
        }
    }
}

/// The arithmetic of placing: what moves where, and the render. Nothing here touches the frame.
enum IdeaPlacing {

    /// What placing `idea` at `spot` in `song` would do. Nil for a section the song does not have.
    static func plan(_ idea: Song, into song: Song, at spot: IdeaSpot) -> IdeaPlacement? {
        let ideaLength = max(1, idea.sections.first?.lengthInBars ?? Song.startingIdeaBars)
        let versions = idea.partIDs.filter { !idea.isAside($0) }.compactMap { part -> PartVersion? in
            guard let newest = idea.latestVersion(of: part) else { return nil }
            return newest.type == .audio ? SongPlayback.sungVersion(of: part, in: idea) ?? newest : newest
        }.filter(AppState.keepsAsIdea)
        let music = versions.filter { $0.type != .lyric }
        // Doubling or halving a tempo first is the merge's rule for audio; written parts and
        // grooves are counted in beats and keep their bars one for one, so an idea holding any of
        // them is stretched as it is, its bars on the song's.
        let allAudio = !music.isEmpty && music.allSatisfy { $0.type == .audio }
        let factor = allAudio ? Merge.stretch(from: idea.tempo, to: song.tempo).factor : 1
        let ideaBars = max(1, Int((Double(ideaLength) * factor).rounded()))

        let section: Section
        let startBar: Int
        var sentences: [String] = []
        switch spot {
        case .section(let id):
            guard let found = song.sections.first(where: { $0.id == id }), let bar = song.startBar(of: id) else { return nil }
            section = found
            startBar = bar
        case .end:
            section = Section(name: idea.title, stitch: [], lengthInBars: ideaBars)
            startBar = song.sections.reduce(0) { $0 + max(1, $1.lengthInBars) }
            sentences.append(song.sections.last.map { "A new section of \(Guidance.count(ideaBars, "bar")) after the \($0.name), called \(idea.title)." }
                             ?? "The song's first section, \(Guidance.count(ideaBars, "bar")), called \(idea.title).")
        }
        let sectionBars = max(1, section.lengthInBars)
        if case .section = spot {
            if sectionBars > ideaBars {
                let rounds = Double(sectionBars) / Double(ideaBars)
                sentences.append(rounds == rounds.rounded()
                    ? "The idea is \(Guidance.count(ideaBars, "bar")) and the \(section.name) \(sectionBars): it goes round \(times(Int(rounds))) there."
                    : "The idea is \(Guidance.count(ideaBars, "bar")) and the \(section.name) \(sectionBars): it goes round until the \(section.name) ends.")
            } else if sectionBars < ideaBars {
                sentences.append("The \(section.name) is \(Guidance.count(sectionBars, "bar")): the first \(sectionBars) of the idea's \(ideaBars) play there.")
            }
        }
        if idea.timeSignature != song.timeSignature {
            sentences.append("The idea is in \(idea.timeSignature.description) and the song in \(song.timeSignature.description): its bars are laid on the song's one for one.")
        }

        let target = MergeTarget(key: song.key, tempo: song.tempo)
        let barSeconds = Double(song.timeSignature.beatsPerBar) * 60 / max(1, song.tempo)
        var audioBytes = 0
        let pieces = music.map { version -> IdeaPiece in
            let title = PartLabel.title(of: version)
            var piece = IdeaPiece(version: version, title: title, move: Merge.move(MergeFragment(label: title, kind: .groove), to: target),
                                  sentence: "\(title) comes as it is.", flags: [], verdict: .asIs, replaces: [])
            switch version.kind {
            case .progression(let progression):
                written(&piece, from: progression.key ?? idea.key, to: target)
            case .bassline(let line):
                written(&piece, from: line.key ?? idea.key, to: target)
            case .melody:
                written(&piece, from: idea.key, to: target)
            case .groove:
                piece.sentence = "\(title) comes as it is: a groove has no key."
            case .sample:
                piece.sentence = "\(title) comes as it is: a chop keeps its pitch, and plays at the song's tempo."
            case .audio(let audio):
                if let source = audioSource(of: version, in: idea) {
                    let drums = isDrums(version, in: idea)
                    var move = Merge.move(MergeFragment(label: title, kind: .sample, key: idea.key, tempo: source.tempo, isDrums: drums),
                                          to: target)
                    if drums {
                        move.semitones = 0
                        move.key = idea.key
                        move.preservesFormants = false
                        move.flags = []
                    }
                    move.tempoFactor = factor
                    move.ratio = source.tempo * factor / max(1, song.tempo)
                    move.tempo = song.tempo
                    piece.move = move
                    piece.flags = move.flags
                    piece.verdict = LibraryFitting.made(move, sentences: [], flags: move.flags, known: true).verdict
                    piece.sentence = audioSentence(title, move: move, from: source.tempo, key: idea.key, drums: drums)
                    if piece.verdict == .far, abs(move.ratio - 1) > Merge.stretchLimit {
                        piece.flags.append(String(format: "%@ stretches %.0f%%: past %.0f%%, it will be heard.", title,
                                                  abs(move.ratio - 1) * 100, Merge.stretchLimit * 100))
                    }
                    if piece.isRefused {
                        piece.flags.append("\(title) would move \(abs(move.semitones)) semitones: too far to be the same recording, so it stays in the idea.")
                    }
                    audioBytes += Int(Double(sectionBars) * barSeconds * audio.sampleRate) * max(1, audio.channelCount) * 4
                } else {
                    piece.sentence = "\(title) has no place in the idea to be read from."
                    piece.verdict = .refused
                }
            default:
                break
            }
            // In a section the song has, the idea's chords, bass line or groove play in place of
            // the section's own, rather than on top of them.
            if case .section = spot, replacesItsKind(version.type) {
                piece.replaces = section.stitch.compactMap { lane in
                    song.latestVersion(of: lane.part).flatMap { $0.type == version.type ? PartLabel.title(of: $0) : nil }
                }
            }
            return piece
        }

        var words: IdeaWords?
        if let lyric = versions.last(where: { $0.type == .lyric }) {
            var sections = song.sections
            if case .end = spot { sections.append(section) }
            let index = sections.firstIndex { $0.id == section.id } ?? 0
            var current: Lyric?
            if let newest = song.versions.last(where: { $0.type == .lyric }), case .lyric(let words) = newest.kind { current = words }
            let has = current?.stanza(forSectionAt: index, in: sections) != nil
            words = IdeaWords(version: lyric,
                              sentence: has ? "The \(section.name) has words of its own: the idea's stay in the idea."
                                            : "The idea's words become the \(section.name)'s.",
                              comes: !has)
        }
        return IdeaPlacement(idea: idea, spot: spot, pieces: pieces, words: words, sectionName: section.name,
                             sectionBars: sectionBars, ideaBars: ideaBars, startBar: startBar, sentences: sentences,
                             audioBytes: audioBytes)
    }

    /// The kinds a section plays one of: a new one takes the place of the old there.
    static func replacesItsKind(_ type: PartType) -> Bool { [.progression, .bassline, .groove].contains(type) }

    private static func times(_ count: Int) -> String {
        switch count {
        case 2: "twice"
        case 3: "three times"
        case 4: "four times"
        default: "\(count) times"
        }
    }

    /// A written part moved by the keys: by arithmetic, at no cost to its sound.
    private static func written(_ piece: inout IdeaPiece, from key: Key?, to target: MergeTarget) {
        let move = Merge.move(MergeFragment(label: piece.title, kind: .written, key: key), to: target)
        piece.move = move
        piece.verdict = move.semitones == 0 ? .asIs : .near
        if move.semitones != 0, let moved = move.key {
            piece.sentence = "\(piece.title) \(move.semitones > 0 ? "up" : "down") \(Guidance.count(abs(move.semitones), "semitone")) to "
                + "\(moved.name): written, so at no cost to its sound."
        } else {
            piece.sentence = key.map { "\(piece.title) stays in \($0.name)." } ?? "\(piece.title) stays as it is: the idea has no key."
        }
    }

    /// "Take 2 up 2 semitones to B minor, stretched ×0.92 from 92 to 100." — the merge's words.
    private static func audioSentence(_ title: String, move: MergeMove, from tempo: Double, key: Key?, drums: Bool) -> String {
        var pieces: [String] = []
        if move.semitones != 0, let moved = move.key {
            pieces.append("\(move.semitones > 0 ? "up" : "down") \(Guidance.count(abs(move.semitones), "semitone")) to \(moved.name)")
        }
        if move.tempoFactor != 1 {
            pieces.append(String(format: "%.0f %@ to %.0f", tempo, move.tempoFactor > 1 ? "doubled" : "halved", tempo * move.tempoFactor))
        }
        if abs(move.ratio - 1) >= 0.005 {
            pieces.append(String(format: "stretched ×%.2f from %.0f to %.0f", move.ratio, tempo * move.tempoFactor, move.tempo ?? tempo))
        }
        guard !pieces.isEmpty else {
            var stays = "\(title) stays"
            if let key, !drums { stays += " in \(key.name)" }
            return stays + String(format: " at %.0f", tempo) + (drums ? ", its pitch left alone: it is drums." : ".")
        }
        return "\(title) \(pieces.joined(separator: ", "))\(drums ? ", its pitch left alone: it is drums" : "")."
    }

    /// Where an idea's audio sits in it: the idea second its file's first frame sounds at, how
    /// much longer the file plays there than it is, the idea seconds before which nothing of it is
    /// heard (a count-in), and the tempo the file itself is at. As the idea's transport plays it.
    static func audioSource(of version: PartVersion, in idea: Song) -> (startsAt: Double, stretch: Double, silentBefore: Double, tempo: Double)? {
        let clock = TransportClock(tempo: max(1, idea.tempo), timeSignature: idea.timeSignature)
        if let audio = TakePlacement.audio(of: version, in: idea) {
            let placed = TakePlacement.placement(of: audio, in: idea, clock: clock)
            let stretch = audio.stretch(in: idea)
            return (placed.audio, stretch, max(0, placed.audio, (placed.take ?? placed.audio) - 0.05), idea.tempo * stretch)
        }
        guard let audio = Guidance.audio(of: version) else { return nil }
        let stretch = SongPlayback.isPlaced(version) ? 1 : SongPlayback.recordStretch(of: version, in: idea)
        let startsAt = (audio.alignmentOffset ?? 0) * stretch
        return (startsAt, stretch, max(0, startsAt), idea.tempo * stretch)
    }

    /// Whether an idea's audio is drums, by its reading: drums most of the way through and no
    /// voice. Drums are stretched with their transients kept and never shifted.
    static func isDrums(_ version: PartVersion, in idea: Song) -> Bool {
        guard let analysis = Guidance.analysis(for: version, in: idea), analysis.duration > 0 else { return false }
        func covered(_ kind: InstrumentKind) -> Double {
            analysis.instruments.filter { $0.instrument == kind }.flatMap(\.ranges).reduce(0) { $0 + max(0, $1.end - $1.start) }
        }
        return covered(.drums) >= analysis.duration * 0.5 && covered(.vocals) == 0
    }

    /// A melody moved by arithmetic: every pitch by the move's semitones.
    static func melody(_ melody: Melody, move: MergeMove) -> Melody {
        guard move.semitones != 0 else { return melody }
        var moved = melody
        moved.notes = melody.notes.map { note in
            var note = note
            note.pitch = note.pitch.transposed(by: move.semitones)
            return note
        }
        return moved
    }

    /// What a written part or groove sounds on in the idea, when a new part in the song would not
    /// sound on it by default: its own pick, or the idea's.
    static func sound(for version: PartVersion, in idea: Song, into song: Song) -> String? {
        switch version.type {
        case .progression, .melody:
            let own = SongPlayback.instrumentID(for: version.partID, in: idea)
            return own == SongPlayback.instrumentID(in: song) ? nil : own
        case .groove:
            let own = SongPlayback.machineID(for: idea.strip(of: version.partID), in: idea)
            return own == SongPlayback.machineID(in: song) ? nil : own
        default:
            return nil
        }
    }

    // MARK: The render

    /// One audio part of an idea as the song will have it.
    struct RenderJob: Sendable {
        var url: URL
        /// The file's second at the idea's first bar: below zero when the file starts after it.
        var ideaStart: Double
        /// Seconds from the idea's first bar, in the file's own, before which nothing is heard.
        var silentBefore: Double
        /// The idea's length in the file's seconds.
        var ideaLength: Double
        /// Pitch, and the stretch that makes the idea exactly `loopSeconds`.
        var move: MergeMove
        var loopSeconds: Double
        var sectionSeconds: Double
    }

    static func job(for piece: IdeaPiece, in placement: IdeaPlacement, song: Song, url: URL) -> RenderJob? {
        let idea = placement.idea
        guard let source = audioSource(of: piece.version, in: idea), source.stretch > 0 else { return nil }
        let ideaBarSeconds = Double(idea.timeSignature.beatsPerBar) * 60 / max(1, idea.tempo)
        let ideaSeconds = Double(max(1, idea.sections.first?.lengthInBars ?? 1)) * ideaBarSeconds
        let barSeconds = Double(song.timeSignature.beatsPerBar) * 60 / max(1, song.tempo)
        let loopSeconds = Double(placement.ideaBars) * barSeconds
        var move = piece.move
        move.ratio = loopSeconds / (ideaSeconds / source.stretch)
        return RenderJob(url: url, ideaStart: -source.startsAt / source.stretch, silentBefore: source.silentBefore / source.stretch,
                         ideaLength: ideaSeconds / source.stretch, move: move, loopSeconds: loopSeconds,
                         sectionSeconds: Double(placement.sectionBars) * barSeconds)
    }

    /// The idea's stretch of the file — silence where the file is not, nothing of a count-in —
    /// moved, cut to exactly the idea's bars of the song, and gone round to fill the section.
    /// Off the main actor: a take of a minute is seconds of work.
    static func render(_ job: RenderJob, to url: URL) throws -> (sampleRate: Double, channels: Int, duration: Double) {
        let (planar, rate) = try BoothAdapter.planar(job.url)
        let frames = max(1, Int((job.ideaLength * rate).rounded()))
        let first = Int((job.ideaStart * rate).rounded())
        let quiet = min(frames, max(0, Int((job.silentBefore * rate).rounded())))
        let segment = planar.map { lane -> [Float] in
            var out = [Float](repeating: 0, count: frames)
            for index in quiet..<frames {
                let from = first + index
                if from >= 0, from < lane.count { out[index] = lane[from] }
            }
            return out
        }
        let moved = try MergeRender.audio(segment, sampleRate: rate, move: job.move)
        let loop = max(1, Int((job.loopSeconds * rate).rounded()))
        let total = max(1, Int((job.sectionSeconds * rate).rounded()))
        let filled = moved.map { lane -> [Float] in
            let once = lane.count >= loop ? Array(lane.prefix(loop)) : lane + [Float](repeating: 0, count: loop - lane.count)
            var out: [Float] = []
            out.reserveCapacity(total)
            while out.count < total { out += once.prefix(total - out.count) }
            return out
        }
        try BoothAdapter.write(filled, sampleRate: rate, to: url)
        return (rate, filled.count, Double(total) / rate)
    }
}

/// Add to This Song…, or an idea dropped on a section: the sheet that says what placing it does.
public struct IdeaPlacingRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var idea: SongID
    public var spot: IdeaSpot
}

extension AppState {

    /// Opens the sheet that puts an idea in the open song: at `spot`, or after the last section.
    /// With no song open, the idea is opened instead.
    public func askToPlace(_ idea: SongID, at spot: IdeaSpot? = nil) {
        guard library.ideaSongs.contains(where: { $0.id == idea }) else {
            note(.session, "That idea is not in the library any more")
            return
        }
        guard let song, song.id != idea else {
            openSong(idea)
            return
        }
        let fallback: IdeaSpot = song.isIdea ? (song.sections.first.map { .section($0.id) } ?? .end) : .end
        placingIdea = IdeaPlacingRequest(idea: idea, spot: spot ?? fallback)
    }

    /// What placing the idea at `spot` in the open song would do. Nil with nothing open, an idea
    /// the library does not hold, or a section the song does not have.
    public func ideaPlacement(_ idea: SongID, at spot: IdeaSpot) -> IdeaPlacement? {
        guard let song, let found = library.ideaSongs.first(where: { $0.id == idea }), found.id != song.id else { return nil }
        return IdeaPlacing.plan(found, into: song, at: spot)
    }

    /// Puts the chosen parts of an idea in the open song, as `placement` says: written parts moved
    /// by the keys, audio rendered into the song's package on the section's bars, each a new part
    /// seeded from the idea, the section stitched — a new one made, at the end — and the words
    /// labelled for it. Returns the new versions.
    /// - Parameter replacing: whether its chords, bass line or groove take the place of the
    ///   section's own of that kind there; false plays them together — an organ's bubble over a
    ///   guitar's skank.
    @discardableResult
    public func place(_ placement: IdeaPlacement, parts: Set<PartID>? = nil, words: Bool = true, replacing: Bool = true,
                      by author: Author = .user) async throws -> [PartVersion] {
        guard let store, libraryIsWritable else { throw IdeaPlacingError.noLibrary }
        guard let opened = song else { throw IdeaPlacingError.noSong }
        let idea = placement.idea
        guard opened.id != idea.id else { throw IdeaPlacingError.itself }
        if opened.isIdea, case .end = placement.spot { throw IdeaPlacingError.inAnIdea }
        let chosen = placement.placeable.filter { parts?.contains($0.id) ?? true }
        let bringsWords = words && placement.words?.comes == true
        guard !chosen.isEmpty || bringsWords else { throw IdeaPlacingError.nothingChosen }
        let section: Section
        switch placement.spot {
        case .section(let id):
            guard let found = opened.sections.first(where: { $0.id == id }) else { throw IdeaPlacingError.sectionGone }
            section = found
        case .end:
            section = Section(name: placement.sectionName, stitch: [], lengthInBars: placement.sectionBars)
        }
        if (try? store.songStore(for: opened.id)) == nil || hasUnsavedChanges { save() }
        let package = try store.songStore(for: opened.id)

        // The audio first, off the main actor, into the song's own package.
        var rendered: [PartID: (media: MediaRef, sampleRate: Double, channels: Int, duration: Double)] = [:]
        for piece in chosen {
            switch piece.version.kind {
            case .audio(let audio):
                guard let url = try? store.mediaURL(for: audio.media, song: idea.id),
                      let job = IdeaPlacing.job(for: piece, in: placement, song: opened, url: url) else {
                    throw IdeaPlacingError.missingMedia(piece.title)
                }
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-idea-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: scratch) }
                let info = try await Task.detached(priority: .userInitiated) { try IdeaPlacing.render(job, to: scratch) }.value
                rendered[piece.id] = (try package.addMedia(copying: scratch), info.sampleRate, info.channels, info.duration)
            case .sample(let sample):
                guard let url = try? store.mediaURL(for: sample.media, song: idea.id) else { throw IdeaPlacingError.missingMedia(piece.title) }
                if !package.hasMedia(sample.media) { try package.addMedia(copying: url) }
            default:
                break
            }
        }
        // Rendered into this song: kept in it, even if another was opened while it ran.
        guard song?.id == opened.id else { throw IdeaPlacingError.noSong }

        let seed = Seed(kind: .idea(idea.id), note: "from the idea \(idea.title)")
        updateSong { $0.seeds.append(seed) }
        let clock = TransportClock(tempo: max(1, opened.tempo), timeSignature: opened.timeSignature)
        var placed: [PartVersion] = []
        for piece in chosen {
            let kind: PartKind
            switch piece.version.kind {
            case .progression(let progression): kind = .progression(MergeRender.progression(progression, move: piece.move))
            case .bassline(let line): kind = .bassline(MergeRender.bassline(line, move: piece.move))
            case .melody(let melody): kind = .melody(IdeaPlacing.melody(melody, move: piece.move))
            case .audio:
                guard let media = rendered[piece.id] else { continue }
                // Sung to the section: it moves with it, and follows a tempo changed later.
                let take = Take(section: section.id, startBar: placement.startBar, input: "The idea \(idea.title)", pass: 1,
                                sectionStartBar: placement.startBar, tempo: opened.tempo, meter: opened.timeSignature)
                kind = .audio(Audio(media: media.media, role: .take, sampleRate: media.sampleRate, channelCount: media.channels,
                                    duration: media.duration, alignmentOffset: clock.seconds(forBar: placement.startBar), take: take))
            default:
                kind = piece.version.kind
            }
            // Chords are called by their symbols, which have just moved: by the idea instead.
            let named = piece.version.type == .progression ? "Chords of \(idea.title)"
                : piece.title.localizedCaseInsensitiveContains(idea.title) ? piece.title : "\(piece.title) of \(idea.title)"
            let version = PartVersion(partID: PartID(), kind: kind, author: author,
                                      operation: piece.version.type == .audio ? Operation.fitted : Operation.adopted,
                                      note: "\(named): \(piece.sentence)", origin: seed.id)
            guard record(version, joiningForm: false) else { throw IdeaPlacingError.noSong }
            placed.append(version)
            if let current = song, let sound = IdeaPlacing.sound(for: piece.version, in: idea, into: current) {
                let name = InstrumentVoiceSpec.preset(id: sound)?.name ?? SynthMachine.preset(id: sound)?.name ?? sound
                record(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: sound, forPart: version.partID)), author: author,
                                   operation: Operation.written, note: "\(name) for \(named), as in the idea", origin: seed.id))
            }
        }

        // The form: the section, made at the end or found, playing what came.
        guard var sections = song?.sections else { throw IdeaPlacingError.noSong }
        if case .end = placement.spot { sections.append(section) }
        guard let index = sections.firstIndex(where: { $0.id == section.id }), let current = song else { throw IdeaPlacingError.sectionGone }
        for version in placed where version.type != .audio && StructureModel.plays(version) {
            if replacing, IdeaPlacing.replacesItsKind(version.type) {
                sections[index].stitch.removeAll { lane in
                    lane.part != version.partID && !placed.contains { $0.partID == lane.part }
                        && current.latestVersion(of: lane.part)?.type == version.type
                }
            }
            sections[index].stitch.append(Lane(part: version.partID))
        }
        if sections != current.sections { arrange(sections) }

        if bringsWords, let words = placement.words, case .lyric(let theirs) = words.version.kind {
            placeWords(theirs, of: idea, in: sections[index], seed: seed, by: author)
        }
        setActiveSection(section.id)
        var said = placement.sentences + chosen.map(\.sentence) + chosen.flatMap(\.flags)
        if let words = placement.words, words.comes == false || bringsWords { said.append(words.sentence) }
        note(.you, "Put \(idea.title) in the \(section.name)", detail: said.joined(separator: " "))
        return placed
    }

    /// The idea's words, as the section's stanza: after the song's words, labelled with its name.
    private func placeWords(_ words: Lyric, of idea: Song, in section: Section, seed: Seed, by author: Author) {
        guard let song else { return }
        let existing = song.versions.last { $0.type == .lyric }
        var lyric: Lyric
        if let existing, case .lyric(let current) = existing.kind { lyric = current } else { lyric = Lyric(lines: []) }
        let lines = words.lines.filter { !$0.syllables.isEmpty }.map { line in
            LyricLine(syllables: line.syllables.map { syllable in
                var syllable = syllable
                syllable.noteIndex = nil
                return syllable
            })
        }
        guard !lines.isEmpty else { return }
        if !lyric.lines.isEmpty { lyric.lines.append(LyricLine(syllables: [])) }
        lyric.labels = (lyric.labels ?? []) + [Lyric.StanzaLabel(line: lyric.lines.count, name: section.name)]
        lyric.lines += lines
        let note = "the words of \(idea.title), for the \(section.name)"
        let version = existing.map { $0.deriving(.lyric(lyric), by: author, operation: Operation.written, note: note) }
            ?? PartVersion(partID: PartID(), kind: .lyric(lyric), author: author, operation: Operation.written, note: note, origin: seed.id)
        record(version, joiningForm: false)
    }
}
