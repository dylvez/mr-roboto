import Analysis
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

/// Every tool, called directly, against the real engines and with no model anywhere.
///
/// The chopper, the classifier, the feel library, the re-groove engine and the song graph are the
/// shipping ones. Only the two things that need a downloaded model — whole-track analysis and stem
/// separation — are stood in for, and what stands in for them returns real data.
@Suite("Director: the tools")
@MainActor
struct DirectorToolTests {

    /// A session: a temporary library, four bars of synthetic break on disk, and a song to record
    /// into. Torn down by the caller.
    struct Session {
        var workbench: DirectorWorkbench
        var workspace: DirectorScratchWorkspace
        var url: URL
        var directory: URL
        var store: LibraryStore
    }

    private func makeSession(bars: Int = 4) throws -> Session {
        let url = try DirectorAudioFixture.write(DirectorAudioFixture.fourBars(), named: "break.wav")
        let library = url.deletingLastPathComponent().appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = LibraryStore(directoryURL: library)
        return Session(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: bars)),
                       workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song(), store: store),
                       url: url,
                       directory: url.deletingLastPathComponent(),
                       store: store)
    }

    private func tearDown(_ session: Session) {
        try? FileManager.default.removeItem(at: session.directory)
    }

    // MARK: import_record

    @Test("import_record reads a file, stores it, and hands back a handle")
    func importRecord() async throws {
        let session = try makeSession()
        defer { tearDown(session) }

        let tool = ImportRecordTool(workbench: session.workbench, workspace: session.workspace)
        let output = try await tool.run(.init(path: session.url.path))

        #expect(output.audio == "audio-1")
        #expect(output.name == "break")
        #expect(output.sampleRate == DirectorAudioFixture.sampleRate)
        #expect(output.channels == 2)
        #expect(abs(output.durationSeconds - 4 * 4 * 60 / DirectorAudioFixture.tempo) < 0.01)
        #expect(output.media != nil, "there is a library, so it was stored")
        #expect(output.note == nil)
    }

    @Test("import_record on a path that is not there says so rather than throwing something opaque")
    func importMissingFile() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let tool = ImportRecordTool(workbench: session.workbench, workspace: session.workspace)
        await #expect(throws: DirectorToolFailure.self) {
            _ = try await tool.run(.init(path: "/nowhere/at/all.wav"))
        }
    }

    @Test("import_record without a library still works, and says the file was not stored")
    func importWithoutLibrary() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let workspace = DirectorScratchWorkspace(song: DirectorSongFixture.song(), store: nil)
        let tool = ImportRecordTool(workbench: session.workbench, workspace: workspace)
        let output = try await tool.run(.init(path: session.url.path))
        #expect(output.media == nil)
        #expect(output.note?.contains("no library directory") == true)
    }

    // MARK: analyse_record and list_bars

    @Test("analyse_record finds the grid and keeps it for the tools that come after")
    func analyseRecord() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await imported(session)

        let output = try await AnalyseRecordTool(workbench: session.workbench).run(.init(audio: handle))
        #expect(output.audio == handle)
        #expect(output.tempo == DirectorAudioFixture.tempo)
        #expect(output.barCount == 4)
        #expect(output.beatCount == 16)
        #expect(await session.workbench.hasAnalysis(handle))
    }

    @Test("list_bars numbers the bars and windows them")
    func listBars() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await analysed(session)

        let all = try await ListBarsTool(workbench: session.workbench)
            .run(.init(audio: handle, fromBar: nil, count: nil))
        #expect(all.barCount == 4)
        #expect(all.bars.map(\.index) == [0, 1, 2, 3])
        let barLength = 4 * 60 / DirectorAudioFixture.tempo
        #expect(abs(all.bars[1].startSeconds - barLength) < 0.02)

        let window = try await ListBarsTool(workbench: session.workbench)
            .run(.init(audio: handle, fromBar: 2, count: 1))
        #expect(window.bars.map(\.index) == [2])
    }

    @Test("list_bars past the end says how many there are")
    func listBarsPastTheEnd() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await analysed(session)
        await #expect(throws: DirectorToolFailure.self) {
            _ = try await ListBarsTool(workbench: session.workbench)
                .run(.init(audio: handle, fromBar: 99, count: 4))
        }
    }

    @Test("list_bars before analysis points at the tool that would fix it")
    func listBarsBeforeAnalysis() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await imported(session)
        do {
            _ = try await ListBarsTool(workbench: session.workbench)
                .run(.init(audio: handle, fromBar: nil, count: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("analyse_record"))
        }
    }

    // MARK: separate_stems

    @Test("separate_stems hands each stem back as its own audio handle")
    func separateStems() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await imported(session)

        let output = try await SeparateStemsTool(workbench: session.workbench)
            .run(.init(audio: handle, stems: nil))
        #expect(output.stems.count == 1)
        #expect(output.stems[0].name == "drums")
        let drums = try await session.workbench.audio(output.stems[0].audio)
        #expect(drums.frameCount > 0)
    }

    @Test("With no separation model the tool says so and suggests what to do instead")
    func separateWithoutAModel() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(separator: nil))
        let handle = try await workbench.loadAudio(at: session.url)
        do {
            _ = try await SeparateStemsTool(workbench: workbench).run(.init(audio: handle, stems: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("no separation model"))
            #expect(failure.suggestion != nil)
        }
    }

    // MARK: chop_bar

    @Test("chop_bar cuts one bar at its transients and finds the four hits")
    func chopBarByOnsets() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await analysed(session)

        let output = try await ChopBarTool(workbench: session.workbench)
            .run(.init(audio: handle, bar: 1, startSeconds: nil, endSeconds: nil,
                       method: .onsets, division: 4))
        #expect(output.chop == "chop-1")
        #expect(output.bar == 1)
        #expect(output.sliceCount >= 4, "four hits in the bar, plus any lead-in")
        let barLength = 4 * 60 / DirectorAudioFixture.tempo
        #expect(abs(output.startSeconds - barLength) < 0.02)
        #expect(abs(output.durationSeconds - barLength) < 0.05)
        #expect(output.slices.allSatisfy { $0.durationSeconds > 0 })
    }

    @Test("chop_bar cuts a span in seconds when no bar is named")
    func chopBarBySpan() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await imported(session)

        let output = try await ChopBarTool(workbench: session.workbench)
            .run(.init(audio: handle, bar: nil, startSeconds: 0, endSeconds: 2,
                       method: .divisions, division: 8))
        #expect(output.sliceCount == 8, "eight equal pieces")
        #expect(abs(output.durationSeconds - 2) < 0.02)
    }

    @Test("chop_bar with nothing to go on says what it needs")
    func chopBarWithNothing() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let handle = try await imported(session)
        do {
            _ = try await ChopBarTool(workbench: session.workbench)
                .run(.init(audio: handle, bar: nil, startSeconds: nil, endSeconds: nil,
                           method: nil, division: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("start_seconds"))
        }
    }

    @Test("chop_bar on a handle nobody made lists the ones that exist")
    func chopUnknownAudio() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        _ = try await imported(session)
        do {
            _ = try await ChopBarTool(workbench: session.workbench)
                .run(.init(audio: "audio-99", bar: nil, startSeconds: 0, endSeconds: 1,
                           method: nil, division: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("audio-1"))
        }
    }

    // MARK: classify_slices

    @Test("classify_slices names every slice and keeps the result on the chop")
    func classifySlices() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await chopped(session)

        let output = try await ClassifySlicesTool(workbench: session.workbench).run(.init(chop: chop, overrides: nil))
        #expect(output.slices.count >= 4)
        #expect(Set(output.counts.keys) == Set(SliceClass.allCases.map(\.rawValue)))
        #expect(output.counts.values.reduce(0, +) == output.slices.count)
        #expect(output.slices.allSatisfy { SliceClass(rawValue: $0.kind) != nil })
        #expect(output.slices.allSatisfy { !$0.isOverride })
        let kept = try await session.workbench.chop(chop).classifications
        #expect(kept.count == output.slices.count)
    }

    @Test("An override beats the classifier, and says it did")
    func classifyWithOverride() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await chopped(session)

        let output = try await ClassifySlicesTool(workbench: session.workbench)
            .run(.init(chop: chop, overrides: [.init(slice: 0, kind: "hat")]))
        let first = try #require(output.slices.first { $0.index == 0 })
        #expect(first.kind == "hat")
        #expect(first.isOverride)
    }

    @Test("An override naming something that is not a kind lists the ones that are")
    func classifyWithBadOverride() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await chopped(session)
        do {
            _ = try await ClassifySlicesTool(workbench: session.workbench)
                .run(.init(chop: chop, overrides: [.init(slice: 0, kind: "cowbell")]))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("kick"))
        }
    }

    // MARK: list_feels and describe_feel

    @Test("list_feels reads the shipped library")
    func listFeels() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let output = try await ListFeelsTool(workbench: session.workbench)
            .run(.init(tempo: nil, idiom: nil, beatsPerBar: nil, limit: 60))
        #expect(output.count == FeelLibrary.standard.count)
        #expect(output.feels.contains { $0.name == "Boom-Bap" })
        #expect(output.idioms.contains("boom-bap"))
        #expect(output.feels.allSatisfy { $0.stepsPerBar > 0 && !$0.summary.isEmpty })
    }

    @Test("list_feels narrows by tempo and idiom")
    func listFeelsFiltered() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let output = try await ListFeelsTool(workbench: session.workbench)
            .run(.init(tempo: 90, idiom: "boom-bap", beatsPerBar: 4, limit: 5))
        #expect(!output.feels.isEmpty)
        #expect(output.feels.allSatisfy { $0.idioms.contains("boom-bap") })
        #expect(output.feels.allSatisfy { $0.tempoLow <= 90 && $0.tempoHigh >= 90 })
    }

    @Test("A filter that matches nothing offers the nearest rather than an empty list")
    func listFeelsFallsBack() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let output = try await ListFeelsTool(workbench: session.workbench)
            .run(.init(tempo: 17, idiom: "polka", beatsPerBar: nil, limit: 3))
        #expect(!output.feels.isEmpty, "a dead end is no use to the model")
    }

    @Test("describe_feel writes the grid out step by step")
    func describeFeel() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let output = try await DescribeFeelTool(workbench: session.workbench).run(.init(name: "Boom-Bap"))
        #expect(output.name == "Boom-Bap")
        #expect(!output.patterns.isEmpty)
        for pattern in output.patterns {
            #expect(pattern.steps.count == output.stepsPerBar * output.bars)
            #expect(pattern.steps.allSatisfy { DirectorFeelNotation.tier(for: $0) != nil })
            #expect(pattern.hits == pattern.steps.filter { $0 != "." }.count)
        }
        #expect(!output.summary.isEmpty)
    }

    @Test("describe_feel on a name nobody has points at list_feels")
    func describeUnknownFeel() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        do {
            _ = try await DescribeFeelTool(workbench: session.workbench).run(.init(name: "Jungle Boogie"))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("list_feels"))
        }
    }

    // MARK: regroove_chop

    @Test("regroove_chop lays the slices onto the feel and reports what landed")
    func regroove() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await classified(session)

        let output = try await RegrooveChopTool(workbench: session.workbench)
            .run(.init(chop: chop, feel: "Boom-Bap", tempo: 90, bars: 2, overlap: nil, rotate: nil))
        #expect(output.groove == "groove-1")
        #expect(output.feel == "Boom-Bap")
        #expect(output.tempo == 90)
        #expect(output.bars == 2)
        #expect(output.placements > 0)
        #expect(output.durationSeconds > 0)
        #expect(!output.hitsByVoice.isEmpty)
    }

    @Test("regroove_chop without classification points at the tool that does it")
    func regrooveUnclassified() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await chopped(session)
        do {
            _ = try await RegrooveChopTool(workbench: session.workbench)
                .run(.init(chop: chop, feel: "Boom-Bap", tempo: nil, bars: nil, overlap: nil, rotate: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("classify_slices"))
        }
    }

    @Test("regroove_chop defaults to the feel's own tempo")
    func regrooveDefaultTempo() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await classified(session)
        let feel = try #require(FeelLibrary.standard.feel(named: "Lo-Fi Hip-Hop"))
        let output = try await RegrooveChopTool(workbench: session.workbench)
            .run(.init(chop: chop, feel: "Lo-Fi Hip-Hop", tempo: nil, bars: nil, overlap: nil, rotate: nil))
        #expect(output.tempo == feel.suggestedTempo)
    }

    @Test("An overlap mode nobody has heard of lists the two that exist")
    func regrooveBadOverlap() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await classified(session)
        do {
            _ = try await RegrooveChopTool(workbench: session.workbench)
                .run(.init(chop: chop, feel: "Boom-Bap", tempo: nil, bars: nil, overlap: "wrap", rotate: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("stretch_to_fit"))
        }
    }

    // MARK: set_swing and set_velocity

    @Test("set_swing re-runs the groove with the new swing, in place")
    func setSwing() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)

        let output = try await SetSwingTool(workbench: session.workbench).run(.init(groove: groove, percent: 66))
        #expect(output.groove == groove, "the same handle, not a new one")
        #expect(output.swingPercent == 66)
        let plan = try await session.workbench.groove(groove).plan
        #expect(plan.swingPercent == 66)
        #expect(await session.workbench.grooveHandles == [groove], "nothing new was made")
    }

    @Test("Swing past the end of the range is clamped, not refused")
    func setSwingClamped() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)
        let output = try await SetSwingTool(workbench: session.workbench).run(.init(groove: groove, percent: 90))
        #expect(output.swingPercent == Swing.maximumPercent)
    }

    @Test("set_velocity scales the whole groove and keeps the shape")
    func setVelocity() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)

        let before = try await session.workbench.groove(groove).performance
        let output = try await SetVelocityTool(workbench: session.workbench).run(.init(groove: groove, scale: 0.6))
        #expect(output.velocityScale == 0.6)

        let after = try await session.workbench.groove(groove).performance
        #expect(after.placements.count == before.placements.count, "the same hits")
        let loudestBefore = before.placements.map(\.velocity).max() ?? 0
        let loudestAfter = after.placements.map(\.velocity).max() ?? 0
        #expect(loudestAfter < loudestBefore, "played softer")
    }

    @Test("set_swing on a handle nobody made lists the ones that exist")
    func setSwingUnknownGroove() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        _ = try await grooved(session)
        do {
            _ = try await SetSwingTool(workbench: session.workbench).run(.init(groove: "groove-9", percent: 60))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("groove-1"))
        }
    }

    // MARK: audition

    @Test("audition with no audio device says so rather than pretending")
    func auditionSilently() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)

        let rig = DirectorSilentAudition()
        let output = try await AuditionTool(workbench: session.workbench, audition: rig)
            .run(.init(groove: groove, bars: 1))
        #expect(!output.played)
        #expect(output.detail.contains("no audio output"))
        #expect(output.bars == 1)
        #expect(rig.requests.map(\.handle) == [groove])
    }

    @Test("audition with nothing wired up is still honest rather than a crash")
    func auditionWithNoRig() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)
        let output = try await AuditionTool(workbench: session.workbench, audition: nil)
            .run(.init(groove: groove, bars: nil))
        #expect(!output.played)
        #expect(output.tempo > 0)
    }

    // MARK: read_song

    @Test("read_song reports the open song")
    func readSong() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let output = try await ReadSongTool(workspace: session.workspace).run(.init())
        #expect(output.isOpen)
        #expect(output.title == "Arrival")
        #expect(output.tempo == DirectorAudioFixture.tempo)
        #expect(output.versions.isEmpty)
    }

    @Test("read_song with nothing open says what that means")
    func readNoSong() async throws {
        let workspace = DirectorScratchWorkspace()
        let output = try await ReadSongTool(workspace: workspace).run(.init())
        #expect(!output.isOpen)
        #expect(output.note?.contains("No song is open") == true)
    }

    // MARK: create_part_version

    @Test("create_part_version records a groove into the song, attributed to the persona")
    func createGrooveVersion() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)

        let tool = CreatePartVersionTool(workbench: session.workbench, workspace: session.workspace)
        let output = try await tool.run(.init(from: groove, note: "Bar 2 on a boom-bap pocket.",
                                              persona: "Nyx", parent: nil))
        #expect(output.recorded)
        #expect(output.type == "groove")
        #expect(output.operation == Operation.regroove)
        #expect(output.author == Author.persona("Nyx").description)

        let song = try #require(session.workspace.song)
        #expect(song.versions.count == 1)
        #expect(song.versions[0].note == "Bar 2 on a boom-bap pocket.")
        #expect(session.workspace.notes.count == 1)
    }

    @Test("create_part_version records a chop as a sample with its markers, signed by the band")
    func createChopVersion() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await classified(session)

        let tool = CreatePartVersionTool(workbench: session.workbench, workspace: session.workspace)
        let output = try await tool.run(.init(from: chop, note: "Bar 1, eight pieces.",
                                              persona: nil, parent: nil))
        #expect(output.recorded)
        #expect(output.type == "sample")
        // The model named nobody, and the version is still the band's: `.user` is unreachable from
        // this tool, because the user does not call tools. A chop the band cut and attributed to
        // the user is the ledger saying the one thing it exists to get right, wrongly.
        #expect(output.author == Author.persona(CreatePartVersionTool.director).description)

        let song = try #require(session.workspace.song)
        guard case .sample(let sample) = song.versions[0].kind else {
            Issue.record("expected a sample")
            return
        }
        #expect(!sample.slices.isEmpty, "the markers go with it")
    }

    @Test("A second version derives from the first when a parent is named")
    func derivedVersion() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)
        let tool = CreatePartVersionTool(workbench: session.workbench, workspace: session.workspace)
        let first = try await tool.run(.init(from: groove, note: "First.", persona: "Nyx", parent: nil))
        _ = try await SetSwingTool(workbench: session.workbench).run(.init(groove: groove, percent: 62))
        let second = try await tool.run(.init(from: groove, note: "Swung.", persona: "Nyx", parent: first.version))

        let song = try #require(session.workspace.song)
        #expect(song.versions.count == 2)
        #expect(song.versions[1].parents.map(\.description) == [first.version])
        #expect(second.part != first.part, "the band's take is a new part, not a revision")
    }

    @Test("a groove the band records from a chop in the song plays that chop's slices, where the chop played")
    func grooveFromAChopPlaysIt() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let chop = try await classified(session)
        let groove = try await grooved(session)
        let tool = CreatePartVersionTool(workbench: session.workbench, workspace: session.workspace)
        let sample = try await tool.run(.init(from: chop, note: "Bar 1, eight pieces.", persona: nil, parent: nil))
        session.workspace.arrange([Section(name: "Verse", stitch: [PartID(uuidString: sample.part)!].lanes, lengthInBars: 4)])

        let made = try await tool.run(.init(from: groove, note: "Bar 1 on a pocket.", persona: "Nyx", parent: sample.version))
        let song = try #require(session.workspace.song)
        let groovePart = try #require(PartID(uuidString: made.part))
        #expect(SongPlayback.drumSoundID(for: groovePart, in: song) == ChopSound.id(for: PartID(uuidString: sample.part)!))
        #expect(song.sections[0].stitch.map(\.part) == [groovePart], "in the chop's place")
    }

    @Test("create_part_version with no song open says nothing was recorded")
    func createWithNoSong() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let groove = try await grooved(session)
        let workspace = DirectorScratchWorkspace(song: nil)
        let tool = CreatePartVersionTool(workbench: session.workbench, workspace: workspace)
        let output = try await tool.run(.init(from: groove, note: "Nowhere to go.", persona: nil, parent: nil))
        #expect(!output.recorded)
        #expect(output.detail?.contains("No song is open") == true)
    }

    @Test("create_part_version from something that is neither says which handles work")
    func createFromNonsense() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let tool = CreatePartVersionTool(workbench: session.workbench, workspace: session.workspace)
        do {
            _ = try await tool.run(.init(from: "audio-1", note: "?", persona: nil, parent: nil))
            Issue.record("expected a failure")
        } catch let failure as DirectorToolFailure {
            #expect(failure.description.contains("regroove_chop"))
        }
    }

    // MARK: The whole run

    @Test("The first proof, end to end: import, analyse, separate, chop, classify, feel, groove, record")
    func wholeRun() async throws {
        let session = try makeSession()
        defer { tearDown(session) }
        let workbench = session.workbench

        let imported = try await ImportRecordTool(workbench: workbench, workspace: session.workspace)
            .run(.init(path: session.url.path))
        let analysis = try await AnalyseRecordTool(workbench: workbench).run(.init(audio: imported.audio))
        #expect(analysis.barCount == 4)

        let stems = try await SeparateStemsTool(workbench: workbench)
            .run(.init(audio: imported.audio, stems: ["drums"]))
        let drums = try #require(stems.stems.first).audio
        // The stem is a buffer, so it carries no analysis of its own: the bar comes from the
        // record's grid and is passed as a span, which is exactly how the app does it.
        let bars = try await ListBarsTool(workbench: workbench)
            .run(.init(audio: imported.audio, fromBar: 1, count: 1))
        let bar = try #require(bars.bars.first)

        let chop = try await ChopBarTool(workbench: workbench)
            .run(.init(audio: drums, bar: nil, startSeconds: bar.startSeconds, endSeconds: bar.endSeconds,
                       method: .onsets, division: 4))
        #expect(chop.sliceCount >= 4)

        let classes = try await ClassifySlicesTool(workbench: workbench).run(.init(chop: chop.chop, overrides: nil))
        #expect(classes.slices.count == chop.sliceCount)

        let feels = try await ListFeelsTool(workbench: workbench)
            .run(.init(tempo: 90, idiom: "boom-bap", beatsPerBar: 4, limit: 3))
        let feel = try #require(feels.feels.first).name

        let groove = try await RegrooveChopTool(workbench: workbench)
            .run(.init(chop: chop.chop, feel: feel, tempo: 88, bars: 2, overlap: "ring", rotate: true))
        #expect(groove.placements > 0)

        let swung = try await SetSwingTool(workbench: workbench).run(.init(groove: groove.groove, percent: 58))
        #expect(swung.swingPercent == 58)
        let softer = try await SetVelocityTool(workbench: workbench).run(.init(groove: groove.groove, scale: 0.85))
        #expect(softer.velocityScale == 0.85)

        let heard = try await AuditionTool(workbench: workbench, audition: DirectorSilentAudition())
            .run(.init(groove: groove.groove, bars: 2))
        #expect(!heard.played, "no audio device in an automated shell, and the tool says so")

        let recorded = try await CreatePartVersionTool(workbench: workbench, workspace: session.workspace)
            .run(.init(from: groove.groove, note: "Bar 2 of the break on \(feel), softened.",
                       persona: "Nyx", parent: nil))
        #expect(recorded.recorded)
        #expect(session.workspace.song?.versions.count == 1)
    }

    // MARK: Steps, shared

    private func imported(_ session: Session) async throws -> String {
        try await ImportRecordTool(workbench: session.workbench, workspace: session.workspace)
            .run(.init(path: session.url.path)).audio
    }

    private func analysed(_ session: Session) async throws -> String {
        let handle = try await imported(session)
        _ = try await AnalyseRecordTool(workbench: session.workbench).run(.init(audio: handle))
        return handle
    }

    private func chopped(_ session: Session) async throws -> String {
        let handle = try await analysed(session)
        return try await ChopBarTool(workbench: session.workbench)
            .run(.init(audio: handle, bar: 1, startSeconds: nil, endSeconds: nil,
                       method: .onsets, division: 4)).chop
    }

    private func classified(_ session: Session) async throws -> String {
        let chop = try await chopped(session)
        _ = try await ClassifySlicesTool(workbench: session.workbench).run(.init(chop: chop, overrides: nil))
        return chop
    }

    private func grooved(_ session: Session) async throws -> String {
        let chop = try await classified(session)
        return try await RegrooveChopTool(workbench: session.workbench)
            .run(.init(chop: chop, feel: "Boom-Bap", tempo: 90, bars: 2, overlap: nil, rotate: nil)).groove
    }
}
