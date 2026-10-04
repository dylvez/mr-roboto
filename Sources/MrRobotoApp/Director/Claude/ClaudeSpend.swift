import Foundation

// What a session costs, kept where a person can see it.
//
// The reason this exists at all: an orchestrator that quietly spends money is the failure mode of
// every agent demo. The Director's spend is a value the frame can render, updated on every turn,
// including the turns that were cancelled or refused.

/// Tokens, by kind, for one turn or for a whole session.
public struct ClaudeUsage: Sendable, Equatable, Hashable, Codable {
    /// Tokens processed at full price — the uncached remainder, not the whole prompt.
    public var inputTokens: Int
    public var outputTokens: Int
    /// Tokens written to the cache this turn, at the write premium.
    public var cacheCreationTokens: Int
    /// Tokens served from the cache this turn, at a tenth of input (less on Fable).
    public var cacheReadTokens: Int
    /// Of the creation tokens, those written at the one-hour TTL rather than five minutes.
    public var cacheCreation1hTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0,
                cacheCreation1hTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
    }

    /// The whole prompt: the uncached remainder plus both cache figures. `inputTokens` alone is
    /// not the prompt size, which is the single most misread number in this API.
    public var promptTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

    public static let zero = ClaudeUsage()

    public static func + (lhs: ClaudeUsage, rhs: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(inputTokens: lhs.inputTokens + rhs.inputTokens,
                    outputTokens: lhs.outputTokens + rhs.outputTokens,
                    cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
                    cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
                    cacheCreation1hTokens: lhs.cacheCreation1hTokens + rhs.cacheCreation1hTokens)
    }

    public static func += (lhs: inout ClaudeUsage, rhs: ClaudeUsage) { lhs = lhs + rhs }

    /// One reply's figures with a later reading of the same reply taken in. A stream counts
    /// cumulatively, so a later figure replaces the earlier one where it has grown and a figure the
    /// later event leaves out stands: nothing in one reply is ever added to itself.
    public func broughtUpToDate(by later: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(inputTokens: max(inputTokens, later.inputTokens),
                    outputTokens: max(outputTokens, later.outputTokens),
                    cacheCreationTokens: max(cacheCreationTokens, later.cacheCreationTokens),
                    cacheReadTokens: max(cacheReadTokens, later.cacheReadTokens),
                    cacheCreation1hTokens: max(cacheCreation1hTokens, later.cacheCreation1hTokens))
    }

    /// What this usage cost on a given model.
    public func cost(on model: ClaudeModel) -> Decimal {
        let price = model.pricing
        let million = Decimal(1_000_000)
        let fiveMinute = max(0, cacheCreationTokens - cacheCreation1hTokens)
        var total = Decimal(inputTokens) * price.input
        total += Decimal(outputTokens) * price.output
        total += Decimal(fiveMinute) * price.cacheWrite5m
        total += Decimal(cacheCreation1hTokens) * price.cacheWrite1h
        total += Decimal(cacheReadTokens) * price.cacheRead
        return total / million
    }

    /// The share of the prompt that came out of the cache, 0…1. Zero across a whole session means
    /// something upstream is rewriting the prefix.
    public var cacheHitRate: Double {
        guard promptTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(promptTokens)
    }
}

extension ClaudeUsage {
    /// The wire shape. `cache_creation` breaks the write down by TTL when it is present.
    struct Wire: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreation: Breakdown?

        struct Breakdown: Decodable {
            var ephemeral5m: Int?
            var ephemeral1h: Int?
            enum CodingKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens"
                case ephemeral1h = "ephemeral_1h_input_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
        }

        var value: ClaudeUsage {
            ClaudeUsage(inputTokens: inputTokens ?? 0,
                        outputTokens: outputTokens ?? 0,
                        cacheCreationTokens: cacheCreationInputTokens ?? 0,
                        cacheReadTokens: cacheReadInputTokens ?? 0,
                        cacheCreation1hTokens: cacheCreation?.ephemeral1h ?? 0)
        }
    }
}

/// One turn's entry in the ledger.
public struct ClaudeSpendEntry: Sendable, Equatable, Identifiable {
    /// How the turn ended, because a cancelled turn still costs money and the ledger says so.
    public enum Outcome: String, Sendable, Equatable {
        case completed
        case cancelled
        case refused
        case failed
    }

    public let id: UUID
    public let at: Date
    public let model: ClaudeModel
    public let role: DirectorRole
    public let usage: ClaudeUsage
    public let outcome: Outcome

    public init(id: UUID = UUID(), at: Date = Date(), model: ClaudeModel, role: DirectorRole,
                usage: ClaudeUsage, outcome: Outcome) {
        self.id = id
        self.at = at
        self.model = model
        self.role = role
        self.usage = usage
        self.outcome = outcome
    }

    public var cost: Decimal { usage.cost(on: model) }
}

/// Everything a session has spent, and on what.
public struct ClaudeSpend: Sendable, Equatable {
    public private(set) var entries: [ClaudeSpendEntry] = []

    public init() {}

    public mutating func record(_ entry: ClaudeSpendEntry) { entries.append(entry) }

    public var usage: ClaudeUsage { entries.reduce(.zero) { $0 + $1.usage } }
    public var total: Decimal { entries.reduce(Decimal.zero) { $0 + $1.cost } }
    public var turnCount: Int { entries.count }

    public func usage(for model: ClaudeModel) -> ClaudeUsage {
        entries.filter { $0.model == model }.reduce(.zero) { $0 + $1.usage }
    }

    public func total(for model: ClaudeModel) -> Decimal {
        entries.filter { $0.model == model }.reduce(Decimal.zero) { $0 + $1.cost }
    }

    /// The share of every prompt token this session that came from the cache.
    public var cacheHitRate: Double { usage.cacheHitRate }

    /// One line for the header: what this session has cost so far.
    public var line: String {
        "\(ClaudeSpend.money(total)) · \(turnCount) turn\(turnCount == 1 ? "" : "s") · \(Int((cacheHitRate * 100).rounded()))% cached"
    }

    /// Money as a person reads it. Sub-cent spends still show something rather than "$0.00".
    public static func money(_ amount: Decimal) -> String {
        if amount > 0 && amount < Decimal(string: "0.01")! {
            return "<$0.01"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
