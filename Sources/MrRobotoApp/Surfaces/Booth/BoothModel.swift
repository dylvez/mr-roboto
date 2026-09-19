import AudioEngine
import Foundation
import SongGraph

/// What the Booth needs from its host: the song, the transport, a recorder, and a way to keep a take.
@MainActor
public protocol BoothHosting: AnyObject {
    var song: Song? { get }
    var clock: TransportClock { get }
    var isPlaying: Bool { get }
    var playhead: Double { get }
    func play() async
    func stop() async
    /// A recorder against the running transport, on the chosen input. Throws when there is no input.
    func recorder() async throws -> Recorder
    /// The input devices here now, the system's default first.
    var inputs: [AudioInputDevice] { get }
    /// Which device and channel a take comes from; remembered across launches.
    var input: InputChoice { get set }
    /// Where a take is written while it records.
    func scratchURL() -> URL
    /// Keeps a recording as a take version. Nil, with the reason in the rail, when it cannot be.
    func keep(_ recording: Recorder.Recording, take: Take) -> PartVersion?
    func note(_ text: String, detail: String?)
    /// The take started: a controller in Kit or Bass mode is captured alongside it.
    func recordingStarted(section: SectionID?, startedAt: Double)
    /// The take stopped, whatever it held.
    func recordingEnded(endedAt: Double)
}

public extension BoothHosting {
    func recordingStarted(section: SectionID?, startedAt: Double) {}
    func recordingEnded(endedAt: Double) {}
}

/// The Booth: pick a section, arm, record while the song plays, stop — that is a take.
@MainActor
@Observable
public final class BoothModel {

    public enum State: Equatable, Sendable {
        case idle
        case armed
        case recording
    }

    public let surfaceID: SurfaceID
    public private(set) var state: State = .idle
    /// The section the take is for. Nil records against the whole song.
    public var section: SectionID?
    /// Stop on the section's last bar by itself.
    public var punchesOut = true
    /// Whether the input is heard through the engine while recording.
    public var monitors = false
    /// The last buffer's peak, 0…1, while recording.
    public private(set) var level: Float = 0
    /// Takes kept this session, newest last.
    public private(set) var takes: [PartVersion] = []
    public private(set) var lastError: String?
    /// Transport seconds the recorder started at, for the display.
    public private(set) var startedAt: Double?
    /// The device and channel the next take comes from.
    public var input: InputChoice {
        didSet { host.input = input }
    }

    private let host: any BoothHosting
    private var recorder: Recorder?
    private var watching: Task<Void, Never>?

    public init(host: any BoothHosting, surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.section = host.song?.sections.first?.id
        self.takes = host.song.map(Guidance.takes(in:)) ?? []
        self.input = host.input
    }

    /// The input devices here now.
    public var inputs: [AudioInputDevice] { host.inputs }

    /// The chosen device, when it is here.
    public var inputDevice: AudioInputDevice? { input.device(in: inputs) }

    /// What the next take will say it came from — or why it falls back.
    public var inputLine: String { input.describe(in: inputs) }

    public var song: Song? { host.song }
    public var clock: TransportClock { host.clock }
    public var sections: [Section] { host.song?.sections ?? [] }
    public var isPlaying: Bool { host.isPlaying }
    public var playhead: Double { host.playhead }

    /// The bars the chosen section spans, 0-based, end exclusive.
    public var sectionBars: Range<Int>? {
        guard let song = host.song, let section else { return nil }
        var start = 0
        for candidate in song.sections {
            if candidate.id == section { return start..<(start + candidate.lengthInBars) }
            start += candidate.lengthInBars
        }
        return nil
    }

    /// Which pass of this section the next take is.
    public var nextPass: Int {
        (takes.compactMap { Guidance.audio(of: $0)?.take }.filter { $0.section == section }.map(\.pass).max() ?? 0) + 1
    }

    public func arm() {
        guard state == .idle else { return }
        state = .armed
        lastError = nil
    }

    public func disarm() {
        guard state == .armed else { return }
        state = .idle
    }

    /// Starts the song if it is not playing, and the recorder with it.
    public func record() async {
        guard state != .recording else { return }
        lastError = nil
        if !host.isPlaying { await host.play() }
        guard host.isPlaying else {
            lastError = "The song did not start, so there is nothing to sing to."
            state = .idle
            return
        }
        do {
            let recorder = try await host.recorder()
            try recorder.start(to: host.scratchURL())
            self.recorder = recorder
            startedAt = host.playhead
            state = .recording
            host.recordingStarted(section: section, startedAt: host.playhead)
            watch()
        } catch {
            lastError = "\(error)"
            state = .idle
        }
    }

    /// Stops the recorder; the recording becomes a take. The song keeps playing unless asked.
    @discardableResult
    public func stopRecording(stopSong: Bool = false) async -> PartVersion? {
        watching?.cancel()
        watching = nil
        guard state == .recording, let recorder else { return nil }
        self.recorder = nil
        state = .idle
        level = 0
        host.recordingEnded(endedAt: host.playhead)
        let recording: Recorder.Recording
        do {
            recording = try recorder.stop()
        } catch {
            lastError = "\(error)"
            if stopSong { await host.stop() }
            return nil
        }
        if stopSong { await host.stop() }
        guard recording.frames > 0 else {
            lastError = "Nothing was recorded."
            return nil
        }
        let placed = recording.alignmentSeconds ?? startedAt ?? 0
        let position = host.clock.position(forSeconds: max(0, placed))
        let take = Take(section: section, startBar: position.bar, startBeat: position.beat, input: recording.input,
                        latencyCompensation: recording.latencySeconds, pass: nextPass)
        guard let version = host.keep(recording, take: take) else {
            lastError = "The take could not be kept."
            return nil
        }
        takes.append(version)
        return version
    }

    /// Follows the level, and punches out at the section's end.
    private func watch() {
        watching?.cancel()
        watching = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                self.level = recorder.peak
                if self.punchesOut, let bars = self.sectionBars, self.host.playhead >= self.host.clock.seconds(forBar: bars.upperBound) {
                    await self.stopRecording()
                    return
                }
                if !self.host.isPlaying {
                    await self.stopRecording()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
