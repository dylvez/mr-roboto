import Foundation
import Performance
import SongGraph

/// One section, played at another intensity: what it plays now, what was written for it, and the
/// levels it sits at.
public struct Shading: Equatable, Sendable {
    /// The section as it will be: its lanes and its intensity.
    public var section: Section
    /// Where it sat before.
    public var was: Double
    /// Variations written for it, when the song did not already have them.
    public var versions: [PartVersion]
    /// The mix with this section's levels moved, or nil when none did.
    public var mix: Mix?
    /// What each lane plays now, in words: "drums", "bass, lighter", "tune".
    public var plays: [String]
    /// What changed, in words: "drums: lifted, now as written", "tune +1.0 dB, now +0.4 dB".
    public var moved: [String]

    public var intensity: Double { section.intensity ?? was }
}

extension Develop {

    /// A section's intensity, when nobody has given it one: its role's.
    public static func intensity(of section: Section) -> Double {
        section.intensity ?? SectionRole.named(section.name).intensity
    }

    /// One section taken to another intensity, without touching the rest of the song.
    ///
    /// Developing gives each kind of section its way of playing the loop — the drums lifted in a
    /// hook, thinned in an intro — and a level. This is the same ladder, walked for one section:
    /// asked for less, the drums come down a rung (lifted, as written, thinned, no kick), then the
    /// bass (as written, lighter, held) and the tune (an octave up, as written, its first phrase,
    /// out), and the levels follow the curve developing uses. Asked for more, they go up it.
    ///
    /// It only ever moves the way it was asked: a section made less intense gets nothing louder
    /// or busier than it had, and one made more intense loses nothing. What gives a section its
    /// character rather than its size is left alone — a bridge's ride and its own chords, a
    /// build's roll, a lane held at a version, a part written for the sections it is in — and a
    /// part the section does not play is not brought in.
    ///
    /// - Returns: nil when the song has no such section.
    public static func shade(_ id: SectionID, to target: Double, in song: Song, electronic: Bool = false,
                             by author: Author = Develop.author) -> Shading? {
        guard let found = song.section(id) else { return nil }
        var section = found
        let role = SectionRole.named(section.name)
        let was = intensity(of: section)
        let x = min(1, max(0, target))
        let down = x < was
        func toward(_ current: Int, _ wanted: Int) -> Int { down ? min(current, wanted) : max(current, wanted) }
        let beats = song.timeSignature.beatsPerBar
        let loop = loop(of: song)
        let byPart = Dictionary(loop.map { ($0.partID, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = placedParts(of: song, loop: loop)
        var spans: [ChordSpan] = []
        if case .progression(let progression)? = loop.last(where: { $0.type == .progression })?.kind {
            spans = progression.bars.flatMap(\.chords)
        }

        var versions: [PartVersion] = []
        /// The part that plays `kind` as a variation of `root`: one the song has, or a new one.
        func variation(of root: PartVersion, named name: String, kind: PartKind, note: String) -> PartID {
            if let existing = song.variations(of: root.partID).first(where: { song.variation(of: $0)?.name == name }),
               let newest = song.latestVersion(of: existing) {
                // Written by developing and gone stale against the loop: written again. One
                // somebody has changed by hand is theirs, and is played as they left it.
                if newest.kind != kind, newest.operation == Operation.developed {
                    versions.append(newest.deriving(kind, by: author, operation: Operation.developed, note: note))
                }
                return existing
            }
            let version = root.varying(kind, as: name, by: author, note: note)
            versions.append(version)
            return version.partID
        }

        var lanes: [Lane] = []
        var plays: [String] = []
        var moved: [String] = []
        for lane in section.stitch {
            let rootID = song.strip(of: lane.part)
            guard !isHeld(lane, in: song), let root = byPart[rootID], !placed.contains(rootID) else {
                lanes.append(lane)
                if let version = song.version(playing: lane) { plays.append("\(word(for: version.type)), as it was set") }
                continue
            }
            let name = lane.part == rootID ? nil : song.variation(of: lane.part)?.name
            switch root.kind {
            case .groove(let groove):
                let rungs: [GrooveTreatment?] = [.noKick, .thin, nil, .lift]
                let words = ["no kick", "thinned", "as written", "lifted"]
                let current: Int? = name == nil ? 2 : name == GrooveTreatment.noKick.rawValue ? 0
                    : name == GrooveTreatment.thin.rawValue ? 1 : name?.hasPrefix(GrooveTreatment.lift.rawValue) == true ? 3 : nil
                guard let current else {
                    // On the ride, building, pushing: what the section is, not how big it is.
                    lanes.append(lane)
                    plays.append("drums, as they were")
                    continue
                }
                var rung = toward(current, x < 0.2 ? 0 : x < 0.4 ? 1 : x < 0.85 ? 2 : 3)
                // A groove on a chop's slices has no layer to add.
                if ChopSound.part(of: SongPlayback.drumSoundID(for: rootID, in: song)) != nil { rung = min(rung, max(current, 2)) }
                guard rung != current else {
                    lanes.append(lane)
                    plays.append("drums, \(words[current])")
                    continue
                }
                let layers = role == .drop ? 2 : 1
                if let treatment = rungs[rung],
                   let varied = GrooveVariation.vary(groove, as: treatment, bars: section.lengthInBars, beatsPerBar: beats,
                                                     layers: layers, electronic: electronic) {
                    let named = treatment.rawValue + (layers > 1 && treatment == .lift ? "-2" : "")
                    lanes.append(Lane(part: variation(of: root, named: named, kind: .groove(varied),
                                                      note: "\(grooveName(treatment, layers: layers)): \(grooveNote(treatment, bars: varied.bars))")))
                } else {
                    rung = 2
                    lanes.append(Lane(part: rootID))
                }
                plays.append("drums, \(words[rung])")
                if rung != current { moved.append("drums: \(words[current]), now \(words[rung])") }

            case .bassline(let line):
                let rungs: [BassTreatment?] = [.held, .light, nil]
                let words = ["held roots", "lighter", "as written"]
                let current: Int? = name == nil ? 2 : name == BassTreatment.held.rawValue ? 0 : name == BassTreatment.light.rawValue ? 1 : nil
                guard let current else {
                    lanes.append(lane)
                    plays.append("bass, as it was")
                    continue
                }
                var rung = toward(current, x < 0.2 ? 0 : x < 0.4 ? 1 : 2)
                guard rung != current else {
                    lanes.append(lane)
                    plays.append("bass, \(words[current])")
                    continue
                }
                if let treatment = rungs[rung],
                   let varied = BassVariation.vary(line, as: treatment, chords: spans, bars: section.lengthInBars, beatsPerBar: beats) {
                    lanes.append(Lane(part: variation(of: root, named: treatment.rawValue, kind: .bassline(varied),
                                                      note: "\(bassName(treatment)): \(bassNote(treatment))")))
                } else {
                    rung = 2
                    lanes.append(Lane(part: rootID))
                }
                plays.append("bass, \(words[rung])")
                if rung != current { moved.append("bass: \(words[current]), now \(words[rung])") }

            case .melody(let tune):
                let words = ["out", "its first phrase only", "as written", "an octave up"]
                let current: Int? = name == nil ? 2 : name == TuneTreatment.sparse.rawValue ? 1
                    : (name == TuneTreatment.lift.rawValue || name == "raised") ? 3 : nil
                guard let current else {
                    lanes.append(lane)
                    plays.append("tune, as it was")
                    continue
                }
                // The octave is for where the song arrives: a verse turned up gets the whole tune.
                let top = role.isPeak ? 3 : max(current, 2)
                var rung = toward(current, min(top, x < 0.3 ? 0 : x < 0.45 ? 1 : x < 0.95 ? 2 : 3))
                guard rung != current else {
                    lanes.append(lane)
                    plays.append("tune, \(words[current])")
                    continue
                }
                switch rung {
                case 0:
                    break
                case 1, 3:
                    let treatment: TuneTreatment = rung == 1 ? .sparse : .lift
                    if let varied = TuneVariation.vary(tune, as: treatment, bars: section.lengthInBars, beatsPerBar: beats) {
                        let twice = (varied.lengthInBars ?? 0) > tune.loopBars(beatsPerBar: beats)
                        let named = treatment == .lift ? (twice ? "lift" : "raised") : treatment.rawValue
                        lanes.append(Lane(part: variation(of: root, named: named, kind: .melody(varied),
                                                          note: "\(tuneTitle(treatment, twice: twice)) of \(PartLabel.title(of: root))")))
                    } else {
                        rung = 2
                        lanes.append(Lane(part: rootID))
                    }
                default:
                    lanes.append(Lane(part: rootID))
                }
                if rung > 0 { plays.append("tune, \(words[rung])") }
                if rung != current { moved.append("tune: \(words[current]), now \(words[rung])") }

            default:
                lanes.append(lane)
                plays.append(word(for: root.type))
            }
        }

        // The levels, on the curve developing sets them by, moved only the way that was asked.
        let before = Guidance.mix(in: song) ?? .unity
        var mix = before
        var seen = Set<PartID>()
        for lane in lanes where !isHeld(lane, in: song) {
            let strip = strip(of: lane.part, in: song, written: versions)
            guard seen.insert(strip).inserted, !placed.contains(strip), let type = byPart[strip]?.type,
                  let wanted = shadeLevel(of: type, at: x) else { continue }
            let base = mix.strip(for: strip)?.gainDB ?? 0
            let current = mix.gainDB(for: strip, in: section.id) - base
            let offset = ((down ? min(current, wanted) : max(current, wanted)) * 10).rounded() / 10
            guard abs(offset - current) >= 0.05 else { continue }
            mix.sectionGains.removeAll { $0.section == section.id && $0.part == strip }
            if offset != 0 {
                mix.sectionGains.append(SectionGain(section: section.id, part: strip, gainDB: max(-60, min(12, base + offset))))
            }
            moved.append(String(format: "%@ %+.1f dB, now %+.1f dB", word(for: type), base + current, base + offset))
        }

        section.stitch = lanes
        section.intensity = (x * 100).rounded() / 100
        return Shading(section: section, was: was, versions: versions, mix: mix == before ? nil : mix, plays: plays, moved: moved)
    }

    /// How far from its strip a part sits in a section of this intensity: the levels developing
    /// gives an intro, a bridge, a verse, a hook and a drop, with straight lines between them.
    static func shadeLevel(of type: PartType, at intensity: Double) -> Double? {
        let points: [(Double, Double)]
        switch type {
        case .groove: points = [(0, -4), (0.25, -2), (0.5, -1), (0.55, 0), (0.9, 0.5), (1, 1)]
        case .melody: points = [(0.3, -1), (0.55, 0), (0.9, 1), (1, 1.5)]
        case .bassline: points = [(0.9, 0), (1, 0.5)]
        default: return nil
        }
        guard let first = points.first, let last = points.last else { return nil }
        if intensity <= first.0 { return first.1 }
        if intensity >= last.0 { return last.1 }
        for (low, high) in zip(points, points.dropFirst()) where intensity <= high.0 {
            return low.1 + (high.1 - low.1) * (intensity - low.0) / (high.0 - low.0)
        }
        return last.1
    }
}

extension AppState {

    /// Takes one section of the open song to another intensity, kept as one move: the variations
    /// it needs, what the section plays, and its levels in a new mix. Nil when the song has no
    /// such section. Nothing moves when the section is already there.
    @discardableResult
    public func shade(_ section: SectionID, to intensity: Double, by source: SessionEntry.Source = .you,
                      author: Author = Develop.author) -> Shading? {
        keepSurfaceWork()
        guard let song, let index = song.sections.firstIndex(where: { $0.id == section }) else { return nil }
        let reading = GenreBook.standard.genre(of: song)
        guard let shading = Develop.shade(section, to: intensity, in: song, electronic: Develop.isElectronic(reading?.profile), by: author) else { return nil }
        var sections = song.sections
        sections[index] = shading.section
        // One move: what the section plays and its levels land together, so the song is never
        // heard — or remembered — with one and not the other.
        var versions = shading.versions
        if let mix = shading.mix {
            versions.append(mixVersion(mix, in: song, by: author,
                                       note: "\(shading.section.name)'s levels, at \(Int((shading.intensity * 100).rounded()))%"))
        }
        guard keep(versions, arranged: sections) else { return nil }
        if shading.mix != nil { refreshSurfaces(of: [.mixer, .master]) }
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        note(source, "\(shading.section.name) at \(percent(shading.intensity)), from \(percent(shading.was))",
             detail: shading.moved.isEmpty ? "Nothing in it had further to go that way: it plays as it did."
                                           : shading.moved.joined(separator: "; ") + ".")
        return shading
    }

    /// A mix as the next version of the song's mix, for a move that keeps it with other things.
    func mixVersion(_ mix: Mix, in song: Song, by author: Author, note: String) -> PartVersion {
        let base = Guidance.mixes(in: song).last
        return PartVersion(partID: base?.partID ?? PartID(), kind: .mix(mix), author: author, parents: base.map { [$0.id] } ?? [],
                           operation: Operation.mix, note: note)
    }
}
