import AVFoundation
import CoreMedia
import Foundation
import MusicTheory
import MusicUnderstanding

/// Apple's Music Understanding framework behind the key, beat, structure, loudness, instrument
/// activity and pace capabilities.
///
/// One `analyze(url:for:)` call runs a `MusicUnderstandingSession` and converts its result to an
/// `AnalysisReport`; reports are cached per file, and concurrent requests for the same file join
/// the in-flight analysis, so asking for the key and then the beats analyses once. By default the
/// first request for a file runs every analysis type (one ≈20 s pass) so later requests are cache
/// hits; pass `prefetchAll: false` to run only what each request asks for.
///
/// Cancellation: cancel the calling task. When the last waiter on an in-flight analysis is
/// cancelled the session itself is cancelled.
public actor MusicUnderstandingProvider: KeyEstimator, BeatTracker, StructureAnalyzer, LoudnessMeter, InstrumentActivityAnalyzer {
    public static let name = "musicUnderstanding"

    public nonisolated var providerName: String { MusicUnderstandingProvider.name }

    private struct InFlight {
        let id: Int
        let capabilities: Set<AnalysisCapability>
        let task: Task<AnalysisReport, Error>
        var waiters: [Int: CheckedContinuation<AnalysisReport, Error>] = [:]
    }

    private let prefetchAll: Bool
    private var cache: [URL: AnalysisReport] = [:]
    private var inFlight: [URL: InFlight] = [:]
    private var nextID = 0

    public init(prefetchAll: Bool = true) {
        self.prefetchAll = prefetchAll
    }

    // MARK: Cache

    /// The cached report for `url`, if any.
    public func cachedReport(for url: URL) -> AnalysisReport? { cache[url.standardizedFileURL] }

    /// Forgets the cached report for `url`.
    public func invalidate(url: URL) { cache[url.standardizedFileURL] = nil }

    /// Forgets every cached report.
    public func clearCache() { cache.removeAll() }

    // MARK: Analysis

    /// The report for `url` covering at least `capabilities`, from cache when possible.
    public func analyze(url rawURL: URL, for capabilities: Set<AnalysisCapability> = .musicUnderstanding) async throws -> AnalysisReport {
        let url = rawURL.standardizedFileURL
        let unsupported = capabilities.subtracting(.musicUnderstanding)
        guard unsupported.isEmpty else { throw AnalysisError.unsupportedCapabilities(unsupported, provider: providerName) }
        let wanted = capabilities.isEmpty ? Set<AnalysisCapability>.musicUnderstanding : capabilities

        while true {
            try Task.checkCancellation()
            if let report = cache[url], report.capabilities.isSuperset(of: wanted) { return report }
            if let current = inFlight[url] {
                do {
                    let report = try await join(url: url, flightID: current.id)
                    if report.capabilities.isSuperset(of: wanted) { return report }
                } catch is Retry {
                    continue
                } catch is CancellationError where !Task.isCancelled {
                    continue  // the flight we joined was cancelled by others; start our own
                }
                continue
            }
            let done = cache[url]?.capabilities ?? []
            let toRun = (prefetchAll ? Set<AnalysisCapability>.musicUnderstanding : wanted).subtracting(done)
            start(url: url, capabilities: toRun.isEmpty ? wanted : toRun)
        }
    }

    /// A JSON dump of the report for `url`.
    public func reportJSON(for url: URL, capabilities: Set<AnalysisCapability> = .musicUnderstanding) async throws -> Data {
        try await analyze(url: url, for: capabilities).jsonData()
    }

    // MARK: Protocol conformances

    public func estimateKey(url: URL) async throws -> KeyEstimate {
        guard let key = try await analyze(url: url, for: [.key]).key else { throw AnalysisError.missingResult(.key, provider: providerName) }
        return key
    }

    public func trackBeats(url: URL) async throws -> BeatTrackingResult {
        guard let beats = try await analyze(url: url, for: [.beats]).beats else { throw AnalysisError.missingResult(.beats, provider: providerName) }
        return beats
    }

    public func analyzeStructure(url: URL) async throws -> StructureAnalysis {
        guard let structure = try await analyze(url: url, for: [.structure]).structure else { throw AnalysisError.missingResult(.structure, provider: providerName) }
        return structure
    }

    public func measureLoudness(url: URL) async throws -> LoudnessAnalysis {
        guard let loudness = try await analyze(url: url, for: [.loudness]).loudness else { throw AnalysisError.missingResult(.loudness, provider: providerName) }
        return loudness
    }

    public func analyzeInstrumentActivity(url: URL) async throws -> InstrumentActivity {
        guard let instruments = try await analyze(url: url, for: [.instrumentActivity]).instruments else {
            throw AnalysisError.missingResult(.instrumentActivity, provider: providerName)
        }
        return instruments
    }

    // MARK: In-flight bookkeeping

    private struct Retry: Error {}

    private func start(url: URL, capabilities: Set<AnalysisCapability>) {
        let id = nextID
        nextID += 1
        let task = Task { [id] () throws -> AnalysisReport in
            do {
                let report = try await MusicUnderstandingProvider.runSession(url: url, capabilities: capabilities)
                self.complete(url: url, flightID: id, result: .success(report))
                return report
            } catch {
                self.complete(url: url, flightID: id, result: .failure(error))
                throw error
            }
        }
        inFlight[url] = InFlight(id: id, capabilities: capabilities, task: task)
    }

    private func join(url: URL, flightID: Int) async throws -> AnalysisReport {
        let waiterID = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var flight = inFlight[url], flight.id == flightID else {
                    continuation.resume(throwing: Retry())
                    return
                }
                flight.waiters[waiterID] = continuation
                inFlight[url] = flight
            }
        } onCancel: {
            Task { await self.cancelWaiter(url: url, flightID: flightID, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(url: URL, flightID: Int, waiterID: Int) {
        guard var flight = inFlight[url], flight.id == flightID, let continuation = flight.waiters.removeValue(forKey: waiterID) else { return }
        inFlight[url] = flight
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty { flight.task.cancel() }
    }

    private func complete(url: URL, flightID: Int, result: Result<AnalysisReport, Error>) {
        guard let flight = inFlight[url], flight.id == flightID else { return }
        inFlight[url] = nil
        if case .success(let report) = result {
            cache[url] = cache[url].map { $0.merging(report) } ?? report
        }
        let final = result.map { cache[url] ?? $0 }
        for continuation in flight.waiters.values { continuation.resume(with: final) }
    }

    // MARK: Session

    private static func runSession(url: URL, capabilities: Set<AnalysisCapability>) async throws -> AnalysisReport {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AnalysisError.fileNotFound(url) }
        let start = ContinuousClock.now
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let session: MusicUnderstandingSession
        do {
            session = try await MusicUnderstandingSession(asset: asset)
        } catch {
            throw mapError(error, url: url, capabilities: capabilities)
        }
        let types = Set(capabilities.compactMap(\.musicUnderstandingType))
        let result: MusicUnderstandingSession.SessionResult
        do {
            result = try await withTaskCancellationHandler {
                capabilities == Set<AnalysisCapability>.musicUnderstanding ? try await session.analyze() : try await session.analyze(for: types)
            } onCancel: {
                Task { await session.cancel() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw mapError(error, url: url, capabilities: capabilities)
        }
        try Task.checkCancellation()
        let duration = try? await asset.load(.duration).seconds
        var report = convert(result, url: url, capabilities: capabilities)
        report.duration = duration.flatMap { $0.isFinite ? $0 : nil }
        report.wallTime = start.duration(to: .now).seconds
        return report
    }

    private static func mapError(_ error: Error, url: URL, capabilities: Set<AnalysisCapability>) -> Error {
        if error is CancellationError { return error }
        if let mu = error as? MusicUnderstandingError {
            switch mu {
            case .invalidAsset: return AnalysisError.unsupportedAsset(url, reason: "MusicUnderstandingError.invalidAsset")
            case .hasProtectedContent: return AnalysisError.protectedContent(url)
            case .emptyAnalysisSet: return AnalysisError.unsupportedCapabilities([], provider: name)
            case .sessionInProgress: return AnalysisError.analysisFailed(url, capabilities: capabilities, reason: "session already in progress")
            case .internalError: return AnalysisError.analysisFailed(url, capabilities: capabilities, reason: "MusicUnderstandingError.internalError")
            @unknown default: return AnalysisError.analysisFailed(url, capabilities: capabilities, reason: "\(mu)")
            }
        }
        return AnalysisError.analysisFailed(url, capabilities: capabilities, reason: "\(error)")
    }

    // MARK: Conversion

    /// Converts a framework result to the plain report types. Internal so tests can exercise it.
    static func convert(_ result: MusicUnderstandingSession.SessionResult, url: URL, capabilities: Set<AnalysisCapability>) -> AnalysisReport {
        var report = AnalysisReport(sourcePath: url.path, capabilities: capabilities)
        for capability in capabilities { report.provenance[capability] = name }

        if let key = result.key {
            var ranges: [KeyRange] = []
            for ranged in key.ranges {
                let (mode, note) = convert(ranged.value.mode)
                if let note, !report.notes.contains(note) { report.notes.append(note) }
                let tonic = convert(ranged.value.tonic)
                ranges.append(KeyRange(start: ranged.range.start.seconds, end: ranged.range.end.seconds, key: Key(tonic: tonic, mode: mode)))
            }
            report.key = KeyEstimate(ranges: ranges)
        } else if capabilities.contains(.key) {
            report.notes.append("framework returned no key result")
        }

        if let rhythm = result.rhythm {
            report.beats = BeatTrackingResult(beats: seconds(rhythm.beats), downbeats: seconds(rhythm.bars), bpm: rhythm.beatsPerMinute.map(Double.init))
        } else if capabilities.contains(.beats) {
            report.notes.append("framework returned no rhythm result")
        }

        if let structure = result.structure {
            report.structure = StructureAnalysis(sections: ranges(structure.sections), segments: ranges(structure.segments), phrases: ranges(structure.phrases))
        } else if capabilities.contains(.structure) {
            report.notes.append("framework returned no structure result")
        }

        if let loudness = result.loudness {
            report.loudness = LoudnessAnalysis(integrated: Double(loudness.integrated.value), truePeak: Double(loudness.peak.value),
                                               momentary: samples(loudness.momentary), shortTerm: samples(loudness.shortTerm))
        } else if capabilities.contains(.loudness) {
            report.notes.append("framework returned no loudness result")
        }

        if let activity = result.instrumentActivity {
            var presence: [Instrument: [TimeRange]] = [:]
            var curves: [Instrument: [TimedSample]] = [:]
            var unknown: Set<String> = []
            for (instrument, list) in activity.ranges {
                if let mapped = convert(instrument) { presence[mapped] = ranges(list) } else { unknown.insert(instrument.rawValue) }
            }
            for (instrument, list) in activity.activity {
                if let mapped = convert(instrument) { curves[mapped] = samples(list) } else { unknown.insert(instrument.rawValue) }
            }
            if !unknown.isEmpty { report.notes.append("dropped unknown instruments: \(unknown.sorted().joined(separator: ", "))") }
            report.instruments = InstrumentActivity(presence: presence, activity: curves)
        } else if capabilities.contains(.instrumentActivity) {
            report.notes.append("framework returned no instrument activity result")
        }

        if let pace = result.pace {
            report.pace = pace.ranges.map { RangedSample(range: TimeRange(start: $0.range.start.seconds, end: $0.range.end.seconds), value: $0.value) }
        } else if capabilities.contains(.pace) {
            report.notes.append("framework returned no pace result")
        }
        return report
    }

    static func convert(_ tonic: KeyResult.Tonic) -> Tonic {
        switch tonic {
        case .a: return .a
        case .aFlat: return .aFlat
        case .aSharp: return .aSharp
        case .b: return .b
        case .bFlat: return .bFlat
        case .c: return .c
        case .cSharp: return .cSharp
        case .d: return .d
        case .dFlat: return .dFlat
        case .dSharp: return .dSharp
        case .e: return .e
        case .eFlat: return .eFlat
        case .f: return .f
        case .fSharp: return .fSharp
        case .g: return .g
        case .gFlat: return .gFlat
        case .gSharp: return .gSharp
        }
    }

    /// Major → Ionian, minor → Aeolian; any mode the framework adds later falls back to major with a note.
    static func convert(_ mode: KeyResult.Mode) -> (Mode, note: String?) {
        switch mode {
        case .major: return (.ionian, nil)
        case .minor: return (.aeolian, nil)
        @unknown default: return (.ionian, "unknown Music Understanding mode '\(mode.rawValue)' mapped to major")
        }
    }

    static func convert(_ instrument: InstrumentActivityResult.Instrument) -> Instrument? {
        switch instrument {
        case .vocal: return .vocal
        case .drum: return .drums
        case .bass: return .bass
        case .other: return .other
        default:
            switch instrument.rawValue.lowercased() {
            case "vocal", "vocals", "voice": return .vocal
            case "drum", "drums", "percussion": return .drums
            case "bass": return .bass
            case "other": return .other
            default: return nil
            }
        }
    }

    private static func seconds(_ times: [CMTime]) -> [Double] {
        times.map(\.seconds).filter(\.isFinite)
    }

    private static func ranges(_ list: [CMTimeRange]) -> [TimeRange] {
        list.compactMap { range in
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite else { return nil }
            return TimeRange(start: start, end: end)
        }
    }

    private static func samples(_ list: [MusicUnderstandingSession.TimedValue<Float>]) -> [TimedSample] {
        list.compactMap { timed in
            let time = timed.time.seconds
            guard time.isFinite else { return nil }
            return TimedSample(time: time, value: Double(timed.value))
        }
    }
}

extension AnalysisCapability {
    /// The framework analysis type for this capability, nil for capabilities Music Understanding lacks.
    var musicUnderstandingType: AnalysisType? {
        switch self {
        case .key: return .key
        case .beats: return .rhythm
        case .structure: return .structure
        case .loudness: return .loudness
        case .instrumentActivity: return .instrumentActivity
        case .pace: return .pace
        case .stemSeparation, .onsets, .timeStretch: return nil
        }
    }
}

extension Duration {
    /// The duration as floating-point seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
