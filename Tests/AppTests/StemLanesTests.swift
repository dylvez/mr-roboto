import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A stem was not something a section could name. A mashup's stems played under every section and a
// record's own under none, so "the drums from bar 3" and "the voice only in the hook" were said
// with a level stepped down 6 dB at a time, which is not silence. These are a stem named in a
// stitch like any part: laid along the form, heard in the sections that name it, cut on the bar.

@MainActor
enum StemLanesFixture {
    /// A mashup of the fixture's two songs: Arrival's "other" and Exit Interview's drums, at 100
    /// bpm, in Lead-in 1 · Verse 3 · Chorus 4. A bar is 2.4 seconds.
    static func mashup(_ label: String) async throws -> (app: AppState, directory: URL, other: PartVersion, drums: PartVersion) {
        let directory = WiringFixture.temporaryDirectory(label)
        let (app, a, b) = try MashupFixture.app(in: directory)
        app.autosaveDelay = nil
        _ = try await app.makeMashup(MashupRequest(a: a.id, b: b.id, backbone: .a, stemsA: ["other"], stemsB: ["drums"]))
        let stems = Guidance.stems(in: try #require(app.song))
        return (app, directory, stems[0], stems[1])
    }

    static let bar = 2.4

    static func structure(_ app: AppState) -> StructureModel {
        let model = StructureModel(host: StructureAdapter(app: app), song: app.song)
        model.autoKeep.delay = nil
        return model
    }

    static func windows(of part: PartID, in app: AppState) -> [Range<Double>]? {
        app.playback.tracks.first { $0.part == part }?.windows
    }

    static func close(_ a: [Range<Double>]?, _ b: [Range<Double>]) -> Bool {
        guard let a, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.lowerBound - $1.lowerBound) < 1e-6 && abs($0.upperBound - $1.upperBound) < 1e-6 }
    }
}

@Suite("A section plays the stems it names", .serialized) @MainActor
struct StemLanesTests {

    @Test("a new mashup seats every stem in every section, and each is one window over the form")
    func seated() async throws {
        let (app, directory, other, drums) = try await StemLanesFixture.mashup("stems-seated")
        defer { WiringFixture.remove(directory) }
        let song = try #require(app.song)
        #expect(song.sections.allSatisfy { $0.stitch.map(\.part) == [other.partID, drums.partID] })
        #expect(song.seatedStems == [other.partID, drums.partID])
        #expect(app.playback.isArranged && app.playback.tracks.count == 2)
        for stem in [other, drums] {
            #expect(StemLanesFixture.close(StemLanesFixture.windows(of: stem.partID, in: app), [0..<8 * StemLanesFixture.bar]),
                    "neighbouring sections join into one window: \(String(describing: StemLanesFixture.windows(of: stem.partID, in: app)))")
        }
    }

    @Test("a stem taken out of a section has no window there; playing from a bar and bouncing one section follow")
    func windows() async throws {
        let (app, directory, other, drums) = try await StemLanesFixture.mashup("stems-windows")
        defer { WiringFixture.remove(directory) }
        let model = StemLanesFixture.structure(app)
        let verse = model.sections[1]
        model.toggle(drums.partID, in: verse.id)
        #expect(model.keep())
        let bar = StemLanesFixture.bar
        #expect(StemLanesFixture.close(StemLanesFixture.windows(of: drums.partID, in: app), [0..<bar, 4 * bar..<8 * bar]))
        #expect(StemLanesFixture.close(StemLanesFixture.windows(of: other.partID, in: app), [0..<8 * bar]))

        // From the Chorus: the drums' second window is the whole of what is left.
        let fromChorus = app.playback.starting(atBar: 4)
        #expect(StemLanesFixture.close(fromChorus.tracks.first { $0.part == drums.partID }?.windows, [0..<4 * bar]))
        // The Verse alone: no drums at all, and the other stem for the Verse's three bars only.
        let (cut, _, bars) = try SectionBounce.isolate(app.playback, section: verse.id)
        #expect(bars == 3 && cut.tracks.map(\.part) == [other.partID])
        #expect(StemLanesFixture.close(cut.tracks.first?.windows, [0..<3 * bar]))

        // Out of every section, it does not play at all.
        for section in model.sections where section.stitch.contains(part: drums.partID) { model.toggle(drums.partID, in: section.id) }
        #expect(model.keep())
        #expect(app.playback.tracks.map(\.part) == [other.partID])
    }

    @Test("a window is cut out of the buffer on its sample, with a fade only where the cut is inside the file")
    func pieces() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 10))
        buffer.frameLength = 48_000 * 10
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 1 }

        let whole = LiveSongPlayer.events(of: buffer, startingAt: 2, in: nil)
        #expect(whole.count == 1 && whole[0].0 === buffer && whole[0].1 == 2)

        // The file sounds from 2 s to 12 s; the form lets it through from 0 to 3 and from 6 to 20.
        let events = LiveSongPlayer.events(of: buffer, startingAt: 2, in: [0..<3, 6..<20])
        #expect(events.map(\.1) == [2, 6])
        #expect(events.map { Int($0.0.frameLength) } == [48_000, 48_000 * 6])
        let first = events[0].0.floatChannelData![0], second = events[1].0.floatChannelData![0]
        #expect(first[0] == 1, "its own first frame is as recorded")
        #expect(first[47_999] == 0 && first[47_000] == 1, "cut at 3 s: the last 8 ms ramp to nothing")
        #expect(second[0] == 0 && second[1_000] == 1, "comes in at 6 s on a ramp")
        #expect(second[48_000 * 6 - 1] == 1, "and runs to its own last frame")
        #expect(LiveSongPlayer.events(of: buffer, startingAt: 2, in: [20..<30]).isEmpty, "past its end there is nothing to play")
    }

    @Test("bounced, a stem out of the Verse is silent in the Verse and back on the Chorus's first beat")
    func silence() async throws {
        let (app, directory, other, drums) = try await StemLanesFixture.mashup("stems-bounce")
        defer { WiringFixture.remove(directory) }
        let model = StemLanesFixture.structure(app)
        // Only the drums' clicks, and not in the Verse.
        for section in model.sections { model.toggle(other.partID, in: section.id) }
        model.toggle(drums.partID, in: model.sections[1].id)
        #expect(model.keep())

        let kits = directory.appendingPathComponent("kits")
        let stems = try await SectionBounce.render(app.playback, section: nil, kitsDirectory: kits, onlyTheMix: true, mastered: false)
        let samples = try #require(stems.mix.first), rate = stems.sampleRate, bar = StemLanesFixture.bar
        func peak(_ from: Double, _ to: Double) -> Float {
            samples[Int(from * rate)..<min(samples.count, Int(to * rate))].map(abs).max() ?? 0
        }
        #expect(peak(bar + 0.05, 4 * bar - 0.05) == 0, "the Verse holds \(peak(bar + 0.05, 4 * bar - 0.05))")
        #expect(peak(4 * bar, 4 * bar + 0.7) > 0.1, "a click in the Chorus's first beat")
        #expect(peak(0, bar) > 0.1 || StemLanesFixture.close(StemLanesFixture.windows(of: drums.partID, in: app), [0..<bar, 4 * bar..<8 * bar]))
    }

    @Test("Structure draws a Stems row, a new section carries the stems of the one beside it, and nothing calls a stem missing")
    func structure() async throws {
        let (app, directory, other, drums) = try await StemLanesFixture.mashup("stems-structure")
        defer { WiringFixture.remove(directory) }
        let model = StemLanesFixture.structure(app)
        let verse = model.sections[1]
        #expect(model.choices(for: verse).map(\.type) == [.audio])
        #expect(model.choices(for: verse).first?.layers.map(\.id) == [other.partID, drums.partID])
        #expect(StructureModel.name(of: .audio) == "Stems" && model.kinds(of: verse) == ["Stems"])
        #expect(model.help(for: model.layer(drums.partID)!, in: verse).contains("runs along the song"))

        model.toggle(drums.partID, in: verse.id)
        #expect(model.missingText(from: model.sections[1]) == nil && model.orphanedText == nil, "a stem left out is a choice")
        // After the Verse, which has no drums: the new section has none either.
        model.select(verse.id)
        #expect(model.add(.hook).stitch.map(\.part) == [other.partID])
        // After the Lead-in, which has both.
        model.select(model.sections[0].id)
        #expect(model.add(.bridge).stitch.map(\.part) == [other.partID, drums.partID])
    }

    @Test("Split cuts a section in two that both play what it played, with a clean seam")
    func split() async throws {
        let (app, directory, _, drums) = try await StemLanesFixture.mashup("stems-split")
        defer { WiringFixture.remove(directory) }
        let model = StemLanesFixture.structure(app)
        let chorus = model.sections[2]
        let second = try #require(model.split(chorus.id, afterBar: 1))
        #expect(model.sections.map(\.lengthInBars) == [1, 3, 1, 3] && model.sections[2].id == chorus.id)
        #expect(second.name == "Chorus" && second.stitch == chorus.stitch && model.selected == second.id)
        #expect(model.sections[2].transitionOut?.kind == .cut && second.transitionIn?.kind == .cut)
        #expect(model.split(second.id, afterBar: 3) == nil && model.split(second.id, afterBar: 0) == nil)
        // "The drums from the Chorus's second bar": out of its first half.
        model.toggle(drums.partID, in: chorus.id)
        #expect(model.keep())
        let bar = StemLanesFixture.bar
        #expect(StemLanesFixture.close(StemLanesFixture.windows(of: drums.partID, in: app), [0..<4 * bar, 5 * bar..<8 * bar]))
    }

    @Test("every writer of the form keeps the stems: a part that joins, developing, an intensity, the Director's stitch and split")
    func writersKeepStems() async throws {
        let (app, directory, other, drums) = try await StemLanesFixture.mashup("stems-writers")
        defer { WiringFixture.remove(directory) }
        let stems = Set([other.partID, drums.partID])
        func seated() -> Bool { app.song!.sections.allSatisfy { stems.isSubset(of: Set($0.stitch.map(\.part))) } }

        // A groove joins the form beside them.
        let groove = TransportFixture.grooveVersion()
        #expect(app.record(groove) && seated())
        #expect(app.song!.sections.allSatisfy { $0.stitch.contains(part: groove.partID) })
        // The default a tool reaches for names them.
        #expect(Set(FormTools.defaultStitch(in: app.song!).map(\.part)) == stems.union([groove.partID]))
        // Developed, section by section.
        let development = try #require(app.develop())
        #expect(seated(), "\(development.plays.map(\.name)): \(app.song!.sections.map { $0.stitch.count })")
        // One section brought down.
        let first = try #require(app.song?.sections.first)
        _ = app.shade(first.id, to: 0.1)
        #expect(seated())

        // The Director names a stem like anything else, and leaving one out is how it is silenced.
        let workspace = AppStateWorkspace(app)
        let verse = try #require(app.song?.sections[1])
        let kept = verse.stitch.filter { $0.part != drums.partID }.compactMap { app.song?.latestVersion(of: $0.part)?.id.description }
        _ = try await StitchSectionTool(workspace: workspace).run(.init(name: "", bars: 0, versions: kept, position: 0, section: verse.id.description))
        #expect(app.song?.sections[1].stitch.contains(part: drums.partID) == false && app.song?.sections[1].stitch.contains(part: other.partID) == true)
        #expect(app.playback.tracks.first { $0.part == drums.partID }?.windows?.count == 2)

        let before = app.song!.sections.count
        let report = try await SplitSectionTool(workspace: workspace).run(.init(section: verse.id.description, afterBar: 1))
        #expect(report.recorded && app.song!.sections.count == before + 1 && app.song!.sections[1].lengthInBars == 1)
        await #expect(throws: DirectorToolFailure.self) {
            _ = try await SplitSectionTool(workspace: workspace).run(.init(section: verse.id.description, afterBar: 1))
        }
        #expect(DirectorTools.names.contains("split_section") && DirectorPrompt.system.contains("split_section"))
    }

    @Test("a record's own stems stay out of an arranged song until a section names one, and a new stem never joins by itself")
    func flipStems() throws {
        let directory = WiringFixture.temporaryDirectory("stems-flip")
        defer { WiringFixture.remove(directory) }
        let (app, a, _) = try MashupFixture.app(in: directory)
        app.autosaveDelay = nil
        app.open(a)
        let stem = try #require(Guidance.stems(in: a).first { Guidance.audio(of: $0)?.stem == "other" })
        let groove = TransportFixture.grooveVersion()
        #expect(app.record(groove))
        app.arrange([Section(name: "Verse", stitch: [groove.partID].lanes, lengthInBars: 2),
                     Section(name: "Hook", stitch: [groove.partID].lanes, lengthInBars: 2)])
        #expect(app.playback.isArranged && app.playback.tracks.isEmpty, "arranged, the record is off")

        let model = StemLanesFixture.structure(app)
        #expect(model.choices(for: model.sections[1]).map(\.type) == [.groove, .audio], "its stems are there to be turned on")
        #expect(model.orphanedText == nil && model.missingText(from: model.sections[1]) == nil)
        model.toggle(stem.partID, in: model.sections[1].id)
        #expect(model.keep())
        let track = try #require(app.playback.tracks.first)
        // At the song's tempo, its first downbeat (0.5 s in) on the form's first bar, heard in the Hook.
        #expect(track.part == stem.partID && abs(track.skip - 0.5) < 1e-9 && track.startsAt == 0)
        #expect(StemLanesFixture.close(track.windows, [2 * 2.4..<4 * 2.4]))

        // Another stem recorded into the arranged song is in no section.
        let media = try #require(Guidance.audio(of: stem)?.media)
        let late = PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .stem, stem: "vocals", sampleRate: 48_000, channelCount: 1, duration: 16)),
                               author: .user, operation: Operation.separate, note: "vocals stem")
        #expect(app.record(late))
        #expect(app.song?.sections.contains { $0.stitch.contains(part: late.partID) } == false)
    }
}
