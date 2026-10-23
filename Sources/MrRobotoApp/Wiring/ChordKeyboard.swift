import Foundation
import MusicTheory
import Observation
import Performance

// One key a chord: a root struck, the buttons held saying what is built on it, on the controller,
// on the Chords sheet's pad, or on the computer's keys. Before it a chord had to be typed, or every
// note of it played.

/// What a chord key plays in: the key that says which chord a root is, how the chord is voiced,
/// and the instrument it sounds on. The Chords sheet's own on its pad, and while Record is on it;
/// the song's otherwise.
public struct ChordContext: Equatable, Sendable {
    public var key: Key
    public var voicing: KeysVoicing
    public var instrument: String
    /// How each chord struck leaves the hand: strummed or poured as a harp when the chords are.
    public var roll: KeysRoll

    public init(key: Key, voicing: KeysVoicing, instrument: String, roll: KeysRoll = .together) {
        self.key = key
        self.voicing = voicing
        self.instrument = instrument
        self.roll = roll
    }
}

/// A surface a chord key writes into while Record is on: the Chords sheet, a chord a bar.
@MainActor
public protocol TakesChords: AnyObject {
    /// What its chord keys play in.
    var chordContext: ChordContext { get }
    /// A chord struck while Record is on it, written as the next bar, turned `lift` steps.
    func takeChord(_ played: ChordKeys.Played, lift: Int)
}

/// The hands on the chord keys: the buttons held, wherever they are held from, the roots down, and
/// the chord struck last. One for the app, on the controller, so the pad lights a button held on
/// the controller, and a chord struck on either is voice-led from the one before it.
@MainActor
@Observable
public final class ChordKeyboard {

    /// Buttons held on the controller, by the key holding each.
    private var onController: [Int: ChordButton] = [:]
    /// Buttons held on the computer's keys.
    private var onKeys: Set<ChordButton> = []
    /// Buttons clicked on the pad. A click holds one until it is clicked again: the pointer that
    /// clicked it is wanted for the key.
    public private(set) var latched: Set<ChordButton> = []
    /// Roots down now, by whoever is holding them: a controller's key, the pad, the computer.
    public private(set) var down: [Int: PitchClass] = [:]
    /// The chord struck last and the notes it sounded on.
    public private(set) var last: Struck?
    /// The dial: how far each chord struck is turned from where its voicing puts it, in
    /// inversions, as the Orchid's voicing dial turns the chord under the hand. A chord written
    /// while Record is on keeps the turn it was struck with.
    public private(set) var lift = 0
    /// How far the dial goes either way: a chord of four notes turned four steps is the same chord
    /// an octave away, so twice that is as far as a turn means anything.
    public static let lifts = -8...8

    public struct Struck: Equatable, Sendable {
        public var played: ChordKeys.Played
        public var voiced: [Int]
        public var key: Key
        public var lift = 0
    }

    public init() {}

    /// The dial turned by `steps`.
    public func turn(_ steps: Int) {
        lift = min(Self.lifts.upperBound, max(Self.lifts.lowerBound, lift + steps))
    }

    /// Every button held, from all three.
    public var held: Set<ChordButton> { Set(onController.values).union(onKeys).union(latched) }

    /// A controller's key below the split: the button it holds down or lets go. False for a key
    /// that holds no button — C, C♯, G and G♯ there are nothing.
    @discardableResult
    public func controllerKey(_ note: Int, isDown: Bool) -> Bool {
        guard let button = ChordKeys.button(forNote: note) else { return false }
        onController[note] = isDown ? button : nil
        return true
    }

    /// A button held or let go on the computer's keys.
    public func key(_ button: ChordButton, isDown: Bool) {
        if isDown { onKeys.insert(button) } else { onKeys.remove(button) }
    }

    /// A button clicked on the pad: held until it is clicked again.
    public func toggle(_ button: ChordButton) {
        if latched.remove(button) == nil { latched.insert(button) }
    }

    /// The computer's keys let go of all at once: the pad lost the keyboard, and a key that comes
    /// up somewhere else is never heard here.
    public func letGoOfKeys() { onKeys = [] }

    /// The chord `root` plays now.
    public func chord(for root: PitchClass, in context: ChordContext) -> ChordKeys.Played {
        ChordKeys.chord(root: root, in: context.key, holding: held)
    }

    /// A root struck, by `id`: the chord it plays, and the notes it is voiced on — as the sheet
    /// voices its chords, from the chord before when they are voice-led, turned by the dial.
    func strike(_ root: PitchClass, id: Int, in context: ChordContext) -> Struck {
        let played = chord(for: root, in: context)
        let before = last.map { [$0.played.chord] } ?? []
        let lifts = (last.map { [$0.lift] } ?? []) + [lift]
        let voiced = Voicing.voicings(of: before + [played.chord], as: context.voicing, lifts: lifts).last ?? []
        let struck = Struck(played: played, voiced: voiced, key: context.key, lift: lift)
        down[id] = root
        last = struck
        return struck
    }

    /// A root let go.
    func release(id: Int) { down[id] = nil }

    /// Every root let go at once: the song they were played over is being left.
    func releaseAll() { down = [:] }
}
