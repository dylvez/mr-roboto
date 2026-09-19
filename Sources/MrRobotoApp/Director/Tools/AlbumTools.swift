import Foundation
import MusicTheory
import SongGraph

// M7 L5: the record, read; put in order; released.

/// The album a tool means: by title or id, or the one the open song is on, or the only one.
private func findAlbum(_ named: String, in library: Library, openSong: SongID?) -> Album? {
    if !named.isEmpty {
        if let byTitle = library.albums.first(where: { $0.title.caseInsensitiveCompare(named) == .orderedSame }) { return byTitle }
        if let byID = library.albums.first(where: { $0.id.description == named }) { return byID }
        return nil
    }
    if let openSong, let containing = library.albums.first(where: { $0.songs.contains(openSong) }) { return containing }
    return library.albums.count == 1 ? library.albums.first : nil
}

private func albumFailure(_ tool: String, _ named: String, _ library: Library) -> DirectorToolFailure {
    let titles = library.albums.map(\.title).joined(separator: ", ")
    return DirectorToolFailure(tool: tool, reason: named.isEmpty ? "No album to read: the open song is on none, and the library holds \(library.albums.count)."
                                                                 : "\"\(named)\" is not an album in the library.",
                               suggestion: titles.isEmpty ? "New Album in the File menu makes one; drag songs into it." : "One of: \(titles).")
}

// MARK: - read_album

public struct ReadAlbumTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// The album's title or id; empty for the open song's album.
        public var album: String
    }

    public struct Output: Encodable, Sendable {
        public struct TrackEntry: Encodable, Sendable {
            public var number: Int
            public var id: String
            public var title: String
            public var key: String?
            public var tempo: Double
            public var seconds: Double
            public var gapBefore: Double
            public var hookSeconds: Double?
            public var releasedLUFS: Double?
            public var sources: [String]
            enum CodingKeys: String, CodingKey { case number, id, title, key, tempo, seconds, sources; case gapBefore = "gap_before"; case hookSeconds = "hook_seconds"; case releasedLUFS = "released_lufs" }
        }
        public struct Neighbour: Encodable, Sendable {
            public var from: String
            public var to: String
            public var keyDistance: Int?
            public var tempoRatio: Double
            enum CodingKeys: String, CodingKey { case from, to; case keyDistance = "key_distance"; case tempoRatio = "tempo_ratio" }
        }
        public struct PaletteEntry: Encodable, Sendable {
            public var entry: String
            public var tracks: [String]
        }
        public struct ClearanceEntry: Encodable, Sendable {
            public var source: String
            public var status: String
        }
        public var album: String
        public var id: String
        public var artist: String
        public var targetLUFS: Double
        public var ceilingDBTP: Double
        public var runningSeconds: Double
        public var tracks: [TrackEntry]
        public var neighbours: [Neighbour]
        public var palette: [PaletteEntry]
        public var clearances: [ClearanceEntry]
        public var producer: [String]
        public var peer: [String]
        public var notes: String
        public var detail: String
        enum CodingKeys: String, CodingKey { case album, id, artist, tracks, neighbours, palette, clearances, producer, peer, notes, detail
            case targetLUFS = "target_lufs"; case ceilingDBTP = "ceiling_dbtp"; case runningSeconds = "running_seconds" }
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "read_album"
    public var purpose: String {
        "Read a record: its tracks in order with key, tempo, length, the gap before each, where the hook arrives and what it was "
        + "last released at; the neighbours' distance on the circle of fifths and in tempo; the running time; the palette the songs "
        + "share; the clearances; and the Producer's and the Peer's lines on the order. Nothing is changed."
    }
    public var schema: DirectorJSON {
        Schema.object([("album", Schema.string("The album's title or id; empty for the open song's album."))], required: ["album"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        guard let album = findAlbum(input.album, in: library, openSong: await workspace.song?.id) else { throw albumFailure(name, input.album, library) }
        let observation = await workspace.observe(album: album)
        let tracks = observation.tracks.enumerated().map { index, track in
            Output.TrackEntry(number: index + 1, id: track.id.description, title: track.title, key: track.key.map { "\($0)" }, tempo: track.tempo,
                              seconds: (track.seconds * 10).rounded() / 10, gapBefore: index == 0 ? 0 : album.gap(before: track.id),
                              hookSeconds: track.hookSeconds.map { ($0 * 10).rounded() / 10 }, releasedLUFS: track.releasedLUFS.map { ($0 * 10).rounded() / 10 },
                              sources: track.sources)
        }
        let producer = Producer().read(observation), peer = Peer().read(observation)
        let flagged = (producer + peer).filter { !$0.holds }.count
        return Output(album: album.title, id: album.id.description, artist: album.artist, targetLUFS: album.targets.integratedLUFS, ceilingDBTP: album.targets.truePeakDBTP,
                      runningSeconds: observation.runningSeconds.rounded(), tracks: tracks,
                      neighbours: observation.neighbours.map { .init(from: $0.from, to: $0.to, keyDistance: $0.keyDistance, tempoRatio: ($0.tempoRatio * 100).rounded() / 100) },
                      palette: observation.palette.map { .init(entry: $0.entry, tracks: $0.tracks) },
                      clearances: await workspace.clearances(of: album).map { .init(source: $0.source, status: $0.status.rawValue) },
                      producer: producer.map(\.says), peer: peer.map(\.says), notes: album.notes,
                      detail: String(format: "%@: %d tracks, %d:%02d with the gaps, target %.0f LUFS; %d reading%@ not holding. sequence takes the track ids in a new order.",
                                     album.title, tracks.count, Int(observation.runningSeconds) / 60, Int(observation.runningSeconds) % 60,
                                     album.targets.integratedLUFS, flagged, flagged == 1 ? "" : "s"))
    }
}

// MARK: - sequence

public struct SequenceTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var album: String
        /// Every track, by id or title, in the new order.
        public var order: [String]
        /// Seconds of silence before each track, one per track (the first is ignored); empty keeps the gaps.
        public var gaps: [Double]
        public var reason: String
    }

    public struct Output: Encodable, Sendable {
        public var order: [String]
        public var producer: String
        public var peer: String
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "sequence"
    public var purpose: String {
        "Put the record in a new order, with the gaps: every track by id or title, once. The Producer and the Peer read the "
        + "order first — a record too long or short, tracks released too far apart, more than one pair of neighbours in one "
        + "key, an opener whose hook comes late, more than one tempo jump — and a refusal names the counter. An order that "
        + "passes is the album's, with your reason in the rail."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("album", Schema.string("The album's title or id; empty for the open song's album.")),
            ("order", Schema.array("Every track, by id or title, in the new order.", of: Schema.string("A track id or title."))),
            ("gaps", Schema.array("Seconds before each track, one per track; empty keeps the gaps.", of: Schema.number("Seconds.", minimum: 0, maximum: 30))),
            ("reason", Schema.string("Why this order, in the readings' words.")),
        ], required: ["album", "order", "gaps", "reason"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        guard let album = findAlbum(input.album, in: library, openSong: await workspace.song?.id) else { throw albumFailure(name, input.album, library) }
        func song(_ named: String) -> SongID? {
            album.songs.first { $0.description == named } ?? album.songs.first { library.song($0)?.title.caseInsensitiveCompare(named) == .orderedSame }
        }
        let order = input.order.compactMap(song)
        guard order.count == album.songs.count, Set(order) == Set(album.songs) else {
            throw DirectorToolFailure(tool: name, reason: "The order has to name every track on \(album.title) once.",
                                      suggestion: "The tracks are: \(album.songs.compactMap { library.song($0)?.title }.joined(separator: ", ")).")
        }
        var proposed = album
        proposed.songs = order
        if input.gaps.count == order.count { for (id, gap) in zip(order, input.gaps) { proposed.gaps[id] = max(0, min(30, gap)) } }
        let observation = await workspace.observe(album: proposed)
        let proposal = PersonaProposal.sequence(minutes: observation.runningMinutes, loudnessSpreadLU: observation.loudnessSpreadLU,
                                                sameKeyPairs: observation.sameKeyPairs, tempoJumps: observation.tempoJumps,
                                                openerHookSeconds: observation.openerHookSeconds ?? 0)
        let producer = Producer().consider(proposal), peer = Peer().consider(proposal)
        for (who, verdict) in [("Producer", producer), ("Peer", peer)] {
            if case .refuse(let rule, let because, let counter) = verdict {
                throw DirectorToolFailure(tool: name, reason: "The \(who) refuses (\(rule)): \(because)", suggestion: counter)
            }
        }
        guard await workspace.sequence(order, gaps: input.gaps.count == order.count ? Dictionary(uniqueKeysWithValues: zip(order, input.gaps)) : nil,
                                       in: album.id, because: input.reason) else {
            throw DirectorToolFailure(tool: name, reason: "The order could not be kept.")
        }
        let titles = order.compactMap { library.song($0)?.title }
        return Output(order: titles, producer: producer.spoken, peer: peer.spoken,
                      detail: "\(album.title) now runs \(titles.joined(separator: " → ")). The Album surface shows it; read_album reads it back.")
    }
}

// MARK: - release

public struct ReleaseTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var album: String
    }

    public struct Output: Encodable, Sendable {
        public var folder: String
        public var tracks: [String]
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "release"
    public var purpose: String {
        "Release a record: every track bounced through its own mix, trimmed to the album's loudness target, limited at its "
        + "ceiling, written as numbered 24-bit WAVs with cover.png and album.json in one folder. Only when the user says release."
    }
    public var schema: DirectorJSON {
        Schema.object([("album", Schema.string("The album's title or id; empty for the open song's album."))], required: ["album"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        guard let album = findAlbum(input.album, in: library, openSong: await workspace.song?.id) else { throw albumFailure(name, input.album, library) }
        let (folder, report) = try await workspace.release(album: album.id)
        return Output(folder: folder.path, tracks: report.tracks.map { String(format: "%@ · %.1f LUFS · %.1f dBTP · %@", $0.file, $0.integratedLUFS, $0.truePeakDBTP, StructureModel.clock($0.durationSeconds)) },
                      detail: String(format: "%@ released to %@: %d tracks, %d:%02d, target %.0f LUFS, ceiling %.1f dBTP, with cover.png and album.json.",
                                     album.title, folder.path, report.tracks.count, Int(report.runningSeconds) / 60, Int(report.runningSeconds) % 60,
                                     report.targetLUFS, report.ceilingDBTP))
    }
}
