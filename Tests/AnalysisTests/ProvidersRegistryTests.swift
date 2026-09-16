import Foundation
import MusicTheory
import Testing
@testable import Analysis

/// A stub key estimator for registry tests.
struct StubKeyEstimator: KeyEstimator {
    var providerName: String
    var key: Key

    func estimateKey(url: URL) async throws -> KeyEstimate { KeyEstimate(key: key, duration: 10) }
}

@Suite("AnalysisProviders registry")
struct ProvidersRegistryTests {
    @Test func defaultSelectsMusicUnderstanding() throws {
        let providers = AnalysisProviders.makeDefault()
        for capability in Set<AnalysisCapability>.musicUnderstanding {
            #expect(providers.selection[capability] == MusicUnderstandingProvider.name)
        }
        #expect(providers.selection[.stemSeparation] == nil)
        #expect(try providers.keyEstimator().providerName == "musicUnderstanding")
        #expect(try providers.beatTracker().providerName == "musicUnderstanding")
        #expect(try providers.structureAnalyzer().providerName == "musicUnderstanding")
        #expect(try providers.loudnessMeter().providerName == "musicUnderstanding")
        #expect(try providers.instrumentActivityAnalyzer().providerName == "musicUnderstanding")
        #expect(throws: AnalysisError.providerUnavailable(.stemSeparation, name: nil)) { try providers.stemSeparator() }
        #expect(throws: AnalysisError.providerUnavailable(.onsets, name: nil)) { try providers.onsetDetector() }
        #expect(providers.summary.contains("key: musicUnderstanding"))
    }

    @Test func sharesOneInstanceAcrossCapabilities() throws {
        let providers = AnalysisProviders.makeDefault()
        let a = try #require(providers.keyEstimator() as? MusicUnderstandingProvider)
        let b = try #require(providers.beatTracker() as? MusicUnderstandingProvider)
        let sameInstance = ObjectIdentifier(a) == ObjectIdentifier(b)
        #expect(sameInstance)
    }

    @Test func fallbackIsASelectionChange() async throws {
        var providers = AnalysisProviders.makeDefault()
        let stub = StubKeyEstimator(providerName: "stub", key: Key(tonic: Tonic.eFlat))
        providers.register(stub, for: [.key])
        // Registering does not displace an existing selection.
        #expect(providers.selection[.key] == "musicUnderstanding")
        #expect(providers.names(for: .key) == ["musicUnderstanding", "stub"])

        try providers.select("stub", for: .key)
        let estimate = try await providers.keyEstimator().estimateKey(url: URL(fileURLWithPath: "/nowhere"))
        #expect(estimate.dominantKey == Key(tonic: Tonic.eFlat))

        #expect(throws: AnalysisError.unknownProvider(name: "nope", capability: .key)) { try providers.select("nope", for: .key) }
        // A provider selected for a capability it does not implement is a mismatch, not a crash.
        providers.register("stub", for: [.beats]) { stub }
        try providers.select("stub", for: .beats)
        #expect(throws: AnalysisError.providerMismatch(.beats, name: "stub")) { try providers.beatTracker() }
    }

    @Test func aggregateAnalyzeSkipsMissingProviders() async throws {
        var providers = AnalysisProviders()
        providers.register(StubKeyEstimator(providerName: "stub", key: Key(tonic: Tonic.g)), for: [.key])
        let report = try await providers.analyze(url: URL(fileURLWithPath: "/nowhere/x.wav"), capabilities: [.key, .beats])
        #expect(report.key?.dominantKey == Key(tonic: Tonic.g))
        #expect(report.beats == nil)
        #expect(report.capabilities == [.key])
        #expect(report.provenance == [.key: "stub"])
        #expect(report.notes.contains("no beat tracker selected"))
    }
}
