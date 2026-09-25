import AVFAudio
import AppKit
import AudioEngine
import Foundation
import Performance
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// Singing is one act: the Booth counts you in, keeps the words in view, and has the section's takes
// and the comp underneath, so nothing about a take needs another surface.

/// Waits for the Booth's own watcher to see what the test just changed.
@MainActor
private func settle(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private func tone(frames: Int, rate: Double = 48_000, hz: Double = 220) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.4 * sin(2 * .pi * hz * Double(i) / rate)) }
    return buffer
}

@Suite("Singing: the Booth counts you in, shows the words, and comps below", .serialized) @MainActor
struct SingingTests {

    /// A Verse of four bars and a Hook of two, at 120: a bar is two seconds, the Hook starts at 8.
    private func song() -> Song {
        var song = FormFixture.build(tempo: 120).song
        let ids = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 4), Section(name: "Hook", stitch: ids, lengthInBars: 2)]
        return song
    }

    /// Defaults of the test's own, so a count-in chosen here is never the app's.
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "booth-test-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// A host whose recorder hears four buffers from `bar` on, against an offline transport whose
    /// zero is the song's top — so the recording is placed in song time.
    private func host(recordingFromBar bar: Int) -> StubBoothHost {
        let host = StubBoothHost(song: song())
        host.transport = Transport(clock: host.clock, mode: .offline(sampleRate: 48_000, maximumFrames: 4_096), originSampleTime: 0)
        let start = host.clock.frame(forBar: bar)
        host.buffers = (0..<4).map { i in (tone(frames: 2_048), AVAudioTime(sampleTime: start + AVAudioFramePosition(i * 2_048), atRate: 48_000)) }
        return host
    }

    @Test("Record starts the song from the section, counted in and clicked as chosen; a song already playing is joined, not counted")
    func recordCountsIn() async throws {
        let host = host(recordingFromBar: 2)
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoothModel(host: host, defaults: defaults)
        let hook = try #require(host.song?.sections[1].id)
        model.section = hook
        model.countInBars = 2
        model.click = true

        await model.record()
        #expect(model.state == .recording)
        #expect(host.plays.count == 1)
        #expect(host.plays.first?.section == hook && host.plays.first?.countInBars == 2 && host.plays.first?.click == true)
        #expect(host.playhead == 4, "two bars before the Hook's first bar, in song time")

        // The song plays on; the next take joins it where it is.
        _ = await model.stopRecording()
        #expect(host.isPlaying)
        await model.record()
        #expect(host.plays.count == 1, "Record started the song again under a take already playing")
        #expect(model.countInLine == nil, "nothing counts in to a song already playing")
        _ = await model.stopRecording(stopSong: true)

        // Off is no count-in, and the host is still told so.
        model.countInBars = 0
        model.click = false
        await model.record()
        #expect(host.plays.last?.countInBars == 0 && host.plays.last?.click == false)
        #expect(model.countInLine == nil)
        _ = await model.stopRecording(stopSong: true)
    }

    @Test("the count-in and the click are remembered in the defaults the Booth is given")
    func settingsPersist() throws {
        let host = StubBoothHost(song: song())
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = BoothModel(host: host, defaults: defaults)
        #expect(first.countInBars == 1 && !first.click, "one bar and no click before anything is chosen")
        first.countInBars = 2
        first.click = true
        #expect(defaults.integer(forKey: "booth.countInBars") == 2 && defaults.bool(forKey: "booth.click"))

        let second = BoothModel(host: host, defaults: defaults)
        #expect(second.countInBars == 2 && second.click)
        second.countInBars = 0
        #expect(BoothModel(host: host, defaults: defaults).countInBars == 0, "Off is remembered as off, not read back as the default")
        second.countInBars = 7
        #expect(second.countInBars == 2, "two bars is the most on offer")
        #expect(defaults.integer(forKey: "booth.countInBars") == 2)
    }

    @Test("the punch-out waits out the count-in, the Booth counts 2… 1…, and a counted-in take begins on the section's first bar")
    func punchOutAfterCountIn() async throws {
        // The recorder hears from bar 2 (4 s), the first of the Hook's two count-in bars, less the
        // stub's 10 ms of latency.
        let host = host(recordingFromBar: 2)
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoothModel(host: host, defaults: defaults)
        let hook = try #require(host.song?.sections[1].id)
        model.section = hook
        model.countInBars = 2
        #expect(model.sectionBars == 4..<6)

        await model.record()
        #expect(model.state == .recording)
        #expect(model.countInBarsLeft == 2 && model.countInLine == "Counting in: 2…")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.state == .recording, "the watcher stopped the take during the count-in")

        host.playhead = 7 // half a bar before the Hook
        await settle { model.countInBarsLeft == 1 }
        #expect(model.countInLine == "Counting in: 2… 1…")

        host.playhead = 9 // inside the Hook: the take proper
        await settle { model.countInBarsLeft == nil }
        #expect(model.countInLine == nil && model.state == .recording)

        host.playhead = 12 // the Hook's last bar is over
        await settle { model.state == .idle }
        #expect(model.state == .idle, "the take did not punch out at the section's end")
        let version = try #require(model.takes.last)
        let audio = try #require(Guidance.audio(of: version))
        let take = try #require(audio.take)
        #expect(take.section == hook)
        #expect(take.startBar == 4 && take.startBeat == 0, "a counted-in take begins on the section's first bar: \(take.startBar) \(take.startBeat)")
        #expect(abs((audio.alignmentOffset ?? 0) - 3.99) < 0.001, "the audio keeps where the recorder heard it, for playback to trim")
    }

    @Test("stopped before the count-in ends, nothing was sung, so nothing is filed and the Booth says why")
    func stoppedDuringCountIn() async throws {
        let host = host(recordingFromBar: 2)
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoothModel(host: host, defaults: defaults)
        model.section = try #require(host.song?.sections[1].id)
        model.countInBars = 2
        await model.record()
        host.playhead = 5
        let version = await model.stopRecording(stopSong: true)
        #expect(version == nil && model.takes.isEmpty && model.lanes?.takes.isEmpty == true)
        #expect(model.lastError == "Stopped during the count-in, so there was no take to keep.")
        #expect(model.state == .idle && model.countInLine == nil && !host.isPlaying)
    }

    @Test("with no count-in the take lands where it was sung, as it always did")
    func noCountInPlacesAsSung() async throws {
        let host = host(recordingFromBar: 2)
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoothModel(host: host, defaults: defaults)
        model.countInBars = 0
        await model.record()
        #expect(model.countInLine == nil)
        let version = try #require(await model.stopRecording(stopSong: true))
        let take = try #require(Guidance.audio(of: version)?.take)
        #expect(take.startBar == 1 && take.startBeat > 3.9, "\(take.startBar) \(take.startBeat)")
    }

    @Test("a take stopped in the Booth is in the section's lanes at once; the comp is made there and holds when another take comes")
    func takeLandsInLanes() async throws {
        let host = host(recordingFromBar: 0)
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoothModel(host: host, defaults: defaults)
        model.countInBars = 0
        let verse = try #require(host.song?.sections[0].id), hook = try #require(host.song?.sections[1].id)
        let lanes = try #require(model.lanes, "the Booth's host reads takes, so the Booth has lanes")
        #expect(lanes.takes.isEmpty)

        func sing() async throws -> PartVersion {
            await model.record()
            let version = try #require(await model.stopRecording(stopSong: true))
            // Eight seconds of audio under the verse, for the comp to render.
            host.audioByVersion[version.id] = Comp.TakeAudio(planar: [(0..<(8 * 48_000)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / 48_000)) }],
                                                             sampleRate: 48_000, alignmentSeconds: 0)
            return version
        }
        let one = try await sing()
        #expect(model.lanes === lanes, "the same lanes, brought up to date, so choices survive a take")
        #expect(lanes.takes.map(\.id) == [one.id])
        #expect(lanes.sectionName == "Verse" && lanes.bars == 0..<4)
        let two = try await sing()
        #expect(lanes.takes.map(\.id) == [one.id, two.id])
        #expect(model.takes(of: verse).count == 2 && model.nextPass == 3)

        lanes.choose(one.id, forBars: 0..<2)
        #expect(!lanes.compIsCurrent)
        #expect(lanes.keepComp(), "\(lanes.lastError ?? "")")
        #expect(lanes.compIsCurrent, "the comp lane is the comp just made, so Make the comp is off")
        #expect(lanes.comp?.parents == [one.id, two.id])

        let three = try await sing()
        #expect(lanes.takes.count == 3)
        #expect(lanes.take(forBar: 3) == two.id && lanes.compIsCurrent, "a take sung after the comp moved the comp lane by itself")
        lanes.choose(three.id, forBar: 3)
        #expect(!lanes.compIsCurrent)

        // Another section has lanes of its own; coming back finds the choices where they were.
        model.section = hook
        #expect(model.lanes !== lanes && model.lanes?.takes.isEmpty == true)
        model.section = verse
        #expect(model.lanes === lanes && lanes.take(forBar: 3) == three.id)
    }

    @Test("a take kept outside the Booth reaches its lanes when the song changes")
    func songChangedReadsTakesAgain() throws {
        let host = StubBoothHost(song: song())
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoothModel(host: host, defaults: defaults)
        let verse = try #require(host.song?.sections[0].id)
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "f", count: 64))!, fileExtension: "wav"), role: .take,
                          sampleRate: 48_000, channelCount: 1, duration: 8, alignmentOffset: 0, take: Take(section: verse, startBar: 0))
        let landed = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 1, Verse")
        try host.song?.append(landed)
        #expect(model.lanes?.takes.isEmpty == true)
        model.songChanged()
        #expect(model.lanes?.takes.map(\.id) == [landed.id])
    }

    @Test("the words are the song's newest lyric, stanza gaps kept; with none, there are no words to show")
    func words() throws {
        // A song with no words at all: the pane has nothing to show and says where words come from.
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let bare = BoothModel(host: StubBoothHost(song: Song(title: "Bare", tempo: 120)), defaults: defaults)
        #expect(bare.lyric == nil && bare.lyricLines.isEmpty && !bare.hasWords)

        // The fixture song has a lyric of its own; newer ones are appended after it.
        let host = StubBoothHost(song: song())
        let model = BoothModel(host: host, defaults: defaults)
        #expect(model.lyric?.type == .lyric, "the fixture's own lyric")

        let blank = PartVersion(partID: PartID(), kind: .lyric(Lyric(lines: [LyricLine(syllables: [])])), author: .user,
                                operation: Operation.written, note: "")
        try host.song?.append(blank)
        #expect(model.lyric?.id == blank.id && !model.hasWords, "a lyric of blank lines is no words")

        let words = Lyric(lines: [
            LyricLine(syllables: [Syllable("I", stress: .primary), Syllable("sang", stress: .primary), Syllable("it"), Syllable("once", stress: .primary)]),
            LyricLine(syllables: [Syllable("and"), Syllable("then", stress: .primary), Syllable("a"), Syllable("gain", stress: .primary, startsWord: false)]),
            LyricLine(syllables: []),
            LyricLine(syllables: [Syllable("the"), Syllable("hook", stress: .primary)]),
        ])
        let newest = blank.deriving(.lyric(words), by: .user, operation: Operation.edit, note: "")
        try host.song?.append(newest)
        #expect(model.lyric?.id == newest.id, "the newest lyric, not the first")
        #expect(model.hasWords)
        #expect(model.lyricLines.map(\.text) == ["I sang it once", "and then again", "", "the hook"])
        // Drawn as one run per line, so it wraps, with a syllable that continues a word joined to it.
        #expect(String(SungWords.sung(model.lyricLines[1]).characters) == "and then again")
    }

    @Test("the words pane sings the chosen section's stanza first, the rest faint under it; unlabelled, it says how to label one")
    func sectionWords() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = StubBoothHost(song: song())
        // Verse, Hook, and a second Verse.
        host.song?.sections.append(Section(name: "Verse", stitch: [], lengthInBars: 4))
        let model = BoothModel(host: host, defaults: defaults)
        let ids = try #require(host.song?.sections.map(\.id))

        // Words that name no stanza: the whole lyric, and how to get the Verse's.
        try host.song?.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "no labels\nat all")),
                                          author: .user, operation: Operation.written, note: ""))
        #expect(model.hasWords && model.sectionWords == nil)
        #expect(model.sectionWordsHint == "Label a stanza [Verse] on the Lyrics surface to see it here.")

        let text = "[Verse]\nfirst verse line\nstill the first\n\n[hook]\nthe hook line\n\n[Verse]\nsecond verse line"
        let words = Lyricist.lyric(from: text)
        try host.song?.append(PartVersion(partID: PartID(), kind: .lyric(words), author: .user,
                                          operation: Operation.written, note: ""))

        let verse = try #require(model.sectionWords)
        #expect(verse.name == "Verse")
        #expect(verse.stanza.map(\.text) == ["first verse line", "still the first"])
        #expect(verse.stanza == words.stanza(named: "Verse"), "the stanza the lyric itself names")
        #expect(verse.rest.map(\.line.text) == ["the hook line", "", "second verse line"], "the rest, one gap between stanzas")
        #expect(verse.rest.map(\.label) == ["hook", nil, "Verse"])
        #expect(model.sectionWordsHint == nil)

        model.section = ids[1]
        #expect(model.sectionWords?.name == "hook", "case aside")
        #expect(model.sectionWords?.stanza.map(\.text) == ["the hook line"])
        #expect(model.sectionWords?.rest.map(\.line.text) == ["first verse line", "still the first", "", "second verse line"])

        model.section = ids[2]
        #expect(model.sectionWords?.stanza.map(\.text) == ["second verse line"], "the second Verse sings the second stanza")

        // Whole song: no section to find, nothing to hint, every stanza labelled in place.
        model.section = nil
        #expect(model.sectionWords == nil && model.sectionWordsHint == nil)
        #expect(model.wordsLines.map(\.line.text) == ["first verse line", "still the first", "", "the hook line", "", "second verse line"])
        #expect(model.wordsLines.compactMap(\.label) == ["Verse", "hook", "Verse"])
        // One Verse stanza for two Verse sections: both sing it.
        try host.song?.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "[Verse]\nonly verse\nhere")),
                                          author: .user, operation: Operation.written, note: ""))
        model.section = ids[2]
        #expect(model.sectionWords?.stanza.map(\.text) == ["only verse", "here"])
        model.section = ids[1]
        #expect(model.sectionWords == nil && model.sectionWordsHint == "Label a stanza [Hook] on the Lyrics surface to see it here.")
    }

    @Test("the words and the takes share the room at every bench size, the words a readable column")
    func layout() {
        for size in SurfaceGeometry.all {
            let content = SurfaceGeometry.content(of: size)
            let layout = BoothLayout(width: content.width)
            #expect(layout.wordsWidth >= 200 && layout.wordsWidth <= 360, "\(size): words \(layout.wordsWidth)")
            #expect(layout.takesWidth >= 340, "\(size): takes \(layout.takesWidth)")
            #expect(layout.wordsWidth + layout.gutter + layout.takesWidth <= content.width + 0.5, "\(size) overflows")
        }
    }

    @Test("the Booth drawn at the bench's minimum and its default, counting in over words and takes",
          .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil, "set MRROBOTO_RENDER to a directory to write the renders"))
    func render() async throws {
        FontRegistration.registerBundledFonts()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] ?? NSTemporaryDirectory())
        let host = host(recordingFromBar: 0)
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Labelled, so the Verse being recorded is sung first and the Hook waits under it.
        let text = "[Verse]\nPulled the blinds on a Tuesday\nlet the kettle sing alone\nevery room I ever rented\nkept a little of my own\n\n"
            + "[Hook]\nSo call it off, call it over\ncall it anything but gone\nI have sung this at the window\nlong enough to know the song"
        try host.song?.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: text)), author: .user,
                                          operation: Operation.written, note: ""))
        let model = BoothModel(host: host, defaults: defaults)
        model.countInBars = 0
        for _ in 0..<3 {
            await model.record()
            _ = await model.stopRecording(stopSong: true)
        }
        model.countInBars = 2
        await model.record()
        for (size, name) in [(SurfaceGeometry.minimum, "booth-minimum"), (SurfaceGeometry.standard, "booth-standard")] {
            let renderer = ImageRenderer(content: BoothSurfaceView(model: model).frame(width: size.width, height: size.height))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        _ = await model.stopRecording(stopSong: true)
    }
}
