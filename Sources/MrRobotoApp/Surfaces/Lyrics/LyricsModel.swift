import Foundation
import SongGraph

/// What the Lyrics surface needs from its host: a version taken.
@MainActor
public protocol LyricsHosting: AnyObject {
    /// Synchronous, so a keep the frame asks for before it plays is in the song when it reads.
    @discardableResult
    func commit(_ version: PartVersion) -> Bool
}

/// The Lyrics surface's model: text in, a lyric with stresses and a scheme out, the Lyricist's
/// readings under it. Nothing is stored as text: the part is the lines, and the text is one way of
/// saying them.
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
            if lastTyped.map({ now.timeIntervalSince($0) >= 1.5 }) ?? true { history.record(oldValue) }
            lastTyped = now
            didEdit()
        }
    }

    // MARK: Keeping as it goes

    private var history = EditHistory<String>()
    private var lastTyped: Date?
    private var isApplyingState = false
    /// Keeps the words a moment after the last edit. A test sets its delay to nil.
    public let autoKeep = AutoKeep()

    private func didEdit() {
        guard hasUnkeptChanges else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    private func apply(_ words: String) {
        isApplyingState = true
        text = words
        isApplyingState = false
        lastTyped = nil
        didEdit()
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
    public var hasUnkeptChanges: Bool {
        guard !isEmpty else { return false }
        guard let kept = versions.last ?? base, case .lyric(let keptLyric) = kept.kind else { return true }
        return keptLyric.lines != lyric.lines
    }
    public let songTitle: String?

    private let host: any LyricsHosting
    private let lyricist = Lyricist()

    public init(host: any LyricsHosting, lyric: PartVersion? = nil, corpus: LyricCorpus, title: String? = nil,
                surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.corpus = corpus
        self.songTitle = title
        if let lyric, case .lyric(let stored) = lyric.kind {
            base = lyric
            text = stored.text
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

    /// One scheme letter per line, aligned to `lyric.lines`; blank lines get none.
    public var schemeLetters: [String] {
        guard let observation else { return [] }
        var letters: [String] = []
        var stanza = 0, inStanza = 0
        for line in lyric.lines {
            if line.syllables.isEmpty {
                if inStanza > 0 { stanza += 1 }
                inStanza = 0
                letters.append("")
            } else {
                let scheme = stanza < observation.schemes.count ? Array(observation.schemes[stanza]) : []
                letters.append(inStanza < scheme.count ? String(scheme[inStanza]) : "")
                inStanza += 1
            }
        }
        return letters
    }

    private func parse() {
        lyric = Lyricist.lyric(from: text)
        guard !isEmpty else { observation = nil; readings = []; return }
        let observed = LyricObservation.of(lyric, label: title, corpus: corpus, title: songTitle)
        observation = observed
        readings = lyricist.read(observed)
    }

    /// Keeps the words as a version: derived from the one it opened on, or a new part.
    @discardableResult
    public func commit() -> PartVersion? {
        lastError = nil
        autoKeep.cancel()
        guard !isEmpty else { lastError = "Nothing to keep."; return nil }
        let payload = PartKind.lyric(lyric)
        let note = "\(observation?.lineCount ?? 0) lines · \(observation?.schemes.joined(separator: " / ") ?? "")"
        let version: PartVersion
        if let previous = versions.last ?? base {
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
        guard let previous = history.undo(from: text) else { return }
        apply(previous)
    }

    public func redo() {
        guard let next = history.redo(from: text) else { return }
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
    init(app: AppState) { self.app = app }

    /// What the Lyricist said last, so words kept as you type do not repeat it in the rail.
    private var lastSaid: String?

    func commit(_ version: PartVersion) -> Bool {
        guard app.record(version) else { return false }
        if case .lyric(let lyric) = version.kind {
            let readings = Lyricist().read(LyricObservation.of(lyric, label: PartLabel.title(of: version), corpus: app.voice, title: app.song?.title))
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
}
