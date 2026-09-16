import MusicTheory
import AVFAudio
import Foundation

/// Schedules click sounds on a player node at the beat times of a `BeatGrid`, with an
/// accented click on bar starts.
///
/// Clicks are scheduled ahead of the transport through `ScheduledSource.schedule(through:)`
/// using `AVAudioPlayerNode.scheduleBuffer(_:atTime:...)` with transport-derived
/// `AVAudioTime`s (host time in realtime, sample time offline). Nothing here runs in a
/// render callback.
@AudioActor
public final class Metronome: ScheduledSource {
    public struct Sound: Hashable, Sendable {
        public var frequency: Double
        public var accentFrequency: Double
        public var duration: Double
        public var amplitude: Float
        public var accentAmplitude: Float
        /// Exponential decay time constant in seconds.
        public var decay: Double

        public init(frequency: Double = 1320, accentFrequency: Double = 1760, duration: Double = 0.012,
                    amplitude: Float = 0.7, accentAmplitude: Float = 0.95, decay: Double = 0.003) {
            self.frequency = frequency
            self.accentFrequency = accentFrequency
            self.duration = duration
            self.amplitude = amplitude
            self.accentAmplitude = accentAmplitude
            self.decay = decay
        }

        public static let `default` = Sound()
    }

    public let player: AVAudioPlayerNode
    public var grid: BeatGrid {
        didSet { downbeats = grid.downbeatIndices() }
    }
    public var sound: Sound {
        didSet { if let transport { buildClicks(sampleRate: transport.sampleRate) } }
    }
    /// When false, beats are consumed but no clicks are scheduled.
    public var isEnabled = true
    /// Number of clicks scheduled since the transport started.
    public private(set) var scheduledBeatCount = 0

    private var transport: Transport?
    private var nextBeatIndex = 0
    private var downbeats: Set<Int>
    private var click: AVReadOnlyAudioPCMBuffer?
    private var accentClick: AVReadOnlyAudioPCMBuffer?

    /// - Parameters:
    ///   - engine: the engine whose player node `playerIndex` this metronome owns.
    ///   - grid: beat and bar times in transport seconds.
    public init(engine: Engine, playerIndex: Int = 0, grid: BeatGrid, sound: Sound = .default) throws {
        self.player = try engine.player(playerIndex)
        self.grid = grid
        self.sound = sound
        self.downbeats = grid.downbeatIndices()
    }

    /// A metronome following a fixed-tempo clock for `bars` bars.
    public convenience init(engine: Engine, playerIndex: Int = 0, clock: TransportClock, bars: Int,
                            sound: Sound = .default) throws {
        try self.init(engine: engine, playerIndex: playerIndex, grid: clock.grid(bars: bars), sound: sound)
    }

    // MARK: ScheduledSource

    public func transportDidStart(_ transport: Transport) {
        self.transport = transport
        nextBeatIndex = 0
        scheduledBeatCount = 0
        buildClicks(sampleRate: transport.sampleRate)
    }

    public func schedule(through seconds: Double) {
        guard let transport, let click, let accentClick else { return }
        while nextBeatIndex < grid.beats.count, grid.beats[nextBeatIndex] < seconds {
            let index = nextBeatIndex
            nextBeatIndex += 1
            let time = grid.beats[index]
            guard time >= 0, isEnabled else { continue }
            let buffer = downbeats.contains(index) ? accentClick : click
            player.scheduleBuffer(buffer, atTime: transport.playerTime(atSeconds: time), options: [],
                                  completionCallbackType: .dataRendered, completionHandler: nil)
            scheduledBeatCount += 1
        }
    }

    public func transportWillStop() {
        transport = nil
    }

    // MARK: clicks

    private func buildClicks(sampleRate: Double) {
        let channels = player.outputFormat(forBus: 0).channelCount
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: max(channels, 1)),
              let normal = AudioSynth.click(format: format, frequency: sound.frequency, duration: sound.duration,
                                            amplitude: sound.amplitude, decay: sound.decay),
              let accent = AudioSynth.click(format: format, frequency: sound.accentFrequency, duration: sound.duration,
                                            amplitude: sound.accentAmplitude, decay: sound.decay)
        else { return }
        click = AVReadOnlyAudioPCMBuffer(copying: normal)
        accentClick = AVReadOnlyAudioPCMBuffer(copying: accent)
    }
}
