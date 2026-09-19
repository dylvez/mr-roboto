import Foundation
import Performance
import Testing

@testable import MrRobotoApp

// M4 Gate C, P11: the evals. `make check` runs the goldens and the disagreements; `make evals`
// (MRROBOTO_EVALS=1) runs the blind sheets too and writes Bench/personas/evals.md.

private let benchPersonas = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Bench/personas", isDirectory: true)

@Suite("Persona evals")
struct PersonaEvalTests {

    @Test("every declared disagreement is exercised by a proposal and shows the way the bible says")
    func disagreements() {
        let results = DisagreementRunner.run(.standard)
        let failures = DisagreementRunner.failures(results)
        #expect(results.count == Cast.standard.bibles.map(\.disagreements.count).reduce(0, +))
        #expect(failures.isEmpty, "\(failures.map(\.description).joined(separator: "\n"))")
        // Every pair in the cast is declared from at least one side.
        let ids = Cast.standard.ids
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] {
                #expect(results.contains { ($0.persona == a && $0.with == b) || ($0.persona == b && $0.with == a) },
                        "\(a.rawValue) and \(b.rawValue) never disagree")
            }
        }
    }

    @Test("the blind sheets read and score, and the pilots pass")
    func blind() throws {
        let sheets = try BlindSheet.loadAll(in: benchPersonas.appendingPathComponent("blind"))
        #expect(sheets.map(\.persona).contains(.beatmaker) && sheets.map(\.persona).contains(.bassist))
        let results = sheets.flatMap { BlindRunner.run($0) }
        #expect(!results.isEmpty)
        let failures = BlindRunner.failures(results)
        #expect(failures.isEmpty, "\(failures.map(\.description).joined(separator: "\n"))")
    }

    @Test("a sheet's material round-trips as JSON")
    func materialCodable() throws {
        let sheet = BlindSheet(persona: .bassist, items: [
            .init(id: "one", label: "Palladino at 40", material: .bassline(hands: "palladino", lagMS: 40, tempo: 92, feel: "Neo-Soul Pocket", density: 0.5, seed: 7), expects: ["bassist.lag-budget": true]),
            .init(id: "two", label: "Boom-Bap", material: .feel(name: "Boom-Bap", tempo: nil), expects: [:]),
        ])
        let data = try JSONEncoder().encode(sheet)
        let back = try JSONDecoder().decode(BlindSheet.self, from: data)
        #expect(back.items.map(\.material) == sheet.items.map(\.material))
    }

    @Test("make evals writes the report", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_EVALS"] != nil))
    func report() throws {
        let goldens = GoldenRunner.run(.standard)
        let disagreements = DisagreementRunner.run(.standard)
        let blind = try BlindSheet.loadAll(in: benchPersonas.appendingPathComponent("blind")).flatMap { BlindRunner.run($0) }
        let markdown = EvalReport.markdown(cast: .standard, goldens: goldens, disagreements: disagreements, blind: blind)
        let url = benchPersonas.appendingPathComponent("evals.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        print("evals: \(goldens.filter(\.passed).count)/\(goldens.count) goldens, \(disagreements.filter(\.passed).count)/\(disagreements.count) disagreements, \(blind.filter(\.passed).count)/\(blind.count) blind → \(url.path)")
    }
}

/// Prints every reading the two pilot personas give the feel library and the writer's lines, so a
/// blind sheet can be authored from what is knowable and checked against what is read.
@Suite("Persona evals: the material, printed", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_BLIND_PRINT"] != nil))
struct PersonaBlindPrintTests {
    @Test func printReadings() throws {
        var out = ""
        for feel in FeelLibrary.standard.feels {
            let readings = try BlindRunner.read(.feel(name: feel.name, tempo: nil), as: .beatmaker, label: "x", feels: .standard)
            out += "FEEL \(feel.name) @\(feel.suggestedTempo)\n" + readings.map { "   \($0.holds ? "✔" : "✘") \($0.rule) \($0.feature)=\(String(format: "%.3g", $0.value)) — \($0.says)" }.joined(separator: "\n") + "\n"
        }
        for (hands, lag, tempo, feel) in [("palladino", 40.0, 92.0, "Neo-Soul Pocket"), ("palladino", 65.0, 92.0, "Neo-Soul Pocket"), ("palladino", 10.0, 92.0, "Boom-Bap"),
                                         ("thundercat", 10.0, 130.0, "Four on the Floor"), ("thundercat", 40.0, 96.0, "Boom-Bap"),
                                         ("programmed", 0.0, 140.0, "Trap Rolling Hats"), ("programmed", 30.0, 90.0, "Lo-Fi Hip-Hop"), ("palladino", -15.0, 92.0, "Neo-Soul Pocket")] {
            let readings = try BlindRunner.read(.bassline(hands: hands, lagMS: lag, tempo: tempo, feel: feel, density: 0.5, seed: 0xBA55_0001), as: .bassist, label: "x", feels: .standard)
            out += "LINE \(hands) lag \(lag) @\(tempo) under \(feel)\n" + readings.map { "   \($0.holds ? "✔" : "✘") \($0.rule) \($0.feature)=\(String(format: "%.3g", $0.value)) — \($0.says)" }.joined(separator: "\n") + "\n"
        }
        try out.write(toFile: ProcessInfo.processInfo.environment["MRROBOTO_BLIND_PRINT"]!, atomically: true, encoding: .utf8)
    }
}
