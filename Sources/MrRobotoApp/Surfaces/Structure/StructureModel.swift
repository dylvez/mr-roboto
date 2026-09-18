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

    /// One version that a section can hold: the newest of each groove, bass line and chop part in
    /// the song, and any older version a section already names.
    public struct Layer: Identifiable, Hashable, Sendable {
        public var id: VersionID
        public var title: String
        public var type: PartType
        /// A chop only plays on the transport once it has been dirtied; a clean one is the lane's
        /// raw material. Said here so the surface can say it too.
        public var plays: Bool
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
        sections = current
        committed = current
        selected = current.first?.id
        layers = song.map(Self.layers(in:)) ?? []
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
            sections = current
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

    public func layer(_ id: VersionID) -> Layer? { layers.first { $0.id == id } }

    /// The layers a section names, in the order the stitch holds them; a version the song no
    /// longer resolves is skipped rather than drawn as a hole.
    public func layers(of section: Section) -> [Layer] { section.stitch.compactMap(layer) }

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
    public func add(name: String, bars: Int, stitch: [VersionID]? = nil) -> Section {
        let section = Section(name: name, stitch: stitch ?? defaultStitch, lengthInBars: max(1, bars))
        let at = selected.flatMap { id in sections.firstIndex { $0.id == id } }.map { $0 + 1 } ?? sections.count
        sections.insert(section, at: at)
        selected = section.id
        return section
    }

    /// What a new section plays: the newest groove, the newest bass line and the newest dirtied
    /// chop in the song — the same choice the transport makes for an unarranged song.
    public var defaultStitch: [VersionID] {
        var out: [VersionID] = []
        for type in [PartType.groove, .bassline, .sample] {
            if let layer = layers.last(where: { $0.type == type && $0.plays }) { out.append(layer.id) }
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

    /// Puts a version into a section's stitch, or takes it out.
    public func toggle(_ version: VersionID, in id: SectionID) {
        update(id) { section in
            if let at = section.stitch.firstIndex(of: version) {
                section.stitch.remove(at: at)
            } else {
                section.stitch.append(version)
            }
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

    /// The newest version of every part that can play on the transport, oldest part first, plus
    /// any older version a section already names.
    static func layers(in song: Song) -> [Layer] {
        var out: [Layer] = []
        var seen = Set<VersionID>()
        let named = Set(song.sections.flatMap(\.stitch))
        for partID in song.partIDs {
            let versions = song.versions(of: partID)
            guard let newest = versions.last, [PartType.groove, .bassline, .sample].contains(newest.type) else { continue }
            for version in versions where version.id == newest.id || named.contains(version.id) {
                guard seen.insert(version.id).inserted else { continue }
                out.append(Layer(id: version.id, title: label(of: version, in: song), type: version.type,
                                 plays: plays(version)))
            }
        }
        return out
    }

    nonisolated static func plays(_ version: PartVersion) -> Bool {
        switch version.kind {
        case .groove(let groove): return groove.patterns.contains { $0.steps.contains { $0 != .rest } }
        case .bassline(let line): return !line.notes.isEmpty
        case .sample(let sample): return !sample.degradation.isEmpty
        default: return false
        }
    }

    static func label(of version: PartVersion, in song: Song) -> String {
        let number = song.versions(of: version.partID).firstIndex { $0.id == version.id }.map { $0 + 1 }
        let title = PartLabel.title(of: version)
        return number.map { "\(title) v\($0)" } ?? title
    }

    nonisolated static func seconds(bars: Int, tempo: Double, timeSignature: TimeSignature) -> Double {
        guard tempo > 0 else { return 0 }
        return Double(bars * timeSignature.beatsPerBar) * 60 / tempo
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
