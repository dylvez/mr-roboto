import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

// One section at a time: made more or less intense, remembered as it stood, and heard against that.
//
// A reader of the brochure asked to see a chorus made more restrained and the two compared. The
// Director rewrote the hook's drums, said the hooks were quieter when they read the same, and
// played two drum beats for "the two choruses". These are the moves that were missing.

@MainActor
private enum SectionFixture {
    /// Afterglow, developed: intro, verse, hook, verse, hook, bridge, hook, outro.
    static func developed() throws -> (app: AppState, directory: URL, loop: DevelopFixture.Loop) {
        let (app, directory, _) = CompletenessFixture.app("section-moves")
        let loop = try DevelopFixture.loop()
        app.open(loop.song)
        _ = try #require(app.develop())
        // Every change counts as one a listener heard: a test does not wait a second between two.
        app.sectionSettle = 0
        return (app, directory, loop)
    }

    static func section(_ name: String, _ app: AppState, nth: Int = 0) throws -> SongGraph.Section {
        try #require(app.song?.sections.filter { $0.name == name }.dropFirst(nth).first)
    }

    /// The name of the variation a section's lane of this kind plays; "" for the part as written,
    /// nil when the section plays none of that kind.
    static func variation(_ type: PartType, in section: SongGraph.Section, of song: Song) -> String? {
        for lane in section.stitch {
            guard let version = song.version(playing: lane), version.type == type else { continue }
            return song.variation(of: lane.part)?.name ?? ""
        }
        return nil
    }

    static func level(_ part: PartID, in section: SongGraph.Section, _ app: AppState) -> Double {
        app.playback.mix?.gainDB(for: part, in: section.id) ?? 0
    }
}

@Suite("One section, more or less", .serialized) @MainActor
struct SectionIntensityTests {

    @Test("a hook brought down loses its lift and its levels, keeps its tune, and nothing else in the song moves")
    func restrained() throws {
        let (app, directory, loop) = try SectionFixture.developed()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try #require(app.song)
        let hook = try SectionFixture.section("Hook", app)
        #expect(SectionFixture.variation(.groove, in: hook, of: before) == "lift")
        #expect(SectionFixture.level(loop.drums.partID, in: hook, app) == 0.5 && SectionFixture.level(loop.tune.partID, in: hook, app) == 1)
        let versions = before.versions.count

        let shading = try #require(app.shade(hook.id, to: 0.7))
        let song = try #require(app.song)
        let now = try SectionFixture.section("Hook", app)
        #expect(shading.was == 0.9 && now.intensity == 0.7 && now.id == hook.id)
        #expect(SectionFixture.variation(.groove, in: now, of: song) == "", "the drums as written, the layer gone")
        #expect(SectionFixture.variation(.melody, in: now, of: song) == "", "the tune is still the tune")
        #expect(SectionFixture.variation(.bassline, in: now, of: song) == "")
        #expect(SectionFixture.level(loop.drums.partID, in: now, app) < 0.5)
        #expect(SectionFixture.level(loop.tune.partID, in: now, app) < 1 && SectionFixture.level(loop.tune.partID, in: now, app) > 0)
        #expect(shading.moved.contains { $0.hasPrefix("drums: lifted, now as written") }, "\(shading.moved)")
        // One mix version and nothing written: the loop's own drums were already in the song.
        #expect(song.versions.count == versions + 1 && shading.versions.isEmpty)
        for (was, is_) in zip(before.sections, song.sections) where was.id != hook.id { #expect(was == is_, "\(was.name) moved") }
        let second = try SectionFixture.section("Hook", app, nth: 1)
        #expect(SectionFixture.level(loop.drums.partID, in: second, app) == 0.5, "the second hook is the hook it was")
        #expect(app.playback.segments.first { $0.section == hook.id }?.groovePart == loop.drums.partID)

        // Further down: thinned drums, a lighter bass, the tune's first phrase — each a variation
        // the song already has from its intro, its outro and its verses, so nothing is written.
        _ = try #require(app.shade(hook.id, to: 0.3))
        let low = try SectionFixture.section("Hook", app)
        let after = try #require(app.song)
        #expect(SectionFixture.variation(.groove, in: low, of: after) == "thin")
        #expect(SectionFixture.variation(.bassline, in: low, of: after) == "light")
        #expect(SectionFixture.variation(.melody, in: low, of: after) == "sparse")
        #expect(SectionFixture.level(loop.drums.partID, in: low, app) < -1)
        #expect(after.partIDs.count == song.partIDs.count, "no new part: the thinned drums are the intro's")
    }

    @Test("it only moves the way it was asked, and leaves a section's character alone")
    func oneWay() throws {
        let (app, directory, loop) = try SectionFixture.developed()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A verse brought up gets the whole tune and the lift, and loses nothing.
        let verse = try SectionFixture.section("Verse", app)
        #expect(SectionFixture.variation(.melody, in: verse, of: try #require(app.song)) == "sparse")
        let up = try #require(app.shade(verse.id, to: 0.9))
        let song = try #require(app.song)
        let now = try SectionFixture.section("Verse", app)
        #expect(SectionFixture.variation(.melody, in: now, of: song) == "", "\(up.moved)")
        #expect(SectionFixture.variation(.groove, in: now, of: song) == "lift")
        #expect(SectionFixture.variation(.bassline, in: now, of: song) == "")
        #expect(SectionFixture.level(loop.drums.partID, in: now, app) == 0.5)
        #expect(now.stitch.count == verse.stitch.count)
        // The octave is for where the song arrives: a verse at the top still plays the tune where it was written.
        _ = app.shade(verse.id, to: 1)
        #expect(SectionFixture.variation(.melody, in: try SectionFixture.section("Verse", app), of: try #require(app.song)) == "")

        // Asked for the same, or for a hair less from the top, nothing is taken away that it has.
        let hook = try SectionFixture.section("Hook", app)
        let same = try #require(app.shade(hook.id, to: 0.88))
        #expect(SectionFixture.variation(.groove, in: try SectionFixture.section("Hook", app), of: try #require(app.song)) == "lift", "\(same.moved)")

        // The bridge keeps its ride, its own chords and the bass written to them, however far down.
        let bridge = try SectionFixture.section("Bridge", app)
        _ = try #require(app.shade(bridge.id, to: 0.1))
        let low = try SectionFixture.section("Bridge", app)
        let after = try #require(app.song)
        #expect(SectionFixture.variation(.groove, in: low, of: after) == "ride")
        #expect(SectionFixture.variation(.progression, in: low, of: after) == "bridge")
        #expect(SectionFixture.variation(.bassline, in: low, of: after) == "bridge")
        #expect(SectionFixture.level(loop.drums.partID, in: low, app) < -1, "its drums come down all the same")

        // A lane held at a version is somebody's decision, and stays.
        var sections = after.sections
        let outro = try #require(sections.firstIndex { $0.name == "Outro" })
        sections[outro].stitch = sections[outro].stitch.map { lane in
            after.version(playing: lane)?.type == .groove ? Lane(part: lane.part, pin: after.version(playing: lane)?.id) : lane
        }
        #expect(app.arrange(sections))
        _ = app.shade(sections[outro].id, to: 0.9)
        let held = try #require(app.song?.sections[outro].stitch.first { app.song?.version(playing: $0)?.type == .groove })
        let outroNow = try #require(app.song?.sections[outro])
        #expect(held.pin != nil)
        #expect(SectionFixture.variation(.groove, in: outroNow, of: try #require(app.song)) == "thin")
        #expect(Develop.shade(SectionID(), to: 0.5, in: after) == nil, "no such section")
    }

    @Test("the level curve is developing's own: an intro, a bridge, a verse, a hook and a drop sit where it puts them")
    func curve() {
        #expect(Develop.shadeLevel(of: .groove, at: 0.25) == -2 && Develop.shadeLevel(of: .groove, at: 0.5) == -1)
        #expect(Develop.shadeLevel(of: .groove, at: 0.55) == 0 && Develop.shadeLevel(of: .groove, at: 0.9) == 0.5)
        #expect(Develop.shadeLevel(of: .groove, at: 1) == 1 && Develop.shadeLevel(of: .groove, at: 0) == -4)
        #expect(Develop.shadeLevel(of: .melody, at: 0.55) == 0 && Develop.shadeLevel(of: .melody, at: 0.9) == 1 && Develop.shadeLevel(of: .melody, at: 1) == 1.5)
        #expect(Develop.shadeLevel(of: .bassline, at: 0.5) == 0 && Develop.shadeLevel(of: .bassline, at: 1) == 0.5)
        #expect(Develop.shadeLevel(of: .progression, at: 0.5) == nil)
        let between = Develop.shadeLevel(of: .groove, at: 0.725) ?? 0
        #expect(abs(between - 0.25) < 1e-9)
    }
}

@Suite("A section as it stood", .serialized) @MainActor
struct SectionStateTests {

    @Test("a section that changes is remembered as it was, and put back it plays and sits as it did")
    func rememberedAndRestored() throws {
        let (app, directory, loop) = try SectionFixture.developed()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = try SectionFixture.section("Hook", app)
        let stood = try #require(app.standing(hook.id))
        #expect(app.earlierStates(of: hook.id).isEmpty, "nothing has changed since it was developed")
        #expect(stood.lanes.allSatisfy { $0.pin != nil } && stood.levels[loop.drums.partID] == 0.5)

        _ = try #require(app.shade(hook.id, to: 0.7))
        let earlier = app.earlierStates(of: hook.id)
        #expect(earlier.count == 1 && earlier[0].sounds(like: stood))
        #expect(app.earlierStates(of: try SectionFixture.section("Verse", app).id).isEmpty, "the verse did not change")
        let now = try #require(app.standing(hook.id))
        let differs = earlier[0].differences(from: now, in: try #require(app.song))
        #expect(differs.contains { $0.hasPrefix("drums: ") } && differs.contains { $0.hasPrefix("tune at +1.0 dB") }, "\(differs)")

        // A part the hook follows written again is the hook changed too: the lifted drums, rewritten.
        _ = app.shade(hook.id, to: 0.9)
        let song = try #require(app.song)
        let lifted = try #require(song.sections.first { $0.id == hook.id }?.stitch.first { song.variation(of: $0.part)?.name == "lift" })
        let old = try #require(song.latestVersion(of: lifted.part))
        guard case .groove(var groove) = old.kind else { return }
        groove.patterns.removeLast()
        #expect(app.record(old.deriving(.groove(groove), by: .user, operation: Operation.written, note: "Lifted drums, held back")))
        let lastHook = try SectionFixture.section("Hook", app, nth: 2)
        #expect(app.earlierStates(of: lastHook.id).count == 1, "every hook plays that part, so every hook changed")
        let was = try #require(app.earlierStates(of: hook.id).last)
        #expect(was.lanes.contains { $0.pin == old.id })

        // Put back: the hook holds the drums at the version it had, at the levels it had; the last hook goes on with the new ones.
        #expect(app.restore(was))
        let back = try #require(app.song?.sections.first { $0.id == hook.id })
        #expect(back.stitch.first { $0.part == lifted.part }?.pin == old.id)
        #expect(app.song?.version(playing: try #require(back.stitch.first { $0.part == lifted.part }))?.id == old.id)
        #expect(app.standing(hook.id)?.sounds(like: was) == true)
        #expect(app.song?.sections.first { $0.id == lastHook.id }?.stitch.first { $0.part == lifted.part }?.pin == nil)
        #expect(app.playback.segments.first { $0.section == hook.id }?.voices.first { $0.groove != nil }?.version == old.id)
    }

    @Test("what stood for less than a moment is not remembered; another song starts with nothing remembered")
    func settles() throws {
        let (app, directory, _) = try SectionFixture.developed()
        defer { try? FileManager.default.removeItem(at: directory) }
        app.sectionSettle = 60
        let hook = try SectionFixture.section("Hook", app)
        _ = app.shade(hook.id, to: 0.7)
        _ = app.shade(hook.id, to: 0.3)
        #expect(app.earlierStates(of: hook.id).isEmpty, "two changes in a burst: neither state was heard")
        app.sectionSettle = 0
        _ = app.shade(hook.id, to: 0.9)
        #expect(app.earlierStates(of: hook.id).count == 1)
        app.open(try DevelopFixture.loop(title: "Another").song)
        #expect(app.sectionHistory.isEmpty)
    }

    @Test("a Compare of a section plays it whole, now and before, reads each, and taking the earlier one puts it back")
    func compared() async throws {
        let (app, directory, loop) = try SectionFixture.developed()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kits = directory.appendingPathComponent("kits", isDirectory: true)
        let hook = try SectionFixture.section("Hook", app)
        #expect(await app.compareSection(hook.id, kitsDirectory: kits) == nil, "it has not changed")
        _ = try #require(app.shade(hook.id, to: 0.3))

        let comparison = try #require(await app.compareSection(hook.id, kitsDirectory: kits))
        #expect(comparison.title == "Hook, now and before" && comparison.rows.count == 2)
        let now = try #require(comparison.rows.first?.lufs), was = try #require(comparison.rows.last?.lufs)
        #expect(now.isFinite && was.isFinite && was > now + 0.5, "the hook as it was is louder: \(was) against \(now)")
        #expect(comparison.rows[1].differs.contains { $0.hasPrefix("drums: ") })
        #expect(app.bench.items.contains { $0.id == comparison.surface && $0.kind == .compare })

        // Through the wiring: a real Compare, two rows that are sections, the verse at the head.
        let wiring = SurfaceWiring()
        wiring.use(WiringFixture.silentService())
        let item = try #require(app.bench.items.first { $0.id == comparison.surface })
        guard case .ready(let model) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("the Compare was not filled")
            return
        }
        #expect(model.candidates.count == 2 && model.candidates.allSatisfy { $0.state != nil })
        #expect(model.reference.title.hasPrefix("Verse") && model.reference.state != nil)
        #expect(model.candidates[0].reading(.integratedLUFS) != nil)

        // The plan a state plays is the section as it stood: lifted drums at +0.5 dB.
        let earlier = try #require(model.candidates[1].state)
        let plan = try #require(app.playback(of: earlier))
        #expect(plan.mix?.gainDB(for: loop.drums.partID, in: hook.id) == 0.5)
        let adapter = CompareAdapter(app: app, service: WiringFixture.silentService(), surface: item.id)
        #expect(await adapter.choose(model.candidates[0]), "taking the one that is playing leaves it")
        #expect(app.standing(hook.id)?.sounds(like: earlier) == false)
        #expect(await adapter.choose(model.candidates[1]))
        #expect(app.standing(hook.id)?.sounds(like: earlier) == true)
        #expect(SectionFixture.level(loop.drums.partID, in: try SectionFixture.section("Hook", app), app) == 0.5)
    }
}

@Suite("Director: set_intensity and compare_section", .serialized) @MainActor
struct DirectorSectionToolTests {

    private func rig() throws -> WritingFixture.Rig {
        let rig = WritingFixture.rig(try DevelopFixture.loop().song)
        _ = try #require(rig.app.develop())
        rig.app.sectionSettle = 0
        return rig
    }

    @Test("\"chorus\" is every hook: each is brought down, says what moved, and reads what it reads")
    func byName() async throws {
        let rig = try rig()
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "set_intensity", #"{"section":"chorus","intensity":0.6}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        let sections = try #require(out["sections"] as? [[String: Any]])
        #expect(sections.count == 3 && sections.allSatisfy { $0["name"] as? String == "Hook" && $0["now"] as? Double == 0.6 })
        #expect((sections[0]["moved"] as? [String])?.contains { $0.hasPrefix("drums: lifted") } == true, "\(sections[0])")
        let before = try #require(sections[0]["lufs_before"] as? Double), after = try #require(sections[0]["lufs_after"] as? Double)
        #expect(after < before, "it read \(before) and reads \(after)")
        #expect((out["detail"] as? String)?.contains("It read") == true)
        #expect(rig.app.song?.sections.filter { $0.name == "Hook" }.allSatisfy { $0.intensity == 0.6 } == true)
        #expect(rig.app.log.contains { $0.source == .director && $0.text.hasPrefix("Hook at 60%, from") })

        // Asked again for the same, nothing moves and it says so.
        let again = WritingFixture.json(await WritingFixture.run(rig.box, "set_intensity", #"{"section":"Hook","intensity":0.6}"#))
        #expect((again["detail"] as? String)?.contains("plays as it did") == true, "\(again["detail"] ?? "")")
    }

    @Test("one section by id; a name the song does not have and a number that is not an intensity are refused")
    func byIDAndRefusals() async throws {
        let rig = try rig()
        defer { rig.clean() }
        let last = try #require(rig.app.song?.sections.last { $0.name == "Hook" })
        let one = WritingFixture.json(await WritingFixture.run(rig.box, "set_intensity", #"{"section":"\#(last.id)","intensity":0.7}"#))
        #expect((one["sections"] as? [[String: Any]])?.count == 1)
        #expect(rig.app.song?.sections.filter { $0.name == "Hook" }.map(\.intensity) == [0.9, 0.93, 0.7])
        let nobody = await WritingFixture.run(rig.box, "set_intensity", #"{"section":"Zebra","intensity":0.5}"#)
        #expect(nobody.isError && nobody.content.contains("Intro, Verse, Hook"))
        let wild = await WritingFixture.run(rig.box, "set_intensity", #"{"section":"Hook","intensity":3}"#)
        #expect(wild.isError && wild.content.contains("0 to 1"))
    }

    @Test("compare_section opens the section against how it stood, and refuses when it has not changed")
    func compare() async throws {
        let rig = try rig()
        defer { rig.clean() }
        let unchanged = await WritingFixture.run(rig.box, "compare_section", #"{"section":"chorus"}"#)
        #expect(unchanged.isError && unchanged.content.contains("has not changed"))
        _ = await WritingFixture.run(rig.box, "set_intensity", #"{"section":"chorus","intensity":0.4}"#)
        let result = await WritingFixture.run(rig.box, "compare_section", #"{"section":"chorus"}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        let rows = try #require(out["rows"] as? [[String: Any]])
        #expect(out["title"] as? String == "Hook, now and before" && rows.count == 2)
        #expect(rows[0]["title"] as? String == "Hook as it is now" && rows[1]["title"] as? String == "Hook before")
        #expect((rows[1]["lufs"] as? Double ?? 0) > (rows[0]["lufs"] as? Double ?? 0))
        #expect(rig.app.bench.items.contains { $0.kind == .compare })
    }

    @Test("the two are the forty-eighth and forty-ninth, said in the prompt, and take a section and a number")
    func appended() throws {
        #expect(Array(DirectorTools.names[47...48]) == ["set_intensity", "compare_section"])
        #expect(DirectorPrompt.system.contains("set_intensity") && DirectorPrompt.system.contains("compare_section"))
        #expect(DirectorPrompt.system.contains("A section that reads the same is not quieter"))
        #expect(DirectorSession.activity(for: "set_intensity") == "Bringing the section up or down…")
        // With no frame behind it the move is still kept: the lanes, the intensity and the levels.
        let loop = try DevelopFixture.loop().song
        let scratch = DirectorScratchWorkspace(song: try DevelopFixture.developed(loop, try #require(Develop.plan(for: loop))))
        let hook = try #require(scratch.song?.sections.first { $0.name == "Hook" })
        let shading = try #require(scratch.shade(section: hook.id, to: 0.6))
        #expect(shading.was == 0.9 && scratch.song?.section(hook.id)?.intensity == 0.6)
    }
}
