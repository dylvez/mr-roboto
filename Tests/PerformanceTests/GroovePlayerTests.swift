import AVFoundation
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// A manual-rendering host for one `VoiceSampler`, the same shape `AudioEngine.Engine` gives it:
/// transport zero anchored at the current render position, sources asked to schedule ahead of every
/// chunk, chunked `renderOffline`. No audio device, which is what this machine's automated shells
/// require.
@AudioActor
final class OfflineGrooveHost {
    let av = AVAudioEngine()
    let sampler: VoiceSampler
    let sampleRate: Double
    let format: AVAudioFormat
    /// Mirrors `Engine.lookAhead`.
    var lookAhead: Double = 0.25
    private(set) var originSampleTime: AVAudioFramePosition = 0
    private var stopped = false

    init(sampler: VoiceSampler, sampleRate: Double = 48_000) throws {
        self.sampler = sampler
        self.sampleRate = sampleRate
        self.format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let node = try #require(sampler.node, "prepare(_:) the sampler before hosting it")
        av.attach(node)
        try av.connectNode(node, to: av.mainMixerNode, format: format)
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try av.start()
    }

    /// Start the transport and give `source` its first look-ahead window, exactly as
    /// `Engine.startTransport` does.
    func startTransport(_ source: GroovePlayer) {
        originSampleTime = av.manualRenderingSampleTime
        source.transportDidStart(originSampleTime: Int64(originSampleTime), sampleRate: sampleRate)
        source.schedule(through: lookAhead)
    }

    var transportSeconds: Double {
        Double(av.manualRenderingSampleTime - originSampleTime) / sampleRate
    }

    /// Render `seconds` of audio, asking `source` to schedule ahead before every chunk.
    @discardableResult
    func render(seconds: Double, driving source: GroovePlayer) throws -> Float {
        let total = AVAudioFramePosition((seconds * sampleRate).rounded())
        let maxFrames = av.manualRenderingMaximumFrameCount
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames))
        var rendered: AVAudioFramePosition = 0
        var peak: Float = 0
        while rendered < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), total - rendered))
            let end = Double(av.manualRenderingSampleTime + AVAudioFramePosition(n) - originSampleTime) / sampleRate
            source.schedule(through: end + lookAhead)
            let status = try av.renderOffline(n, to: chunk)
            guard status == .success || status == .insufficientDataFromInputNode else {
                Issue.record("offline render returned \(status.rawValue)")
                break
            }
            if let data = chunk.floatChannelData {
                for i in 0..<Int(chunk.frameLength) { peak = max(peak, abs(data[0][i * chunk.stride])) }
            }
            rendered += AVAudioFramePosition(chunk.frameLength)
        }
        return peak
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        av.stop()
        if let node = sampler.node { av.detach(node) }
        if av.isInManualRenderingMode { av.disableManualRenderingMode() }
    }
}

@Suite("Groove player")
struct GroovePlayerTests {

    static let sampleRate = 48_000.0

    /// Twelve hits a bar: kick on 1 and 3, snare on 2 and 4, hats on every eighth.
    static let oneBar = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
        GroovePattern(voice: .closedHat, steps: (0..<16).map { $0 % 2 == 0 ? .normal : .rest }),
        GroovePattern(voice: .snare, steps: (0..<16).map { $0 == 4 || $0 == 12 ? .accent : .rest }),
        GroovePattern(voice: .kick, steps: (0..<16).map { $0 == 0 || $0 == 8 ? .accent : .rest }),
    ])
    static let hitsPerBar = 8 + 2 + 2

    /// Build a TR-808 into a temporary folder and prepare a sampler on it.
    static func preparedSampler() throws -> (VoiceSampler, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceTests-\(UUID().uuidString)", isDirectory: true)
        let kit = try SynthesizedKit.build(.tr808, in: folder, sampleRate: sampleRate, layerCount: 2)
        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: sampleRate, channels: 1)
        return (sampler, folder)
    }

    @AudioActor
    @Test("four bars through a real sampler: every hit arrives, none is dropped")
    func fourBarsThroughTheSampler() async throws {
        let (sampler, folder) = try Self.preparedSampler()
        defer { try? FileManager.default.removeItem(at: folder) }

        let bpm = 90.0
        let player = GroovePlayer(sampler: sampler, groove: Self.oneBar,
                                  timeline: .tempo(bpm), bars: 4)
        let host = try OfflineGrooveHost(sampler: sampler, sampleRate: Self.sampleRate)
        defer { host.stop() }

        host.startTransport(player)
        let barSeconds = 60.0 / bpm * 4
        // A little past the end so the last bar's hits are consumed, not merely queued.
        let peak = try host.render(seconds: 4 * barSeconds + 1.0, driving: player)

        #expect(player.scheduledLoopCount == 4, "four one-bar iterations")
        #expect(player.scheduledHitCount == 4 * Self.hitsPerBar,
                "expected \(4 * Self.hitsPerBar) hits, got \(player.scheduledHitCount)")
        #expect(player.isFinished)
        #expect(sampler.droppedEventCount == 0, "the core dropped events")
        #expect(sampler.unmappedHitCount == 0, "the kit had no zone for a voice in the groove")
        #expect(sampler.pendingHitCount == 0, "hits were left queued past the end of the run")
        #expect(peak > 0.01, "four bars of drums should make a sound")
    }

    @AudioActor
    @Test("looping forever keeps producing, and stops when the transport does")
    func loopsUntilStopped() async throws {
        let (sampler, folder) = try Self.preparedSampler()
        defer { try? FileManager.default.removeItem(at: folder) }

        let player = GroovePlayer(sampler: sampler, groove: Self.oneBar, timeline: .tempo(120), bars: nil)
        let host = try OfflineGrooveHost(sampler: sampler, sampleRate: Self.sampleRate)
        defer { host.stop() }

        host.startTransport(player)
        try host.render(seconds: 6.0, driving: player)
        #expect(player.isFinished == false)
        #expect(player.scheduledLoopCount >= 3)
        #expect(player.scheduledHitCount == player.scheduledLoopCount * Self.hitsPerBar)
        #expect(sampler.droppedEventCount == 0)

        player.transportWillStop()
        #expect(player.isFinished)
    }

    // MARK: Position and shape — no engine needed

    @AudioActor
    @Test("the player reports where it is")
    func reportsPosition() async throws {
        let sampler = VoiceSampler(cache: SampleCache())
        let bpm = 120.0
        let beat = 60.0 / bpm
        let player = GroovePlayer(sampler: sampler, groove: Self.oneBar, timeline: .tempo(bpm), bars: 8)
        player.drivesSampler = false

        #expect(player.stepsPerLoop == 16)
        #expect(player.barsPerLoop == 1)
        #expect(player.totalLoops == 8)
        #expect(abs(player.endTime! - 8 * 4 * beat) < 1e-9)

        let position = player.position(at: 5 * beat + beat / 2)
        #expect(position.bar == 1)
        #expect(abs(position.beat - 5.5) < 1e-9)
        #expect(abs(position.beatInBar - 1.5) < 1e-9)
        #expect(position.loop == 1)
        #expect(position.step == 6, "beat 1.5 of the bar is the seventh sixteenth")
    }

    @AudioActor
    @Test("a two-bar feel rounds its bar count up to whole phrases")
    func roundsToWholePhrases() async throws {
        let sampler = VoiceSampler(cache: SampleCache())
        let feel = FeelLibrary.standard["Boom-Bap Pocket"]!
        let player = GroovePlayer(sampler: sampler, feel: feel, timeline: feel.suggestedTimeline, bars: 5)
        player.drivesSampler = false
        #expect(player.barsPerLoop == 2)
        #expect(player.totalLoops == 3, "five bars of a two-bar phrase is three phrases")
    }

    /// Scheduling in look-ahead chunks must produce exactly what one offline render would — the
    /// property that makes a bounce reproducible even though playback is chunked.
    @AudioActor
    @Test("chunked scheduling equals a single render")
    func chunkedEqualsWhole() async throws {
        let sampler = VoiceSampler(cache: SampleCache())
        let feel = FeelLibrary.standard["Lo-Fi Hip-Hop"]!
        let timeline = feel.suggestedTimeline
        let player = GroovePlayer(sampler: sampler, feel: feel, timeline: timeline, bars: 8)
        player.drivesSampler = false

        player.transportDidStart(originSampleTime: 0, sampleRate: Self.sampleRate)
        var t = 0.0
        while !player.isFinished && t < 60 {
            player.schedule(through: t)
            t += 0.05
        }
        #expect(player.scheduledLoopCount == 4)

        var options = GrooveRenderOptions.feel(feel)
        options.repeats = 4
        let whole = GrooveRenderer.render(feel.groove, on: timeline, options: options)
        #expect(player.scheduledHitCount == whole.count)
    }
}
