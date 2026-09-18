// MARK: - Degradation

/// One pass of a degradation chain over a sample or a groove, as the graph stores it.
///
/// ## Where dust lives in the graph
///
/// On the part it dirties. A dusty chop is a **new version of the chop** — same part, the dry
/// version as its parent, `Operation.degrade` as the operation — whose `Sample.degradation` names
/// the chain it plays through. Three properties fall out of that and they are the reason for the
/// shape:
///
/// * **The dry version is untouched and still playable.** Nothing is printed: the media hash is the
///   same, the slices are the same, and the chain is a render-time instruction carried beside them.
///   Selecting the parent plays the chop clean.
/// * **Provenance is ordinary.** The ledger says "degrade → sample v2 · from v1", and `Lineage`
///   answers "what was this dirtied from" without a second kind of edge. A `.sound` part that named
///   the chop as its parent would have made a *routing* question ("what does the transport play?")
///   depend on a provenance edge, which is the thing parents are not for.
/// * **It stays a chop.** Everything that already reads a `.sample` — the Chop lane, the Compare,
///   the critics, the Director's tools, clearances through `sourceRecord` — reads a dusty one
///   without learning a new type, and a Compare of the dry chop against the dusty one is like
///   against like.
///
/// `degradation` is an ordered list of passes, first pass nearest the media. One pass is the
/// normal case; two is a *stack* — a second machine over the first — which is expressible on
/// purpose so the chain critic can flag it rather than the graph silently flattening it.
///
/// ## The seed
///
/// `seed` is the `UInt64` the chain's noise and crackle generator is seeded with, and it is what
/// makes a bounce reproducible from a stored version. It is **encoded as a decimal string**, not a
/// JSON number. The non-clean presets all use `0x9E3779B97F4A7C15`, which is above `Int64.max` and
/// far above 2^53: a `Double` cannot carry it, and neither can this module's own `JSONValue` (which
/// is what every schema migration round-trips a document through — it tries `Int`, then falls back
/// to `Double`). A string survives both. Decoding also accepts an integer, for hand-written files.
///
/// The parameters travel as `[String: Double]`, like `Sound.parameters`, so this module stays
/// ignorant of what the chain is; `Instrument.DegradeSettings` is the typed view and owns the keys.
public struct Degradation: Hashable, Sendable {
    /// Which chain processes this pass. `"degrade"` is `Instrument.DegradeChain`, the only one there
    /// is; a free string for the same reason `Sound.instrument` is one.
    public var chain: String
    /// The named set the pass was reached from ("sp1200"), when it was reached from one. Provenance
    /// and a label: the parameters, not the name, are what render.
    public var preset: String?
    /// Every parameter of the pass, by name. Enumerations travel as their stable C values.
    public var parameters: [String: Double]
    /// The noise generator's seed. See the type's documentation for why it is a string on disk.
    public var seed: UInt64

    public init(chain: String = Degradation.degradeChain, preset: String? = nil,
                parameters: [String: Double] = [:], seed: UInt64 = 0) {
        self.chain = chain
        self.preset = preset
        self.parameters = parameters
        self.seed = seed
    }

    /// `Instrument.DegradeChain`'s identifier.
    public static let degradeChain = "degrade"

    /// What a person calls this pass: its preset, or the chain's name when it was hand-set.
    public var name: String { preset ?? chain }
}

extension Degradation: Codable {
    private enum CodingKeys: String, CodingKey { case chain, preset, parameters, seed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chain = try c.decodeIfPresent(String.self, forKey: .chain) ?? Degradation.degradeChain
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        parameters = try c.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:]
        if let text = try? c.decode(String.self, forKey: .seed) {
            guard let value = UInt64(text) else {
                throw DecodingError.dataCorruptedError(forKey: .seed, in: c,
                                                       debugDescription: "\"\(text)\" is not a UInt64 seed")
            }
            seed = value
        } else {
            seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chain, forKey: .chain)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(String(seed), forKey: .seed)
    }
}

// MARK: - Reading and writing the chain on a part

extension PartKind {

    /// The chain this payload plays through, first pass nearest the media. Empty for a dry part and
    /// for every kind that cannot carry one.
    public var degradation: [Degradation] {
        switch self {
        case .sample(let sample): return sample.degradation
        case .groove(let groove): return groove.degradation
        default: return []
        }
    }

    /// Whether this kind of payload can carry a chain at all: a sample and a groove.
    public var canCarryDegradation: Bool {
        switch self {
        case .sample, .groove: return true
        default: return false
        }
    }

    /// The same payload playing through `passes` instead, or nil for a kind that cannot carry a
    /// chain. Everything else about the part is kept exactly.
    public func withDegradation(_ passes: [Degradation]) -> PartKind? {
        switch self {
        case .sample(var sample):
            sample.degradation = passes
            return .sample(sample)
        case .groove(var groove):
            groove.degradation = passes
            return .groove(groove)
        default:
            return nil
        }
    }

    /// The dry payload: the same part with no chain on it.
    public var dry: PartKind { withDegradation([]) ?? self }
}
