import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// A loop played another way for a section: what each treatment keeps, and what it leaves alone.
@Suite("Variations")
struct VariationTests {

    static func row(_ voice: DrumVoice, _ text: String) -> GroovePattern {
        GroovePattern(voice: voice, steps: text.map { $0 == "X" ? .accent : $0 == "x" ? .normal : $0 == "g" ? .ghost : .rest })
    }

    /// One bar of house: four on the floor, claps on two and four, hats, a shaker.
    static let house = Groove(stepsPerBar: 16, bars: 1, swing: Swing(percent: 56).factor, patterns: [
        row(.kick, "X...X...X...X..."),
        row(.clap, "....X.......X..."),
        row(.closedHat, "x.gxx.gxx.gxx.gx"),
        row(.shaker, "gxgxgxgxgxgxgxgx"),
    ], feel: GrooveFeel(name: "Classic House", seed: 7))

    /// A kick and a snare and nothing else.
    static let bare = Groove(stepsPerBar: 16, bars: 1, patterns: [
        row(.kick, "X.......X......."),
        row(.snare, "....X.......X..."),
    ])

    private func steps(_ groove: Groove?, _ voice: DrumVoice) -> [VelocityTier] {
        groove?.patterns.first { $0.voice == voice }?.steps ?? []
    }

    private func voices(_ groove: Groove?) -> Set<DrumVoice> { Set(groove?.patterns.map(\.voice) ?? []) }

    // MARK: Roles

    @Test("a section's name says what it is for, whatever number follows it")
    func roles() {
        #expect(SectionRole.named("Intro") == .intro)
        #expect(SectionRole.named("Intro 2") == .intro)
        #expect(SectionRole.named("Verse 1") == .verse)
        #expect(SectionRole.named("Pre-Chorus") == .pre)
        #expect(SectionRole.named("Post-Chorus") == .hook)
        #expect(SectionRole.named("Chorus") == .hook)
        #expect(SectionRole.named("Hook") == .hook)
        #expect(SectionRole.named("Drop Variation") == .drop)
        #expect(SectionRole.named("Breakdown") == .breakdown)
        #expect(SectionRole.named("Break") == .breakdown)
        #expect(SectionRole.named("Build") == .build)
        #expect(SectionRole.named("Rise") == .build)
        #expect(SectionRole.named("Bridge") == .bridge)
        #expect(SectionRole.named("B") == .bridge)
        #expect(SectionRole.named("A") == .verse)
        #expect(SectionRole.named("Refrão central") == .hook)
        #expect(SectionRole.named("Coro-pregón") == .hook)
        #expect(SectionRole.named("Coda") == .outro)
        #expect(SectionRole.named("Outro") == .outro)
        #expect(SectionRole.named("Solos") == .solo)
        #expect(SectionRole.named("Groove") == .groove)
        #expect(SectionRole.named("Main") == .groove)
        #expect(SectionRole.named("Whatever this is") == .groove)
        // A word inside another is not the word: "Theme" holds no "the", a "Bandstand" no "b".
        #expect(SectionRole.named("Bandstand") == .groove)
    }

    // MARK: Drums

    @Test("thinned is the kick and what keeps time; the backbeat waits")
    func thin() {
        let thin = GrooveVariation.vary(Self.house, as: .thin, bars: 8, beatsPerBar: 4)
        #expect(voices(thin) == [.kick, .closedHat, .shaker])
        #expect(steps(thin, .kick) == steps(Self.house, .kick))
        #expect(thin?.feel == Self.house.feel)
        #expect(thin?.swing == Self.house.swing)
    }

    @Test("with nothing to keep time, thinned keeps the backbeat a step down")
    func thinBare() {
        let thin = GrooveVariation.vary(Self.bare, as: .thin, bars: 8, beatsPerBar: 4)
        #expect(voices(thin) == [.kick, .snare])
        #expect(steps(thin, .snare)[4] == .normal)
    }

    @Test("a breakdown has no kick, the claps softer, the shaker as it was")
    func noKick() {
        let broken = GrooveVariation.vary(Self.house, as: .noKick, bars: 16, beatsPerBar: 4)
        #expect(!voices(broken).contains(.kick))
        #expect(steps(broken, .clap)[4] == .normal)
        #expect(steps(broken, .closedHat)[0] == .ghost)
        #expect(steps(broken, .shaker) == steps(Self.house, .shaker))
    }

    @Test("a groove that is only a kick has no breakdown in it")
    func noKickOfAKick() {
        let kick = Groove(stepsPerBar: 16, bars: 1, patterns: [Self.row(.kick, "X...X...X...X...")])
        #expect(GrooveVariation.vary(kick, as: .noKick, bars: 8, beatsPerBar: 4) == nil)
    }

    @Test("a build is written through the section: quarters, eighths, sixteenths, and no kick")
    func build() throws {
        let build = try #require(GrooveVariation.vary(Self.house, as: .build, bars: 8, beatsPerBar: 4))
        #expect(build.bars == 8)
        #expect(!voices(build).contains(.kick))
        // The loop claps, so the roll is on the clap.
        let roll = steps(build, .clap)
        #expect(roll.count == 128)
        #expect(Array(roll[0..<16]) == Self.row(.clap, "g...g...g...g...").steps)
        #expect(Array(roll[48..<64]) == Self.row(.clap, "x...x...x...x...").steps)
        #expect(Array(roll[64..<80]) == Self.row(.clap, "x.x.x.x.x.x.x.x.").steps)
        #expect(Array(roll[96..<112]) == Self.row(.clap, "xxxxxxxxxxxxxxxx").steps)
        #expect(Array(roll[112..<128]) == Self.row(.clap, "XXXXXXXXXXXXXXXX").steps)
        #expect(steps(build, .shaker).count == 128)
        // 56% is loosening, not a shuffle: the roll is straight.
        #expect(build.swing == 0)
    }

    @Test("a shuffle's build stays a shuffle, and a section past sixteen bars has no roll written through it")
    func buildSwungAndLong() throws {
        var shuffle = Self.house
        shuffle.swing = Swing.triplet.factor
        let build = try #require(GrooveVariation.vary(shuffle, as: .build, bars: 16, beatsPerBar: 4))
        #expect(build.swing == shuffle.swing)
        #expect(build.bars == 16)
        #expect(GrooveVariation.vary(shuffle, as: .build, bars: 32, beatsPerBar: 4) == nil)
        #expect(GrooveVariation.vary(shuffle, as: .push, bars: 24, beatsPerBar: 4) == nil)
        #expect(BassVariation.vary(Self.line, as: .pulse, chords: Self.chords, bars: 24, beatsPerBar: 4) == nil)
    }

    @Test("a push is the loop, with the snare on every beat of its last two bars")
    func push() throws {
        let push = try #require(GrooveVariation.vary(Self.bare, as: .push, bars: 4, beatsPerBar: 4))
        #expect(push.bars == 4)
        #expect(Array(steps(push, .snare)[0..<16]) == steps(Self.bare, .snare))
        #expect(Array(steps(push, .snare)[32..<48]) == Self.row(.snare, "x...X...x...X...").steps)
        #expect(Array(steps(push, .snare)[48..<64]) == Self.row(.snare, "X...X...X...X...").steps)
        #expect(Array(steps(push, .kick)[48..<64]) == steps(Self.bare, .kick))
    }

    @Test("a lift adds what the loop does not have: an open hat off the beat for dance music")
    func liftElectronic() throws {
        let lift = try #require(GrooveVariation.vary(Self.house, as: .lift, bars: 16, beatsPerBar: 4, electronic: true))
        #expect(steps(lift, .openHat) == Self.row(.openHat, "..x...x...x...x.").steps)
        // The closed hat gives way where the open one sounds.
        #expect(steps(lift, .closedHat) == Self.row(.closedHat, "x..xx..xx..xx..x").steps)
        #expect(steps(lift, .kick) == steps(Self.house, .kick))
        #expect(!voices(lift).contains(.tambourine))
    }

    @Test("two layers for a drop, and a band reaches for the tambourine first")
    func liftLayers() throws {
        let drop = try #require(GrooveVariation.vary(Self.house, as: .lift, bars: 16, beatsPerBar: 4, layers: 2, electronic: true))
        #expect(voices(drop).isSuperset(of: [.openHat, .tambourine]))
        let band = try #require(GrooveVariation.vary(Self.bare, as: .lift, bars: 8, beatsPerBar: 4))
        #expect(steps(band, .tambourine) == Self.row(.tambourine, "x.g.x.g.x.g.x.g.").steps)
        #expect(!voices(band).contains(.openHat))
    }

    @Test("a lift in triplets puts the off-beat on the last of the three")
    func liftTriplets() throws {
        let shuffle = Groove(stepsPerBar: 12, bars: 1, patterns: [
            Self.row(.kick, "X.....X....."), Self.row(.snare, "...X.....X.."),
        ])
        let lift = try #require(GrooveVariation.vary(shuffle, as: .lift, bars: 8, beatsPerBar: 4))
        #expect(steps(lift, .tambourine) == Self.row(.tambourine, "x.gx.gx.gx.g").steps)
    }

    @Test("a bridge moves the hats to the ride, and a loop with no hats has no such bridge")
    func ride() throws {
        let ride = try #require(GrooveVariation.vary(Self.house, as: .ride, bars: 8, beatsPerBar: 4))
        #expect(steps(ride, .ride) == steps(Self.house, .closedHat))
        #expect(!voices(ride).contains(.closedHat))
        #expect(GrooveVariation.vary(Self.bare, as: .ride, bars: 8, beatsPerBar: 4) == nil)
    }

    @Test("an empty groove has no variations")
    func empty() {
        let empty = Groove(stepsPerBar: 16, bars: 1, patterns: [Self.row(.kick, "................")])
        for treatment in GrooveTreatment.allCases {
            #expect(GrooveVariation.vary(empty, as: treatment, bars: 8, beatsPerBar: 4) == nil)
        }
    }

    // MARK: Bass

    static func n(_ midi: Int, _ start: Double, _ duration: Double, _ velocity: Int = 100) -> NoteEvent {
        NoteEvent(pitch: Pitch(midi: midi), start: start, duration: duration, velocity: velocity)
    }

    /// Two bars of eighths on A then F, each a little behind the beat.
    static let line = Bassline(notes: (0..<16).map { i in
        n(i < 8 ? 45 : 41, Double(i) * 0.5 + 0.05, 0.4, i % 2 == 0 ? 100 : 80)
    }, sound: "finger", key: Key(parsing: "A minor"), lengthInBars: 2, hands: "palladino")

    static let chords = [ChordSpan(Chord(parsing: "Am7")!, beats: 4), ChordSpan(Chord(parsing: "Fmaj7")!, beats: 4)]

    @Test("lighter is half the notes, the ones on the bar and the middle of it")
    func light() throws {
        let light = try #require(BassVariation.vary(Self.line, as: .light, bars: 8, beatsPerBar: 4))
        #expect(light.notes.count == 8)
        #expect(light.notes.prefix(4).map(\.start) == [0.05, 1.05, 2.05, 3.05])
        #expect(light.sound == "finger")
        #expect(light.hands == "palladino")
        #expect(light.lengthInBars == 2)
    }

    @Test("held roots follow the chords, in the line's own octave")
    func held() throws {
        let held = try #require(BassVariation.vary(Self.line, as: .held, chords: Self.chords, bars: 16, beatsPerBar: 4))
        #expect(held.notes.map(\.pitch.midi) == [45, 41])
        #expect(held.notes.map(\.start) == [0, 4])
        #expect(held.notes.allSatisfy { $0.duration > 3.5 })
        #expect(held.lengthInBars == 2)
    }

    @Test("with no chords the roots are what each bar of the line opens on")
    func heldWithoutChords() throws {
        let held = try #require(BassVariation.vary(Self.line, as: .held, bars: 16, beatsPerBar: 4))
        #expect(held.notes.map(\.pitch.midi) == [45, 41])
    }

    @Test("a pulse is eighths on the root through the section, louder as it goes")
    func pulse() throws {
        let pulse = try #require(BassVariation.vary(Self.line, as: .pulse, chords: Self.chords, bars: 4, beatsPerBar: 4))
        #expect(pulse.notes.count == 32)
        #expect(pulse.lengthInBars == 4)
        #expect(pulse.notes[0].pitch.midi == 45)
        #expect(pulse.notes[8].pitch.midi == 41)
        #expect(pulse.notes[16].pitch.midi == 45)
        #expect(pulse.notes.last!.velocity > pulse.notes[0].velocity + 30)
    }

    @Test("a line of one note a bar has nothing lighter in it")
    func lightOfLittle() {
        let sparse = Bassline(notes: [Self.n(45, 0, 3.5), Self.n(41, 4, 3.5)], lengthInBars: 2)
        #expect(BassVariation.vary(sparse, as: .light, bars: 8, beatsPerBar: 4) == nil)
    }

    // MARK: The tune

    static let tune = Melody(notes: [n(72, 0, 1), n(74, 1, 1), n(76, 2, 2), n(79, 4, 1), n(76, 5, 1), n(72, 6, 1.5)], lengthInBars: 2)

    @Test("lifted is the tune, then the tune an octave up")
    func lifted() throws {
        let lift = try #require(TuneVariation.vary(Self.tune, as: .lift, bars: 8, beatsPerBar: 4))
        #expect(lift.lengthInBars == 4)
        #expect(lift.notes.count == 12)
        #expect(Array(lift.notes.prefix(6)) == Self.tune.notes)
        #expect(lift.notes[6].pitch.midi == 84)
        #expect(lift.notes[6].start == 8)
    }

    @Test("in a section with no room to say it twice, lifted is the tune an octave up")
    func raised() throws {
        let lift = try #require(TuneVariation.vary(Self.tune, as: .lift, bars: 2, beatsPerBar: 4))
        #expect(lift.lengthInBars == 2)
        #expect(lift.notes.map(\.pitch.midi) == Self.tune.notes.map { $0.pitch.midi + 12 })
    }

    @Test("a tune already at the top of the instrument is not lifted")
    func liftedTooHigh() {
        let high = Melody(notes: [Self.n(90, 0, 1), Self.n(88, 1, 1)], lengthInBars: 1)
        #expect(TuneVariation.vary(high, as: .lift, bars: 8, beatsPerBar: 4) == nil)
    }

    @Test("sparse is the first half, quieter, and as long as the tune was")
    func sparse() throws {
        let sparse = try #require(TuneVariation.vary(Self.tune, as: .sparse, bars: 8, beatsPerBar: 4))
        #expect(sparse.notes.map(\.pitch.midi) == [72, 74, 76])
        #expect(sparse.notes.allSatisfy { $0.velocity == 80 })
        #expect(sparse.lengthInBars == 2)
    }
}
