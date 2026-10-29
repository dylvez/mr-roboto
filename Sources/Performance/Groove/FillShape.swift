import SongGraph

/// What a drummer plays at the end of a section to lead into the next: one of a few shapes a kit
/// knows. Every song had one — the snare down the toms, half a bar, at every edge — and a
/// listener who has heard thirty songs from the app heard it thirty times.
public enum FillShape: String, Codable, Sendable, Hashable, CaseIterable {
    /// The snare walks down the toms, one voice a beat: what every song had.
    case tomWalkDown = "tom-walk-down"
    /// The toms up to the snare: the way into a bridge.
    case tomWalkUp = "tom-walk-up"
    /// Eighths on the snare, then sixteenths: the roll into a hook.
    case snareRoll = "snare-roll"
    /// Kick, kick, snare, over and over: the stutter.
    case kickSnare = "kick-snare"
    /// One beat: a hit on four and a grace note on the last sixteenth into the crash.
    case flam
    /// The kit stops a beat or two before the crash; the bass and the rest keep going.
    case dropOut = "drop-out"
    /// Open hats on every eighth through the last of it, no toms: the electronic families' fill.
    case hatLift = "hat-lift"
    /// The rim on four and a tom on the and of it: the one drop's pickup.
    case rimPickup = "rim-pickup"
    /// The timbales, high to low: what a groove with timbales fills on.
    case timbales
    /// A bar of the snare from eighths into sixteenths, rising, the kick on the beats: a build.
    case build
    /// No fill: the groove runs to the bar line.
    case none

    /// The shape by its plain name: what the menus and the band say.
    public var name: String {
        switch self {
        case .tomWalkDown: return "the snare down the toms"
        case .tomWalkUp: return "the toms up to the snare"
        case .snareRoll: return "a snare roll"
        case .kickSnare: return "kick, kick, snare"
        case .flam: return "a flam into the crash"
        case .dropOut: return "the kit out"
        case .hatLift: return "the hats lifted"
        case .rimPickup: return "a rim pickup"
        case .timbales: return "the timbales"
        case .build: return "a build"
        case .none: return "no fill"
        }
    }

    public var about: String {
        switch self {
        case .tomWalkDown: return "the kit rests and the snare walks down the toms, a voice a beat, accented on the beats"
        case .tomWalkUp: return "the kit rests and the toms walk up to the snare, a voice a beat"
        case .snareRoll: return "the kit rests and the snare rolls, eighths then sixteenths, accented on the beats"
        case .kickSnare: return "the kit rests and the kick stutters twice into the snare on every beat"
        case .flam: return "the last beat: a snare on four and a grace note on the last sixteenth, into the crash"
        case .dropOut: return "the kit stops; the bass, the chords and the percussion go on into the crash"
        case .hatLift: return "the closed hats become open hats on every eighth; the kick and snare play as written; no toms"
        case .rimPickup: return "the last beat: the rim on four, a tom on the and of four"
        case .timbales: return "the timbales walk high to low where a drummer's toms would"
        case .build: return "the snare from eighths into sixteenths, ghost to accent, the kick on the beats"
        case .none: return "the groove runs to the bar line"
        }
    }

    /// The sizes a shape comes in. A flam and a rim pickup are a beat by definition; a build is
    /// a bar or two; the kit stops for anything up to a bar.
    public var sizes: [FillSize] {
        switch self {
        case .flam, .rimPickup: return [.beat]
        case .build: return [.bar, .twoBars]
        case .hatLift: return [.halfBar, .bar, .twoBars]
        case .none: return []
        default: return [.beat, .halfBar, .bar]
        }
    }

    public var defaultSize: FillSize {
        switch self {
        case .flam, .rimPickup: return .beat
        case .build: return .bar
        case .hatLift: return .bar
        default: return .halfBar
        }
    }

    /// By its raw value or its plain name, as the band or a menu might say it.
    public static func named(_ text: String) -> FillShape? {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = FillShape(rawValue: folded) { return exact }
        return allCases.first { $0.name == folded || $0.rawValue.replacingOccurrences(of: "-", with: " ") == folded }
    }
}

/// How long a fill is.
public enum FillSize: String, Codable, Sendable, Hashable, CaseIterable {
    case beat, halfBar = "half-bar", bar, twoBars = "two-bars"

    public var name: String {
        switch self {
        case .beat: return "a beat"
        case .halfBar: return "half a bar"
        case .bar: return "a bar"
        case .twoBars: return "two bars"
        }
    }

    /// The size in beats, in a meter.
    public func beats(in beatsPerBar: Int) -> Double {
        let bar = Double(max(1, beatsPerBar))
        switch self {
        case .beat: return 1
        case .halfBar: return bar >= 3 ? (bar / 2).rounded(.down) : 1
        case .bar: return bar
        case .twoBars: return bar * 2
        }
    }

    /// The size a length in beats names, in a meter: the largest that fits.
    public static func of(beats: Double, in beatsPerBar: Int) -> FillSize? {
        guard beats > 0 else { return nil }
        let bar = Double(max(1, beatsPerBar))
        if beats >= bar * 2 - 1e-6 { return .twoBars }
        if beats >= bar - 1e-6 { return .bar }
        if beats >= FillSize.halfBar.beats(in: beatsPerBar) - 1e-6, bar >= 3 { return .halfBar }
        return .beat
    }

    public static func named(_ text: String) -> FillSize? {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = FillSize(rawValue: folded) { return exact }
        return allCases.first { $0.name == folded || $0.rawValue.replacingOccurrences(of: "-", with: " ") == folded }
    }
}

/// A fill: a shape, at a size.
public struct Fill: Hashable, Codable, Sendable {
    public var shape: FillShape
    public var size: FillSize

    public init(shape: FillShape, size: FillSize? = nil) {
        self.shape = shape
        self.size = size ?? shape.defaultSize
    }

    /// What every song had before fills were chosen: the snare down the toms, half a bar.
    public static let usual = Fill(shape: .tomWalkDown, size: .halfBar)

    /// "a snare roll, half a bar"; "no fill".
    public var name: String {
        shape == .none ? shape.name : "\(shape.name), \(size.name)"
    }
}

public extension Transition {
    /// A way out that is this fill: the kind is a fill, the shape its name, the beats its size.
    static func fill(_ fill: Fill, beatsPerBar: Int) -> Transition {
        Transition(kind: .fill, beats: fill.size.beats(in: beatsPerBar), shape: fill.shape.rawValue)
    }

    /// The fill a way out names, in a meter. Nil when it is not a fill, or is a fill with no shape
    /// said — the usual one, which is the caller's to supply.
    func fill(beatsPerBar: Int) -> Fill? {
        guard kind == .fill, let shape = shape.flatMap(FillShape.init(rawValue:)) else { return nil }
        return Fill(shape: shape, size: FillSize.of(beats: beats, in: beatsPerBar) ?? shape.defaultSize)
    }

    /// The way out, said: "a snare roll, half a bar", "the usual fill", "cut", "a build's roll".
    func wayOut(beatsPerBar: Int) -> String {
        switch kind {
        case .fill: return fill(beatsPerBar: beatsPerBar)?.name ?? "the usual fill"
        case .cut: return "cut"
        case .riser: return "a build's roll to the bar line"
        case .fadeOut: return "a fade out"
        case .fadeIn: return "a fade in"
        case .breakdown: return "a breakdown"
        case .drop: return "a drop"
        case .crossfade: return "a crossfade"
        }
    }
}

// MARK: - Choosing

/// The families of feels, as far as fills go: what kind of player is at the kit.
public enum FillFamily: String, Sendable, Hashable, CaseIterable {
    /// A drummer at a kit: soul, funk, rock, pop, the hip-hop families on a kit, country, folk.
    case kit
    /// A machine: house, techno, electronic, breakbeat, drum and bass, trap. No toms; the hats
    /// lift or the kit drops out.
    case electronic
    /// Reggae, dub, ska, dancehall: a rim pickup, or the kit out.
    case reggae
    /// Latin: the timbales carry it, or nothing — the percussion is the fill.
    case latin
    /// Jazz and swing: nothing, or a brushed beat.
    case jazz
    /// Cinematic, ambient, a ballad: nothing, or the kit out.
    case quiet

    public var name: String {
        switch self {
        case .kit: return "a drummer at a kit"
        case .electronic: return "a machine"
        case .reggae: return "a reggae kit"
        case .latin: return "latin percussion"
        case .jazz: return "a jazz kit"
        case .quiet: return "a quiet room"
        }
    }

    /// The family a feel's idioms put it in: the most specific idiom first, the kit when none says.
    public static func of(idioms: [Idiom]) -> FillFamily {
        for idiom in idioms {
            switch idiom {
            case .house, .electronic, .breakbeat, .drumAndBass, .trap: return .electronic
            case .reggae, .dub, .ska, .dancehall: return .reggae
            case .latin, .flamenco: return .latin
            case .jazz, .swing: return .jazz
            case .cinematic, .ambient, .ballad: return .quiet
            default: continue
            }
        }
        return .kit
    }
}

public extension SectionFill {

    /// Decision 2: a fill may take a whole bar only into a hook, chorus or drop, from a verse or a
    /// build; half a bar at most elsewhere. The step that makes it a bar.
    static let bigStep = 0.3

    /// The fill for an edge of a form, by the feel's family, the roles either side and how far
    /// the intensity rises, the song's seed and the edge's place choosing among the shapes that
    /// fit — so two edges of one song differ and two songs differ. Nil for no next section, and
    /// for a build, whose roll is its own way out.
    static func choose(from: SectionRole, to: SectionRole?, step: Double, family: FillFamily,
                       seed: UInt64, index: Int) -> Fill? {
        guard let to else { return nil }
        if from == .build { return nil }
        let candidates = candidates(from: from, to: to, step: step, family: family)
        guard !candidates.isEmpty else { return Fill(shape: .none) }
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        state ^= UInt64(index &+ 1) &* 0x9E37_79B9_7F4A_7C15
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        let pick = Int((state &* 2_685_821_657_736_338_717) >> 33) % candidates.count
        return candidates[pick]
    }

    /// The shapes that fit an edge, in the family's idiom.
    static func candidates(from: SectionRole, to: SectionRole, step: Double, family: FillFamily) -> [Fill] {
        func f(_ shape: FillShape, _ size: FillSize? = nil) -> Fill { Fill(shape: shape, size: size) }
        let none = f(.none)
        // Into a break: the kit out, whoever is playing.
        if to == .breakdown {
            return family == .electronic ? [f(.dropOut, .bar), f(.dropOut, .halfBar)] : [f(.dropOut, .halfBar), f(.dropOut, .beat)]
        }
        // Into a bridge: the walk up.
        if to == .bridge {
            switch family {
            case .kit: return [f(.tomWalkUp, .halfBar), f(.snareRoll, .halfBar)]
            case .electronic: return [f(.hatLift, .halfBar), f(.dropOut, .halfBar)]
            case .reggae: return [f(.rimPickup), f(.dropOut, .beat)]
            case .latin: return [f(.timbales, .halfBar), none]
            case .jazz: return [none, f(.flam)]
            case .quiet: return [none, f(.dropOut, .beat)]
            }
        }
        // Up into a hook or a drop: the big one, a whole bar when the step is big.
        if to.isPeak, !from.isPeak {
            let big = step >= bigStep || from == .verse && to == .drop
            switch family {
            case .kit:
                return big ? [f(.snareRoll, .bar), f(.tomWalkDown, .bar), f(.kickSnare, .bar), f(.snareRoll, .halfBar)]
                           : [f(.snareRoll, .halfBar), f(.tomWalkDown, .halfBar), f(.kickSnare, .halfBar)]
            case .electronic:
                return to == .drop ? [f(.dropOut, .bar), f(.hatLift, .bar), f(.build, .bar)]
                                   : big ? [f(.hatLift, .bar), f(.dropOut, .halfBar), f(.hatLift, .halfBar)]
                                         : [f(.hatLift, .halfBar), f(.dropOut, .halfBar)]
            case .reggae: return [f(.rimPickup), f(.dropOut, .halfBar)]
            case .latin: return [f(.timbales, .halfBar), f(.timbales, .beat), none]
            case .jazz: return [none, f(.flam)]
            case .quiet: return [none, f(.dropOut, .halfBar)]
            }
        }
        // Down out of a hook: small.
        if from.isPeak, !to.isPeak {
            switch family {
            case .kit: return [f(.flam), f(.dropOut, .beat), none]
            case .electronic: return [f(.dropOut, .beat), none]
            case .reggae: return [none, f(.rimPickup)]
            case .latin, .jazz, .quiet: return [none]
            }
        }
        // The same kind again, or out to the end: nothing, or a beat.
        if from == to || to == .outro {
            switch family {
            case .kit: return [none, f(.flam)]
            case .electronic: return [none, f(.dropOut, .beat)]
            default: return [none]
            }
        }
        // Everything else — an intro into a verse, a verse into a pre, a solo: a modest fill.
        switch family {
        case .kit: return [f(.tomWalkDown, .halfBar), f(.snareRoll, .halfBar), f(.kickSnare, .halfBar)]
        case .electronic: return [f(.hatLift, .halfBar), f(.dropOut, .halfBar)]
        case .reggae: return [f(.rimPickup), none]
        case .latin: return [f(.timbales, .halfBar), none]
        case .jazz: return [none, f(.flam)]
        case .quiet: return [none]
        }
    }
}
