import Foundation
import MusicTheory
import SongGraph

/// The Chords surface's entry in the catalog: the lead sheet, surface #5, bound to a progression.
public struct ChordsSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .chords }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Chords") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

/// The Chords surface's model: a line of chord symbols, read as a `Progression` in the song's key.
///
/// You type what a lead sheet says — `Dm7 G7 | Cmaj7` — and the surface shows the bars with their
/// Roman numerals, plays a bar when you touch it, and commits the progression as a version the
/// bass writer reads. Nothing is stored as text: the part is the chords, and the text is one way
/// of saying them.
@MainActor
@Observable
public final class ChordsModel {

    public let surfaceID: SurfaceID
    public var surface: ChordsSurface {
        ChordsSurface(id: surfaceID, bound: base.map { [$0.id] } ?? [], title: title)
    }

    public var title: String {
        if let base { return PartLabel.title(of: base) }
        return progression.map { "\($0.chords.count) chords in \($0.key)" } ?? "Chords"
    }

    /// What is typed. Parsed on every change; a symbol that cannot be read is named in `problem`.
    public var text: String {
        didSet { parse() }
    }
    public private(set) var key: Key
    public private(set) var progression: Progression?
    public private(set) var problem: String?
    public private(set) var base: PartVersion?
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    /// The instrument these chords are voiced on, by preset id.
    public var instrument: String { host.instrument }

    public func setInstrument(_ id: String) {
        host.setInstrument(id)
        if let progression, let first = progression.chords.first { audition(first) }
    }
    public let beatsPerBar: Int

    private let host: any ChordsHosting

    public init(host: any ChordsHosting, key: Key, beatsPerBar: Int = 4, progression: PartVersion? = nil,
                surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.key = key
        self.beatsPerBar = beatsPerBar
        if let progression, case .progression(let stored) = progression.kind {
            base = progression
            self.key = stored.key
            text = stored.symbols()
        } else {
            text = ""
        }
        parse()
    }

    /// Reads `text` as the key's I–IV–V–I when it is empty, so an open surface is never blank.
    private func parse() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            progression = Progression(key: key, bars: Self.defaultBars(in: key, beatsPerBar: beatsPerBar))
            problem = nil
            return
        }
        switch Progression.parse(trimmed, key: key, beatsPerBar: beatsPerBar) {
        case .success(let parsed):
            progression = parsed
            problem = nil
        case .failure(let error):
            problem = error.description
        }
    }

    /// I–IV–V–I in the key, a bar each: what the bass writer uses when nothing is stated.
    static func defaultBars(in key: Key, beatsPerBar: Int) -> [ProgressionBar] {
        [1, 4, 5, 1].compactMap { degree in
            key.scale.diatonicChord(degree: degree, root: key.tonic.pitchClass, size: 4)
                .map { ProgressionBar($0, beats: Double(beatsPerBar)) }
        }
    }

    public var isDefault: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    public func setKey(_ newKey: Key) {
        key = newKey
        parse()
    }

    /// The Roman numeral of a chord in the key, or its symbol when it is not diatonic.
    public func numeral(of chord: Chord) -> String {
        key.romanNumeral(for: chord).map { "\($0)" } ?? chord.symbol(preferring: key.signature.preference)
    }

    // MARK: Playing

    /// Sounds a bar's first chord as a bass voicing — root, third, seventh — an octave above the
    /// bass register, for one beat.
    public func audition(_ chord: Chord) {
        let root = 48 + chord.root.rawValue
        let pitches = chord.pitches(root: Pitch(midi: root)).map(\.midi)
        Task { [host] in await host.audition(pitches: pitches, duration: 0.9) }
    }

    // MARK: Versions

    @discardableResult
    public func commit(note: String? = nil) -> PartVersion? {
        guard let progression, problem == nil else { return nil }
        let payload = PartKind.progression(progression)
        let text = note ?? "\(progression.symbols()) in \(progression.key)"
        let version: PartVersion
        if let previous = versions.last ?? base {
            version = previous.deriving(payload, by: .user, operation: Operation.edit, note: text)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user, operation: Operation.written, note: text)
        }
        versions.append(version)
        Task { @MainActor [host, weak self] in
            if await !host.commit(version) { self?.lastError = "The host refused the version." }
        }
        return version
    }
}
