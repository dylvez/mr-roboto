import Foundation

/// What a section is for, read from its name.
///
/// A form is a line of names — "Intro", "Verse", "Drop" — and a player reads the name before the
/// bar count: an intro is thin, a breakdown has no kick, a drop is everything. This is that reading,
/// so an arrangement can be written from a form and not only laid out to it.
public enum SectionRole: String, Sendable, CaseIterable, Codable {
    case intro, verse, pre, hook, drop, breakdown, build, bridge, solo, outro, groove

    /// The role a name asks for. Numbers and letters after the name are the section's place, not
    /// its kind: "Verse 2" is a verse and "Intro 2" an intro. A name nobody recognises is a groove
    /// — the loop, played — which is what a section was before it was anything else.
    public static func named(_ name: String) -> SectionRole {
        let folded = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let words = folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let text = words.joined(separator: " ")
        func has(_ candidates: [String]) -> Bool {
            candidates.contains { candidate in
                candidate.contains(" ") ? text.contains(candidate) : words.contains(candidate)
            }
        }
        // The longer names first: a "pre-chorus" is not a chorus, a "drop variation" is a drop, and
        // a "breakdown" is not a "break" that happens to be longer.
        if has(["pre", "prechorus", "lift"]) { return .pre }
        if has(["post"]) { return .hook }
        if has(["build", "buildup", "rise", "riser"]) { return .build }
        if has(["breakdown", "break", "interlude", "mid section", "middle section"]) { return .breakdown }
        if has(["drop", "peak", "shout", "climax"]) { return .drop }
        if has(["intro", "introduction", "opening", "riff"]) { return .intro }
        if has(["outro", "coda", "tag", "ending", "end"]) { return .outro }
        if has(["hook", "chorus", "refrain", "refrao", "coro", "head", "theme"]) { return .hook }
        if has(["bridge", "middle", "mambo", "mona", "b"]) { return .bridge }
        if has(["solo", "solos", "instrumental"]) { return .solo }
        if has(["verse", "a", "parte", "call"]) { return .verse }
        return .groove
    }

    /// 0…1: how much is happening, as a form's curve would draw it.
    public var intensity: Double {
        switch self {
        case .intro: return 0.25
        case .outro: return 0.3
        case .breakdown: return 0.35
        case .bridge: return 0.5
        case .verse: return 0.55
        case .groove: return 0.6
        case .pre: return 0.7
        case .solo: return 0.75
        case .build: return 0.85
        case .hook: return 0.9
        case .drop: return 1
        }
    }

    /// Where the song arrives: what a tune is saved for.
    public var isPeak: Bool { self == .hook || self == .drop }
}
