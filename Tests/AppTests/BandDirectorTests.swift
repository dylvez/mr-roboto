import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

/// `PersonaDirecting`, conformed.
///
/// `Cast.swift` declared four calls and said out loud that nothing conformed to them. These are the
/// tests of the conformer, and the thing every one of them is really checking is that a persona's
/// opinion reaches the user *attributed to that persona* — which is the whole reason the protocol
/// has an `openCheck` and a `mark` rather than a `fix`.
@Suite("Band: the Director the personas are driven through") @MainActor
struct BandDirectorTests {

    // MARK: Reading a sentence

    @Test("the reader names engine parameters, or says the sentence names none")
    func theReaderReadsQuantities() {
        let reader = EngineVocabularyReader()
        let context = PersonaReadingContext(tempo: 90, idiom: "boom-bap", ghostRatio: 0.3,
                                            sourceTransients: 14)

        #expect(reader.read("put the swing at 62", context: context)
            == .setSwing(percent: 62, idiom: "boom-bap", tempo: 90))
        #expect(reader.read("snare 18 ms late", context: context)
            == .displaceVoice(voice: "snare", milliseconds: 18, tempo: 90))
        #expect(reader.read("snare 18ms early", context: context)
            == .displaceVoice(voice: "snare", milliseconds: -18, tempo: 90))
        #expect(reader.read("quantise it hard", context: context) == .quantiseHard(idiom: "boom-bap"))
        #expect(reader.read("take the ghosts out", context: context)
            == .removeGhosts(currentRatio: 0.3, idiom: "boom-bap"))
        #expect(reader.read("cut it into 8 slices", context: context)
            == .chopDensity(slicesPerBar: 8, sourceTransients: 14))

        // "Dustier" is this instrument's own word, and it reads as the machine the word comes from.
        guard case .applyDegrade(let preset, _, _) = reader.read("give me something dustier", context: context) else {
            Issue.record("\"dustier\" was not read as the chain")
            return
        }
        #expect(preset == DegradeSettings.Preset.sp1200.rawValue)
        guard case .applyDegrade(let tape, _, _) = reader.read("run it through tape", context: context) else {
            Issue.record("\"tape\" was not read as the chain")
            return
        }
        #expect(tape == DegradeSettings.Preset.cassette.rawValue)

        // And a sentence that names nothing this instrument can move says so, rather than guessing.
        #expect(reader.read("make it better", context: context) == .outOfScope(what: "make it better"))
    }

    @Test("the reading context comes off the open song rather than out of the air")
    func theContextIsTheSong() throws {
        let directory = WiringFixture.temporaryDirectory("band-context")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)

        #expect(band.context.tempo == app.song?.tempo)
        #expect(band.context.sourceTransients == 4, "the chopped bar's markers are the transients")
        // 44.1 kHz in the fixture's take, so the ceiling is its Nyquist rather than a guess at zero.
        #expect(band.context.sourceBandwidthHz == 20_000 || band.context.sourceBandwidthHz == 22_050)
    }

    @Test("a sentence with no song behind it still reads, and the cast still answers")
    func proposalNeedsNoSong() async throws {
        let directory = WiringFixture.temporaryDirectory("band-nosong")
        defer { WiringFixture.remove(directory) }
        let app = AppState(store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        let band = BandDirector(app: app)
        let proposal = try await band.proposal(for: "put the swing at 80")
        #expect(proposal == .setSwing(percent: 80, idiom: "hip-hop", tempo: 90))
    }

    // MARK: A persona's line reaching the rail

    @Test("a persona's line lands in the rail attributed to that persona")
    func aPersonaSpeaks() async {
        let directory = WiringFixture.temporaryDirectory("band-rail")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)

        let answer = await band.ask("put the swing at 58")
        #expect(answer.owner == .beatmaker)
        let lines = app.log.filter { if case .persona = $0.source { return true } else { return false } }
        #expect(lines.count == 1, "exactly one persona had an opinion about swing")
        #expect(lines[0].source == .persona("Beatmaker"))
        // The rail draws a model's line in the accent because `isBand` is true for it; nothing was
        // added to the rail to make a persona work.
        #expect(lines[0].source.isBand)
        #expect(lines[0].source.label == "Beatmaker")
        #expect(!lines[0].text.isEmpty)
    }

    @Test("a refusal reaches the rail with the rule that refused it and a counter to press")
    func aPersonaRefuses() async {
        let directory = WiringFixture.temporaryDirectory("band-refusal")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)

        // 80% is past the machines' maximum: the Beatmaker's swing-domain rule refuses it.
        let answer = await band.ask("put the swing at 80")
        #expect(answer.wasRefused)
        let refusal = answer.verdicts.first { $0.verdict.isRefusal }
        #expect(refusal?.verdict.refusedByRule == "beatmaker.swing-domain")
        let line = app.log.last { if case .persona = $0.source { return true } else { return false } }
        #expect(line?.source == .persona("Beatmaker"))
        #expect(line?.detail?.contains("beatmaker.swing-domain") == true)
        // A refusal that offered nothing would be an obstacle; the counter is in the line itself.
        #expect(line?.text.contains("75") == true)
    }

    @Test("a sentence nobody in the cast can take is said to be one, rather than guessed at")
    func nobodyTakesIt() async {
        let directory = WiringFixture.temporaryDirectory("band-nobody")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)

        let answer = await band.ask("write me a bridge in D minor")
        #expect(answer.owner == nil)
        #expect(!app.log.contains { if case .persona = $0.source { return true } else { return false } })
        #expect(app.log.last?.source == .session)
        #expect(app.log.last?.text.contains("Nobody in the band") == true)
    }

    // MARK: Opening a Compare

    @Test("openCompare opens the surface, files the brief and attributes every row")
    func openingACompare() throws {
        let directory = WiringFixture.temporaryDirectory("band-open-compare")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)
        let wiring = SurfaceWiring()
        let grooves = app.versions.compactMap { version -> PartVersion? in
            if case .groove = version.kind { return version } else { return nil }
        }
        let reference = try #require(grooves.first)
        let candidates = Array(grooves.dropFirst()).map { version in
            CompareCandidate(id: version.id.description, title: version.note ?? "",
                             proposedBy: .beatmaker, rationale: "slower, and it keeps the ghosts",
                             readings: [CompareReading(.swingPercent, 58, unit: "%")],
                             version: version)
        }

        let id = try band.openCompare(
            title: "Two slower reads",
            reference: CompareReference(title: "Bar 9, as it is", kind: "what the song already has",
                                        readings: [CompareReading(.swingPercent, 50, unit: "%")],
                                        version: reference.id),
            candidates: candidates,
            features: [.swingPercent],
            levers: [.tempo, .degradeMix])

        let item = try #require(app.bench.items.first { $0.id == id })
        #expect(item.kind == .compare)
        #expect(app.bound(for: id).first == reference.id, "the reference is bound first")
        // The levers the Director validated are on the surface, in the frame's own vocabulary.
        #expect(app.levers(for: id).map(\.quantity) == [.tempo, .dust])

        guard case .ready(let model) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("the filed brief did not produce a Compare")
            return
        }
        #expect(model.candidates.count == candidates.count)
        #expect(model.candidates.allSatisfy { $0.proposedBy == .beatmaker })
        #expect(model.reference.title == "Bar 9, as it is")
    }

    @Test("a Compare judged against something the song does not hold is refused before it opens")
    func aCompareNeedsARealReference() throws {
        let directory = WiringFixture.temporaryDirectory("band-compare-refused")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)
        let grooves = app.versions.compactMap { version -> PartVersion? in
            if case .groove = version.kind { return version } else { return nil }
        }
        let candidates = grooves.map { CompareCandidate(id: $0.id.description, title: "", version: $0) }
        let opened = app.bench.items.count

        #expect(throws: DirectorChoiceProblem.self) {
            _ = try band.openCompare(title: "Nothing to beat",
                                     reference: CompareReference(title: "A remembered original",
                                                                 kind: "not in the graph"),
                                     candidates: candidates, features: [], levers: [])
        }
        // A candidate with no version behind it is refused for the same reason: a row you cannot
        // take is a row you cannot judge.
        #expect(throws: DirectorChoiceProblem.self) {
            _ = try band.openCompare(
                title: "Two labels",
                reference: CompareReference(title: "Bar 9", kind: "as it is", version: grooves[0].id),
                candidates: [CompareCandidate(id: "a", title: "A"), CompareCandidate(id: "b", title: "B")],
                features: [], levers: [])
        }
        #expect(app.bench.items.count == opened, "a refused Compare still opened something")
    }

    // MARK: A critic's finding reaching the user

    @Test("a critic's finding opens a Check and says so in the persona's own voice")
    func aFindingOpensACheck() throws {
        let directory = WiringFixture.temporaryDirectory("band-check-open")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)
        let wiring = SurfaceWiring()
        let finding = BandFixture.lateCut()
        let sample = try #require(app.versions.first { if case .sample = $0.kind { return true } else { return false } })

        let id = band.openCheck(finding)
        let item = try #require(app.bench.items.first { $0.id == id })
        #expect(item.kind == .check)
        #expect(app.bound(for: id) == [sample.id], "the Check bound to the part the finding is about")

        guard case .finding(let model) = wiring.checkFilling(for: item, app: app) else {
            Issue.record("openCheck did not file the finding")
            return
        }
        #expect(model.finding.id == finding.id)
        #expect(model.fixes.count == 2)

        // And the rail says who found it, in their own name.
        let line = try #require(app.log.last { if case .persona = $0.source { return true } else { return false } })
        #expect(line.source == .persona("Sampler"))
        #expect(line.text == finding.headline)
        #expect(line.detail?.contains(finding.measurement.description) == true)
    }

    @Test("marks land on the lane they belong to, and are never acted on")
    func marksLandOnTheLane() async throws {
        let directory = WiringFixture.temporaryDirectory("band-marks")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let band = BandDirector(app: app, wiring: wiring)
        let finding = BandFixture.lateCut()
        let before = app.versions.count

        // With no lane open the finding still has to reach the user — a dropped finding looks
        // exactly like a critic that never ran.
        band.mark([finding], on: SurfaceID())
        #expect(app.log.contains { $0.source == .persona("Sampler") && $0.text == finding.headline })
        #expect(app.versions.count == before, "marking changed the song")
    }

    @Test("a lane that is drawing a bar takes the marks rather than the rail")
    func marksReachAnOpenLane() async throws {
        let directory = WiringFixture.temporaryDirectory("band-marks-lane")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let band = BandDirector(app: app, wiring: wiring)
        let sample = try #require(app.versions.first { if case .sample = $0.kind { return true } else { return false } })

        let item = BandFixture.item(.chopLane, in: app, title: "Bar 9", bound: [sample.id])
        let binding = wiring.chopBinding(for: item, app: app)
        await binding.waitForLoad()

        // The fixture's media is not on disk, so the lane fails to resolve its bar — and a lane with
        // no bar must say a mark did not land rather than swallowing it.
        #expect(!binding.mark([BandFixture.lateCut().mark]))
        band.mark([BandFixture.lateCut()], on: item.id)
        #expect(app.log.contains { $0.source == .persona("Sampler") })
    }
}
