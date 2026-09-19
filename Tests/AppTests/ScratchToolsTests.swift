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
        let son = FeelLibrary.standard.feel(named: "Son Clave 3-2")!.groove.patterns.first { $0.voice == .rim }!
        #expect(son.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == [0, 6, 12, 20, 24], "three, then two")
        let rumba = FeelLibrary.standard.feel(named: "Rumba Clave")!.groove.patterns.first { $0.voice == .rim }!
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
        let rim = try #require(groove.patterns.first { $0.voice == .rim })
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
        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "", bars: 2, swing_percent: 0, rows: ["cowbell: x..."], note: "no such voice")) }
        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "", bars: 2, swing_percent: 0, rows: ["kick: x.o."], note: "bad step")) }
        await #expect(throws: DirectorToolFailure.self) { try await write.run(.init(feel: "No Such Feel", bars: 2, swing_percent: 0, rows: [], note: "x")) }
        let empty = DirectorScratchWorkspace(song: nil)
        await #expect(throws: DirectorToolFailure.self) { try await self.tools(empty).1.run(.init(feel: "Dembow", bars: 2, swing_percent: 0, rows: [], note: "x")) }
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
