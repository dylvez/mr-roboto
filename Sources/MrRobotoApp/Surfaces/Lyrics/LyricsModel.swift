import Foundation
import SongGraph

/// What the Lyrics surface needs from its host: a version taken.
@MainActor
public protocol LyricsHosting: AnyObject {
    @discardableResult
    func commit(_ version: PartVersion) async -> Bool
}

/// The Lyrics surface's model: text in, a lyric with stresses and a scheme out, the Lyricist's
/// readings under it. Nothing is stored as text: the part is the lines, and the text is one way of
/// saying them.
@MainActor
@Observable
public final class LyricsModel {

    public let surfaceID: SurfaceID
    public var text: String { didSet { parse() } }
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
    public func commit() async -> PartVersion? {
        lastError = nil
        guard !isEmpty else { lastError = "Nothing to keep."; return nil }
        let payload = PartKind.lyric(lyric)
        let note = "\(observation?.lineCount ?? 0) lines · \(observation?.schemes.joined(separator: " / ") ?? "")"
        let version: PartVersion
        if let previous = versions.last ?? base {
            version = previous.deriving(payload, by: .user, operation: Operation.edit, note: note)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user, operation: Operation.written, note: note)
        }
        guard await host.commit(version) else { lastError = "The song would not take that version."; return nil }
        versions.append(version)
        lastKept = version
        return version
    }
}

/// `AppState` seen through `LyricsHosting`: a commit is recorded, and the Lyricist's readings go
/// to the rail in its own name.
@MainActor
final class LyricsAdapter: LyricsHosting {
    private let app: AppState
    init(app: AppState) { self.app = app }

    func commit(_ version: PartVersion) async -> Bool {
        guard app.record(version) else { return false }
        if case .lyric(let lyric) = version.kind {
            let readings = Lyricist().read(LyricObservation.of(lyric, label: PartLabel.title(of: version), corpus: app.voice, title: app.song?.title))
            let flags = readings.filter { !$0.holds }
            app.note(.persona("Lyricist"), flags.isEmpty ? (readings.first?.says ?? "That holds.") : flags.map(\.says).joined(separator: " "),
                     detail: PartLabel.title(of: version))
        }
        return true
    }
}
