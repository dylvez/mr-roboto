import Foundation
import MusicTheory
import SongGraph

/// What the Piano roll needs from whatever is hosting it.
///
/// Four things: sound one note now, play the line once, stop, and take a version. The transport
/// — the line under the groove, looping — is the frame's (`SongPlayback`), not the surface's: a
/// bass line is only ever heard against its drums from the space bar, which is where the drums are.
@MainActor
public protocol PianoRollHosting: AnyObject {
    /// One note, now, through `sound`'s voice.
    func audition(note: Int, velocity: Int, duration: Double, sound: String) async
    /// The whole line once, on its own, from its first beat.
    func play(_ bassline: Bassline, tempo: Double, timeSignature: TimeSignature) async
    /// One note of a melody, on the pitched instrument rather than the bass.
    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async
    /// A whole melody, at its written beats.
    func playMelody(_ notes: [NoteEvent], tempo: Double, timeSignature: TimeSignature, instrument: String) async
    /// The song's pitched instrument becomes this one, for everything that plays through it.
    func setInstrument(_ id: String)
    func stop() async
    /// A new part version left the surface. `false` when the host refused it.
    @discardableResult
    func commit(_ version: PartVersion) async -> Bool
}

/// What the Chords surface needs: a chord sounded on touch, and a version taken.
@MainActor
public protocol ChordsHosting: AnyObject {
    func audition(pitches: [Int], duration: Double) async
    /// The song's pitched instrument: what these chords are voiced on.
    var instrument: String { get }
    func setInstrument(_ id: String)
    @discardableResult
    func commit(_ version: PartVersion) async -> Bool
}
