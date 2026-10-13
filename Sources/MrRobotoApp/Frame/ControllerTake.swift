import Foundation
import SongGraph

// Inputs I8: the controller recorded into the surface in front of you — hits onto the Grid's steps,
// notes onto the Piano roll, chords onto the lead sheet. Before this a controller could only play
// in a new part of its own, from a switch in the transport bar, and none of the three surfaces
// said it could take anything.

/// A surface the controller records into. Record on the surface makes it the controller's: the
/// controller sounds the surface's own kit, bass or instrument, and what is played lands on the
/// surface as an edit of what it shows — one step of ⌘Z, kept the way the surface keeps an edit.
@MainActor
public protocol TakesFromController: AnyObject {
    /// The surface it is, so its Record control knows the take is its own.
    var surfaceID: SurfaceID { get }
    /// What the surface is called in a sentence: "the Grid", "the Piano roll".
    var takeName: String { get }
    /// What the controller sounds while it records here.
    var controllerVoice: MIDIControl.Voice { get }
    /// In time against the song: the Grid and the Piano roll put each note where it was played. A
    /// lead sheet takes a chord at a time as it is played, with nothing running.
    var takesInTime: Bool { get }
    /// Whether a take is coming in now.
    var isTaking: Bool { get }

    /// A take starts. `bars` is how long the section it is played over is, when it is played over
    /// one.
    func beginTake(bars: Int?)
    /// A key put down. `beat` is where, in beats from the section's first bar; nil on a surface
    /// that does not take in time.
    func takeNoteOn(_ note: Int, velocity: Int, beat: Double?)
    func takeNoteOff(_ note: Int, beat: Double?)
    /// The take is over, at `beat` when it was in time: a key still down is let go there.
    func endTake(at beat: Double?)
    /// Sounds a hit itself, for a kit the controller cannot name by id — a chop's slices. False
    /// leaves it to `controllerVoice`.
    func soundTakeHit(_ note: Int, velocity: Int) -> Bool
}

extension TakesFromController {
    public func soundTakeHit(_ note: Int, velocity: Int) -> Bool { false }
}
