import Foundation
import Instrument
import Performance
import SongGraph

/// A section as it stood: what each lane played, and how loud each strip was there.
///
/// A section is the one thing in a song that is edited in place, and what it plays also changes
/// under it — a section follows its parts, so a new version of the hook's drums is a new hook.
/// Nothing kept "the chorus before". This is that: every lane with the version it was playing,
/// and every strip's level in the section, so the section can be heard again as it was, compared
/// with what it is now, and put back.
public struct SectionState: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var section: SectionID
    public var name: String
    public var bars: Int
    public var intensity: Double?
    /// Every lane, held at the version it played.
    public var lanes: [Lane]
    /// Each strip's level in the section, dB.
    public var levels: [PartID: Double]
    /// When the section came to stand this way.
    public var since: Date

    /// The section as it stands in `song`, under `mix`.
    public static func of(_ section: Section, in song: Song, mix: Mix?, at date: Date = Date()) -> SectionState {
        var lanes: [Lane] = []
        var levels: [PartID: Double] = [:]
        for lane in section.stitch {
            guard let version = song.version(playing: lane) ?? song.latestVersion(of: lane.part) else { continue }
            lanes.append(Lane(part: lane.part, pin: version.id))
            let strip = song.strip(of: lane.part)
            levels[strip] = mix?.gainDB(for: strip, in: section.id) ?? 0
        }
        return SectionState(section: section.id, name: section.name, bars: section.lengthInBars, intensity: section.intensity,
                            lanes: lanes, levels: levels, since: date)
    }

    /// Whether the two would be heard as the same section: the same versions at the same levels
    /// for the same length. A name or an intensity changed moves nothing anybody hears.
    public func sounds(like other: SectionState) -> Bool {
        lanes == other.lanes && bars == other.bars && levels == other.levels
    }

    /// What is different about this state against `now`, in words, one phrase a part.
    public func differences(from now: SectionState, in song: Song) -> [String] {
        var out: [String] = []
        func word(_ lane: Lane) -> String {
            lane.pin.flatMap(song.version).map { Develop.word(for: $0.type) } ?? "a part"
        }
        func title(_ lane: Lane) -> String {
            guard let version = lane.pin.flatMap(song.version) else { return "something the song no longer holds" }
            let history = song.versions.filter { $0.partID == version.partID }
            let number = history.firstIndex { $0.id == version.id }.map { " (v\($0 + 1))" } ?? ""
            return PartLabel.title(of: version) + (history.count > 1 ? number : "")
        }
        for lane in lanes {
            let strip = song.strip(of: lane.part)
            let other = now.lanes.first { song.strip(of: $0.part) == strip }
            if other == nil {
                out.append("\(word(lane)) in: \(title(lane))")
            } else if let other, other != lane {
                out.append("\(word(lane)): \(title(lane))")
            }
        }
        for lane in now.lanes where !lanes.contains(where: { song.strip(of: $0.part) == song.strip(of: lane.part) }) {
            out.append("no \(word(lane))")
        }
        for (strip, level) in levels.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
            guard let other = now.levels[strip], abs(other - level) >= 0.05,
                  let type = song.latestVersion(of: strip)?.type else { continue }
            out.append(String(format: "%@ at %+.1f dB", Develop.word(for: type), level))
        }
        if bars != now.bars { out.append("\(bars) bars") }
        return out
    }
}

extension AppState {

    /// How many earlier states of a section are remembered.
    static let sectionStatesKept = 6

    /// Reads every section of the song as it stands now and, where one has changed, remembers how
    /// it stood. Called whenever the song is set.
    ///
    /// A state that stood for less than `sectionSettle` is not remembered: developing a song is
    /// several changes in a row, and the song between two of them is nothing anybody heard.
    func rememberSections(after old: Song?) {
        guard let song else {
            sectionHistory = [:]
            sectionStanding = [:]
            return
        }
        if old?.id != song.id {
            sectionHistory = [:]
            sectionStanding = [:]
        }
        let now = Date()
        let mix = Guidance.mix(in: song)
        var standing: [SectionID: SectionState] = [:]
        var history = sectionHistory.filter { id, _ in song.sections.contains { $0.id == id } }
        for section in song.sections {
            let state = SectionState.of(section, in: song, mix: mix, at: now)
            guard let was = sectionStanding[section.id] else {
                standing[section.id] = state
                continue
            }
            if was.sounds(like: state) {
                var same = was
                same.name = state.name
                same.intensity = state.intensity
                standing[section.id] = same
                continue
            }
            if now.timeIntervalSince(was.since) >= sectionSettle {
                var kept = history[section.id] ?? []
                kept.removeAll { $0.sounds(like: was) }
                kept.append(was)
                history[section.id] = Array(kept.suffix(Self.sectionStatesKept))
            }
            standing[section.id] = state
        }
        sectionStanding = standing
        if history != sectionHistory { sectionHistory = history }
    }

    /// How a section stands now.
    public func standing(_ section: SectionID) -> SectionState? {
        guard let song, let found = song.section(section) else { return nil }
        return sectionStanding[section] ?? SectionState.of(found, in: song, mix: Guidance.mix(in: song))
    }

    /// The states a section stood in before, the newest last, without the one it stands in now.
    public func earlierStates(of section: SectionID) -> [SectionState] {
        guard let now = standing(section) else { return [] }
        return (sectionHistory[section] ?? []).filter { !$0.sounds(like: now) }
    }

    /// The plan that plays the song with one section as it stood.
    func playback(of state: SectionState) -> SongPlayback? {
        guard var variant = song, let index = variant.sections.firstIndex(where: { $0.id == state.section }) else { return nil }
        variant.sections[index].stitch = state.lanes.filter { $0.pin.flatMap(variant.version) != nil }
        variant.sections[index].lengthInBars = state.bars
        var plan = SongPlayback.plan(for: variant) { [store, song] ref in
            guard let store else { return nil }
            return try? store.mediaURL(for: ref, song: song?.id)
        }
        var mix = plan.mix ?? .unity
        mix.sectionGains.removeAll { $0.section == state.section }
        for (strip, level) in state.levels where abs((mix.strip(for: strip)?.gainDB ?? 0) - level) >= 0.001 {
            mix.sectionGains.append(SectionGain(section: state.section, part: strip, gainDB: level))
        }
        plan.mix = mix
        return plan
    }

    /// A state bounced through the mix, kept so a Compare plays it at once.
    func audio(of state: SectionState, kitsDirectory: URL = AuditionService.defaultKitsDirectory) async -> Bounce? {
        if let held = sectionBounces[state.id] { return held }
        guard let plan = playback(of: state), plan.isPlayable,
              let stems = try? await SectionBounce.render(plan, section: state.section, kitsDirectory: kitsDirectory, onlyTheMix: true),
              stems.mix.first?.isEmpty == false else { return nil }
        let bounce = Bounce(planar: stems.mix, sampleRate: stems.sampleRate)
        if sectionBounces.count >= 8 { sectionBounces.removeAll() }
        sectionBounces[state.id] = bounce
        return bounce
    }

    /// Puts a section back as it stood: each lane on what it played then, held at that version
    /// where the part has moved on since, and each strip at the level it had. Its place in the
    /// form is the one it has now.
    @discardableResult
    public func restore(_ state: SectionState, by source: SessionEntry.Source = .you, author: Author = .user) -> Bool {
        keepSurfaceWork()
        guard let song, let index = song.sections.firstIndex(where: { $0.id == state.section }) else { return false }
        var sections = song.sections
        sections[index].stitch = state.lanes.compactMap { lane in
            guard let pin = lane.pin, song.version(pin) != nil else { return nil }
            // Following the part again where the part is still on that version; held there otherwise.
            return song.latestVersion(of: lane.part)?.id == pin ? Lane(part: lane.part) : lane
        }
        sections[index].lengthInBars = state.bars
        sections[index].intensity = state.intensity
        let before = Guidance.mix(in: song) ?? .unity
        var mix = before
        mix.sectionGains.removeAll { $0.section == state.section }
        for (strip, level) in state.levels where abs((mix.strip(for: strip)?.gainDB ?? 0) - level) >= 0.001 {
            mix.sectionGains.append(SectionGain(section: state.section, part: strip, gainDB: level))
        }
        // The same levels in another order are the same mix.
        let moved = Set(mix.sectionGains) != Set(before.sectionGains)
        // One move, as it was one state: what it plays and its levels together.
        guard keep(moved ? [mixVersion(mix, in: song, by: author, note: "\(state.name)'s levels, as they were")] : [], arranged: sections) else {
            return false
        }
        if moved { refreshSurfaces(of: [.mixer, .master]) }
        note(source, "\(state.name) is back as it was", detail: "What it plays now is still in the song, a version on from what it plays again.")
        return true
    }

    /// What a section comparison holds: the question, and what each row read at.
    public struct SectionComparison: Sendable {
        public var surface: SurfaceID
        public var title: String
        public var rows: [(title: String, state: SectionState, lufs: Double?, differs: [String])]
    }

    /// Opens a Compare on a section as it is and as it stood before: each state bounced through
    /// the mix and read, the section it follows at the head to hear them come out of. Nil when the
    /// section has not changed since the song was opened.
    @discardableResult
    public func compareSection(_ id: SectionID, kitsDirectory: URL = AuditionService.defaultKitsDirectory) async -> SectionComparison? {
        guard let song, let index = song.sections.firstIndex(where: { $0.id == id }), let now = standing(id) else { return nil }
        let earlier = Array(earlierStates(of: id).suffix(CompareModel.maximumCandidates - 1).reversed())
        guard !earlier.isEmpty else { return nil }
        func reading(_ state: SectionState) async -> (Double?, [CompareReading]) {
            guard let bounce = await audio(of: state, kitsDirectory: kitsDirectory) else { return (nil, []) }
            let lufs = MixMeter.integratedLoudness(bounce.planar, sampleRate: bounce.sampleRate)
            guard lufs.isFinite else { return (nil, []) }
            return (lufs, [CompareReading(.integratedLUFS, lufs, unit: "LUFS"),
                           CompareReading(.crestDB, MixMeter.crestDB(bounce.planar), unit: "dB")])
        }
        func ago(_ date: Date) -> String {
            let minutes = Int(Date().timeIntervalSince(date) / 60)
            return minutes < 1 ? "a moment ago" : minutes == 1 ? "a minute ago" : minutes < 60 ? "\(minutes) minutes ago" : "\(minutes / 60) h ago"
        }
        var rows: [(title: String, state: SectionState, lufs: Double?, differs: [String])] = []
        var candidates: [CompareCandidate] = []
        let (nowLUFS, nowReadings) = await reading(now)
        candidates.append(CompareCandidate(id: now.id.uuidString, title: "\(now.name) as it is now", rationale: "What the song plays.",
                                           readings: nowReadings, state: now))
        rows.append(("\(now.name) as it is now", now, nowLUFS, []))
        for (offset, state) in earlier.enumerated() {
            let differs = state.differences(from: now, in: song)
            let (lufs, readings) = await reading(state)
            let title = offset == 0 ? "\(state.name) before" : "\(state.name), \(offset + 1) changes back"
            candidates.append(CompareCandidate(id: state.id.uuidString, title: title,
                                               rationale: "Until \(ago(now.since)): " + (differs.isEmpty ? "the same parts" : differs.joined(separator: "; ")) + ".",
                                               readings: readings, state: state))
            rows.append((title, state, lufs, differs))
        }
        // What it comes out of: the section before it, or the one after when it is the first.
        let neighbour = index > 0 ? song.sections[index - 1] : song.sections.count > 1 ? song.sections[index + 1] : song.sections[index]
        let lead = standing(neighbour.id) ?? now
        let (_, leadReadings) = await reading(lead)
        let reference = CompareReference(title: neighbour.id == id ? "\(now.name) as it is" : "\(neighbour.name), \(index > 0 ? "which it follows" : "which follows it")",
                                         kind: "the section beside it, as the song plays it", readings: leadReadings, state: lead)
        let title = "\(now.name), now and before"
        let surface = openSurface(.compare, title: title)
        file(.compare(CompareBrief(title: title, reference: reference, candidates: candidates,
                                   features: [.integratedLUFS, .crestDB], vocabulary: Engineer.bible)), for: surface)
        // The bench holds one Compare: this is a new question on it.
        SurfaceWiring.shared.discardModel(for: surface)
        return SectionComparison(surface: surface, title: title, rows: rows)
    }
}
