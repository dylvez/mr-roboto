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
    /// What the key field last failed to read, or nil while the key is what was typed. The key
    /// itself stays put on a bad line: a field that half-read "F#m" as F major would be worse than
    /// one that says no.
    public private(set) var keyProblem: String?
    public private(set) var base: PartVersion?
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    /// The version the last keep made, for the footer to say so. Nil until one is kept, and set
    /// aside again — by `hasUnkeptChanges` turning true — once the chords move on from it.
    public private(set) var lastKept: PartVersion?

    /// Whether the bars on screen are a progression the song does not have yet: something that
    /// reads, and differs from the last version kept or the one the surface was opened on. A line
    /// with a typo has nothing to keep; a fresh surface's I–IV–V–I does.
    public var hasUnkeptChanges: Bool {
        guard problem == nil, let progression else { return false }
        guard let kept = versions.last ?? base, case .progression(let keptProgression) = kept.kind else { return true }
        return keptProgression != progression
    }

    /// True while the line has a typo: the bars still show the last line that read, and the view
    /// says so rather than letting them pass for what is typed.
    public var barsAreStale: Bool { problem != nil }
    /// The instrument these chords are voiced on, by preset id.
    public var instrument: String { host.instrument }

    public func setInstrument(_ id: String) {
        host.setInstrument(id, for: part)
        if let progression, let first = progression.chords.first { audition(first) }
    }

    /// The part these chords belong to, once they have been kept.
    public var part: PartID? { (versions.last ?? base)?.partID }
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
        keyProblem = nil
        parse()
    }

    /// The key as a line you type: "D major", "F# minor", "Bb", "E dorian" — whatever `Key` reads.
    /// A line it does not read leaves the key alone and says so in `keyProblem`; true when the
    /// key changed to what was typed.
    @discardableResult
    public func setKey(parsing text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Key(parsing: trimmed) else {
            keyProblem = trimmed.isEmpty
                ? "Type a key, like D major or F# minor."
                : "Not a key I know — try D major, F# minor or E dorian."
            return false
        }
        setKey(parsed)
        return true
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
        lastKept = version
        lastError = nil
        Task { @MainActor [host, weak self] in
            let kept = await host.commit(version)
            guard !kept, let self else { return }
            // Refused: the version is not in the song, so it is not in this list either, and the
            // keep control comes back for another try.
            versions.removeAll { $0.id == version.id }
            if lastKept?.id == version.id { lastKept = nil }
            lastError = "The host refused the version."
        }
        return version
    }
}
