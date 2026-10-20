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
        /// The lowest corner a strip's low-pass reaches in it, when one closes.
        var filterCornerHz: Double?
        /// True when it is one section of a form, not the whole song.
        var isSection = false

        var observation: MixObservation {
            var observation = MixObservation.measure(label: label, mix: mix, sampleRate: sampleRate,
                                                     drums: drums.first?.isEmpty == false ? drums : nil,
                                                     bass: bass.first?.isEmpty == false ? bass : nil,
                                                     chainCornerHz: chainCornerHz)
            observation.filterCornerHz = filterCornerHz
            observation.section = isSection ? label : nil
            return observation
        }
    }

    /// How a long render shares the audio actor: in pieces this many frames long, yielding between
    /// them so a sound asked for meanwhile is not kept waiting, saying how far it has got, and
    /// stopping when its task is cancelled. Nil renders in one go, as an export does.
    struct Pacing: Sendable {
        var frames: AVAudioFramePosition
        var progress: (@Sendable (Double) -> Void)?
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
    /// - Parameter upTo: render no more than this many bars of it.
    /// - Parameter onlyTheMix: skip the drums-only and bass-only renders. The Engineer's reading of
    ///   who owns the low end needs them; a loudness reading, an export and a strip solo do not,
    ///   and a whole song rendered three times over was most of what a master reading cost.
    @AudioActor
    static func render(_ plan: SongPlayback, section: SectionID? = nil, kitsDirectory: URL,
                       sampleRate: Double = 48_000, tailSeconds: Double = 0.5,
                       onlyTheMix: Bool = false, mastered: Bool = true, upTo limit: Int? = nil,
                       pacing: Pacing? = nil) async throws -> Stems {
        let clock = TransportClock(tempo: plan.tempo, timeSignature: plan.timeSignature, sampleRate: sampleRate)
        let (base, label, whole) = try isolate(plan, section: section)
        // A few bars of it, for hearing something against the song: not the whole record.
        let bars = limit.map { min(whole, max(1, $0)) } ?? whole
        let seconds = clock.seconds(forBeat: Double(bars * plan.timeSignature.beatsPerBar)) + tailSeconds
        let frames = AVAudioFramePosition((seconds * sampleRate).rounded())

        var stems = Stems(label: label, sampleRate: sampleRate, mix: [], drums: [], bass: [],
                          chainCornerHz: corner(of: base), filterCornerHz: filterCorner(of: base, section: section),
                          isSection: section != nil)
        stems.mix = try await renderOne(base, part: .mix, clock: clock, frames: frames, kitsDirectory: kitsDirectory, sampleRate: sampleRate,
                                        pacing: pacing)
        // A song never mixed has the default master, ceiling and all: it used to go out with no
        // ceiling, over 0 dBFS and hard-clipped, while the Master tab read a limited mix. A stem
        // (`mastered` false) goes out as its strip made it.
        if mastered {
            let master = base.mix?.master ?? Master()
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

    /// How long a song with no form runs: its stated length, its audio to the end, and one pass of
    /// its longest loop. It used to be its stated length or one bar, and a song with no sections
    /// has none — so an imported record exported as one bar and half a second.
    static func naturalBars(of plan: SongPlayback) -> Int {
        let clock = TransportClock(tempo: max(1, plan.tempo), timeSignature: plan.timeSignature)
        let beatsPerBar = max(1, plan.timeSignature.beatsPerBar)
        var bars = plan.lengthInBars ?? 0
        if let seconds = plan.audioDuration, clock.secondsPerBar > 0 {
            bars = max(bars, Int((seconds / clock.secondsPerBar - 1e-9).rounded(.up)))
        }
        for voice in plan.voices {
            switch voice.play {
            case .groove(let groove): bars = max(bars, groove.bars)
            case .bassline(let line): bars = max(bars, line.loopBars(beatsPerBar: beatsPerBar))
            case .melody(let tune): bars = max(bars, tune.loopBars(beatsPerBar: beatsPerBar))
            case .progression(let progression): bars = max(bars, progression.bars.count)
            case .chop(let chop): bars = max(bars, chop.bars(beatsPerBar: beatsPerBar))
            default: break
            }
        }
        return max(1, bars)
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
            // The section as the transport plays it alone (`SongPlayback.only(section:)`), once.
            guard let segment = plan.segments.first(where: { $0.section == section }),
                  let moved = plan.looping(false).only(section: section) else {
                throw Failure.nothingToBounce("the song has no such section")
            }
            return (moved, segment.name, segment.lengthInBars)
        }
        guard section == nil else { throw Failure.nothingToBounce("the song is not arranged") }
        let bars = naturalBars(of: plan)
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

    /// The lowest corner a low-pass filter reaches on a strip sounding in `section` (or anywhere,
    /// for the whole song): the section's own corner, held or swept to, else the strip's where it
    /// is closed. A whole song counts only the strips' own: one section's sweep does not darken
    /// it. Nil when no low-pass closes, or the plan has no mix.
    static func filterCorner(of plan: SongPlayback, section: SectionID?) -> Double? {
        guard let mix = plan.mix else { return nil }
        let sounding = section.flatMap { id in plan.segments.first { $0.section == id } }
            .map { Set($0.voices.compactMap(\.part)) } ?? Set(plan.parts)
        var corners: [Double] = []
        for strip in mix.strips where sounding.contains(strip.part) && !strip.isMuted {
            guard let filter = strip.filter, filter.kind == .lowPass else { continue }
            if let effect = mix.sectionEffect(for: strip.part, in: section), let from = effect.filterFromHz {
                corners += [from, effect.filterToHz ?? from]
            } else {
                corners.append(filter.cutoffHz)
            }
        }
        return corners.filter { $0 < 19_000 }.min()
    }

    // MARK: - One render

    @AudioActor
    private static func renderOne(_ plan: SongPlayback, part: Part, clock: TransportClock, frames: AVAudioFramePosition,
                                  kitsDirectory: URL, sampleRate: Double, pacing: Pacing? = nil) async throws -> [[Float]] {
        // As many nodes as the live graph: a bounce goes through the same `LiveSongPlayer`, so a
        // form it can play is a form this can render.
        let engine = try Engine(playerCount: SongPlayback.playerNodes, sampleRate: sampleRate, channels: 2)
        try engine.prepare(offlineSampleRate: sampleRate, maximumFrames: 4_096)
        try engine.start()
        let service = AuditionService(engine: { engine }, kitsDirectory: kitsDirectory)
        let player = LiveSongPlayer(service: service)
        defer {
            engine.stopTransport()
            engine.stop()
        }
        let rendering = only(part, of: plan)
        try await player.begin(rendering, clock: clock)
        _ = try engine.startTransport(clock: clock)
        // Section by section when the mix changes by section, as the transport moves the strips
        // when the playhead crosses into one: a whole-song render used to keep the first section's
        // overrides to the end.
        var planar: [[Float]] = []
        var rendered: AVAudioFramePosition = 0
        /// The next `count` frames: at once, or a piece at a time when paced.
        func render(_ count: AVAudioFramePosition) async throws {
            guard let pacing, pacing.frames > 0 else {
                append(AuditionService.planar(try OfflineRenderer.renderBuffer(engine: engine, frames: count)), to: &planar)
                rendered += count
                return
            }
            var left = count
            while left > 0 {
                let piece = min(left, pacing.frames)
                append(AuditionService.planar(try OfflineRenderer.renderBuffer(engine: engine, frames: piece)), to: &planar)
                left -= piece
                rendered += piece
                pacing.progress?(Double(rendered) / Double(max(1, frames)))
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        do {
            for boundary in sectionBoundaries(of: rendering, clock: clock, sampleRate: sampleRate) where boundary.frame < frames {
                if boundary.frame > rendered { try await render(boundary.frame - rendered) }
                await player.mixChanged(rendering.mix, section: boundary.section)
            }
            if frames > rendered { try await render(frames - rendered) }
        } catch {
            // A render stopped part way still gives its kits back.
            await player.end()
            await service.shutdown()
            throw error
        }
        await player.end()
        await service.shutdown()
        return planar
    }

    /// Where each section after the first begins, in frames — only when the mix changes by
    /// section, a level or an effect; otherwise nothing changes along the way and the render is
    /// one piece.
    static func sectionBoundaries(of plan: SongPlayback, clock: TransportClock, sampleRate: Double) -> [(frame: AVAudioFramePosition, section: SectionID)] {
        guard let mix = plan.mix, mix.changesBySection else { return [] }
        return plan.segments.dropFirst().map { segment in
            (AVAudioFramePosition((clock.seconds(forBar: segment.startBar) * sampleRate).rounded()), segment.section)
        }
    }

    private static func append(_ piece: [[Float]], to planar: inout [[Float]]) {
        if planar.isEmpty { planar = piece; return }
        for channel in planar.indices where channel < piece.count { planar[channel] += piece[channel] }
    }

    enum Failure: Error, CustomStringConvertible {
        case nothingToBounce(String)
        var description: String {
            switch self { case .nothingToBounce(let why): return "Nothing to bounce: \(why)." }
        }
    }
}
