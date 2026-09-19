import Foundation
import Instrument
import SongGraph
import Testing

@testable import MrRobotoApp

// The guidance that says *where you are*: the path strip, the lineage crumbs, the ledger grouped by
// stage, and the primers. The same invariant as `GuidanceTests` holds here — a step that offers an
// action must open a surface when pressed — so the last test in the path suite presses every one.

@MainActor
private enum PathFixture {
    static let always: (SurfaceAction) -> Bool = { _ in true }

    /// The chop, and a dusty version of it: SP-1200 at 60%.
    static func dusty() throws -> (built: GuidanceFixture.Built, dusty: PartVersion) {
        var built = GuidanceFixture.chopped()
        let dusty = try #require(Dust.version(dirtying: built.sample!, through: [Dust.pass(.sp1200, mix: 0.6)],
                                              by: .persona("Director")))
        try built.song.append(dusty)
        return (built, dusty)
    }

    /// A beat from scratch: a groove with no record behind it.
    static func beat() throws -> Song {
        var song = GuidanceFixture.emptySong(title: "Sketch")
        try song.append(PartVersion(partID: PartID(), kind: .groove(GridModel.emptyGroove()), author: .user,
                                    operation: Operation.written, note: "Boom-bap pocket"))
        return song
    }

    static func step(_ kind: PathStep.Kind, _ steps: [PathStep]) -> PathStep? { steps.first { $0.kind == kind } }
}

@Suite("Work path: where you are") @MainActor
struct WorkPathTests {

    @Test("a song that holds a record is a flip; one that does not is a beat")
    func whichPath() throws {
        #expect(WorkPath.of(GuidanceFixture.imported().song) == .flip)
        #expect(WorkPath.of(try PathFixture.beat()) == .beat)

        var seeded = GuidanceFixture.emptySong()
        seeded.seeds.append(Seed(kind: .importedRecord(RecordID())))
        #expect(WorkPath.of(seeded) == .flip, "the seed says flip before the take has even landed")
    }

    @Test("a fresh import: the record is done and separating the stems is next")
    func afterImport() throws {
        let built = GuidanceFixture.imported()
        let steps = WorkPath.steps(for: built.song, active: nil, canPerform: PathFixture.always).steps
        #expect(steps.map(\.kind) == [.record, .stems, .chop, .groove, .chords, .bass, .dust, .arrange, .sing, .mix])
        #expect(PathFixture.step(.record, steps)?.isDone == true)
        let stems = try #require(PathFixture.step(.stems, steps))
        #expect(stems.isNext)
        #expect(stems.action?.prepare == .separateStems(of: built.take.id))
        #expect(steps.filter(\.isNext).count == 1, "one next step, never two")
    }

    @Test("with stems separated, the next step chops a bar of the drums")
    func afterSeparation() throws {
        let built = GuidanceFixture.separated()
        let steps = WorkPath.steps(for: built.song, active: nil, canPerform: PathFixture.always).steps
        #expect(PathFixture.step(.stems, steps)?.count == 4)
        let chop = try #require(PathFixture.step(.chop, steps))
        #expect(chop.isNext)
        #expect(chop.action?.prepare == .chopBar(of: built.stems["drums"]!.id))
    }

    @Test("with a chop, the next step re-grooves it in the lane; with a groove, dust is next")
    func chopThenGroove() throws {
        let chopped = GuidanceFixture.chopped()
        var steps = WorkPath.steps(for: chopped.song, active: nil, canPerform: PathFixture.always).steps
        let groove = try #require(PathFixture.step(.groove, steps))
        #expect(groove.isNext)
        #expect(groove.action == SurfaceAction(surface: .chopLane, title: PartLabel.title(of: chopped.sample!),
                                               bound: [chopped.sample!.id]))

        // With a groove, the bass is next — written under it — and chords, being optional, never are.
        let grooved = GuidanceFixture.grooved()
        steps = WorkPath.steps(for: grooved.song, active: nil, canPerform: PathFixture.always).steps
        let bass = try #require(PathFixture.step(.bass, steps))
        #expect(bass.isNext)
        #expect(bass.action?.surface == .pianoRoll)
        #expect(bass.action?.bound == [grooved.groove!.id])
        let chords = try #require(PathFixture.step(.chords, steps))
        #expect(!chords.isNext)
        #expect(chords.action?.surface == .chords, "optional, but still pressable")
        let dust = try #require(PathFixture.step(.dust, steps))
        #expect(!dust.isNext)
        #expect(dust.action?.surface == .sound)
        #expect(dust.action?.bound == [grooved.groove!.id], "dust goes on the groove before the chop")
    }

    @Test("a dusty version counts as one part, and arranging opens Structure once there is something to arrange")
    func dustAndArrange() throws {
        let (built, dusty) = try PathFixture.dusty()
        let steps = WorkPath.steps(for: built.song, active: nil, canPerform: PathFixture.always).steps
        #expect(PathFixture.step(.chop, steps)?.count == 1, "the dry chop and its dusty version are one chop")
        #expect(PathFixture.step(.dust, steps)?.count == 1)
        #expect(PathFixture.step(.dust, steps)?.action?.bound == [dusty.id])
        let arrange = try #require(PathFixture.step(.arrange, steps))
        #expect(arrange.later == nil, "arranging arrived with Gate C")
        #expect(arrange.action?.surface == .structure)
        #expect(arrange.action?.bound.isEmpty == true, "Structure draws the song, not a version")
        #expect(arrange.count == 0)
    }

    @Test("with nothing that plays there is nothing to arrange, and a form counts its sections")
    func arrangeNeedsParts() throws {
        let empty = Song(title: "Blank")
        let steps = WorkPath.steps(for: empty, active: nil, canPerform: PathFixture.always).steps
        #expect(PathFixture.step(.arrange, steps)?.action == nil)

        var song = try PathFixture.dusty().built.song
        song.sections = [Section(name: "Intro", stitch: [], lengthInBars: 4), Section(name: "Verse", stitch: [], lengthInBars: 16)]
        let arranged = WorkPath.steps(for: song, active: (kind: .structure, bound: []), canPerform: PathFixture.always).steps
        let arrange = try #require(PathFixture.step(.arrange, arranged))
        #expect(arrange.count == 2)
        #expect(arrange.isHere, "the Structure surface lights the Arrange step")
    }

    @Test("the surface you are in lights its step; Sound is dust on a chop and the kit on a sound")
    func here() throws {
        let (built, dusty) = try PathFixture.dusty()
        func lit(_ kind: SurfaceKind, _ bound: [VersionID], in song: Song) -> [PathStep.Kind] {
            WorkPath.steps(for: song, active: (kind, bound), canPerform: PathFixture.always).steps
                .filter(\.isHere).map(\.kind)
        }
        #expect(lit(.chopLane, [built.sample!.id], in: built.song) == [.chop])
        #expect(lit(.importRecord, [], in: built.song) == [.record])
        #expect(lit(.sound, [dusty.id], in: built.song) == [.dust])
        #expect(lit(.compare, [], in: built.song) == [], "an answer surface is not a step")

        let beat = try PathFixture.beat()
        #expect(lit(.sound, [], in: beat) == [.kit])
        #expect(WorkPath.steps(for: beat, active: nil, canPerform: PathFixture.always).steps.map(\.kind)
                == [.groove, .chords, .bass, .kit, .dust, .arrange, .sing, .mix])
    }

    @Test("a step the frame could not carry out offers nothing and is not next")
    func gated() throws {
        let built = GuidanceFixture.imported()
        let steps = WorkPath.steps(for: built.song, active: nil, canPerform: { $0.prepare == .none }).steps
        let stems = try #require(PathFixture.step(.stems, steps))
        #expect(stems.action == nil)
        #expect(!stems.isNext)
    }

    @Test("every step that offers an action opens a surface when pressed")
    func everyStepWorks() throws {
        let directory = GuidanceFixture.temporaryDirectory("path")
        defer { try? FileManager.default.removeItem(at: directory) }
        for built in [GuidanceFixture.separated(), GuidanceFixture.chopped(), GuidanceFixture.grooved()] {
            let app = GuidanceFixture.app(nil, in: directory)
            app.open(built.song)
            let steps = WorkPath.steps(for: try #require(app.song), active: nil, canPerform: app.canPerform).steps
            for step in steps {
                guard let action = step.action else { continue }
                let opened = try #require(app.perform(action), "\(step.kind) offered \(action.title) and it opened nothing")
                #expect(app.bench.items.contains { $0.id == opened })
            }
        }
    }
}

@Suite("Lineage crumbs") @MainActor
struct LineageCrumbTests {

    @Test("a dusty chop reads back to the record, and names the machine rather than repeating the chop")
    func dustyChop() throws {
        let (built, dusty) = try PathFixture.dusty()
        let crumbs = PartLineage.crumbs(for: dusty.id, in: built.song)
        #expect(crumbs.map(\.title) == ["Arrival", "Drums stem", "Bar 5 of drums stem", "SP-1200 at 60%"])
        #expect(crumbs.last?.action == nil, "the crumb you are on is not a link")
        #expect(crumbs.dropLast().allSatisfy { $0.action != nil }, "every crumb above it opens its part")
        #expect(crumbs.first?.action?.surface == .importRecord)
    }

    @Test("the record is anchored on the song's name alone; a beat with no record starts from its song")
    func anchors() throws {
        let built = GuidanceFixture.grooved()
        #expect(PartLineage.crumbs(for: built.take.id, in: built.song).map(\.title) == ["Arrival"])

        let beat = try PathFixture.beat()
        let groove = try #require(beat.versions.first)
        let crumbs = PartLineage.crumbs(for: groove.id, in: beat)
        #expect(crumbs.map(\.title) == ["Sketch", "Boom-bap pocket"])
        #expect(crumbs.first?.action == nil)
    }

    @Test("a version that is not in the song has no lineage")
    func unknown() {
        #expect(PartLineage.crumbs(for: VersionID(), in: GuidanceFixture.grooved().song).isEmpty)
    }

    @Test("the chain is spoken as the machine and the amount, nearest the listener first")
    func spoken() {
        #expect(Dust.spoken([]) == "Clean")
        #expect(Dust.spoken([Dust.pass(.sp1200, mix: 0.6)]) == "SP-1200 at 60%")
        #expect(Dust.spoken([Dust.pass(.sp1200, mix: 0.6), Dust.pass(.cassette, mix: 1)])
                == "Cassette at 100% over SP-1200 at 60%")
    }
}

@Suite("Parts ledger: grouped by stage") @MainActor
struct LedgerGroupTests {

    @Test("parts sit under the path's stage names, in path order")
    func stages() {
        let groups = LedgerGroups.groups(for: GuidanceFixture.everyKind().song)
        #expect(groups.map(\.title) == ["Record", "Stems", "Chops", "Grooves", "Kit", "Chords", "Bass", "Written", "Mix"])
        #expect(groups.first { $0.title == "Record" }?.parts.count == 2, "the take and its analysis")
        #expect(groups.first { $0.title == "Stems" }?.parts.count == 4)
        #expect(groups.first { $0.title == "Chords" }?.parts.count == 1)
        #expect(groups.first { $0.title == "Bass" }?.parts.count == 1)
        #expect(groups.first { $0.title == "Written" }?.parts.count == 2, "melody and lyric, which no surface edits yet")
    }

    @Test("a chop and its dusty version are one row with two versions, each named for what it is")
    func nested() throws {
        let (built, dusty) = try PathFixture.dusty()
        let chops = try #require(LedgerGroups.groups(for: built.song).first { $0.title == "Chops" })
        #expect(chops.parts.count == 1)
        let part = try #require(chops.parts.first)
        #expect(part.versions.map(\.id) == [built.sample!.id, dusty.id])
        #expect(LedgerGroups.versionLabel(part.versions[0], parent: nil) == "clean")
        #expect(LedgerGroups.versionLabel(part.versions[1], parent: part.versions[0]) == "SP-1200 at 60%")
        #expect(LedgerGroups.action(for: dusty, in: built.song)?.surface == .sound,
                "a dusty version opens where its dust is")
        #expect(LedgerGroups.action(for: built.sample!, in: built.song)?.surface == .chopLane)
    }
}

@Suite("Primers") @MainActor
struct PrimerTests {

    private func scratch() throws -> UserDefaults {
        let name = "mrroboto.primers.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("every surface says what it makes")
    func everySurface() {
        for kind in SurfaceKind.allCases {
            let primer = Primer.text(for: kind)
            #expect(!primer.body.isEmpty)
            #expect(primer.title == kind.rawValue)
        }
    }

    @Test("a primer shows until dismissed, stays dismissed across launches, and ? brings it back")
    func lifecycle() throws {
        let defaults = try scratch()
        let store = PrimerStore(defaults: defaults)
        #expect(store.isShowing(.chopLane))

        store.dismiss(.chopLane)
        #expect(!store.isShowing(.chopLane))
        #expect(!PrimerStore(defaults: defaults).isShowing(.chopLane), "remembered for the next launch")
        #expect(PrimerStore(defaults: defaults).isShowing(.grid), "dismissing one leaves the others")

        store.toggle(.chopLane)
        #expect(store.isShowing(.chopLane))
        store.toggle(.chopLane)
        #expect(!store.isShowing(.chopLane))

        store.resetAll()
        #expect(store.isShowing(.chopLane))
        #expect(PrimerStore(defaults: defaults).isShowing(.chopLane))
    }
}
