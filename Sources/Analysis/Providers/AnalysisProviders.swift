import Foundation

/// The provider registry: which implementation serves each capability, chosen by name.
///
/// Register providers under a name for the capabilities they cover, then `select` one per
/// capability. Falling back from one implementation to another (Music Understanding beats to a
/// Beat This! port, say) is then a change of selection, not of calling code.
///
/// Factories are closures so a provider can be shared across capabilities: the default registry
/// hands the same `MusicUnderstandingProvider` instance to every capability it covers, so its
/// per-file cache is shared too.
public struct AnalysisProviders: Sendable {
    public typealias Factory = @Sendable () -> any AnalysisProvider

    private var factories: [AnalysisCapability: [String: Factory]] = [:]
    /// The chosen provider name per capability.
    public private(set) var selection: [AnalysisCapability: String] = [:]

    /// An empty registry.
    public init() {}

    /// The default configuration: Music Understanding for everything it can do, Signalsmith Stretch
    /// for time stretching, nothing selected for stem separation or onsets until another module
    /// registers a provider.
    public static func makeDefault() -> AnalysisProviders {
        var providers = AnalysisProviders()
        let musicUnderstanding = MusicUnderstandingProvider()
        providers.register(MusicUnderstandingProvider.name, for: .musicUnderstanding) { musicUnderstanding }
        for capability in Set<AnalysisCapability>.musicUnderstanding {
            try? providers.select(MusicUnderstandingProvider.name, for: capability)
        }
        providers.register(SignalsmithTimeStretcher.name, for: [.timeStretch]) { SignalsmithTimeStretcher() }
        return providers
    }

    // MARK: Registration

    /// Registers `factory` under `name` for `capabilities`. If nothing is selected yet for a
    /// capability, this provider becomes its selection.
    public mutating func register(_ name: String, for capabilities: Set<AnalysisCapability>, _ factory: @escaping Factory) {
        for capability in capabilities {
            factories[capability, default: [:]][name] = factory
            if selection[capability] == nil { selection[capability] = name }
        }
    }

    /// Registers one provider instance under `name` for `capabilities`.
    public mutating func register(_ provider: any AnalysisProvider, for capabilities: Set<AnalysisCapability>, name: String? = nil) {
        register(name ?? provider.providerName, for: capabilities) { provider }
    }

    /// Chooses the provider named `name` for `capability`.
    public mutating func select(_ name: String, for capability: AnalysisCapability) throws {
        guard factories[capability]?[name] != nil else { throw AnalysisError.unknownProvider(name: name, capability: capability) }
        selection[capability] = name
    }

    /// Chooses `name` for every capability it is registered for.
    public mutating func select(_ name: String) {
        for (capability, byName) in factories where byName[name] != nil { selection[capability] = name }
    }

    /// Provider names registered for `capability`, sorted.
    public func names(for capability: AnalysisCapability) -> [String] {
        (factories[capability] ?? [:]).keys.sorted()
    }

    /// The selected provider name per capability, for logs and configuration dumps.
    public var summary: String {
        AnalysisCapability.allCases.map { "\($0): \(selection[$0] ?? "-")" }.joined(separator: "\n")
    }

    // MARK: Resolution

    /// The selected provider for `capability`.
    public func provider(for capability: AnalysisCapability) throws -> any AnalysisProvider {
        guard let name = selection[capability] else { throw AnalysisError.providerUnavailable(capability, name: nil) }
        guard let factory = factories[capability]?[name] else { throw AnalysisError.providerUnavailable(capability, name: name) }
        return factory()
    }

    private func resolve<T>(_ capability: AnalysisCapability, as type: T.Type) throws -> T {
        let provider = try provider(for: capability)
        guard let typed = provider as? T else { throw AnalysisError.providerMismatch(capability, name: provider.providerName) }
        return typed
    }

    public func keyEstimator() throws -> any KeyEstimator { try resolve(.key, as: (any KeyEstimator).self) }
    public func beatTracker() throws -> any BeatTracker { try resolve(.beats, as: (any BeatTracker).self) }
    public func structureAnalyzer() throws -> any StructureAnalyzer { try resolve(.structure, as: (any StructureAnalyzer).self) }
    public func loudnessMeter() throws -> any LoudnessMeter { try resolve(.loudness, as: (any LoudnessMeter).self) }
    public func instrumentActivityAnalyzer() throws -> any InstrumentActivityAnalyzer { try resolve(.instrumentActivity, as: (any InstrumentActivityAnalyzer).self) }
    public func stemSeparator() throws -> any StemSeparator { try resolve(.stemSeparation, as: (any StemSeparator).self) }
    public func onsetDetector() throws -> any OnsetDetector { try resolve(.onsets, as: (any OnsetDetector).self) }
    public func timeStretcher() throws -> any TimeStretcher { try resolve(.timeStretch, as: (any TimeStretcher).self) }

    // MARK: Aggregate

    /// Runs every selected whole-track analyser on `url` and merges the results into one report.
    ///
    /// Three outcomes per capability, and they are three different things:
    ///
    ///  * **No provider selected.** Skipped and noted.
    ///  * **The analyser ran and had nothing to say.** Noted, and the capability is *not* claimed:
    ///    the field stays nil and the report is returned. A drums stem has no tonal content, so
    ///    Music Understanding returns no key for it and `estimateKey` — correctly, for a caller
    ///    who asked for a key and only a key — throws `missingResult`. Letting that fail the whole
    ///    aggregate meant `analyse_record` failed on every stem in every live run, throwing away a
    ///    beat grid, a structure, a loudness figure and an instrument curve that had all succeeded,
    ///    because the record happened not to have a key in it. "This audio has no key" is a finding,
    ///    not a failure.
    ///  * **The analyser failed.** Thrown, and the call fails. A missing file, a protected asset or
    ///    a session that fell over is not a finding about the music, and swallowing it would turn a
    ///    broken analysis into an empty one.
    public func analyze(url: URL, capabilities: Set<AnalysisCapability> = [.key, .beats, .structure, .loudness, .instrumentActivity]) async throws -> AnalysisReport {
        var report = AnalysisReport(sourcePath: url.path)
        let start = ContinuousClock.now
        for capability in AnalysisCapability.allCases where capabilities.contains(capability) {
            let provider: (any AnalysisProvider)?
            var found = false
            switch capability {
            case .key:
                provider = try? keyEstimator()
                if let p = provider as? any KeyEstimator {
                    report.key = try await Self.present(capability) { try await p.estimateKey(url: url) }
                    found = report.key != nil
                }
            case .beats:
                provider = try? beatTracker()
                if let p = provider as? any BeatTracker {
                    report.beats = try await Self.present(capability) { try await p.trackBeats(url: url) }
                    found = report.beats != nil
                }
            case .structure:
                provider = try? structureAnalyzer()
                if let p = provider as? any StructureAnalyzer {
                    report.structure = try await Self.present(capability) { try await p.analyzeStructure(url: url) }
                    found = report.structure != nil
                }
            case .loudness:
                provider = try? loudnessMeter()
                if let p = provider as? any LoudnessMeter {
                    report.loudness = try await Self.present(capability) { try await p.measureLoudness(url: url) }
                    found = report.loudness != nil
                }
            case .instrumentActivity:
                provider = try? instrumentActivityAnalyzer()
                if let p = provider as? any InstrumentActivityAnalyzer {
                    report.instruments = try await Self.present(capability) { try await p.analyzeInstrumentActivity(url: url) }
                    found = report.instruments != nil
                }
            case .pace, .stemSeparation, .onsets, .timeStretch:
                continue
            }
            guard let provider else {
                report.notes.append("no \(capability.providerNoun) selected")
                continue
            }
            guard found else {
                report.notes.append("\(provider.providerName) found no \(capability.noun) in this audio")
                continue
            }
            report.capabilities.insert(capability)
            report.provenance[capability] = provider.providerName
        }
        report.wallTime = start.duration(to: .now).seconds
        return report
    }

    /// Runs one analyser, turning "this audio has none of that" into nil rather than into a throw.
    ///
    /// Only `missingResult` for the capability being run is caught, and only that: every other
    /// error — including a `missingResult` for something else, which would mean an analyser is
    /// answering a question it was not asked — is a real failure and goes on up.
    private static func present<T>(_ capability: AnalysisCapability,
                                   _ body: () async throws -> T) async throws -> T? {
        do {
            return try await body()
        } catch let error as AnalysisError {
            guard case .missingResult(let absent, _) = error, absent == capability else { throw error }
            return nil
        }
    }
}

extension AnalysisCapability {
    /// What the capability finds, as a note about the music reads it ("no key in this audio").
    var noun: String {
        switch self {
        case .key: return "key"
        case .beats: return "beat grid"
        case .structure: return "structure"
        case .loudness: return "loudness"
        case .instrumentActivity: return "instrument activity"
        case .pace: return "pace"
        case .stemSeparation: return "stems"
        case .onsets: return "onsets"
        case .timeStretch: return "time stretch"
        }
    }

    /// The kind of provider the registry looks for, for notes and errors ("beat tracker").
    var providerNoun: String {
        switch self {
        case .key: return "key estimator"
        case .beats: return "beat tracker"
        case .structure: return "structure analyzer"
        case .loudness: return "loudness meter"
        case .instrumentActivity: return "instrument activity analyzer"
        case .pace: return "pace analyzer"
        case .stemSeparation: return "stem separator"
        case .onsets: return "onset detector"
        case .timeStretch: return "time stretcher"
        }
    }
}
