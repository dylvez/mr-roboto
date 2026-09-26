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

    enum Part {
        case mix, drums, bass

        /// Which voices this stem keeps, or nil for the whole mix. A chop is audio cut from the
        /// record and belongs to neither stem, which is why it is in neither list.
        var keeps: ((SongPlayback.Voice) -> Bool)? {
            switch self {
            case .mix: return nil
            case .drums: return { $0.groove != nil }
            case .bass: return { $0.bassline != nil }
            }
        }
    }

    /// Renders one section of an arranged plan, or the whole song (every section in order, or the
    /// flat plan) when `section` is nil. The tail is half a second past the last bar, so a ringing
    /// kick is counted.
    /// - Parameter onlyTheMix: skip the drums-only and bass-only renders. The Engineer's reading of
    ///   who owns the low end needs them; a loudness reading, an export and a strip solo do not,
    ///   and a whole song rendered three times over was most of what a master reading cost.
    @AudioActor
    static func render(_ plan: SongPlayback, section: SectionID? = nil, kitsDirectory: URL,
                       sampleRate: Double = 48_000, tailSeconds: Double = 0.5,
                       onlyTheMix: Bool = false) async throws -> Stems {
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
            // The whole song ends as it plays: its fade, after the limiter, so it only ever lowers.
            if section == nil, base.isArranged,
               let span = FadeOut.span(bars: master.fadeOutBars, songBars: bars, clock: clock) {
                FadeOut.apply(&stems.mix, sampleRate: sampleRate, span: span)
            }
        }
        if onlyTheMix { return stems }
        if has(base, .drums) {
            stems.drums = try await renderOne(base, part: .drums, clock: clock, frames: frames, kitsDirectory: kitsDirectory, sampleRate: sampleRate)
        }
        if has(base, .bass) {
            stems.bass = try await renderOne(base, part: .bass, clock: clock, frames: frames, kitsDirectory: kitsDirectory, sampleRate: sampleRate)
        }
        return stems
    }

    // MARK: - The plan, cut down

    /// The plan reduced to one section starting at bar 0, the loop off; with no section named, an
    /// arranged plan is left whole — every section in order — and a flat plan is bounded by its
    /// own length or one bar.
    static func isolate(_ plan: SongPlayback, section: SectionID?) throws -> (SongPlayback, String, Int) {
        var copy = plan.looping(false)
        if plan.isArranged {
            guard let section else {
                let bars = plan.lengthInBars ?? plan.segments.map { $0.startBar + $0.lengthInBars }.max() ?? 1
                copy.lengthInBars = bars
                return (copy, "Song", max(1, bars))
            }
            guard let segment = plan.segments.first(where: { $0.section == section }) else {
                throw Failure.nothingToBounce("the song has no such section")
            }
            // The whole plan moved to the section's first bar — takes and the record with it, one
            // already sounding played from that point of its file — then cut to the section. Only
            // the section used to move, so a Hook rendered at bar 0 had the Verse's take under it
            // and its own take outside the render.
            var moved = plan.looping(false).starting(atBar: segment.startBar)
            moved.segments = moved.segments.filter { $0.section == section }
            moved.lengthInBars = segment.lengthInBars
            let end = TransportClock(tempo: max(1, plan.tempo), timeSignature: plan.timeSignature).seconds(forBar: segment.lengthInBars)
            moved.tracks = moved.tracks.filter { $0.startsAt < end }
            return (moved, segment.name, segment.lengthInBars)
        }
        guard section == nil else { throw Failure.nothingToBounce("the song is not arranged") }
        let bars = max(1, plan.lengthInBars ?? 1)
        copy.lengthInBars = bars
        return (copy, "Song", bars)
    }

    /// The plan with only one part left in it.
    ///
    /// This used to nil eight fields on the plan and four more on every segment, twice, and adding
    /// a kind to the plan meant remembering to nil it here — which is how the chords ended up in
    /// the mix but in neither stem. A voice knows what it plays, so it is a filter.
    static func only(_ part: Part, of plan: SongPlayback) -> SongPlayback {
        var copy = plan
        guard let keep = part.keeps else { return copy }
        copy.voices = copy.voices.filter(keep)
        copy.segments = copy.segments.map { var s = $0; s.voices = s.voices.filter(keep); return s }
        copy.tracks = []
        return copy
    }

    static func has(_ plan: SongPlayback, _ part: Part) -> Bool {
        guard let keep = part.keeps else { return plan.isPlayable }
        return plan.voices.contains(where: keep) || plan.segments.contains { $0.voices.contains(where: keep) }
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
        // As many nodes as the live graph: a bounce goes through the same `LiveSongPlayer`, so a
        // form it can play is a form this can render.
        let engine = try Engine(playerCount: 8, sampleRate: sampleRate, channels: 2)
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
