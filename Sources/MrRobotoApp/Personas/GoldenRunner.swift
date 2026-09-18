import Foundation

/// Executes every golden a persona's bible declares with a proposal, and says which held.
///
/// The hand-written golden tests assert on the prose — the reason, the counter, the words. This
/// asks the one question a document can ask: put the golden's proposal to the persona, and is the
/// verdict the shape the bible said it would be? It is what `make evals` runs, and what a bible
/// that arrived as a file is held to before it gets a seat.
public enum GoldenRunner {

    public struct Result: Hashable, Sendable, CustomStringConvertible {
        public var persona: PersonaID
        public var golden: String
        public var expected: VerdictShape
        public var got: VerdictShape
        /// The line the persona actually said.
        public var said: String

        public var passed: Bool { expected == got }

        public var description: String {
            "\(passed ? "✔" : "✘") \(golden): expected \(expected.description), got \(got.description)"
                + (passed ? "" : " — \"\(said)\"")
        }
    }

    /// Every executable golden, in the bible's order. Prose-only goldens are skipped, not failed.
    public static func run(_ persona: any Persona) -> [Result] {
        persona.bible.goldens.compactMap { golden in
            guard let proposal = golden.proposal, let expects = golden.expects else { return nil }
            let verdict = persona.consider(proposal)
            return Result(persona: persona.bible.id, golden: golden.id, expected: expects,
                          got: VerdictShape(verdict), said: verdict.spoken)
        }
    }

    /// The whole cast.
    public static func run(_ cast: Cast) -> [Result] {
        cast.personas.flatMap(run)
    }

    public static func failures(_ results: [Result]) -> [Result] { results.filter { !$0.passed } }
}
