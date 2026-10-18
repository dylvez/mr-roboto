import Foundation

/// The effects a genre's own profile describes, as moves the band can make: each one read out of
/// the profile's cited notes, references and players, not added to them. A genre whose research
/// says nothing about an effect has none here.
///
/// `read_genre` says them, so a song placed in dub hears of its spring and its swept high-pass, a
/// techno song of its bass ducked on the kick; and `Develop` puts the pump on where a profile
/// says the genre pumps.
public enum GenreEffects {
    public struct Move: Sendable, Hashable {
        /// What it is, as set_effects or tune_take names it.
        public var move: String
        /// What it goes on.
        public var on: Target
        /// What the profile says, in short.
        public var why: String

        public enum Target: String, Sendable, Hashable {
            case bass, chords, chop, melody, drums, vocal, returns
        }

        /// "pump kick on the bass: …".
        public var said: String { "\(move) on the \(on == .returns ? "returns" : on.rawValue): \(why)" }
    }

    /// Genre id to the moves its profile describes.
    public static let byGenre: [String: [Move]] = [
        "afrobeats": [
            Move(move: "pump kick", on: .bass, why: "the bass sidechained to the kick for the pumping bounce"),
            Move(move: "tune_take hard", on: .vocal, why: "Auto-Tune used openly, its artefacts a feature"),
        ],
        "amapiano": [Move(move: "pump kick", on: .bass, why: "the sine sub under the log drum sidechained so the two do not fight")],
        "boom-bap": [Move(move: "pump kick", on: .chop, why: "the sample side-chained to the kick")],
        "lo-fi-hip-hop": [Move(move: "pump kick", on: .chords, why: "heavy side-chain of the melodic loop to the kick: the wave-like rise and fall")],
        "techno": [Move(move: "pump kick", on: .bass, why: "the bass sidechained to the kick and band-limited")],
        "breakbeat": [
            Move(move: "filter sweep", on: .chop, why: "builds and drops moved along with filters"),
            Move(move: "modulation phaser or flanger", on: .chop, why: "phasers and flangers on the builds"),
        ],
        "drum-and-bass": [Move(move: "modulation phaser or chorus, a filter moving", on: .bass, why: "a Reese of detuned saws with filter movement, chorus or phaser")],
        "dub": [
            Move(move: "filter high-pass swept by section", on: .drums, why: "Tubby swept the desk's high-pass until a part vanished"),
            Move(move: "room spring", on: .returns, why: "Tubby's spring was liberally used"),
            Move(move: "echo_tape and echo throws by section", on: .returns, why: "the Space Echo turning snatches of a part into repeats"),
            Move(move: "modulation phaser-slow", on: .chords, why: "Perry's Mu-tron Bi-phase on guitars and keys"),
        ],
        "reggae": [
            Move(move: "room spring", on: .returns, why: "a spring on the drum bus, the classic-reggae auxiliary"),
            Move(move: "filter high-pass swept by section", on: .drums, why: "Tubby's high-pass ridden live"),
        ],
        "dubstep": [Move(move: "filter low-pass held then open at the drop", on: .bass, why: "a heavily filtered bass revealed at the drop")],
        "ambient": [Move(move: "echo_tape", on: .returns, why: "phrases run through tape delay")],
        "arabic-pop": [Move(move: "tune_take hard", on: .vocal, why: "heavy Auto-Tune on the voice")],
        "drill": [Move(move: "tune_take hard", on: .vocal, why: "an often Auto-Tuned, deadpan delivery")],
        "reggaeton": [Move(move: "tune_take hard", on: .vocal, why: "Auto-Tune standard today")],
        "rnb": [
            Move(move: "tune_take natural", on: .vocal, why: "takes tuned with Melodyne rather than Auto-Tune"),
            Move(move: "pedal wah-sixteenths", on: .chords, why: "late-90s records add 70s wah-wah guitar licks"),
        ],
        "house": [Move(move: "modulation chorus", on: .chords, why: "Juno synth lines among its sources")],
        "synth-pop": [Move(move: "modulation chorus", on: .chords, why: "a Juno-60 backing")],
        "rock": [Move(move: "modulation chorus", on: .chords, why: "quiet verses with chorused clean guitar before the distorted choruses")],
    ]

    public static func moves(for genre: String) -> [Move] { byGenre[genre] ?? [] }

    /// Whether the genre's profile says its parts pump on the kick, and which.
    public static func pumped(in genre: String) -> [Move.Target] {
        moves(for: genre).filter { $0.move == "pump kick" }.map(\.on)
    }
}
