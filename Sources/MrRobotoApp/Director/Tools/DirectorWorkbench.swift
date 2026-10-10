import Analysis
import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph

// Where the audio is, so that the tools never carry any.
//
// The rule the tool layer lives by is that every call takes and returns small structured data. A
// chop is a list of frame ranges; a classification is a kind and a number. But somebody has to
// hold the samples those ranges point into, and that is this: an actor keyed by short handles the
// model passes back and forth ("audio-1", "chop-2") and never has to understand.

/// The engines the tools run on, gathered so a test can swap the two that need models.
///
/// `chopper`, `classifier`, `feels` and everything in `Performance` and `SongGraph` are pure
/// computation and are used as-is in tests. `providers` and `separator` reach for Apple's Music
/// Understanding and for Demucs, so they are injectable.
public struct DirectorEngines: Sendable {
    public var providers: AnalysisProviders
    public var chopper: Chopper
    public var classifier: SliceClassifier
    public var feels: FeelLibrary
    /// Nil when this build has no separation model. The tool says so rather than hanging.
    public var separator: (any StemSeparator)?

    public init(providers: AnalysisProviders = AnalysisProviders.makeDefault(),
                chopper: Chopper = Chopper(),
                classifier: SliceClassifier = SliceClassifier(),
                feels: FeelLibrary = .standard,
                separator: (any StemSeparator)? = nil) {
        self.providers = providers
        self.chopper = chopper
        self.classifier = classifier
        self.feels = feels
        self.separator = separator
    }
}

/// Audio and the half-finished things made from it, held between tool calls.
public actor DirectorWorkbench {
    /// One loaded file: planar for rendering, mono for analysis, and where it came from.
    public struct LoadedAudio: Sendable {
        public var url: URL
        public var planar: [[Float]]
        public var mono: [Float]
        public var sampleRate: Double
        /// What the library stored it under, when it was stored. An excerpt inherits its source's,
        /// because a chop's markers are in the record's time and point into the record's media.
        public var media: MediaRef?

        public var frameCount: Int { planar.first?.count ?? 0 }
        public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
        public var channelCount: Int { planar.count }
    }

    /// A chop, what it was cut from, and what the classifier made of it.
    public struct StoredChop: Sendable {
        public var chop: Chop
        public var audio: String
        public var classifications: [SliceClassification]
        /// Where in the record this chop starts, in seconds. Kept for a version's note.
        public var sourceOffset: Double
        public var barIndex: Int?
    }

    public let engines: DirectorEngines

    /// What `audio` loads when a handle is not one of its own: a record in the crate by its id —
    /// read_library's read_as — or an audio idea by its, so the record tools reach what the
    /// library holds without a file path. Nil says the id is nobody's.
    public typealias LibraryLoader = @Sendable (String) async throws -> LoadedAudio?
    private let libraryLoader: LibraryLoader?

    private var audio: [String: LoadedAudio] = [:]
    private var analyses: [String: AnalysisReport] = [:]
    private var chops: [String: StoredChop] = [:]
    private var grooves: [String: StoredGroove] = [:]
    private var counters: [String: Int] = [:]

    public init(engines: DirectorEngines = DirectorEngines(), libraryLoader: LibraryLoader? = nil) {
        self.engines = engines
        self.libraryLoader = libraryLoader
    }

    /// A loader over whatever resolves an id to a file in the library: the app's own lookup, run
    /// where the library lives. The file is read here, off that actor.
    public static func libraryLoader(resolving resolve: @escaping @Sendable (String) async throws -> (url: URL, media: MediaRef)?) -> LibraryLoader {
        { handle in
            guard UUID(uuidString: handle) != nil, let found = try await resolve(handle) else { return nil }
            let (planar, sampleRate) = try ChopAudio.readPlanar(found.url)
            guard !planar.isEmpty, !planar[0].isEmpty else { return nil }
            return LoadedAudio(url: found.url, planar: planar, mono: ChopAudio.mono(planar), sampleRate: sampleRate, media: found.media)
        }
    }

    // MARK: Handles

    /// Short, readable, and countable from one: "chop-1", "chop-2". A UUID here would cost the
    /// model tokens and cost a person the ability to follow what happened.
    private func nextHandle(_ prefix: String) -> String {
        let next = (counters[prefix] ?? 0) + 1
        counters[prefix] = next
        return "\(prefix)-\(next)"
    }

    // MARK: Audio

    /// Reads a file in and returns its handle. The same URL loaded twice is loaded twice: the
    /// model may be working on two copies of one record on purpose.
    public func loadAudio(at url: URL) throws -> String {
        let (planar, sampleRate) = try ChopAudio.readPlanar(url)
        guard !planar.isEmpty, !(planar[0].isEmpty) else {
            throw DirectorToolFailure(tool: "load", reason: "\(url.lastPathComponent) holds no audio.")
        }
        let handle = nextHandle("audio")
        audio[handle] = LoadedAudio(url: url, planar: planar,
                                    mono: ChopAudio.mono(planar), sampleRate: sampleRate)
        return handle
    }

    /// Adopts audio that is already in memory, for tests and for a separated stem.
    public func adopt(planar: [[Float]], sampleRate: Double, url: URL, media: MediaRef? = nil) -> String {
        let handle = nextHandle("audio")
        audio[handle] = LoadedAudio(url: url, planar: planar,
                                    mono: ChopAudio.mono(planar), sampleRate: sampleRate, media: media)
        return handle
    }

    /// Notes where a loaded file ended up in the library. Called once, by `import_record`.
    public func setMedia(_ ref: MediaRef, for handle: String) {
        audio[handle]?.media = ref
    }

    public func audio(_ handle: String) async throws -> LoadedAudio {
        if let found = audio[handle] { return found }
        // Not a handle of this bench: the library's, when the id names something it holds. Kept
        // under the id itself, so chops cut from it say where they came from.
        if let libraryLoader, let loaded = try await libraryLoader(handle) {
            audio[handle] = loaded
            return loaded
        }
        throw Self.unknown("audio", handle, Array(audio.keys))
    }

    public var audioHandles: [String] { audio.keys.sorted() }

    // MARK: Analysis

    public func store(_ report: AnalysisReport, for handle: String) {
        analyses[handle] = report
    }

    public func analysis(_ handle: String) throws -> AnalysisReport {
        guard let found = analyses[handle] else {
            throw DirectorToolFailure(tool: "analysis", reason: "\(handle) has not been analysed yet.",
                                      suggestion: "Call analyse_record on it first.")
        }
        return found
    }

    public func hasAnalysis(_ handle: String) -> Bool { analyses[handle] != nil }

    // MARK: Chops

    public func store(_ chop: Chop, audio handle: String, sourceOffset: Double, bar: Int?) -> String {
        let id = nextHandle("chop")
        chops[id] = StoredChop(chop: chop, audio: handle, classifications: [],
                               sourceOffset: sourceOffset, barIndex: bar)
        return id
    }

    public func chop(_ handle: String) throws -> StoredChop {
        guard let found = chops[handle] else { throw Self.unknown("chop", handle, Array(chops.keys)) }
        return found
    }

    public func setClassifications(_ classifications: [SliceClassification], for handle: String) throws {
        guard var stored = chops[handle] else { throw Self.unknown("chop", handle, Array(chops.keys)) }
        stored.classifications = classifications
        chops[handle] = stored
    }

    public var chopHandles: [String] { chops.keys.sorted() }

    // MARK: Grooves

    /// A performance and the plan that produced it.
    ///
    /// The plan is kept, not just the result, because adjusting swing or velocity is not an edit to
    /// a list of hits — it is the same re-groove run again with one number changed. Keeping the
    /// plan is what makes `set_swing` a one-line tool instead of a second engine.
    public struct StoredGroove: Sendable {
        public var plan: DirectorGroovePlan
        public var performance: RegroovePerformance
    }

    @discardableResult
    public func store(_ performance: RegroovePerformance, plan: DirectorGroovePlan) -> String {
        let id = nextHandle("groove")
        grooves[id] = StoredGroove(plan: plan, performance: performance)
        return id
    }

    public func groove(_ handle: String) throws -> StoredGroove {
        guard let found = grooves[handle] else { throw Self.unknown("groove", handle, Array(grooves.keys)) }
        return found
    }

    /// Replaces a groove in place, for the tools that adjust one (swing, velocity).
    public func replace(_ performance: RegroovePerformance, plan: DirectorGroovePlan, at handle: String) throws {
        guard grooves[handle] != nil else { throw Self.unknown("groove", handle, Array(grooves.keys)) }
        grooves[handle] = StoredGroove(plan: plan, performance: performance)
    }

    public var grooveHandles: [String] { grooves.keys.sorted() }

    // MARK: Errors

    private static func unknown(_ kind: String, _ handle: String, _ known: [String]) -> DirectorToolFailure {
        let list = known.sorted()
        return DirectorToolFailure(
            tool: kind,
            reason: "There is no \(kind) called \"\(handle)\".",
            suggestion: list.isEmpty ? "Nothing of that kind has been made yet."
                                     : "Known: \(list.joined(separator: ", ")).")
    }
}
