import Foundation
import Performance
import SongGraph

/// Fills chosen for a form: by the feel's family, what each edge goes into, and the song's seed.
///
/// A song's fills are written into its sections, as the way out each already had a field for,
/// so a song keeps the fills it was given rather than drifting on load: a section that says
/// nothing plays the usual fill it always did.
enum FillChoosing {

    /// What kind of player is at the kit: the genre somebody said, else the main groove's feel,
    /// else who the groove sounds like: a drummer plays a snare, and a groove with none is a
    /// machine. A record's groove often has no feel at all, and a house song read by that alone
    /// got toms. Never a genre guessed from a note: a shuffle whose note names a folk strum is
    /// not a folk song, and a guess would leave it with no fills.
    static func family(of song: Song) -> FillFamily {
        if let named = song.genre, let profile = GenreBook.standard.profile(named: named) {
            return FillFamily.of(idioms: profile.idioms.map(Idiom.init(rawValue:)))
        }
        guard let version = Guidance.grooves(in: song).last, case .groove(let groove) = version.kind else { return .kit }
        if let name = groove.feel?.name, let feel = FeelLibrary.standard.feel(named: name) { return FillFamily.of(idioms: feel.idioms) }
        return groove.patterns.contains { $0.voice == .snare && $0.steps.contains { $0 != .rest } } ? .kit : .electronic
    }

    /// Whether any groove in the song sounds timbales: who there is to fill on them.
    static func hasTimbales(in song: Song) -> Bool {
        song.versions.contains { version in
            guard case .groove(let groove) = version.kind else { return false }
            return groove.patterns.contains { ($0.voice == .timbaleHigh || $0.voice == .timbaleLow) && $0.steps.contains { $0 != .rest } }
        }
    }

    /// Every edge's way out chosen afresh: a build keeps its roll, the last section leaves on
    /// nothing, a seam where a section was cut in two stays a cut, and the rest get a fill of the
    /// family's by the rule in `SectionFill.choose`. The way in follows: a crash where the drums
    /// lead into the section or the song arrives there; after no fill the groove just goes on.
    static func chosen(_ sections: [Section], family: FillFamily, seed: UInt64, beatsPerBar: Int,
                       hasTimbales: Bool = false) -> [Section] {
        var out = sections
        /// The last fill played, so the same one is not played twice running when another fits.
        var last: Fill?
        for index in out.indices {
            let from = SectionRole.named(out[index].name)
            if from == .build || out[index].transitionOut?.kind == .riser {
                out[index].transitionOut = Transition(kind: .riser)
                continue
            }
            guard index + 1 < out.count else { continue }
            let next = out[index + 1]
            let to = SectionRole.named(next.name)
            // The two halves of one section: what comes in part-way comes in on the bar.
            if out[index].transitionOut?.kind == .cut, from == to { continue }
            let step = (next.intensity ?? to.intensity) - (out[index].intensity ?? from.intensity)
            if let fill = SectionFill.choose(from: from, to: to, step: step, family: family, seed: seed, index: index,
                                             avoiding: last?.shape == .none ? nil : last, hasTimbales: hasTimbales) {
                out[index].transitionOut = Transition.fill(fill, beatsPerBar: beatsPerBar)
                out[index + 1].transitionIn = fill.shape != .none || to.isPeak ? nil : Transition(kind: .cut)
                last = fill
            }
        }
        return out
    }

    /// A section's way in, said: "a crash", "cut".
    static func wayIn(of section: Section) -> String {
        guard let way = section.transitionIn else { return "a crash" }
        switch way.kind {
        case .cut: return "cut"
        case .fadeIn: return "a fade in"
        case .crossfade: return "a crossfade"
        default: return "a crash"
        }
    }

    /// A section's way out, said: "the usual fill", "a snare roll, half a bar", "cut". On a song
    /// with its fills turned off, a section that names none has none.
    static func wayOut(of section: Section, beatsPerBar: Int, fillsOn: Bool = true) -> String {
        section.transitionOut?.wayOut(beatsPerBar: beatsPerBar) ?? (fillsOn ? "the usual fill" : "no fill")
    }

    /// Each edge of the form, said: "Verse → Hook: a snare roll, half a bar".
    static func edges(_ sections: [Section], beatsPerBar: Int) -> [String] {
        zip(sections, sections.dropFirst()).map { from, to in
            "\(from.name) → \(to.name): \(wayOut(of: from, beatsPerBar: beatsPerBar))"
        }
    }

    /// What the form's fills are, in one sentence, each way out once with where it goes: "a snare
    /// roll, half a bar into Hook; the kit out into Break; a flam into the crash into Verse".
    static func sentence(_ sections: [Section], beatsPerBar: Int) -> String {
        var seen: [String] = []
        var into: [String: [String]] = [:]
        for (from, to) in zip(sections, sections.dropFirst()) {
            let way = wayOut(of: from, beatsPerBar: beatsPerBar)
            if into[way] == nil { seen.append(way) }
            let name = to.name.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
            if into[way, default: []].contains(name) == false { into[way, default: []].append(name) }
        }
        return seen.map { "\($0) into \(into[$0, default: []].joined(separator: " and "))" }.joined(separator: "; ")
    }
}
