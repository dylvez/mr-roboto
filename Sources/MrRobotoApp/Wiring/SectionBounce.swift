import AVFAudio
import AudioEngine
import Foundation
import Instrument
import Performance
import SongGraph

/// A section of the song rendered offline, the way the transport would play it — and then again
/// with only the drums, and again with only the bass — so the Engineer can read the mix and say
/// who owns the low end. Nothing here touches the live graph: each render is its own manual-mode
/// engine, driven through the same `LiveSongPlayer` the transport uses, so the bounce is what
/// playback would have been, not a second opinion of it.
enum SectionBounce {

    struct Stems: Sendable {
        var label: String
        var sampleRate: Double
        var mix: [[Float]]
        var drums: [[Float]]
        var bass: [[Float]]
        /// The high cut of the section's chain, when it has one.
        var chainCornerHz: Double?

        var observation: MixObservation {
            MixObservation.measure(label: label, mix: mix, sampleRate: sampleRate,
                                   drums: drums.first?.isEmpty == false ? drums : nil,
                                   bass: bass.first?.isEmpty == false ? bass : nil,
                                   chainCornerHz: chainCornerHz)
        }
    }

    enum Part { case mix, drums, bass }

    /// Renders one section of an arranged plan, or the whole of a flat one when `section` is nil.
    /// The tail is half a second past the section's last bar, so a ringing kick is counted.
    @AudioActor
    static func render(_ plan: SongPlayback, section: SectionID? = nil, kitsDirectory: URL,
                       sampleRate: Double = 48_000, tailSeconds: Double = 0.5) async throws -> Stems {
        let clock = TransportClock(tempo: plan.tempo, timeSignature: plan.timeSignature, sampleRate: sampleRate)
        let (base, label, bars) = try isolate(plan, section: section)
        let seconds = clock.seconds(forBeat: Double(bars * plan.timeSignature.beatsPerBar)) + tailSeconds
        let frames = AVAudioFramePosition((seconds * sampleRate).rounded())

        var stems = Stems(label: label, sampleRate: sampleRate, mix: [], drums: [], bass: [],
                          chainCornerHz: corner(of: base))
        stems.mix = try await renderOne(base, part: .mix, clock: clock, frames: frames, kitsDirectory: kitsDirectory, sampleRate: sampleRate)
        if let master = base.mix?.master {
            // The ceiling is not on the live chain (a lookahead limiter has latency): it is here.
            stems.mix = Limiter.apply(stems.mix, sampleRate: sampleRate, ceilingDBTP: master.ceilingDBTP)
        }
        if has(base, .drums) {
            stems.drums = try await renderOne(base, part: .drums, clock: clock, frames: frames, kitsDirectory: kitsDirectory, sampleRate: sampleRate)
        }
        if has(base, .bass) {
            stems.bass = try await renderOne(base, part: .bass, clock: clock, frames: frames, kitsDirectory: kitsDirectory, sampleRate: sampleRate)
        }
        return stems
    }

    // MARK: - The plan, cut down

    /// The plan reduced to one section starting at bar 0, the loop off. A flat plan is left whole,
    /// bounded by its own length or one bar.
    static func isolate(_ plan: SongPlayback, section: SectionID?) throws -> (SongPlayback, String, Int) {
        var copy = plan.looping(false)
        if plan.isArranged {
            guard let segment = section.flatMap({ id in plan.segments.first { $0.section == id } }) ?? plan.segments.first else {
                throw Failure.nothingToBounce("the song has no sections")
            }
            var moved = segment
            moved.startBar = 0
            copy.segments = [moved]
            copy.lengthInBars = moved.lengthInBars
            return (copy, segment.name, moved.lengthInBars)
        }
        guard section == nil else { throw Failure.nothingToBounce("the song is not arranged") }
        let bars = max(1, plan.lengthInBars ?? 1)
        copy.lengthInBars = bars
        return (copy, "Song", bars)
    }

    /// The plan with only one part left in it.
    static func only(_ part: Part, of plan: SongPlayback) -> SongPlayback {
        var copy = plan
        switch part {
        case .mix:
            break
        case .drums:
            copy.bassline = nil; copy.basslineVersion = nil; copy.bassSound = nil
            copy.chop = nil; copy.tracks = []
            copy.segments = copy.segments.map { var s = $0; s.bassline = nil; s.basslineVersion = nil; s.bassSound = nil; s.chop = nil; return s }
        case .bass:
            copy.groove = nil; copy.grooveVersion = nil; copy.grooveChain = []
            copy.chop = nil; copy.tracks = []
            copy.segments = copy.segments.map { var s = $0; s.groove = nil; s.grooveVersion = nil; s.grooveChain = []; s.chop = nil; return s }
        }
        return copy
    }

    static func has(_ plan: SongPlayback, _ part: Part) -> Bool {
        switch part {
        case .mix: return plan.isPlayable
        case .drums: return plan.groove != nil || plan.segments.contains { $0.groove != nil }
        case .bass: return plan.bassline != nil || plan.segments.contains { $0.bassline != nil }
        }
    }

    /// The chain's high cut, when the groove is dusty and the chain sets one above zero.
    static func corner(of plan: SongPlayback) -> Double? {
        let chain = plan.segments.first?.grooveChain ?? plan.grooveChain
        let cuts = chain.compactMap { pass -> Double? in
            let cut = DegradeSettings(pass).highCut
            return cut > 0 ? cut : nil
        }
        return cuts.min()
    }

    // MARK: - One render

    @AudioActor
    private static func renderOne(_ plan: SongPlayback, part: Part, clock: TransportClock, frames: AVAudioFramePosition,
                                  kitsDirectory: URL, sampleRate: Double) async throws -> [[Float]] {
        let engine = try Engine(playerCount: 4, sampleRate: sampleRate, channels: 2)
        try engine.prepare(offlineSampleRate: sampleRate, maximumFrames: 4_096)
        try engine.start()
        let service = AuditionService(engine: { engine }, kitsDirectory: kitsDirectory)
        let player = LiveSongPlayer(service: service)
        defer {
            engine.stopTransport()
            engine.stop()
        }
        try await player.begin(only(part, of: plan), clock: clock)
        _ = try engine.startTransport(clock: clock)
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: frames)
        await player.end()
        await service.shutdown()
        return AuditionService.planar(out)
    }

    enum Failure: Error, CustomStringConvertible {
        case nothingToBounce(String)
        var description: String {
            switch self { case .nothingToBounce(let why): return "Nothing to bounce: \(why)." }
        }
    }
}
