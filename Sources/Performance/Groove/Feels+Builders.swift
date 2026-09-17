import SongGraph

extension Feels {
    /// One voice's line, written the way the source tables write it: the indices that sound.
    ///
    /// Tiers come from position unless they are named. A step that lands on a beat is an accent and
    /// anything between beats is normal, which is what a drum machine's own accent button does and
    /// what makes a boolean table from `beats.ts` sound like a groove rather than a typewriter.
    /// Ghosts are always explicit, because a ghost note is a decision.
    ///
    /// - Parameters:
    ///   - count: total steps, i.e. `stepsPerBar * bars`.
    ///   - beat: steps per beat — 4 for sixteenths in 4/4, 3 for triplet eighths, 8 for thirty-seconds.
    ///   - on: the steps that sound.
    ///   - ghosts: steps that sound quietly. Added to `on` if not already there.
    ///   - accents: overrides the on-the-beat rule entirely when given.
    static func line(_ voice: DrumVoice, steps count: Int, beat: Int, on active: [Int],
                     ghosts: [Int] = [], accents: [Int]? = nil) -> GroovePattern {
        var tiers = [VelocityTier](repeating: .rest, count: max(0, count))
        let ghostSet = Set(ghosts)
        let accentSet = accents.map(Set.init)
        let stepsPerBeat = max(1, beat)
        for index in Set(active).union(ghostSet).sorted() where index >= 0 && index < tiers.count {
            if ghostSet.contains(index) {
                tiers[index] = .ghost
            } else if let accentSet {
                tiers[index] = accentSet.contains(index) ? .accent : .normal
            } else {
                tiers[index] = index % stepsPerBeat == 0 ? .accent : .normal
            }
        }
        return GroovePattern(voice: voice, steps: tiers)
    }

    /// Every even step up to `count` — an eighth-note line on a sixteenth grid.
    static func eighths(upTo count: Int) -> [Int] { stride(from: 0, to: count, by: 2).map { $0 } }

    /// Every step up to `count`.
    static func all(upTo count: Int) -> [Int] { Array(0..<count) }
}
