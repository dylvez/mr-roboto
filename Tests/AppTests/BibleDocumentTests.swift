import Foundation
import Testing

@testable import MrRobotoApp

// M4 Gate A: a bible is a document. The three shipped bibles round-trip through JSON with every
// claim intact and the same bytes twice; the method is one function that names what a bible gets
// wrong; the goldens execute.

@Suite("Bible: as a document")
struct BibleDocumentTests {

    private static let bibles: [PersonaBible] = Cast.standard.bibles

    @Test("every shipped bible round-trips through JSON, value for value and byte for byte", arguments: bibles)
    func roundTrip(_ bible: PersonaBible) throws {
        let data = try BibleDocument.encode(bible)
        let back = try BibleDocument.decode(data)
        #expect(back == bible)
        #expect(back.claims.count == bible.claims.count)
        #expect(back.citedClaimCount == bible.citedClaimCount)
        #expect(try BibleDocument.encode(back) == data, "the second export is the same bytes")
        #expect(data.count > 10_000, "\(bible.name) is \(data.count) bytes — too small to be a bible")
        // The mark is visible in the file, as the method wants.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"cited\"") && text.contains("\"inferred\""))
    }

    @Test("every proposal a golden can carry survives the document", arguments: [
        PersonaProposal.setSwing(percent: 56, idiom: "boom-bap", tempo: 90),
        .displaceVoice(voice: "snare", milliseconds: -21, tempo: 90),
        .quantiseHard(idiom: "lo-fi"),
        .setHumanizeTiming(milliseconds: 12, tempo: 90),
        .removeGhosts(currentRatio: 0.4, idiom: "neo-soul"),
        .chopDensity(slicesPerBar: 12, sourceTransients: 20),
        .moveCutLate(milliseconds: 9),
        .applyDegrade(preset: "sp1200", sourceBandwidthHz: 15_000, sourceNoiseFloorDB: -60),
        .stackDegrade(first: "vinyl", second: "cassette"),
        .leaveAlone(sourceBandwidthHz: 18_000),
        .writeBassline(lineage: "palladino", lagMS: 40, tempo: 92, hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger"),
        .pushBassAhead(milliseconds: 30, alternating: true),
        .sustainUnder808(sound: "finger", kickDecaySeconds: 0.7),
        .transposeSample(label: "Horns", semitones: -5),
        .mergeSources(drumSources: 2, uncleared: ["Vessel – Arrival"]),
        .outOfScope(what: "the artwork"),
    ])
    func proposals(_ proposal: PersonaProposal) throws {
        let data = try JSONEncoder().encode(proposal)
        #expect(try JSONDecoder().decode(PersonaProposal.self, from: data) == proposal)
        for shape in [VerdictShape.agree, .caveat, .refuse(rule: "x.y"), .defer_(to: .sampler)] {
            #expect(try JSONDecoder().decode(VerdictShape.self, from: try JSONEncoder().encode(shape)) == shape)
        }
    }

    @Test("the method as a function holds for every shipped bible", arguments: bibles)
    func lintHolds(_ bible: PersonaBible) {
        let violations = BibleMethod.lint(bible)
        #expect(violations.isEmpty, "\(bible.name): \(violations)")
    }

    @Test("a bible with one uncited rule too many, and one that does not execute, is refused with the violations named")
    func lintRefuses() throws {
        var bible = Sampler.bible
        // Every claim inferred: M1 trips on the ratio.
        bible.rules = bible.rules.map { rule in
            var rule = rule
            rule.evidence = .inferred("a hunch")
            return rule
        }
        bible.lineages = bible.lineages.map { var l = $0; l.evidence = .inferred("a hunch"); return l }
        bible.vocabulary = bible.vocabulary.map { var v = $0; v.evidence = .inferred("a hunch"); return v }
        bible.ranges = bible.ranges.map { var r = $0; r.evidence = .inferred("a hunch"); return r }
        bible.references = bible.references.map { var r = $0; r.evidence = .inferred("a hunch"); return r }
        bible.openQuestions = bible.openQuestions.map { var q = $0; q.evidence = .inferred("a hunch"); return q }
        // A rule off its namespace, and goldens that do not execute.
        bible.rules[0].id = "someone-elses.rule"
        bible.goldens = bible.goldens.map { var g = $0; g.proposal = nil; g.expects = nil; return g }
        let violations = BibleMethod.lint(bible)
        #expect(violations.contains { $0.rule == "M1" && $0.message.contains("guesses") })
        #expect(violations.contains { $0.rule == "M2" && $0.message.contains("namespaced") })
        #expect(violations.contains { $0.rule == "M5" && $0.message.contains("execute") })
        // And a document that does not parse is an error, not a bible.
        #expect(throws: (any Error).self) { try BibleDocument.decode(Data("{\"id\": 3}".utf8)) }
    }

    @Test("the bundled documents are the shipped bibles, by value")
    func bundled() {
        let bundled = BibleDocument.bundled()
        #expect(Set(bundled.map(\.id)) == Set(Cast.standard.ids), "\(bundled.map(\.id))")
        for bible in Self.bibles {
            #expect(bundled.first { $0.id == bible.id } == bible, "\(bible.name)'s document has drifted from its Swift value: re-export")
        }
    }

    @Test("every executable golden of every shipped persona passes through the runner")
    func goldensRun() {
        let results = GoldenRunner.run(Cast.standard)
        #expect(results.count >= 20, "\(results.count) executable goldens")
        let failures = GoldenRunner.failures(results)
        let report = failures.map(\.description).joined(separator: "\n")
        #expect(failures.isEmpty, "\(report)")
        for bible in Self.bibles {
            let mine = results.filter { $0.persona == bible.id }
            #expect(mine.count * 2 >= bible.goldens.count, "\(bible.name): \(mine.count) of \(bible.goldens.count) execute")
        }
    }
}

/// Writes the shipped bibles as documents into the app's resources. Run by hand:
///
///     MRROBOTO_EXPORT_BIBLES=1 swift test --filter BibleExport
@Suite("Bible export", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_EXPORT_BIBLES"] == "1",
                              "set MRROBOTO_EXPORT_BIBLES=1 to write Resources/Bibles"))
struct BibleExportTests {
    @Test("export the shipped bibles")
    func export() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/MrRobotoApp/Resources/\(BibleDocument.directoryName)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for bible in Cast.standard.bibles {
            try BibleDocument.encode(bible).write(to: directory.appendingPathComponent("\(bible.id.rawValue).\(BibleDocument.fileExtension)"))
        }
    }
}

/// Lints one bible file. Run by hand:
///
///     MRROBOTO_BIBLE=/path/to/bible.json swift test --filter BibleLint
@Suite("Bible lint", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_BIBLE"] != nil,
                            "set MRROBOTO_BIBLE to a bible file to lint it"))
struct BibleLintTests {
    @Test("the file holds to the method")
    func lint() throws {
        let path = ProcessInfo.processInfo.environment["MRROBOTO_BIBLE"]!
        let (bible, violations) = try BibleDocument.load(URL(fileURLWithPath: path))
        print("[lint] \(bible.name): \(bible.rules.count) rules, \(bible.goldens.count) goldens, \(bible.citedClaimCount) cited / \(bible.inferredClaimCount) inferred")
        for violation in violations { print("[lint] \(violation)") }
        let report = violations.map(\.description).joined(separator: "\n")
        #expect(violations.isEmpty, "\(report)")
        let results = GoldenRunner.run(DocumentPersona(bible: bible))
        for result in results { print("[lint] \(result)") }
        let failed = GoldenRunner.failures(results).map(\.description).joined(separator: "\n")
        #expect(GoldenRunner.failures(results).isEmpty, "\(failed)")
    }
}
