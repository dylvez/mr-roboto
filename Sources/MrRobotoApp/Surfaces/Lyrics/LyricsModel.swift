import Foundation
import SongGraph

/// A melody the words can be set to: one version of a melody part, named as the ledger names it.
public struct LyricsMelody: Hashable, Sendable, Identifiable {
    public var version: VersionID
    public var part: PartID
    public var title: String
    public var melody: Melody

    public var id: VersionID { version }

    public init(version: VersionID, part: PartID, title: String, melody: Melody) {
        self.version = version
        self.part = part
        self.title = title
        self.melody = melody
    }
}

/// What the Lyrics surface needs from its host: a version taken, and the parts of the song the
/// words are written against — its melodies, its sections, its bar.
@MainActor
public protocol LyricsHosting: AnyObject {
    /// Synchronous, so a keep the frame asks for before it plays is in the song when it reads.
    @discardableResult
    func commit(_ version: PartVersion) -> Bool
    /// The melodies the words can be set to: each melody part's newest version, in song order.
    var melodies: [LyricsMelody] { get }
    /// One melody version by id, older ones included. Words set to a version stay set to it: the
    /// note indices are that version's, not whatever its part has become since.
    func melody(_ version: VersionID) -> LyricsMelody?
    /// The song's section names, each once, in form order: the labels a stanza is offered.
    var sectionNames: [String] { get }
    /// Beats in one of the song's bars, for where a note falls.
    var beatsPerBar: Int { get }
    /// The newest version of a part in the song, so a keep builds on it — the Lyricist's rewrite,
    /// or a restore — rather than on the version this page last kept.
    func newest(of part: PartID) -> PartVersion?
}

extension LyricsHosting {
    public func newest(of part: PartID) -> PartVersion? { nil }
}

/// A host with no song around the words: nothing to set them to, no sections to name, 4/4.
extension LyricsHosting {
    public var melodies: [LyricsMelody] { [] }
    public func melody(_ version: VersionID) -> LyricsMelody? { melodies.first { $0.version == version } }
    public var sectionNames: [String] { [] }
    public var beatsPerBar: Int { 4 }
}

/// The Lyrics surface's model: text in, a lyric with stresses and a scheme out, the Lyricist's
/// readings under it. Nothing is stored as text: the part is the lines, and the text is one way of
/// saying them — labels included, as "[Hook]" above a stanza.
@MainActor
@Observable
public final class LyricsModel {

    public let surfaceID: SurfaceID
    public var text: String {
        didSet {
            parse()
            guard !isApplyingState, oldValue != text else { return }
            let now = Date()
            // One step of undo per pause in the typing, not per key.
            if lastTyped.map({ now.timeIntervalSince($0) >= 1.5 }) ?? true { history.record(Page(text: oldValue, setTo: setTo)) }
            lastTyped = now
            didEdit()
        }
    }

    /// The melody version the words are set to, one syllable to a note. Nil is not set.
    public private(set) var setTo: VersionID?

    // MARK: Keeping as it goes

    /// One step of undo: the words, and the melody they were set to. Setting the words to a tune
    /// is an edit like any other, so ⌘Z takes it back.
    private struct Page: Equatable, Sendable {
        var text: String
        var setTo: VersionID?
    }

    private var history = EditHistory<Page>()
    private var lastTyped: Date?
    private var isApplyingState = false
    /// Keeps the words a moment after the last edit. A test sets its delay to nil.
    public let autoKeep = AutoKeep()

    private func didEdit() {
        guard hasUnkeptChanges else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    private func apply(_ page: Page) {
        isApplyingState = true
        setTo = page.setTo
        text = page.text
        // The words may be the same and only the setting moved; read them again either way.
        parse()
        isApplyingState = false
        lastTyped = nil
        didEdit()
    }

    /// An edit made by a control rather than by typing — a label chip, a melody chosen. It is its
    /// own step of undo, and the typing after it starts another.
    private func change(_ edit: (inout Page) -> Void) {
        let before = Page(text: text, setTo: setTo)
        var after = before
        edit(&after)
        guard after != before else { return }
        history.record(before)
        apply(after)
    }

    public private(set) var lyric: Lyric
    public private(set) var observation: LyricObservation?
    public private(set) var readings: [PersonaReading] = []
    public private(set) var base: PartVersion?
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    /// The version the last keep made, for the footer to say so. Nil until one is kept, and set
    /// aside again — by `hasUnkeptChanges` turning true — once the words move on from it.
    public private(set) var lastKept: PartVersion?
    public let corpus: LyricCorpus

    /// Whether the words on the page differ from the last version kept, or from the one the
    /// surface was opened on. The keep control follows this, so pressing it twice cannot file the
    /// same words twice; an empty page has nothing to keep.
    ///
    /// The whole lyric, not only its lines: a stanza newly called the Hook, or the words set to a
    /// tune, changes nothing a line says and is still an edit.
    public var hasUnkeptChanges: Bool {
        guard !isEmpty else { return false }
        guard let kept = keptLyric else { return true }
        return kept != lyric
    }
    public let songTitle: String?

    private let host: any LyricsHosting
    private let lyricist = Lyricist()

    /// The song's genre, asked each time the readings are made: a reading is re-judged in it
    /// (`GenreLens`). Nil — the default, and a song nobody has placed — leaves the persona's own.
    public var genre: @MainActor () -> GenreLens? = { nil }

    public init(host: any LyricsHosting, lyric: PartVersion? = nil, corpus: LyricCorpus, title: String? = nil,
                surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.corpus = corpus
        self.songTitle = title
        if let lyric, case .lyric(let stored) = lyric.kind {
            base = lyric
            text = stored.text
            setTo = stored.alignedTo
            self.lyric = stored
        } else {
            text = ""
            self.lyric = Lyric(lines: [])
        }
        parse()
    }

    public var title: String {
        if let base { return PartLabel.title(of: base) }
        return lyric.lines.first?.text.isEmpty == false ? String(lyric.lines[0].text.prefix(32)) : "Lyrics"
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// One scheme letter per line, aligned to `lyric.lines`; blank lines get none, and neither
    /// does a stanza of one line, which has nothing to rhyme with. Stanzas are the Lyricist's own,
    /// so a label starts one here exactly as it does there.
    public var schemeLetters: [String] {
        guard let observation else { return [] }
        var letters = Array(repeating: "", count: lyric.lines.count)
        let schemed = LyricObservation.stanzas(of: lyric).filter { $0.count >= 2 }
        for (stanza, scheme) in zip(schemed, observation.schemes) {
            for (line, letter) in zip(stanza, scheme) { letters[line] = String(letter) }
        }
        return letters
    }

    /// The section name written above each stanza, by the index of the line it starts at.
    public var stanzaLabels: [Int: String] {
        Dictionary((lyric.labels ?? []).map { ($0.line, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var keptLyric: Lyric? {
        guard let kept = versions.last ?? base, case .lyric(let words) = kept.kind else { return nil }
        return words
    }

    private func parse() {
        var words = Lyricist.lyric(from: text)
        if let setTo {
            if let kept = keptLyric, kept.alignedTo == setTo, kept.unaligned() == words {
                // The words as they were kept, setting and all: nothing moved, so nothing is
                // re-set — a hand-placed syllable stays where it was put.
                words = kept
            } else if let melody = host.melody(setTo) {
                // The words moved, so the setting follows them: one syllable to a note again.
                words = words.aligned(to: melody.melody, version: setTo)
            }
        }
        lyric = words
        guard !isEmpty else { observation = nil; readings = []; return }
        let set = lyric.alignedTo.flatMap { host.melody($0)?.melody }
        let observed = LyricObservation.of(lyric, label: title, corpus: corpus, title: songTitle,
                                           melody: set, beatsPerBar: host.beatsPerBar)
        observation = observed
        readings = GenreLens.judge(lyricist.read(observed), by: Lyricist.bible, in: genre())
    }

    // MARK: Labels

    /// The song's section names, each once: what a stanza can be called with one press.
    public var labelChoices: [String] {
        var seen = Set<String>()
        return host.sectionNames.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Writes "[name]" above the stanza the caret is in — `row` is a row of `text`, label rows
    /// counted — or above the first stanza with no label. An edit like a typed one, and its own
    /// step of undo.
    public func label(_ name: String, atRow row: Int? = nil) {
        guard let labelled = Self.labelling(text, as: name, atRow: row) else { return }
        change { $0.text = labelled }
    }

    /// The text with "[name]" above a stanza, or nil when that changes nothing.
    ///
    /// Which stanza: the one `row` is in; the one just under it when `row` is a blank line above
    /// a stanza; a new stanza started at `row` when it is a blank line with nothing under it;
    /// otherwise the first stanza with no label, and when every stanza has one, a new stanza
    /// started at the end. A stanza that already has a label is renamed, not labelled twice — its
    /// label is the nearest line above it that is not blank, when that line is a label, which is
    /// how the parser reads it too.
    static func labelling(_ text: String, as name: String, atRow row: Int?) -> String? {
        enum Kind { case blank, label, sung }
        var rows = text.components(separatedBy: "\n")
        let kinds: [Kind] = rows.map { row in
            if row.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
            return Lyricist.label(in: row) == nil ? .sung : .label
        }
        let tag = "[\(name)]"
        let starts = kinds.indices.filter { kinds[$0] == .sung && ($0 == 0 || kinds[$0 - 1] != .sung) }
        func existingLabel(above start: Int) -> Int? {
            var index = start - 1
            while index >= 0, kinds[index] == .blank { index -= 1 }
            return index >= 0 && kinds[index] == .label ? index : nil
        }
        /// A new stanza begun in place of the blank row at `index`, or after the last row: one
        /// blank line between it and the words above, the label, and a line under it to type on.
        func startingStanza(at index: Int) -> String {
            var head = Array(rows.prefix(index))
            let tail = Array(rows.dropFirst(index + 1))
            while head.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { head.removeLast() }
            if !head.isEmpty { head.append("") }
            return (head + [tag, ""] + tail).joined(separator: "\n")
        }

        var target: Int?
        if let row, kinds.indices.contains(row) {
            switch kinds[row] {
            case .sung:
                target = starts.last { $0 <= row }
            case .label:
                guard rows[row].trimmingCharacters(in: .whitespaces) != tag else { return nil }
                rows[row] = tag
                return rows.joined(separator: "\n")
            case .blank:
                let below = kinds[(row + 1)...].firstIndex { $0 != .blank }
                if let below, kinds[below] == .sung { target = below }
                else if below == nil { return startingStanza(at: row) }
            }
        }
        if target == nil { target = starts.first { existingLabel(above: $0) == nil } }
        // Nothing unlabelled to name — an empty page, or every stanza named already: the label
        // starts the next stanza, at the end.
        guard let start = target else { return startingStanza(at: rows.count) }
        if let existing = existingLabel(above: start) {
            guard rows[existing].trimmingCharacters(in: .whitespaces) != tag else { return nil }
            rows[existing] = tag
        } else {
            rows.insert(tag, at: start)
        }
        return rows.joined(separator: "\n")
    }

    // MARK: Setting the words to a melody

    /// The melodies on offer, newest version of each.
    public var melodyChoices: [LyricsMelody] { host.melodies }

    /// The melody the words are set to, when the song still holds it.
    public var setMelody: LyricsMelody? { setTo.flatMap { host.melody($0) } }

    /// The words are set to a version of a melody that has a newer one: choosing the melody again
    /// sets them to what it is now.
    public var setToOlderVersion: Bool {
        guard let set = setMelody else { return false }
        return host.melodies.contains { $0.part == set.part && $0.version != set.version }
    }

    /// Sets the words to a melody's notes, one syllable to a note, or — with nil — unsets them. An
    /// edit: undoable, and kept a moment later like anything typed.
    public func setMelody(_ version: VersionID?) {
        if let version, host.melody(version) == nil { return }
        change { $0.setTo = version }
    }

    /// How the words landed on the notes, counted.
    public struct Setting: Equatable, Sendable {
        public var melody: String
        public var syllables: Int
        /// Syllables with a note.
        public var set: Int
        public var notes: Int

        /// Syllables sung after the melody has run out of notes.
        public var past: Int { syllables - set }
        /// Notes after the last syllable: melisma, or a phrase still to be written.
        public var spareNotes: Int { max(0, notes - syllables) }

        /// "34 syllables · 32 set to notes · 2 past the last note".
        public var line: String {
            func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
            var parts = [count(syllables, "syllable"), "\(set) set to notes"]
            if past > 0 { parts.append("\(past) past the last note") }
            else if spareNotes > 0 { parts.append("\(count(spareNotes, "note")) with no syllable") }
            else { parts.append("one to each") }
            return parts.joined(separator: " · ")
        }
    }

    public var setting: Setting? {
        guard lyric.alignedTo != nil, let melody = setMelody else { return nil }
        return Setting(melody: melody.title, syllables: lyric.syllableCount, set: lyric.setSyllableCount,
                       notes: melody.melody.notes.count)
    }

    /// Keeps the words as a version: derived from the one it opened on, or a new part.
    @discardableResult
    public func commit() -> PartVersion? {
        lastError = nil
        autoKeep.cancel()
        guard !isEmpty else { lastError = "Nothing to keep."; return nil }
        let payload = PartKind.lyric(lyric)
        var note = "\(observation?.lineCount ?? 0) lines · \(observation?.schemes.joined(separator: " / ") ?? "")"
        if let setting { note += " · set to \(setting.melody)" }
        let version: PartVersion
        if let kept = versions.last ?? base {
            let previous = host.newest(of: kept.partID) ?? kept
            version = previous.deriving(payload, by: .user, operation: Operation.edit, note: note)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user, operation: Operation.written, note: note)
        }
        guard host.commit(version) else { lastError = "The song would not take that version."; return nil }
        versions.append(version)
        lastKept = version
        return version
    }
}

extension LyricsModel: KeepsAsItGoes {
    @discardableResult
    public func keepNow() -> Bool {
        guard hasUnkeptChanges else { autoKeep.cancel(); return true }
        return commit() != nil
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let previous = history.undo(from: Page(text: text, setTo: setTo)) else { return }
        apply(previous)
    }

    public func redo() {
        guard let next = history.redo(from: Page(text: text, setTo: setTo)) else { return }
        apply(next)
    }

    public var keepLine: KeepLine {
        if let lastError { return .refused(lastError) }
        if hasUnkeptChanges { return .pending }
        if let kept = versions.last ?? base { return .kept(title: PartLabel.title(of: kept)) }
        return .untouched
    }
}

/// `AppState` seen through `LyricsHosting`: a commit is recorded, and the Lyricist's readings go
/// to the rail in its own name.
@MainActor
final class LyricsAdapter: LyricsHosting {
    private let app: AppState
    /// The page's bench item, whose binding follows what it keeps.
    private let surface: SurfaceID?
    init(app: AppState, surface: SurfaceID? = nil) {
        self.app = app
        self.surface = surface
    }

    func newest(of part: PartID) -> PartVersion? {
        app.song?.versions.last { $0.partID == part }
    }

    /// What the Lyricist said last, so words kept as you type do not repeat it in the rail.
    private var lastSaid: String?

    func commit(_ version: PartVersion) -> Bool {
        guard app.record(version) else { return false }
        if let surface { app.surfaceKept(version, on: surface) }
        if case .lyric(let lyric) = version.kind {
            let set = lyric.alignedTo.flatMap { melody($0)?.melody }
            let readings = Lyricist().read(LyricObservation.of(lyric, label: PartLabel.title(of: version), corpus: app.voice,
                                                               title: app.song?.title, melody: set, beatsPerBar: beatsPerBar))
            let flags = readings.filter { !$0.holds }
            // The readings are on the surface; the rail hears only what changed and went wrong.
            let line = flags.map(\.says).joined(separator: " ")
            if !flags.isEmpty, line != lastSaid {
                app.note(.persona("Lyricist"), line, detail: PartLabel.title(of: version))
            }
            lastSaid = flags.isEmpty ? nil : line
        }
        return true
    }

    var melodies: [LyricsMelody] {
        guard let song = app.song else { return [] }
        return song.partIDs.compactMap { part in
            song.latestVersion(of: part).flatMap(Self.melody(of:))
        }
    }

    func melody(_ version: VersionID) -> LyricsMelody? {
        app.song?.version(version).flatMap(Self.melody(of:))
    }

    var sectionNames: [String] {
        var seen = Set<String>()
        return (app.song?.sections ?? []).map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }

    var beatsPerBar: Int { app.song?.timeSignature.beatsPerBar ?? 4 }

    private static func melody(of version: PartVersion) -> LyricsMelody? {
        guard case .melody(let melody) = version.kind else { return nil }
        return LyricsMelody(version: version.id, part: version.partID, title: PartLabel.title(of: version), melody: melody)
    }
}
