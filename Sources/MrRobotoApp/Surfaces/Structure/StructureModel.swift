import Foundation
import MusicTheory
import SongGraph

/// The Structure surface's entry in the catalog: the form, surface #14, bound to nothing — it
/// draws the song's sections, and the song is what is open.
public struct StructureSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .structure }
    public var bound: [VersionID] { [] }
    public var title: String

    public init(id: SurfaceID = SurfaceID(), title: String = "Structure") {
        self.id = id
        self.title = title
    }
}

/// What the Structure surface needs from whatever hosts it: the form kept, and the transport.
@MainActor
public protocol StructureHosting: AnyObject {
    /// Replace the song's sections. `false` when the host refused (nothing open).
    @discardableResult
    func arrange(_ sections: [Section]) async -> Bool
    /// Play the song from the top, as the space bar does.
    func play() async
    func stop() async
    /// A library row dropped on a section: adopt it into the song and stitch it in. `false` when
    /// nothing was stitched, with the host saying why.
    @discardableResult
    func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool
}

/// The Structure surface's model: the sections as a working copy, edited in place and kept as
/// one move.
///
/// Sections are the one thing in a song that is not versioned — a form is an *ordering* of
/// versions, and the versions it names are never touched — so this surface has a working copy
/// and a Keep rather than a commit that derives a new version. `isDirty` is the gap between the
/// two, and Revert closes it the other way.
@MainActor
@Observable
public final class StructureModel {

    /// One **part** a section can play: its kind, and what its newest version is called.
    ///
    /// This used to be a version — the newest of each part, plus any older one a section still
    /// named — and the surface drew a chip per version with a "v2" after it. A section names parts
    /// now, and a part's newest version is what sounds, so there is nothing to choose between: one
    /// chip per part, and keeping a new version of it changes what you hear without touching the
    /// form. Holding a section at an older version is a `Lane.pin`, which is deliberate, rare, and
    /// not offered here.
    public struct Layer: Identifiable, Hashable, Sendable {
        /// The part. A stitch names these.
        public var id: PartID
        /// Its newest version, which is the one that plays.
        public var version: VersionID
        public var title: String
        public var type: PartType
        /// A chop only plays on the transport once it has been dirtied; a clean one is the lane's
        /// raw material. Said here so the surface can say it too.
        public var plays: Bool

        /// "Groove", "Bass", "Chords" — what this is, in one word, so a row of chips is readable
        /// without opening any of them. The version titles are sentences: a groove of this app's
        /// own writing is called "Brushes under the C loop: kick on 1, brushed accent on 3, …",
        /// which says everything about the part and nothing about which part it is.
        public var kind: String { StructureModel.name(of: type) }

        /// Why it does not play, in a word, or nil when it does. A clean chop is "dry" — the lane's
        /// raw material, waiting to be dirtied; anything else silent is simply "empty", and saying
        /// "dry" about a melody, as this surface used to, is not a word about melodies at all.
        public var silentReason: String? {
            guard !plays else { return nil }
            return type == .sample ? "dry" : "empty"
        }
    }

    /// The one-word name of a part kind, as this surface says it.
    public nonisolated static func name(of type: PartType) -> String {
        switch type {
        case .groove: return "Groove"
        case .bassline: return "Bass"
        case .progression: return "Chords"
        case .melody: return "Tune"
        case .sample: return "Chop"
        default: return type.rawValue.capitalized
        }
    }

    /// The shapes a section is usually added in.
    public enum Preset: String, CaseIterable, Sendable {
        case intro = "Intro", verse = "Verse", hook = "Hook", bridge = "Bridge", outro = "Outro"
        public var bars: Int {
            switch self {
            case .intro: return 4
            case .verse: return 16
            case .hook: return 8
            case .bridge: return 8
            case .outro: return 4
            }
        }
    }

    public let surfaceID: SurfaceID
    public var surface: StructureSurface { StructureSurface(id: surfaceID, title: title) }
    public let title: String
    public let tempo: Double
    public let timeSignature: TimeSignature

    public private(set) var sections: [Section]
    public private(set) var committed: [Section]
    public private(set) var selected: SectionID?
    public private(set) var layers: [Layer]
    public private(set) var lastError: String?

    private let host: any StructureHosting

    public init(host: any StructureHosting, song: Song?, surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        title = song?.title ?? "Structure"
        tempo = song?.tempo ?? 90
        timeSignature = song?.timeSignature ?? .fourFour
        let current = song?.sections ?? []
        let built = song.map(Self.layers(in:)) ?? []
        layers = built
        // The working copy is tidied; `committed` is the song's own, so a form that named two of a
        // kind shows as dirty and Keep writes back the one that was sounding.
        sections = current.map { Self.normalised($0) }
        committed = current
        selected = current.first?.id
    }

    /// Follows the song: a part adopted or a section stitched from outside this surface — a drop, the
    /// Director's `arrange` — shows up here. A working copy with unkept edits is left alone.
    public func sync(with song: Song?) {
        layers = song.map(Self.layers(in:)) ?? []
        let current = song?.sections ?? []
        guard current != committed else { return }
        let wasClean = !isDirty
        committed = current
        if wasClean {
            sections = normalised(current)
            if selected.map({ id in sections.contains { $0.id == id } }) != true { selected = sections.first?.id }
        }
    }

    /// A library row dropped on a section.
    public func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool {
        // The host stitches into the *kept* form, so unkept edits are kept first rather than lost.
        if isDirty { guard await keep() else { return false } }
        return await host.receive(payload, into: section)
    }

    // MARK: Reading

    public var isDirty: Bool { sections != committed }
    public var totalBars: Int { sections.reduce(0) { $0 + $1.lengthInBars } }
    public var isEmpty: Bool { sections.isEmpty }
    public var selectedSection: Section? { selected.flatMap { id in sections.first { $0.id == id } } }

    /// "46 bars · 2:00 at 92 bpm".
    public var lengthText: String {
        let seconds = Self.seconds(bars: totalBars, tempo: tempo, timeSignature: timeSignature)
        return "\(totalBars) bar\(totalBars == 1 ? "" : "s") · \(Self.clock(seconds)) at \(Int(tempo.rounded())) bpm"
    }

    public func layer(_ id: PartID) -> Layer? { layers.first { $0.id == id } }

    /// The layers a section names, in the order the stitch holds them; a part the song no longer
    /// holds is skipped rather than drawn as a hole.
    public func layers(of section: Section) -> [Layer] { section.stitch.compactMap { layer($0.part) } }

    /// The layers a section holds, grouped by kind in `playableTypes` order, with every kind the
    /// song offers present even when the section names none of it. This is what the surface draws:
    /// one row per kind, so "what does this section play" is answered by reading down a column
    /// rather than by recognising version titles.
    public func choices(for section: Section) -> [(type: PartType, layers: [Layer])] {
        Self.playableTypes.compactMap { type in
            let matching = layers.filter { $0.type == type }
            return matching.isEmpty ? nil : (type, matching)
        }
    }

    /// The kinds a section actually sounds, in order: "Groove · Bass · Chords".
    public func kinds(of section: Section) -> [String] {
        Self.playableTypes.compactMap { type in
            layers(of: section).contains { $0.type == type && $0.plays } ? Self.name(of: type) : nil
        }
    }

    /// Kinds the song has something playable of that this section does not play.
    ///
    /// The whole reason this surface got rebuilt: a song can hold three progressions and a chosen
    /// pad, and a form written before any of that was stitchable plays the drums and the bass and
    /// nothing else — silently, with no line anywhere saying the chords are sitting this one out.
    public func missing(from section: Section) -> [PartType] {
        let present = Set(layers(of: section).filter(\.plays).map(\.type))
        return Self.playableTypes.filter { type in
            !present.contains(type) && layers.contains { $0.type == type && $0.plays }
        }
    }

    /// The same, as words: "chords and a tune".
    public func missingText(from section: Section) -> String? {
        let names = missing(from: section).map { Self.name(of: $0).lowercased() }
        guard !names.isEmpty else { return nil }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Why a section would play nothing, or nil when it plays.
    public func silence(of section: Section) -> String? {
        let playing = layers(of: section).filter(\.plays)
        if playing.isEmpty {
            return section.stitch.isEmpty ? "Nothing stitched in: a rest of \(section.lengthInBars) bars."
                                          : "Nothing in it plays on the transport."
        }
        return nil
    }

    // MARK: Editing

    public func select(_ id: SectionID?) { selected = id }

    /// A section in the preset's shape, stitched from the newest of everything, after the selected
    /// section or at the end.
    @discardableResult
    public func add(_ preset: Preset) -> Section {
        add(name: preset.rawValue, bars: preset.bars)
    }

    @discardableResult
    public func add(name: String, bars: Int, stitch: [Lane]? = nil) -> Section {
        let section = Section(name: name, stitch: stitch ?? defaultStitch, lengthInBars: max(1, bars))
        let at = selected.flatMap { id in sections.firstIndex { $0.id == id } }.map { $0 + 1 } ?? sections.count
        sections.insert(section, at: at)
        selected = section.id
        return section
    }

    /// What a new section plays: the newest groove, bass line, chords, tune and dirtied chop in the
    /// song — the same choice the transport makes for an unarranged song, and in the same order.
    public var defaultStitch: [Lane] {
        var out: [Lane] = []
        for type in Self.playableTypes {
            if let layer = layers.last(where: { $0.type == type && $0.plays }) { out.append(Lane(part: layer.id)) }
        }
        return out
    }

    public func remove(_ id: SectionID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections.remove(at: index)
        if selected == id { selected = sections.isEmpty ? nil : sections[min(index, sections.count - 1)].id }
    }

    /// A copy with a new id, right after the original.
    @discardableResult
    public func duplicate(_ id: SectionID) -> Section? {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return nil }
        let original = sections[index]
        let copy = Section(name: original.name, stitch: original.stitch, lengthInBars: original.lengthInBars,
                           intensity: original.intensity, transitionIn: original.transitionIn,
                           transitionOut: original.transitionOut)
        sections.insert(copy, at: index + 1)
        selected = copy.id
        return copy
    }

    /// Moves a section so that it lands at `index` in the resulting list.
    public func move(_ id: SectionID, to index: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }) else { return }
        let section = sections.remove(at: from)
        sections.insert(section, at: max(0, min(index, sections.count)))
    }

    /// Drops `id` before `target`, or at the end when `target` is nil.
    public func move(_ id: SectionID, before target: SectionID?) {
        guard id != target, let from = sections.firstIndex(where: { $0.id == id }) else { return }
        let section = sections.remove(at: from)
        let to = target.flatMap { t in sections.firstIndex { $0.id == t } } ?? sections.count
        sections.insert(section, at: to)
    }

    public func moveEarlier(_ id: SectionID) {
        guard let index = sections.firstIndex(where: { $0.id == id }), index > 0 else { return }
        sections.swapAt(index, index - 1)
    }

    public func moveLater(_ id: SectionID) {
        guard let index = sections.firstIndex(where: { $0.id == id }), index < sections.count - 1 else { return }
        sections.swapAt(index, index + 1)
    }

    public func rename(_ id: SectionID, to name: String) {
        update(id) { $0.name = name }
    }

    public func setLength(_ id: SectionID, bars: Int) {
        update(id) { $0.lengthInBars = max(1, min(128, bars)) }
    }

    /// Puts a part into a section's stitch, or takes it out.
    ///
    /// No longer one of a kind. The transport used to hold one groove, one bass line and one of
    /// each other kind per section and sound the last of whatever a stitch named twice, so two
    /// chips lit and one part sounding was a lie this had to prevent. A section plays everything it
    /// names now, so two grooves is a thing you can mean — and a part is in a section once or not
    /// at all, which is the only rule left.
    public func toggle(_ part: PartID, in id: SectionID) {
        update(id) { section in
            if let at = section.stitch.firstIndex(where: { $0.part == part }) {
                section.stitch.remove(at: at)
            } else {
                section.stitch.append(Lane(part: part))
            }
        }
    }

    /// A section naming each part once.
    ///
    /// A form cannot play the same part twice — it is one lane, one strip, one sampler — and the
    /// schema migration already collapses the duplicates a version-id stitch could hold. This is
    /// the belt to that braces: a stitch assembled by hand or by a tool stays sane.
    static func normalised(_ section: Section) -> Section {
        var seen = Set<PartID>()
        var tidied = section
        tidied.stitch = section.stitch.filter { seen.insert($0.part).inserted }
        return tidied
    }

    private func normalised(_ sections: [Section]) -> [Section] {
        sections.map { Self.normalised($0) }
    }

    /// Parts the song holds that play, and that **no** section plays — in words: "the chords".
    ///
    /// The per-section line below says what one section leaves out. This says what the *song*
    /// leaves out, which is the case that actually bites: a part written after the form was
    /// arranged belongs to no section at all, and every section's line says the same thing, so the
    /// one you happen to have selected looks like a local problem rather than the whole form's.
    public var orphanedText: String? {
        let named = Set(sections.flatMap(\.stitch).map(\.part))
        let kinds = Self.playableTypes.filter { type in
            layers.contains { $0.type == type && $0.plays && !named.contains($0.id) }
        }
        guard !kinds.isEmpty, !sections.isEmpty else { return nil }
        let names = kinds.map { Self.name(of: $0).lowercased() }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Puts every part no section plays into every section. One move for the case above.
    public func fillAll() {
        for section in sections { fill(section.id) }
    }

    /// Stitches the newest playable version of every kind this section is missing into it: the
    /// same choice `defaultStitch` makes for a new section, offered to one that already exists.
    public func fill(_ id: SectionID) {
        guard let section = sections.first(where: { $0.id == id }) else { return }
        for type in missing(from: section) {
            guard let layer = layers.last(where: { $0.type == type && $0.plays }) else { continue }
            toggle(layer.id, in: id)
        }
    }

    private func update(_ id: SectionID, _ change: (inout Section) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        change(&sections[index])
    }

    // MARK: Keeping

    /// Hands the working copy to the song. Nothing is versioned: the sections *are* the song's.
    public func keep() async -> Bool {
        lastError = nil
        guard await host.arrange(sections) else {
            lastError = "Nothing is open to keep the arrangement in."
            return false
        }
        committed = sections
        return true
    }

    public func revert() {
        sections = committed
        if selected.map({ id in sections.contains { $0.id == id } }) != true { selected = sections.first?.id }
    }

    /// Keeps, then plays from the top.
    public func play() async {
        guard await keep() else { return }
        await host.play()
    }

    public func stop() async { await host.stop() }

    // MARK: Helpers

    /// The part kinds the transport can sound, in the order a section stitches them. Kept beside
    /// `SongPlayback.segments(of:)`, which reads exactly these out of a stitch: a kind offered here
    /// that the transport ignores is a section that looks like it plays and does not.
    nonisolated static let playableTypes: [PartType] = [.groove, .bassline, .progression, .melody, .sample]

    /// The newest version of every part that can play on the transport, oldest part first, plus
    /// any older version a section already names.
    static func layers(in song: Song) -> [Layer] {
        // One row per part, named by what its newest version is called. It used to be one row per
        // *version* — the newest of each part plus any older one a section still named — because a
        // stitch chose between versions. Nothing chooses now: a lane follows its part.
        song.partIDs.compactMap { partID in
            guard let newest = song.latestVersion(of: partID), playableTypes.contains(newest.type) else { return nil }
            return Layer(id: partID, version: newest.id, title: PartLabel.title(of: newest),
                         type: newest.type, plays: plays(newest))
        }
    }

    nonisolated static func plays(_ version: PartVersion) -> Bool {
        switch version.kind {
        case .groove(let groove): return groove.patterns.contains { $0.steps.contains { $0 != .rest } }
        case .bassline(let line): return !line.notes.isEmpty
        case .progression(let progression): return !progression.chords.isEmpty
        case .melody(let melody): return !melody.notes.isEmpty
        case .sample(let sample): return !sample.degradation.isEmpty
        default: return false
        }
    }

    // `label(of:in:)` is gone with the reason for it. It numbered a chip "Palladino line v2",
    // because a chip was a version and you were choosing between takes; a chip is a part, and the
    // version it plays is whichever is newest.

    nonisolated static func seconds(bars: Int, tempo: Double, timeSignature: TimeSignature) -> Double {
        guard tempo > 0 else { return 0 }
        return Double(bars * timeSignature.beatsPerBar) * 60 / tempo
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
