import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// The five rules, as tests.
//
// Everything here runs against a real `AppState` over a real temporary library, because the last
// gate a choice goes through is `AppState.canPerform` — the same one Gate A's derived proposals go
// through — and a stub would be testing a copy of it rather than it.

@Suite("Director: choosing a surface") @MainActor
struct DirectorChoiceTests {

    /// A song with a record, stems, a chop, a sound, and four grooves to compare.
    struct Built {
        var app: AppState
        var stage: AppStateStage
        var directory: URL
        var sample: VersionID
        var sound: VersionID
        var take: VersionID
        var grooves: [VersionID]
    }

    static func build() -> Built {
        let directory = GuidanceFixture.temporaryDirectory("choice")
        var built = GuidanceFixture.grooved()
        var grooves = [built.groove!.id]
        for name in ["Slower", "Dustier", "Both"] {
            let extra = built.sample!.spawning(.groove(GridModel.emptyGroove()), by: .persona("Director"),
                                               operation: Operation.regroove, note: name)
            try? built.song.append(extra)
            grooves.append(extra.id)
        }
        let sound = PartVersion(partID: PartID(), kind: .sound(SoundState().sound), author: .user,
                                operation: Operation.written, note: "tr808 kick")
        try? built.song.append(sound)

        let app = GuidanceFixture.app(nil, in: directory)
        app.open(built.song)
        return Built(app: app, stage: AppStateStage(app), directory: directory,
                     sample: built.sample!.id, sound: sound.id, take: built.take.id, grooves: grooves)
    }

    static func clean(_ built: Built) { try? FileManager.default.removeItem(at: built.directory) }

    // MARK: Rule 1 — the notation

    @Test("A surface only takes a part it can draw")
    func notation() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        // A chop belongs in the chop lane.
        let lane = try DirectorSurfaceChoice.make(surface: .chopLane, title: "Bar 5 of Arrival",
                                                  fill: .parts([built.sample]),
                                                  because: "The bar the drums come in on.",
                                                  in: built.stage)
        #expect(lane.action.surface == .chopLane)
        #expect(lane.action.bound == [built.sample])

        // A take does not belong on Sound: dust is carried by a chop or a groove, not by the record.
        // This is rule 1 as an error rather than as a style note. (A groove on Sound is legal now —
        // it opens the groove's chain; see `DustTests`.)
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .sound, title: "Wrong",
                                           fill: .parts([built.take]),
                                           because: "", in: built.stage)
        }
        // Nor does a groove belong in the Chop lane.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .chopLane, title: "Wrong",
                                           fill: .parts([built.grooves[0]]),
                                           because: "", in: built.stage)
        }
        // And neither does a version the song has never heard of.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .grid, title: "Ghost",
                                           fill: .parts([VersionID(rawValue: UUID())]),
                                           because: "", in: built.stage)
        }
    }

    @Test("Every Gate A surface has a notation, and the answer surfaces take anything")
    func everySurfaceSaysWhatItDraws() {
        #expect(SurfaceKind.grid.notation == [.groove])
        #expect(SurfaceKind.sound.notation == [.sound, .sample, .groove])
        #expect(SurfaceKind.chopLane.notation.contains(.sample))
        #expect(SurfaceKind.importRecord.notation.contains(.audio))
        for kind in SurfaceKind.answers {
            #expect(kind.notation == Set(PartType.allCases))
            #expect(kind.isAnswer)
        }
        for kind in SurfaceKind.gateA { #expect(!kind.isAnswer) }
    }

    // MARK: Rule 2 — alternatives get a Compare, one finding gets a Check

    @Test("A Compare fill only goes on a Compare, and a part fill never does")
    func shapeFitsTheSurface() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .grid, title: "Not a compare",
                fill: .compare(against: built.grooves[0], candidates: Array(built.grooves[1...])),
                because: "", in: built.stage)
        }
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .compare, title: "Not parts",
                                           fill: .parts(built.grooves),
                                           because: "", in: built.stage)
        }
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .check, title: "No finding",
                                           fill: .check(of: built.grooves[0], finding: "  "),
                                           because: "", in: built.stage)
        }
    }

    @Test("A Check names one part and the one thing found about it")
    func check() throws {
        let built = Self.build()
        defer { Self.clean(built) }
        let check = try DirectorSurfaceChoice.make(
            surface: .check, title: "The snare is late",
            fill: .check(of: built.grooves[0], finding: "Slice 2 lands 31 ms after the backbeat."),
            because: "One finding, flagged rather than fixed.", in: built.stage)
        #expect(check.fill.bound == [built.grooves[0]])
        #expect(check.fill.reference == built.grooves[0])
    }

    // MARK: Rule 4 — the reference stays at the top

    @Test("A Compare puts what the candidates are judged against first, and never among them")
    func theReferenceIsFirstAndSeparate() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        let compare = try DirectorSurfaceChoice.make(
            surface: .compare, title: "Three slower reads",
            fill: .compare(against: built.grooves[0], candidates: Array(built.grooves[1...3])),
            because: "Each one is the same bar on a different feel.", in: built.stage)

        // The binding the frame stores is reference-first. That ordering is the contract the
        // Compare surface reads, and it is produced by the type rather than assembled by hand.
        #expect(compare.action.bound.first == built.grooves[0])
        #expect(compare.action.bound.count == 4)
        #expect(compare.fill.reference == built.grooves[0])

        // Judged against one of its own candidates is not a badly-configured Compare, it is refused.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .compare, title: "Itself",
                fill: .compare(against: built.grooves[1], candidates: Array(built.grooves[1...3])),
                because: "", in: built.stage)
        }
        // Two of the same candidate is not two candidates.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .compare, title: "Twice",
                fill: .compare(against: built.grooves[0], candidates: [built.grooves[1], built.grooves[1]]),
                because: "", in: built.stage)
        }
        // One candidate is not a comparison.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .compare, title: "Alone",
                fill: .compare(against: built.grooves[0], candidates: [built.grooves[1]]),
                because: "", in: built.stage)
        }
        // Like against like: a groove and a sound are not alternatives to each other.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .compare, title: "Apples and oranges",
                fill: .compare(against: built.grooves[0], candidates: [built.grooves[1], built.sound]),
                because: "", in: built.stage)
        }
    }

    // MARK: Rule 5 — at most two levers, and only audible ones

    @Test("Two levers is the limit, each one a quantity the surface can move, each value in range")
    func levers() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        let ok = try DirectorSurfaceChoice.make(
            surface: .grid, title: "Motown, 120",
            fill: .parts([built.grooves[0]]),
            levers: [SurfaceLever(quantity: .swing, label: "Swing", value: 58),
                     SurfaceLever(quantity: .velocity, label: "How hard", value: 0.8)],
            because: "Two things you can hear.", in: built.stage)
        #expect(ok.levers.count == 2)
        #expect(ok.levers[0].line == "Swing · 58 %")

        // Three is a control panel.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .grid, title: "Too many",
                fill: .parts([built.grooves[0]]),
                levers: [SurfaceLever(quantity: .swing, label: "a", value: 55),
                         SurfaceLever(quantity: .velocity, label: "b", value: 1),
                         SurfaceLever(quantity: .tempo, label: "c", value: 90)],
                because: "", in: built.stage)
        }
        // Swing means nothing on the Sound surface.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .sound, title: "Nonsense",
                fill: .parts([built.sound]),
                levers: [SurfaceLever(quantity: .swing, label: "Swing", value: 60)],
                because: "", in: built.stage)
        }
        // A value outside the range is a knob that does nothing or breaks something.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .grid, title: "Out of range",
                fill: .parts([built.grooves[0]]),
                levers: [SurfaceLever(quantity: .swing, label: "Swing", value: 140)],
                because: "", in: built.stage)
        }
        // Two knobs on the same quantity is one knob and a decoy.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(
                surface: .grid, title: "Twice",
                fill: .parts([built.grooves[0]]),
                levers: [SurfaceLever(quantity: .swing, label: "a", value: 55),
                         SurfaceLever(quantity: .swing, label: "b", value: 60)],
                because: "", in: built.stage)
        }
    }

    @Test("There is no way to name a quantity the instrument cannot move")
    func everyQuantityIsAudible() {
        // The closed enum *is* the rule: "vibe" and "energy" are not expressible, and every case
        // that does exist has a range, a home and a sentence a model can choose by.
        for quantity in SurfaceLever.Quantity.allCases {
            #expect(!quantity.surfaces.isEmpty, "\(quantity.rawValue) belongs nowhere")
            #expect(quantity.range.lowerBound < quantity.range.upperBound)
            #expect(quantity.sentence.count > 10)
            for surface in quantity.surfaces {
                #expect(!DirectorSurfaceChoice.quantities(on: surface).isEmpty)
            }
        }
        #expect(SurfaceLever.Quantity(rawValue: "vibe") == nil)
    }

    // MARK: The last gate

    @Test("An unperformable choice cannot be built, so nothing downstream has to filter it")
    func theFrameHasTheLastWord() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        // A song that holds nothing: every id in the fixture is now a stranger, and every choice
        // that names one is refused at construction rather than at the click.
        built.app.open(Song(title: "Empty", tempo: 120))
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .chopLane, title: "Gone",
                                           fill: .parts([built.sample]),
                                           because: "", in: built.stage)
        }
        // And nothing bound at all is not a surface either.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .grid, title: "Empty",
                                           fill: .parts([]), because: "", in: built.stage)
        }
    }

    @Test("A choice carries a title, and an untitled panel is refused")
    func titles() throws {
        let built = Self.build()
        defer { Self.clean(built) }
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .grid, title: "   ",
                                           fill: .parts([built.grooves[0]]),
                                           because: "", in: built.stage)
        }
    }

    // MARK: A proposal is a validated choice

    @Test("A proposal made from a choice is performable, and the rail renders it unchanged")
    func proposalsArePerformable() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        let choice = try DirectorSurfaceChoice.make(
            surface: .grid, title: "Motown, 120", fill: .parts([built.grooves[0]]),
            because: "The groove the chop already made.", in: built.stage)
        let offered = DirectorProposal(choice: choice, title: "Open it in the Grid")

        #expect(built.app.canPerform(offered.proposal.action))
        #expect(offered.proposal.source == .director)
        #expect(offered.proposal.source.label == "The Director")
        #expect(offered.proposal.rationale == "The groove the chop already made.")

        built.app.director = [offered.proposal]
        #expect(built.app.proposals.count == 1)
        let id = try #require(built.app.perform(offered.proposal.action))
        #expect(built.app.bench.items.first { $0.id == id }?.kind == .grid)
    }

    // MARK: Rule 3 — three surfaces is the whole bench

    @Test("One answer may open three surfaces and no more")
    func threeIsTheBench() async throws {
        let built = Self.build()
        defer { Self.clean(built) }
        let pad = DirectorStagePad()
        await pad.begin()

        for title in ["one", "two", "three"] {
            let choice = try DirectorSurfaceChoice.make(surface: .grid, title: title,
                                                        fill: .parts([built.grooves[0]]),
                                                        because: "", in: built.stage)
            try await pad.record(choice)
        }
        #expect(await pad.opened.count == 3)
        #expect(DirectorStagePad.maximumOpens == 3)

        let fourth = try DirectorSurfaceChoice.make(surface: .grid, title: "four",
                                                    fill: .parts([built.grooves[0]]),
                                                    because: "", in: built.stage)
        await #expect(throws: DirectorChoiceProblem.self) { try await pad.record(fourth) }
    }

    // MARK: Opening one

    @Test("Opening a choice binds the surface and hangs its levers on it")
    func openingCarriesTheLevers() throws {
        let built = Self.build()
        defer { Self.clean(built) }

        let choice = try DirectorSurfaceChoice.make(
            surface: .compare, title: "Three slower reads",
            fill: .compare(against: built.grooves[0], candidates: Array(built.grooves[1...3])),
            levers: [SurfaceLever(quantity: .tempo, label: "Slower", value: 82),
                     SurfaceLever(quantity: .dust, label: "Dustier", value: 0.6)],
            because: "Same bar, three feels, judged against what the song already has.",
            in: built.stage)

        let id = try #require(built.stage.open(choice))
        #expect(built.app.bound(for: id) == [built.grooves[0]] + Array(built.grooves[1...3]))
        #expect(built.app.levers(for: id).map(\.quantity) == [.tempo, .dust])
        #expect(built.app.bench.items.first { $0.id == id }?.kind == .compare)

        // Closing takes the levers with it: a lever without a surface is a control on nothing.
        built.app.closeSurface(id)
        #expect(built.app.levers(for: id).isEmpty)
    }
}

// MARK: - Attribution

@Suite("Director: who said it") @MainActor
struct DirectorAttributionTests {

    @Test("Four voices, and the two a model wrote are marked as such")
    func voices() {
        #expect(SessionEntry.Source.you.label == "You")
        #expect(SessionEntry.Source.session.label == "Session")
        #expect(SessionEntry.Source.director.label == "Director")
        #expect(SessionEntry.Source.persona("Cass").label == "Cass")

        #expect(!SessionEntry.Source.you.isBand)
        #expect(!SessionEntry.Source.session.isBand)
        #expect(SessionEntry.Source.director.isBand)
        #expect(SessionEntry.Source.persona("Cass").isBand)

        // A persona is not the Director wearing a name, and the log must not conflate them.
        #expect(SessionEntry.Source.director != SessionEntry.Source.persona("Director"))
        // An unnamed persona still says something rather than printing an empty label.
        #expect(SessionEntry.Source.persona("").label == "The band")
    }

    @Test("Every line in the rail carries its source, and the log keeps them apart")
    func theLogKeepsThemApart() {
        let app = FrameFixture.state()
        app.note(.you, "Chop the drums from bar 9")
        app.note(.director, "Cut bar 9 into eight pieces.")
        app.note(.persona("Cass"), "The hat is doing too much work.")
        app.note(.session, "Closed Grid to make room")

        #expect(app.log.map(\.source) == [.you, .director, .persona("Cass"), .session])
        #expect(app.log.filter(\.source.isBand).count == 2)
        #expect(app.log.map(\.source.label) == ["You", "Director", "Cass", "Session"])
    }

    @Test("A proposal says who is proposing, and the three sources read differently")
    func proposalSources() {
        #expect(Proposal.Source.session.label == "What next")
        #expect(Proposal.Source.director.label == "The Director")
        #expect(Proposal.Source.persona("Cass").label == "Cass")
    }
}
