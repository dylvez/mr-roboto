import Foundation
import MusicTheory
import SongGraph

// A song from ideas (ideas-first, Phase 5): ideas laid end to end as a new song's sections — two on
// one row play together in one — at the tempo, key and meter of the idea that would lose most by
// moving, which is the one whose grid costs the rest least: recorded audio before written parts,
// since a written part moves at no cost. Each idea goes in as Phase 4 puts one in a song, so the
// ideas are copied and left as they were. See Demos/plans/ideas-first.md.

/// File ▸ New Song from Ideas…, or Make a Song from These on the Ideas shelf: the sheet that lays
/// ideas out as a song, open while this is set.
public struct SongFromIdeasRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The ideas it starts with, in order, each a section of its own.
    public var ideas: [SongID]
}

/// One idea's tempo, key and meter as a song's, and what taking it does to the others.
public struct IdeasGrid: Identifiable, Sendable {
    /// The idea it is taken from.
    public var idea: SongID
    public var title: String
    public var tempo: Double
    public var key: Key?
    public var timeSignature: TimeSignature
    /// What moving every other idea onto it costs, as the Library ranks a fit: a semitone a
    /// semitone, a step for doubling or halving, a semitone for every three percent of stretch.
    /// Written parts move at no cost.
    public var cost: Double
    /// Each other idea's moves, as the sheet and the rail say them.
    public var sentences: [String]
    /// What is flagged on the way: far moves, stretches that will be heard.
    public var flags: [String]
    public var id: SongID { idea }
}

enum SongFromIdeas {

    /// Each idea's grid, cheapest for the rest first; a tie keeps the ideas' order, so ideas that
    /// are all written take the first one's.
    static func grids(for ideas: [Song]) -> [IdeasGrid] {
        let grids = ideas.map { candidate -> IdeasGrid in
            let target = FitTarget(candidate)
            var cost = 0.0
            var sentences: [String] = []
            var flags: [String] = []
            for other in ideas where other.id != candidate.id {
                guard let fit = LibraryFitting.fit(other, into: target) else { continue }
                if fit.cost.isFinite { cost += fit.cost }
                sentences.append("\(other.title): " + fit.sentences.joined(separator: " "))
                flags += fit.flags
            }
            return IdeasGrid(idea: candidate.id, title: candidate.title, tempo: candidate.tempo, key: candidate.key,
                             timeSignature: candidate.timeSignature, cost: cost, sentences: sentences, flags: flags)
        }
        return grids.enumerated().sorted { ($0.element.cost, $0.offset) < ($1.element.cost, $1.offset) }.map(\.element)
    }

    /// "92 bpm in A minor", with the meter when it is not 4/4.
    static func line(_ grid: IdeasGrid) -> String {
        let tempo = grid.tempo.rounded() == grid.tempo ? "\(Int(grid.tempo))" : String(format: "%.1f", grid.tempo)
        var line = "\(tempo) bpm"
        if let key = grid.key { line += " in \(key.name)" }
        if grid.timeSignature != .fourFour { line += ", \(grid.timeSignature.description)" }
        return line
    }
}

extension AppState {

    /// The ideas a song can be made from: every idea of its own on the shelf, the one open as it
    /// stands now rather than as it was last saved.
    public var ideasToMakeSongsFrom: [Song] {
        guard let song, song.isIdea else { return library.ideaSongs }
        return library.ideaSongs.map { $0.id == song.id ? song : $0 }
    }

    /// Opens the sheet that makes a song from ideas, starting with these.
    public func askToMakeSong(from ideas: [SongID] = []) {
        guard store != nil else {
            note(.session, "Nowhere to make a song", detail: "This session has no library directory.")
            return
        }
        let known = ideas.filter { id in library.ideaSongs.contains { $0.id == id } }
        makingSongFromIdeas = SongFromIdeasRequest(ideas: known)
    }

    /// Makes a new song of ideas, a section for each row — named after its first idea, as long as
    /// it — with the row's ideas in it, at the grid of the idea `grid` names (the cheapest for the
    /// rest when nil), and opens it on Structure. The open song is saved and left first; the ideas
    /// are not touched.
    @discardableResult
    public func makeSong(from rows: [[SongID]], grid: SongID? = nil, title: String = "",
                         by source: SessionEntry.Source = .you) async throws -> SongID {
        guard let store, libraryIsWritable else { throw IdeaPlacingError.noLibrary }
        _ = store
        let shelf = ideasToMakeSongsFrom
        let rows = rows.map { row in row.filter { id in shelf.contains { $0.id == id } } }.filter { !$0.isEmpty }
        let ideas = rows.flatMap { $0 }.compactMap { id in shelf.first { $0.id == id } }
        guard !ideas.isEmpty else { throw IdeaPlacingError.nothingChosen }
        let grids = SongFromIdeas.grids(for: ideas)
        guard let chosen = grids.first(where: { $0.idea == grid }) ?? grids.first,
              let from = ideas.first(where: { $0.id == chosen.idea }) else { throw IdeaPlacingError.nothingChosen }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var made = Song(title: name.isEmpty ? MrRobotoApp.untitledName() : name, key: chosen.key, tempo: chosen.tempo,
                        timeSignature: chosen.timeSignature, sections: [])
        made.gridChosen = true
        made.genre = from.genre ?? ideas.compactMap(\.genre).first
        open(made, by: source)
        guard song?.id == made.id else { throw IdeaPlacingError.noSong }
        save()
        let author: Author = source == .director ? .persona("Director") : .user
        for row in rows {
            var section: SectionID?
            for id in row {
                guard let plan = ideaPlacement(id, at: section.map { .section($0) } ?? .end) else { continue }
                if plan.placeable.isEmpty, plan.words?.comes != true { continue }
                // Ideas sharing a section play together: the second's chords join the first's
                // rather than taking their place, as they would in a section that had its own.
                try await place(plan, replacing: section == nil, by: author)
                if section == nil { section = song?.sections.last?.id }
            }
        }
        guard let finished = song, finished.id == made.id else { throw IdeaPlacingError.noSong }
        save()
        perform(Guidance.dockAction(for: .structure, in: finished))
        let form = finished.sections.map { "\($0.name) \($0.lengthInBars)" }.joined(separator: " · ")
        note(source, "Made \(finished.title) from \(Guidance.count(ideas.count, "idea"))",
             detail: "At \(SongFromIdeas.line(chosen)), \(from.title)'s. \(form). The ideas are as they were.")
        return made.id
    }
}
