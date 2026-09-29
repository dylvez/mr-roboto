import Foundation
import MusicTheory
import Performance
import SongGraph

// MARK: - What the band asks

/// Someone in the band asking what you want to do next, with the few things most worth doing.
///
/// There is always a question. With no song open the Director asks where to start; in a song, the
/// member whose work the moment is asks — the Beatmaker over a groove, the Engineer at the mix —
/// in the song's own numbers. What it offers is ranked three ways: the order the work goes in, what
/// just happened, and what you have chosen at this point before (`NextPreferences`). It is worked
/// out here, from the song, instantly; the band's field is always one option away for anything
/// the question did not think of.
public struct NextQuestion: Equatable, Sendable {
    /// Who asks: the member whose work this moment is.
    public var asker: Proposal.Source
    /// What they see: one sentence in the song's numbers.
    public var observation: String
    public var question: String
    /// Best first; up to `NextAdvisor.maximumOptions`.
    public var options: [NextOption]
    /// Where on the path this is asked — "flip.bass", "launch" — so what you choose here is
    /// remembered here.
    public var stage: String
}

public struct NextOption: Identifiable, Equatable, Sendable {
    /// What kind of move it is, for remembering: "bass", "arrange", "openSong".
    public var kind: String
    public var title: String
    public var rationale: String
    public var move: NextMove
    /// Raised by what you have chosen at this point before, and said so on the option.
    public var isYourUsual = false

    public var id: String { "\(kind)|\(move.identity)" }
}

/// What taking an option does. Most open a surface; the rest are the app's own verbs.
public enum NextMove: Equatable, Sendable {
    case surface(SurfaceAction)
    case openSong(SongID)
    case newSong
    case importRecord
    case mashup
    case play
    case songSettings
    /// The library's list, unfolded: every song, for one the question did not name.
    case showLibrary
    case exportMaster
    /// The loop arranged into a song: `AppState.developAndMaster`.
    case develop
    /// The song as it was before it was developed.
    case putBackDevelopment
    case addToAlbum(AlbumID)
    /// The band's field, with a sentence ready in it and the column open. Nothing is sent: the
    /// band costs a request, and sending is yours.
    case askBand(String)

    var identity: String {
        switch self {
        case .surface(let action): return action.identity
        case .openSong(let id): return "open|\(id.rawValue)"
        case .newSong: return "new"
        case .importRecord: return "import"
        case .mashup: return "mashup"
        case .play: return "play"
        case .songSettings: return "settings"
        case .showLibrary: return "library"
        case .exportMaster: return "export"
        case .develop: return "develop"
        case .putBackDevelopment: return "putBack"
        case .addToAlbum(let id): return "album|\(id.rawValue)"
        case .askBand(let text): return "ask|\(text)"
        }
    }
}

// MARK: - What you choose, remembered

/// What you choose at each point, kept across launches: an option you keep taking rises there, one
/// you pass over sinks a little, and one you wave away with "Not this" sinks further. A choice also
/// counts a little everywhere, so a habit — mixing before you write words, starting from records —
/// carries to steps you have not been at yet.
@MainActor
public final class NextPreferences {
    struct Tally: Codable, Equatable {
        var chose = 0
        var passed = 0
        var declined = 0
        var score: Double { Double(chose) - 0.35 * Double(passed) - 1.5 * Double(declined) }
    }

    static let key = "next.preferences.v1"
    private let defaults: UserDefaults
    private var tallies: [String: Tally]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        tallies = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Tally].self, from: $0) } ?? [:]
    }

    /// How far your history moves an option, about −4 to +4.
    func weight(of kind: String, at stage: String) -> Double {
        let here = tallies["\(stage)|\(kind)"]?.score ?? 0
        let anywhere = tallies["*|\(kind)"]?.score ?? 0
        return max(-4, min(4, here + 0.3 * anywhere))
    }

    /// `kind` was taken at `stage`; the options offered above it were passed over.
    func chose(_ kind: String, at stage: String, offered: [String]) {
        bump(kind, at: stage) { $0.chose += 1 }
        for other in offered.prefix(while: { $0 != kind }) { bump(other, at: stage) { $0.passed += 1 } }
        save()
    }

    func declined(_ kind: String, at stage: String) {
        bump(kind, at: stage) { $0.declined += 1 }
        save()
    }

    /// Everything forgotten: the question goes back to the order the work goes in.
    func forget() {
        tallies = [:]
        defaults.removeObject(forKey: Self.key)
    }

    private func bump(_ kind: String, at stage: String, _ change: (inout Tally) -> Void) {
        for key in ["\(stage)|\(kind)", "*|\(kind)"] { change(&tallies[key, default: Tally()]) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tallies) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Working out the question

@MainActor
enum NextAdvisor {
    /// Past three it is a menu, not a question; "Something else" is always there besides.
    static let maximumOptions = 3

    /// How recent a keep is still "what just happened".
    static let recent: TimeInterval = 10 * 60

    struct Candidate {
        var option: NextOption
        var score: Double
    }

    static func question(for app: AppState) -> NextQuestion {
        guard let song = app.song else { return launch(app) }
        guard !song.versions.isEmpty else { return starting(song, app) }
        return working(song, app)
    }

    // MARK: No song open

    private static func launch(_ app: AppState) -> NextQuestion {
        let stage = "launch"
        var candidates: [Candidate] = []
        let last = app.lastOpenedSong ?? app.library.songs.first
        if let last {
            let parts = Set(last.versions.map(\.partID)).count
            var rationale = "\(Int(last.tempo.rounded())) bpm\(last.key.map { " in \($0.name)" } ?? ""), \(Guidance.count(parts, "part"))"
            if let next = nextStep(of: last) { rationale += "; next on its path: \(next.title.lowercased())" }
            candidates.append(Candidate(option: NextOption(kind: "openSong", title: "Pick up \(last.title)",
                                                           rationale: rationale + ".", move: .openSong(last.id)), score: 10))
        }
        candidates.append(Candidate(option: NextOption(
            kind: "newSong", title: "Start a new song",
            rationale: "A title, a tempo and a key first: every writer in the band reads them.", move: .newSong), score: 8))
        candidates.append(Candidate(option: NextOption(
            kind: "importRecord", title: "Flip a record",
            rationale: "Drop in an audio file: its bars, tempo, key and form are read, and a bar of it becomes a groove.",
            move: .importRecord), score: 7))
        let others = app.library.songs.count - (last == nil ? 0 : 1)
        if others > 0 {
            candidates.append(Candidate(option: NextOption(
                kind: "openLibrary", title: last == nil ? "Open a song" : "Open another song",
                rationale: "\(Guidance.count(app.library.songs.count, "song")) in the library; the list unfolds on the left.",
                move: .showLibrary), score: 6))
        }
        if app.library.songs.filter({ Mashups.source(for: $0) != nil }).count >= 2 {
            candidates.append(Candidate(option: NextOption(
                kind: "mashup", title: "Put two songs on one grid",
                rationale: "A mashup: one keeps its tempo and key, the other is moved to meet it.", move: .mashup), score: 4))
        }
        let observation: String
        if let last {
            observation = app.lastOpenedSong != nil ? "Last time you were in \(last.title)." : "\(Guidance.count(app.library.songs.count, "song")) in the library."
        } else {
            observation = "The library is empty."
        }
        let options = rank(candidates, at: stage, app: app)
        let question = last == nil ? "How do you want to start?" : "What would you like to do?"
        return NextQuestion(asker: .director, observation: observation, question: question, options: options, stage: stage)
    }

    // MARK: A song with nothing in it

    private static func starting(_ song: Song, _ app: AppState) -> NextQuestion {
        let stage = "start"
        var candidates: [Candidate] = []
        let settled = song.key != nil || abs(song.tempo - 120) > 0.01 || !song.title.hasPrefix("Untitled")
        if !settled {
            candidates.append(Candidate(option: NextOption(
                kind: "songSettings", title: "Name it, and set its tempo and key",
                rationale: "Every writer reads them; a bass line written before the key is set is written to C.",
                move: .songSettings), score: 10))
        }
        candidates.append(Candidate(option: NextOption(
            kind: "groove", title: "Paint a groove",
            rationale: "Start on a feel, \(FeelLibrary.standard.count) of them on board, and paint the steps by hand.",
            move: .surface(Guidance.dockAction(for: .grid, in: song))), score: 9))
        candidates.append(Candidate(option: NextOption(
            kind: "chords", title: "Start from chords",
            rationale: "Type a lead sheet — Dm7 G7 | Cmaj7 — and the bass is written to it.",
            move: .surface(Guidance.dockAction(for: .chords, in: song))), score: 6))
        candidates.append(Candidate(option: NextOption(
            kind: "askBand", title: "Ask the Beatmaker for a groove",
            rationale: "Say the feel in words; the band writes it onto a drum machine for you to change.",
            move: .askBand("Write me a groove to start \(song.title) on.")), score: 5))
        let options = rank(candidates, at: stage, app: app)
        return NextQuestion(asker: .director,
                            observation: "\(song.title) is empty: \(Int(song.tempo.rounded())) bpm\(song.key.map { " in \($0.name)" } ?? ", no key yet").",
                            question: "How do you want to start it?", options: options, stage: stage)
    }

    // MARK: A song in progress

    private static func working(_ song: Song, _ app: AppState) -> NextQuestion {
        let active = app.bench.active.map { (kind: $0.kind, bound: app.bound(for: $0.id)) }
        let (path, steps) = WorkPath.steps(for: song, active: active, canPerform: app.canPerform)
        let next = steps.first(where: \.isNext)?.kind
        let stage = "\(path.rawValue).\(next?.rawValue ?? "done")"

        // The Director's own answer, when it has given one, is what is offered; otherwise every
        // step the song supports, in the path's order.
        let fromTheBand = !app.director.isEmpty
        let proposals = fromTheBand ? app.director : Guidance.allProposals(for: song)
        var candidates: [Candidate] = []
        for (index, proposal) in proposals.enumerated() where app.canPerform(proposal.action) && !app.isShowing(proposal.action) {
            candidates.append(Candidate(option: NextOption(kind: kind(of: proposal.action), title: proposal.title,
                                                           rationale: proposal.rationale, move: .surface(proposal.action)),
                                        score: 10 - Double(index) + (fromTheBand ? 4 : 0)))
        }

        // Steps the derivation leaves to the dock, offered where they are what usually comes next.
        if !fromTheBand, !Guidance.grooves(in: song).isEmpty, Guidance.progressions(in: song).isEmpty {
            let chords = Guidance.dockAction(for: .chords, in: song)
            if !app.isShowing(chords) {
                candidates.append(Candidate(option: NextOption(
                    kind: "chords", title: "Write chords",
                    rationale: "Optional: the bass is written to the key without them, and to them once they are there.",
                    move: .surface(chords)), score: 4))
            }
        }
        // The loop, arranged: offered once there is a loop worth arranging and until it has been.
        // Two parts that play is a loop; three is one that is waiting to be a song.
        if !fromTheBand, !app.isDeveloping, !app.isMastering, !Develop.isDeveloped(song), let development = app.development() {
            let parts = Develop.loop(of: song).count
            if parts >= 2 {
                let seconds = StructureModel.seconds(bars: development.bars, tempo: song.tempo, timeSignature: song.timeSignature)
                candidates.append(Candidate(option: NextOption(
                    kind: "develop", title: "Develop it into a song",
                    rationale: "Every section plays the same \(Guidance.count(parts, "part")). This is \(development.shape), "
                        + "\(StructureModel.clock(seconds)), in \(development.form.words), each section playing the loop its own way.",
                    move: .develop), score: parts >= 3 ? 7 : 4.5))
            }
        }
        if !fromTheBand, app.canPutBackDevelopment, !app.isDeveloping, !app.isMastering {
            candidates.append(Candidate(option: NextOption(
                kind: "putBack", title: "Put it back as it was",
                rationale: "The form and the mix from before it was developed. What was written for it stays in the song.",
                move: .putBackDevelopment), score: 1.5))
        }
        // Finishing: a mixed, arranged song is ready to leave as a file, or to join a record.
        if !fromTheBand, !Guidance.mixes(in: song).isEmpty, song.sections.contains(where: { !$0.stitch.isEmpty }) {
            candidates.append(Candidate(option: NextOption(
                kind: "export", title: "Export the master",
                rationale: "Bounced through the mix, limited at \(String(format: "%.1f", Guidance.mix(in: song)?.master.ceilingDBTP ?? -1)) dBTP, with a loudness report beside it.",
                move: .exportMaster), score: 2.5))
            if let album = app.library.albums.last, !album.songs.contains(song.id) {
                candidates.append(Candidate(option: NextOption(
                    kind: "album", title: "Put it on \(album.title)",
                    rationale: "Last on the record, where the Producer and the Peer read it against its neighbours.",
                    move: .addToAlbum(album.id)), score: 2))
            }
        }
        if app.playback.isPlayable, !app.transport.isPlaying {
            candidates.append(Candidate(option: NextOption(
                kind: "play", title: "Hear \(song.title) through",
                rationale: app.playback.summary.isEmpty ? "Everything that plays, from the top." : "\(app.playback.summary), from the top.",
                move: .play), score: 3))
        }

        // What just happened: a part kept in the last few minutes brings what usually follows it up.
        let newest = song.versions.last
        let justMade = newest.flatMap { Date().timeIntervalSince($0.createdAt) < recent ? $0 : nil }
        let follows = justMade.map(followers(of:)) ?? []
        for index in candidates.indices {
            let kind = candidates[index].option.kind
            if let at = follows.firstIndex(of: kind) { candidates[index].score += 3 - Double(at) * 0.5 }
            if let next, stepKinds(next).contains(kind) { candidates[index].score += 2 }
        }

        let options = rank(candidates, at: stage, app: app)
        let lead = options.first?.kind
        let asker: Proposal.Source = fromTheBand ? .director : .persona(owner(of: lead))
        // What just happened, and — when it was someone else's step — what the member asking sees.
        let own = observe(lead, in: song, app: app)
        var observation = own
        if let justMade {
            let made = said(about: justMade, in: song)
            let madeBy = owner(of: followers(of: justMade).isEmpty ? nil : kind(ofPart: justMade))
            observation = madeBy == owner(of: lead) || fromTheBand ? made : "\(made) \(own)"
        }
        return NextQuestion(asker: asker, observation: observation, question: ask(options), options: options, stage: stage)
    }

    // MARK: Ranking

    /// Best practice and the situation are in the scores already; this adds what you have chosen
    /// here before, drops what you waved away, and keeps the best few.
    static func rank(_ candidates: [Candidate], at stage: String, app: AppState) -> [NextOption] {
        var seen: Set<String> = []
        var ranked: [(option: NextOption, score: Double)] = []
        for candidate in candidates where !app.nextDismissed.contains("\(stage)|\(candidate.option.kind)") {
            guard seen.insert(candidate.option.id).inserted else { continue }
            let weight = app.nextPreferences.weight(of: candidate.option.kind, at: stage)
            var option = candidate.option
            option.isYourUsual = weight >= 1.5
            ranked.append((option, candidate.score + 1.5 * weight))
        }
        // Stable: equal scores keep the path's order.
        let ordered = ranked.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }
        return ordered.prefix(maximumOptions).map(\.element.option)
    }

    // MARK: The words

    /// What kind of move a surface action is.
    static func kind(of action: SurfaceAction) -> String {
        switch action.prepare {
        case .separateStems: return "stems"
        case .chopBar: return "chop"
        case .none: break
        }
        switch action.surface {
        case .importRecord: return "record"
        case .chopLane: return "regroove"
        case .grid: return "groove"
        case .pianoRoll: return "bass"
        case .chords: return "chords"
        case .structure: return "arrange"
        case .lyrics: return "words"
        case .booth: return "sing"
        case .takes: return "comp"
        case .mixer: return "mix"
        case .master: return "master"
        case .sound: return "sound"
        default: return action.surface.rawValue.lowercased()
        }
    }

    /// The kinds of move that make progress on a path step.
    static func stepKinds(_ step: PathStep.Kind) -> Set<String> {
        switch step {
        case .record: return ["record"]
        case .stems: return ["stems"]
        case .chop: return ["chop", "regroove"]
        case .groove: return ["groove", "regroove"]
        case .chords: return ["chords"]
        case .bass: return ["bass"]
        case .kit, .dust: return ["sound"]
        case .arrange: return ["arrange", "develop"]
        case .words: return ["words"]
        case .sing: return ["sing", "comp"]
        case .mix: return ["mix", "master"]
        }
    }

    /// What usually follows a part just made, most usual first.
    static func followers(of version: PartVersion) -> [String] {
        switch version.kind {
        case .groove: return ["bass", "chords", "play", "arrange"]
        case .sample: return ["regroove", "groove"]
        case .bassline: return ["develop", "arrange", "chords", "play"]
        case .progression: return ["bass", "develop", "arrange"]
        case .melody: return ["develop", "words", "arrange"]
        case .lyric: return ["sing", "words"]
        case .audio(let audio):
            if audio.comp != nil { return ["mix", "play"] }
            if audio.take != nil { return ["comp", "sing"] }
            return audio.role == .stem ? ["chop"] : ["stems", "chop"]
        case .mix: return ["master", "export", "play"]
        case .sound: return ["play", "arrange"]
        case .analysis: return ["stems", "chop"]
        }
    }

    /// The kind of move that made a part, for saying whose step it was.
    static func kind(ofPart version: PartVersion) -> String {
        switch version.kind {
        case .groove: return "groove"
        case .sample: return "regroove"
        case .bassline: return "bass"
        case .progression: return "chords"
        case .melody, .lyric: return "words"
        case .audio(let audio): return audio.take != nil || audio.comp != nil ? "sing" : "stems"
        case .mix: return "mix"
        case .sound: return "sound"
        case .analysis: return "record"
        }
    }

    /// Whose work a kind of move is.
    static func owner(of kind: String?) -> String {
        switch kind {
        case "stems", "chop", "regroove", "record": return "Sampler"
        case "groove", "sound": return "Beatmaker"
        case "bass": return "Bassist"
        case "chords": return "Harmonist"
        case "words": return "Lyricist"
        case "arrange", "develop", "putBack", "sing", "comp": return "Producer"
        case "mix", "master", "export": return "Engineer"
        case "play", "album": return "Peer"
        default: return "Producer"
        }
    }

    /// A kind of move as the question names it.
    static func phrase(_ option: NextOption) -> String {
        switch option.kind {
        case "stems": return "separate the stems"
        case "chop": return "chop a bar"
        case "regroove": return "re-groove the chop"
        case "groove": return "work the groove"
        case "bass": return "a bass line"
        case "chords": return "chords"
        case "arrange": return "arrange it"
        case "develop": return "develop it into a song"
        case "putBack": return "put it back as it was"
        case "words": return "the words"
        case "sing": return "sing over it"
        case "comp": return "comp the takes"
        case "mix": return "mix it"
        case "master": return "master it"
        case "sound": return "shape the sound"
        case "record": return "back to the record"
        case "play": return "hear it through"
        case "export": return "export the master"
        case "album": return "put it on the album"
        default: return option.title.prefix(1).lowercased() + option.title.dropFirst()
        }
    }

    /// "A bass line next, or chords?"
    static func ask(_ options: [NextOption]) -> String {
        guard let first = options.first else { return "What would you like to do?" }
        let lead = phrase(first)
        let capital = lead.prefix(1).uppercased() + lead.dropFirst()
        guard options.count > 1 else { return "\(capital) next?" }
        return "\(capital) next, or \(phrase(options[1]))?"
    }

    /// What was just made, as the member who owns it would say it.
    static func said(about version: PartVersion, in song: Song) -> String {
        let name = PartLabel.title(of: version)
        let by = version.author == .user ? "" : " — the band's"
        switch version.kind {
        case .groove(let groove):
            let swing = Int((50 + 25 * groove.swing).rounded())
            return "\(name) is in\(by): \(Guidance.count(max(1, groove.bars), "bar")) at \(swing)% swing."
        case .bassline(let line):
            return "\(name) is in\(by): \(Guidance.count(line.notes.count, "note")) under the groove."
        case .progression(let progression):
            return "\(name) is in\(by): \(Guidance.count(progression.chords.count, "chord")) in \(progression.key.name)."
        case .lyric(let lyric):
            let lines = lyric.lines.filter { !$0.syllables.isEmpty }.count
            return "\(Guidance.count(lines, "line")) of words\(lyric.alignedTo == nil ? ", not set to a tune yet" : ", set to the tune")."
        case .audio(let audio):
            if audio.comp != nil { return "The comp is made\(by)." }
            if let take = audio.take { return "Take \(take.pass) is kept." }
            if audio.role == .stem {
                let names = Guidance.stems(in: song).compactMap { Guidance.audio(of: $0)?.stem }
                return "The stems are separated: \(names.joined(separator: ", "))."
            }
            return "The record is in: \(Guidance.duration(of: version)) of it."
        case .mix:
            return "A mix move is kept."
        default:
            return "\(name) is in\(by)."
        }
    }

    /// Where the song stands, as the member asking sees it.
    static func observe(_ kind: String?, in song: Song, app: AppState) -> String {
        let played = song.sections.filter { !$0.stitch.isEmpty }
        switch owner(of: kind) {
        case "Sampler":
            if let take = Guidance.take(in: song), Guidance.stems(in: song).isEmpty {
                return "\(song.title) is one \(Guidance.duration(of: take)) record."
            }
            if let chop = Guidance.samples(in: song).last { return "\(PartLabel.title(of: chop)) is cut and waiting for a feel." }
            return "\(Guidance.count(Guidance.stems(in: song).count, "stem")) separated, nothing chopped yet."
        case "Beatmaker":
            if let groove = Guidance.grooves(in: song).last { return "\(PartLabel.title(of: groove)) is the groove." }
            return "No groove yet."
        case "Bassist":
            if let groove = Guidance.grooves(in: song).last { return "\(PartLabel.title(of: groove)) has nothing under it yet." }
            return "No bass line yet."
        case "Harmonist":
            return "No chords yet: the bass is written to \(song.key?.name ?? "the key")."
        case "Lyricist":
            return "\(Guidance.count(played.count, "section")) \(play(played.count)), and there are no words yet."
        case "Engineer":
            let parts = Set(song.versions.filter(StructureModel.plays).map(\.partID)).count
            if Guidance.mixes(in: song).isEmpty { return "\(Guidance.count(parts, "part")) \(play(parts)), every one at unity." }
            return "It is mixed; the master has not been read yet."
        case "Peer":
            let bars = played.reduce(0) { $0 + max(1, $1.lengthInBars) }
            let seconds = Double(bars * song.timeSignature.beatsPerBar) * 60 / max(1, song.tempo)
            return bars > 0 ? "\(Guidance.count(played.count, "section")), \(StructureModel.clock(seconds)) long." : "It plays."
        default:
            let parts = Set(song.versions.filter(StructureModel.plays).map(\.partID)).count
            if played.isEmpty { return "\(Guidance.count(parts, "part")) \(play(parts)), and no form yet." }
            let takes = Guidance.takes(in: song).count
            return takes > 0 ? "\(Guidance.count(takes, "take")), \(Guidance.comps(in: song).isEmpty ? "not comped yet" : "comped")." : "\(Guidance.count(played.count, "section")) arranged."
        }
    }

    /// "plays" for one, "play" for more.
    static func play(_ count: Int) -> String { count == 1 ? "plays" : "play" }

    /// The first undone step on a song's path, for the launch question's line about it.
    static func nextStep(of song: Song) -> PathStep.Kind? {
        guard !song.versions.isEmpty else { return nil }
        return WorkPath.steps(for: song, active: nil, canPerform: { _ in true }).steps.first(where: \.isNext)?.kind
    }
}

// MARK: - The frame's side

extension AppState {

    /// What the band asks right now: always something, from launch on.
    public var nextQuestion: NextQuestion { NextAdvisor.question(for: self) }

    /// The question and its best answer, for the dock when the band's column is folded away.
    public var dockQuestion: (question: NextQuestion, option: NextOption)? {
        // Not while the empty bench is showing the whole card.
        guard regions.isCollapsed(.rail), !bench.visible.isEmpty else { return nil }
        let question = nextQuestion
        return question.options.first.map { (question, $0) }
    }

    /// Takes an option: remembers the choice, then does it.
    public func take(_ option: NextOption, from question: NextQuestion) {
        nextPreferences.chose(option.kind, at: question.stage, offered: question.options.map(\.kind))
        switch option.move {
        case .surface(let action):
            perform(action)
        case .openSong(let id):
            openSong(id)
        case .newSong:
            open(Song.new(title: MrRobotoApp.untitledName()))
            wantsSongSettings = true
        case .importRecord:
            MrRobotoApp.importRecord(self)
        case .mashup:
            openSurface(.mashup, title: "Mashup")
        case .play:
            Task { await startTransport() }
        case .songSettings:
            wantsSongSettings = true
        case .showLibrary:
            regions.setCollapsed(false, for: .library)
        case .exportMaster:
            MrRobotoApp.export(self, what: "Exporting the master…") { try await Export.master(self, to: $0).wav }
        case .develop:
            Task { await developAndMaster() }
        case .putBackDevelopment:
            putBackDevelopment()
        case .addToAlbum(let id):
            if addSong(song?.id ?? SongID(), to: id) { _ = openAlbum(id) }
        case .askBand(let text):
            askTheBand(text)
        }
    }

    /// "Not this": this option sinks here from now on, and leaves the question until the step moves on.
    public func decline(_ option: NextOption, in question: NextQuestion) {
        nextPreferences.declined(option.kind, at: question.stage)
        nextDismissed.insert("\(question.stage)|\(option.kind)")
    }

    /// "Something else": the band's field, open and ready, with `text` in it when there is some.
    public func askTheBand(_ text: String = "") {
        regions.setCollapsed(false, for: .rail)
        if !text.isEmpty, band?.composing.isEmpty ?? false { band?.composing = text }
        band?.wantsFocus = true
    }
}
