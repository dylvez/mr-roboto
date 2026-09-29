import Foundation
import MusicTheory
import SongGraph

/// What the Piano roll needs from whatever is hosting it.
///
/// A note sounded now, an instrument picked, stop, and a version taken. Playing the whole line is
/// the frame's: the surface's header and ⌥Space play it once through `PartPlayer`, on the bass or,
/// in melody mode, on its instrument; and the transport plays it under the groove, looping.
@MainActor
public protocol PianoRollHosting: AnyObject {
    /// One note, now, through `sound`'s voice.
    func audition(note: Int, velocity: Int, duration: Double, sound: String) async
    /// One note of a melody, on the pitched instrument rather than the bass.
    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async
    /// The instrument this surface's part plays on. Nil is the song's own pick, which is what a
    /// surface working on nothing yet sets.
    func setInstrument(_ id: String, for part: PartID?)
    func stop() async
    /// A new part version left the surface. `false` when the host refused it. Synchronous, so a
    /// keep the frame asks for before it plays is in the song before the transport reads it.
    @MainActor @discardableResult
    func commit(_ version: PartVersion) -> Bool
    /// The newest version of a part in the song, so a keep builds on it — a restore, or what the
    /// band wrote since — rather than on the version this roll last kept.
    func newest(of part: PartID) -> PartVersion?
}

extension PianoRollHosting {
    public func newest(of part: PartID) -> PartVersion? { nil }
}

/// What the Chords surface needs: a chord sounded on touch, and a version taken.
@MainActor
public protocol ChordsHosting: AnyObject {
    func audition(pitches: [Int], duration: Double) async
    /// The song's pitched instrument: what these chords are voiced on.
    var instrument: String { get }
    /// The instrument this surface's part plays on. Nil is the song's own pick, which is what a
    /// surface working on nothing yet sets.
    func setInstrument(_ id: String, for part: PartID?)
    @discardableResult
    func commit(_ version: PartVersion) -> Bool
    /// The song's newest bass line, for the Harmonist to ask whether it agrees with the chords.
    /// Nil when there is none, and then nothing is said about the bass.
    var bassline: Bassline? { get }
    /// The newest version of a part in the song, so a keep builds on it.
    func newest(of part: PartID) -> PartVersion?
    /// The instrument a part's chords play on: its own pick, else the song's. Nil is the song's.
    func instrument(for part: PartID?) -> String
    /// A chord, on the instrument `part` plays on.
    func audition(pitches: [Int], duration: Double, for part: PartID?) async
    /// The chords as they are played — voiced and struck — on the instrument `part` plays on, at
    /// the song's tempo: what is heard when the way they are played is changed.
    func audition(_ progression: Progression, for part: PartID?) async
    /// The family of the instrument `part` plays on: keys, pad, strings. A short pattern on an
    /// instrument that swells into its notes is mostly silence, and the sheet says so.
    func instrumentFamily(for part: PartID?) -> String
}

extension ChordsHosting {
    public var bassline: Bassline? { nil }
    public func newest(of part: PartID) -> PartVersion? { nil }
    public func instrument(for part: PartID?) -> String { instrument }
    public func audition(pitches: [Int], duration: Double, for part: PartID?) async {
        await audition(pitches: pitches, duration: duration)
    }
    public func audition(_ progression: Progression, for part: PartID?) async {}
    public func instrumentFamily(for part: PartID?) -> String { "keys" }
}
