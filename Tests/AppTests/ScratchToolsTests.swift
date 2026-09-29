import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// From an idea: a song with nothing imported, and a beat written onto its drum machine.

@Suite("Director: a beat from nothing", .serialized) @MainActor
struct ScratchToolsTests {
    private func tools(_ workspace: DirectorScratchWorkspace) -> (StartSongTool, WriteGrooveTool) {
        (StartSongTool(workspace: workspace), WriteGrooveTool(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace))
    }

    @Test("the library has Latin feels beyond Bossa Nova, each two bars of sixteenths with a clave-length cycle and a stated lineage")
    func latinFeels() {
        let latin = FeelLibrary.standard.feels.filter { $0.idioms.contains(.latin) }
        #expect(latin.count >= 9, "\(latin.map(\.name))")
        let names = ["Son Clave 3-2", "Son Clave 2-3", "Rumba Clave", "Salsa Tumbao", "Cha-Cha-Chá", "Samba", "Baião", "Dembow"]
        for name in names {
            guard let feel = FeelLibrary.standard.feel(named: name) else { Issue.record("no \(name)"); continue }
            let shaped = feel.groove.stepsPerBar == 16 && feel.groove.bars == 2 && feel.groove.patterns.allSatisfy { $0.steps.count == 32 }
            #expect(shaped, "\(name)")
            let origin = feel.provenance.origin
            #expect(!feel.provenance.lineage.isEmpty && origin == Provenance.Origin.original, "\(name)")
            #expect(feel.tempoRange.contains(feel.suggestedTempo))
        }
        let son = FeelLibrary.standard.feel(named: "Son Clave 3-2")!.groove.patterns.first { $0.voice == .claves }!
        #expect(son.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == [0, 6, 12, 20, 24], "three, then two")
        let rumba = FeelLibrary.standard.feel(named: "Rumba Clave")!.groove.patterns.first { $0.voice == .claves }!
        #expect(rumba.steps[14] != .rest && rumba.steps[12] == .rest, "the third stroke a sixteenth late")
    }

    @Test("start_song sets up an empty song in place, with no record; write_groove lays a feel on its machine with the swing asked for")
    func fromAFeel() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "Untitled"))
        let (start, write) = tools(workspace)
        let started = try await start.run(.init(title: "Night Bus", tempo: 120, key: "A minor", machine: "tr909"))
        #expect(started.song == "Night Bus" && started.tempo == 120 && started.key == "A minor")
        #expect(workspace.song?.versions.count == 1, "only the drum machine: nothing imported")
        #expect(SongPlayback.machineID(in: workspace.song!) == "tr909")

        let out = try await write.run(.init(feel: "son clave 3-2", bars: 4, swing_percent: 57, rows: [], note: "Four bars of son clave, leaning a little"))
        #expect(out.bars == 4 && abs(out.swingPercent - 57) < 0.11 && out.hits > 40)
        let version = try #require(Guidance.grooves(in: workspace.song!).last)
        #expect(version.operation == Operation.written && version.author == .persona("Beatmaker") && version.note == "Four bars of son clave, leaning a little")
        guard case .groove(let groove) = version.kind else { Issue.record("not a groove"); return }
        #expect(groove.bars == 4 && groove.patterns.allSatisfy { $0.steps.count == 64 })
        let rim = try #require(groove.patterns.first { $0.voice == .claves })
        #expect(rim.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == [0, 6, 12, 20, 24, 32, 38, 44, 52, 56], "the two-bar clave, twice")
        #expect(workspace.heard == [version.id], "it is played for the user")
        #expect(out.detail.contains("Nothing was sampled"))
        #expect(workspace.song?.versions.contains { $0.type == .audio || $0.type == .sample } == false)
    }

    @Test("rows written by hand, and rows over a feel: accents, ghosts, repeats, and what is refused")
    func byHand() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "Sketch", tempo: 92))
        let (_, write) = tools(workspace)
        let out = try await write.run(.init(feel: "", bars: 2, swing_percent: 0,
                                            rows: ["kick: X..x..x.X..x..x.", "Snare: ....X..g....X...", "closedhat: x.x."], note: "A half-time thing"))
        #expect(out.rows == ["kick: X..x..x.X..x..x.X..x..x.X..x..x.", "snare: ....X..g....X.......X..g....X...", "closedHat: " + String(repeating: "x.x.", count: 8)])
        #expect(out.swingPercent == 50 && out.bars == 2)

        // Over a feel: the kick is rewritten, the rest of the feel stays.
        let over = try await write.run(.init(feel: "Dembow", bars: 2, swing_percent: 0, rows: ["kick: X...X...X...X.x."], note: "Dembow with a pickup"))
        #expect(over.rows.contains { $0.hasPrefix("kick: X...X...X...X.x.") } && over.rows.contains { $0.hasPrefix("snare: ...x..X") })

        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "", bars: 2, swing_percent: 0, rows: [], note: "nothing")) }
        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "", bars: 2, swing_percent: 0, rows: ["gong: x..."], note: "no such voice")) }
        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "", bars: 2, swing_percent: 0, rows: ["kick: x.o."], note: "bad step")) }
        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "No Such Feel", bars: 2, swing_percent: 0, rows: [], note: "x")) }
        let empty = DirectorScratchWorkspace(song: nil)
        await #expect(throws: DirectorToolFailure.self) { try await self.tools(empty).1.run(.init(feel: "Dembow", bars: 2, swing_percent: 0, rows: [], note: "x")) }
    }

    @Test("a feel is written on its own grid: brushes in eighths, a shuffle in triplets, a waltz in a song in three")
    func anyGrid() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "Still Water", tempo: 72))
        let (_, write) = tools(workspace)
        // What was asked for on the first day, and refused for not being in sixteenths.
        let brushes = try await write.run(.init(feel: "Ballad Brushes", bars: 4, swing_percent: 0, rows: [], note: "Brushes"))
        let feel = try #require(FeelLibrary.standard.feel(named: "Ballad Brushes"))
        #expect(brushes.stepsPerBar == 8 && brushes.bars == 4 && brushes.hits > 0)
        guard case .groove(let groove)? = Guidance.grooves(in: workspace.song!).last?.kind else { Issue.record("not a groove"); return }
        #expect(groove.stepsPerBar == 8 && groove.patterns.allSatisfy { $0.steps.count == 32 })
        #expect(groove.feel?.name == "Ballad Brushes", "its pocket goes with it")
        for pattern in feel.groove.patterns {
            let written = try #require(groove.patterns.first { $0.voice == pattern.voice })
            #expect(Array(written.steps.prefix(pattern.steps.count)) == pattern.steps)
        }
        #expect(brushes.detail.contains("8 steps a bar"))

        let shuffle = try await write.run(.init(feel: "Shuffle", bars: 2, swing_percent: 0, rows: ["rim: x.....x....."], note: "A shuffle"))
        #expect(shuffle.stepsPerBar == 12)
        #expect(shuffle.rows.contains("rim: x.....x.....x.....x....."), "a row is read on the feel's grid: \(shuffle.rows)")
        // Rows said to be on a grid the feel is not on are a mistake, not a guess.
        await #expect(throws: DirectorToolFailure.self) {
            try await write.run(.init(feel: "Shuffle", bars: 2, swing_percent: 0, rows: [], note: "x", steps_per_bar: 16))
        }

        // In a song in three, a waltz is in its own meter.
        let three = DirectorScratchWorkspace(song: Song(title: "Three", tempo: 100, timeSignature: .threeFour))
        let waltz = try await tools(three).1.run(.init(feel: "Jazz Waltz", bars: 4, swing_percent: 0, rows: [], note: "A waltz"))
        let own = try #require(FeelLibrary.standard.feel(named: "Jazz Waltz"))
        #expect(waltz.stepsPerBar == own.groove.stepsPerBar)
        #expect(!waltz.detail.contains("turns over"))
    }

    @Test("a feel in another meter is laid across the song's bars, and says where they meet; one that counts another beat is refused")
    func anotherMeter() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "trynta", tempo: 131))
        let (_, write) = tools(workspace)
        let own = try #require(FeelLibrary.standard.feel(named: "Jazz Waltz"))
        let perBeat = own.groove.stepsPerBar / 3
        let waltz = try await write.run(.init(feel: "Jazz Waltz", bars: 3, swing_percent: 0, rows: [], note: "A waltz for the bridge"))
        #expect(waltz.stepsPerBar == perBeat * 4, "as many steps a beat as the waltz has, four beats to the bar")
        #expect(waltz.detail.contains("Jazz Waltz is in 3/4 and the song is in 4/4"))
        #expect(waltz.detail.contains("every 3 bars of the song"))
        guard case .groove(let groove)? = Guidance.grooves(in: workspace.song!).last?.kind else { Issue.record("not a groove"); return }
        // Bar one of the waltz begins again a beat before the song's second bar does.
        let kick = try #require(own.groove.patterns.first { $0.voice == .kick } ?? own.groove.patterns.first)
        let written = try #require(groove.patterns.first { $0.voice == kick.voice })
        let cycle = own.groove.stepCount
        #expect(written.steps.count == perBeat * 4 * 3)
        #expect(Array(written.steps[cycle..<min(written.steps.count, cycle * 2)]) == Array(written.steps[0..<min(cycle, written.steps.count - cycle)]))

        // Eighths of six against quarters of four: no step in common.
        do {
            _ = try await write.run(.init(feel: "Afro-Cuban 6/8", bars: 2, swing_percent: 0, rows: [], note: "x"))
            Issue.record("a feel in six-eight was laid over a song in four-four")
        } catch let failure as DirectorToolFailure {
            #expect(failure.reason.contains("do not count the same beat"))
            #expect(failure.suggestion?.contains("set_song") == true)
        }
        // By hand, on a grid of your own.
        let triplets = try await write.run(.init(feel: "", bars: 1, swing_percent: 0, rows: ["kick: X.....X.....", "closedHat: x.xx.x"], note: "Triplets", steps_per_bar: 12))
        #expect(triplets.stepsPerBar == 12 && triplets.rows == ["kick: X.....X.....", "closedHat: x.xx.xx.xx.x"])
        await #expect(throws: DirectorToolFailure.self) {
            try await write.run(.init(feel: "", bars: 1, swing_percent: 0, rows: ["kick: x"], note: "x", steps_per_bar: 97))
        }
    }

    @Test("a beat written again names the beat it answers and is its next version; a waltz over four bars is told it does not close")
    func theSameBeatAgain() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "trynta", tempo: 131))
        let (_, write) = tools(workspace)
        let first = try await write.run(.init(feel: "Jazz Waltz", bars: 4, swing_percent: 0, rows: [], note: "A waltz"))
        #expect(first.detail.contains("At 4 bars the loop turns back partway through a bar of Jazz Waltz: 3 or 6 bars close it."), "\(first.detail)")
        if !first.flags.isEmpty {
            #expect(first.detail.contains("write it again with parent \(first.version)"), "\(first.detail)")
        }
        let second = try await write.run(.init(feel: "Jazz Waltz", bars: 3, swing_percent: 66.7, rows: [], note: "A waltz, swung", parent: first.version))
        #expect(!second.detail.contains("turns back partway"))
        #expect(second.detail.contains("It is the next version of"))
        let grooves = workspace.song!.versions.filter { $0.type == .groove }
        #expect(grooves.count == 2 && Set(grooves.map(\.partID)).count == 1)
        #expect(grooves.last?.parents.first?.description == first.version)
        // With nobody named it is another beat, as it always was.
        _ = try await write.run(.init(feel: "Jazz Waltz", bars: 3, swing_percent: 0, rows: [], note: "Another"))
        #expect(Set(workspace.song!.versions.filter { $0.type == .groove }.map(\.partID)).count == 2)
        // A parent that is not a groove, or not in the song, is refused.
        await #expect(throws: DirectorToolFailure.self) {
            try await write.run(.init(feel: "Jazz Waltz", bars: 3, swing_percent: 0, rows: [], note: "x", parent: "not-an-id"))
        }
    }

    @Test("in the app: a song holding work is saved and a new one opened; an empty one is set up in place")
    func inTheApp() throws {
        let directory = WiringFixture.temporaryDirectory("scratch-song")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory, song: FormFixture.build(tempo: 100).song)
        let before = try #require(app.song?.id)
        let fresh = try #require(app.startSong(title: "From nothing", tempo: 128, key: Key(tonic: NoteName(.a), mode: .aeolian), machine: "linn"))
        #expect(fresh.id != before && app.song?.title == "From nothing" && app.song?.tempo == 128)
        #expect(app.song?.versions.map(\.type) == [.sound] && SongPlayback.machineID(in: app.song!) == "linn")
        let again = try #require(app.startSong(title: "", tempo: 90, key: nil, machine: "tr808"))
        #expect(again.id == fresh.id && app.song?.tempo == 90, "a song holding only its drum machine is still a blank sketch: set up in place")
        #expect(SongPlayback.machineID(in: app.song!) == "tr808" && app.song?.title == "From nothing")
    }
}
