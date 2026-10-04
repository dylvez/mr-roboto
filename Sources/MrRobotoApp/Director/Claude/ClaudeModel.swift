import Foundation

// The models the band runs on, what they cost, and the handful of ways they differ from each other
// that this client has to know about. Everything here is a fact about the 2026 Messages API rather
// than a preference, so it is written down once and asserted in tests: a wrong model id is a 404
// and a wrong price is an invisible lie about what a session spent.

/// A model the Director can call.
///
/// Three, deliberately. Every call in the app picks a `DirectorRole` and the role picks the model,
/// so "which model does the critic use" is answered in one place rather than at every call site.
/// The one exception is the Director's own conversation, which runs on the model the user chose
/// in the rail (`DirectorModelChoice`): it is nearly all of the bill, and the bill is theirs.
public enum ClaudeModel: String, Sendable, Codable, Hashable, CaseIterable, CustomStringConvertible {
    /// Judgment: choosing a surface, reading a song, deciding what to propose.
    case opus5 = "claude-opus-5"
    /// The frequent cheap calls: labels, one-line critiques, classifying an intent.
    case sonnet5 = "claude-sonnet-5"
    /// The hardest reasoning, and the most expensive: arranging a whole song, resolving an argument.
    case fable51 = "claude-fable-5-1"

    /// The exact string the API wants. Never date-suffixed.
    public var id: String { rawValue }
    public var description: String { rawValue }

    /// Price per million tokens, first-party Claude API rates.
    public var pricing: ClaudePricing {
        switch self {
        case .opus5: ClaudePricing(input: 5, output: 25)
        case .sonnet5: ClaudePricing(input: 2, output: 10)
        // Fable 5.1 reads cache at a flat $0.25/MTok — 0.025×, not the usual 0.1× — which changes
        // every break-even on it, so it is spelled out rather than derived.
        case .fable51: ClaudePricing(input: 10, output: 50, cacheRead: 0.25)
        }
    }

    /// Below this many tokens a `cache_control` marker is silently ignored. Model-dependent, and
    /// not monotonic across generations, so the prefix builder checks it rather than assuming.
    public var minimumCacheablePrefix: Int {
        switch self {
        case .opus5, .fable51: 512
        case .sonnet5: 1024
        }
    }

    /// Whether `tool_choice` may be `any` or a named tool. Fable 5.1 returns a 400 for both; the
    /// client refuses to send one rather than letting the request fail in the field.
    public var allowsForcedToolChoice: Bool {
        switch self {
        case .opus5, .sonnet5: true
        case .fable51: false
        }
    }

    /// Whether a `{"role": "system"}` message may be appended mid-conversation. Where it is
    /// available it is the operator channel that does not invalidate the cached prefix; Sonnet 5
    /// does not have it, so an instruction for that model goes in a user turn instead.
    public var allowsMidConversationSystem: Bool {
        switch self {
        case .opus5, .fable51: true
        case .sonnet5: false
        }
    }

    /// Whether an explicit `thinking` block may be sent. Fable 5.1 thinks always and rejects any
    /// explicit configuration, so the client omits the parameter for it.
    public var allowsExplicitThinking: Bool {
        switch self {
        case .opus5, .sonnet5: true
        case .fable51: false
        }
    }
}

extension ClaudeModel {
    /// The name a person reads: "Sonnet 5".
    public var label: String {
        switch self {
        case .opus5: "Opus 5"
        case .sonnet5: "Sonnet 5"
        case .fable51: "Fable 5.1"
        }
    }
}

/// Which model the band runs on: chosen in the rail, kept between launches.
///
/// Sonnet 5 until somebody says otherwise. Run through the same five-sentence session it reached
/// for the same tools as Opus 5 at two fifths of the price, once the tools' answers carried the
/// numbers it is asked to say; Opus 5 is the more careful reporter, and one click away.
public struct DirectorModelChoice {
    private let read: () -> String?
    private let write: (String) -> Void
    static let key = "director.model"

    /// What the band runs on before anybody has chosen.
    public static let standard = ClaudeModel.sonnet5
    /// The ones offered, the less expensive first.
    public static let offered: [ClaudeModel] = [.sonnet5, .opus5]

    /// The choice as the app keeps it, in its defaults.
    public init(defaults: UserDefaults = .standard) {
        self.init(read: { defaults.string(forKey: Self.key) }, write: { defaults.set($0, forKey: Self.key) })
    }

    /// The choice kept wherever the caller says. A test keeps it in memory: defaults made for one
    /// test leave a file in Preferences every run, whether or not the test takes them away again.
    init(read: @escaping () -> String?, write: @escaping (String) -> Void) {
        self.read = read
        self.write = write
    }

    public var model: ClaudeModel {
        get {
            let kept = read().flatMap(ClaudeModel.init(rawValue:))
            return kept.flatMap { Self.offered.contains($0) ? $0 : nil } ?? Self.standard
        }
        nonmutating set { write(newValue.rawValue) }
    }

    /// A model as the menu offers it: its name, and what it costs beside the least expensive one,
    /// worked out from the prices rather than written down a second time.
    public static func line(for model: ClaudeModel) -> String {
        guard let least = offered.min(by: { $0.pricing.input < $1.pricing.input }), model != least else {
            return "\(model.label), the less expensive"
        }
        let times = NSDecimalNumber(decimal: model.pricing.input / least.pricing.input).doubleValue
        let said = times == times.rounded() ? String(format: "%.0f", times) : String(format: "%.1f", times)
        return "\(model.label), \(said) times the price"
    }
}

/// What a call is for. The Director asks for a role; the role, not the call site, picks the model.
public enum DirectorRole: String, Sendable, Codable, Hashable, CaseIterable {
    /// Reading the song and deciding what to do about it.
    case judgment
    /// The cheap chatter: labels, short critiques, classification.
    case chatter
    /// The hardest reasoning in the app, and the only thing worth Fable prices.
    case hardest

    public var model: ClaudeModel {
        switch self {
        case .judgment: .opus5
        case .chatter: .sonnet5
        case .hardest: .fable51
        }
    }
}

/// Dollars per million tokens, by kind of token.
///
/// Cache writes are 1.25× input at the five-minute TTL and 2× at an hour; cache reads are 0.1× of
/// input unless a model says otherwise. `Decimal` rather than `Double`: this arithmetic ends up in
/// front of a person as money.
public struct ClaudePricing: Sendable, Equatable, Hashable {
    public var input: Decimal
    public var output: Decimal
    public var cacheWrite5m: Decimal
    public var cacheWrite1h: Decimal
    public var cacheRead: Decimal

    public init(input: Decimal, output: Decimal,
                cacheWrite5m: Decimal? = nil, cacheWrite1h: Decimal? = nil, cacheRead: Decimal? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m ?? input * Decimal(string: "1.25")!
        self.cacheWrite1h = cacheWrite1h ?? input * 2
        self.cacheRead = cacheRead ?? input / 10
    }
}
