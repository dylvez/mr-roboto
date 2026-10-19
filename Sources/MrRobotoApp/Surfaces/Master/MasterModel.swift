import Foundation
import Performance
import SongGraph

/// The Master: the last bounce read against the target, and the levers that set the target,
/// the ceiling and the gain before the limiter.
///
/// It lives in two places. On its own it is the Master surface, holding a working mix of its own.
/// As the Mixer's Master tab it `follow`s the Mixer, and reads and moves the Mixer's working mix
/// instead — see `follow(_:)` for why that has to be one mix and not two.
@MainActor
@Observable
public final class MasterModel {

    public struct Reading: Sendable {
        public var observation: MixObservation
        public var truePeakDBTP: Double
        /// The spectrum in dB, 48 log-spaced bars from 40 Hz to 16 kHz.
        public var spectrumDB: [Double]
        /// The Engineer's: the delivery numbers, then the balance against the reference when one
        /// is read.
        public var readings: [PersonaReading]
        /// The Peer's: whether each hook lifts off the verse before it.
        public var lifts: [PersonaReading]
        /// What was actually bounced and measured — see `Scope`.
        public var scope: Scope
        /// How long the bounce was, tail included. The honest check on `scope`: a whole-song
        /// reading of a two-minute song is two minutes long.
        public var seconds: Double
        /// The mix the bounce went through. What `isStale` compares the working mix with.
        public var mix: Mix
        /// The same bounce, read section by section.
        public var whole: WholeSongReading
        /// The first reading that does not hold: what to change first.
        public var firstToChange: PersonaReading? { readings.first { !$0.holds } }
        /// Each section of the form, in order, off the bounce.
        public var sections: [SectionMeter.Reading] { whole.sheet.sections }
    }

    /// How much of the song a reading covers: all of it.
    ///
    /// The Master used to bounce only the first section of an arranged song — a whole-song bounce
    /// on every read seemed too long to wait for — and printed the numbers under a label saying
    /// so. But the loudness a song is delivered at is the whole song's; a verse is not the song,
    /// and a label does not stop "−14 LUFS" being read as the song's. So every reading is of every
    /// section in order (or the flat plan, when nothing is arranged), and the scope says how much
    /// that was, so the wait has a reason on screen.
    public struct Scope: Equatable, Sendable {
        /// Bars bounced, before the half-second tail.
        public var bars: Int
        /// Sections played in order; 0 for a song with no arrangement, which bounces as its plan.
        public var sections: Int

        public init(bars: Int, sections: Int) {
            self.bars = bars
            self.sections = sections
        }

        /// The label beside the numbers.
        public var label: String { "Whole song" }

        /// "3 sections · 24 bars", or "8 bars" for a song that is not arranged.
        public var detail: String {
            let bars = "\(self.bars) bar\(self.bars == 1 ? "" : "s")"
            guard sections > 0 else { return bars }
            return "\(sections) section\(sections == 1 ? "" : "s") · \(bars)"
        }

        /// What the surface says while the bounce runs. A long song takes a while to bounce, and
        /// the count is what tells you why.
        public var progressLine: String { "Bouncing \(bars) bar\(bars == 1 ? "" : "s")…" }

        /// The scope of a whole-song bounce of `plan`: the same bars `SectionBounce` will render
        /// when it is handed no section, so the label and the bounce cannot disagree.
        static func wholeSong(of plan: SongPlayback) -> Scope {
            let bars = (try? SectionBounce.isolate(plan, section: nil))?.2 ?? max(1, plan.lengthInBars ?? 1)
            return Scope(bars: bars, sections: plan.segments.count)
        }
    }

    public let surfaceID: SurfaceID
    public let targets: Master
    public private(set) var reading: Reading?
    public private(set) var isReading = false

    private let host: any MixHosting
    /// The working mix, base, last move and last failure when this Master stands on its own.
    /// Following a Mixer, the mix, base and moves are the Mixer's; see the accessors below.
    private var ownMix: Mix
    private var ownBase: PartVersion?
    private var committed: Mix
    private var ownNote: String?
    private var ownError: String?

    /// The Mixer whose working mix this Master reads and moves, when it is the Mixer's Master tab.
    ///
    /// Weak, and outside observation: the Mixer owns its model and the Master only looks through
    /// it. Reads of `mixer.mix` are observed on the Mixer's own model, so a view drawing `mix`
    /// here still redraws when a strip or a knob moves it.
    @ObservationIgnored private weak var mixer: MixerModel?

    public init(host: any MixHosting, base: PartVersion? = nil, surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.ownBase = base
        self.targets = host.targets
        let starting = Self.startingMix(host: host, base: base)
        ownMix = starting
        committed = starting
    }

    /// Where a mix surface starts: the bound mix version, else the one the song plays, else unity
    /// with the master on the album's target and ceiling. The Mixer starts from the same place, so
    /// the Master tab and the Master surface show the same numbers on a song with no mix yet.
    static func startingMix(host: any MixHosting, base: PartVersion?) -> Mix {
        if let base, case .mix(let stored) = base.kind { return stored }
        if let planned = host.playback.mix { return planned }
        var unity = Mix.unity
        let targets = host.targets
        unity.master = Master(gainDB: 0, ceilingDBTP: targets.ceilingDBTP, targetLUFS: targets.targetLUFS)
        return unity
    }

    public var song: Song? { host.song }

    // MARK: One mix under both tabs

    /// Makes this Master the Mixer's Master tab: from now on it reads and moves the Mixer's
    /// working mix rather than its own.
    ///
    /// Two working mixes on one surface would fork. The Mixer keeps a strip move as a version off
    /// its base; a Master holding its own copy would then keep a gain move off the *same* base,
    /// without the strip move — two sibling versions, and whichever came second quietly undoes
    /// the first in the song. One mix, one line of versions. Idempotent, so a view can call it
    /// every time it is built.
    public func follow(_ mixer: MixerModel) {
        guard self.mixer !== mixer else { return }
        self.mixer = mixer
    }

    /// Whether this Master is the Mixer's Master tab.
    public var isFollowingMixer: Bool { mixer != nil }

    /// The working mix: the Mixer's when following one, else this Master's own.
    public var mix: Mix { mixer?.mix ?? ownMix }
    /// The version the working mix descends from; nil for a song never mixed.
    public var base: PartVersion? { mixer.map { $0.base } ?? ownBase }
    /// The last move kept. Following the Mixer that is the Mixer's last move, strips included:
    /// it is the version the numbers are about to be read against.
    public var lastNote: String? { mixer?.lastNote ?? ownNote }
    public var lastError: String? { ownError ?? mixer?.lastError }

    // MARK: Reading

    /// What the next reading will cover: the whole song, every section in order.
    public var scope: Scope { Scope.wholeSong(of: host.playback) }

    /// What the surface says while a bounce runs, or nil when none is.
    public var progressLine: String? { isReading ? readingScope?.progressLine : nil }
    /// The scope of the bounce in flight, fixed when it started.
    private var readingScope: Scope?

    /// True once the working mix differs from the one the reading was bounced through in anything
    /// that changes the audio. The numbers are still shown, dimmed: they were true of a mix that is
    /// no longer the one on the strips.
    ///
    /// Worked out rather than set by the levers, because on the Mixer the levers are not the only
    /// thing that moves the mix — a strip fader, a knob on the controller, a mute — and a reading
    /// that kept saying "current" after the bass came down 6 dB would be wrong. It also means a
    /// lever put back where it was is not a change, and a move made while the bounce ran leaves the
    /// new reading stale the moment it lands.
    public var isStale: Bool {
        guard let reading else { return false }
        return Self.audible(reading.mix) != Self.audible(mix)
    }

    /// The mix without the target. The target is what the numbers are judged against, not
    /// something in the bounce, so moving it leaves a reading current.
    private static func audible(_ mix: Mix) -> Mix {
        var copy = mix
        copy.master.targetLUFS = 0
        return copy
    }

    /// The song's genre, asked each time the readings are made: a reading is re-judged in it
    /// (`GenreLens`). Nil — the default, and a song nobody has placed — leaves the persona's own.
    public var genre: @MainActor () -> GenreLens? = { nil }

    /// Bounces the whole song through the working mix and reads it: the whole, and every section
    /// off the same bounce. The reading is kept where the Director's tools read from, and judged
    /// against the reference once that is measured — the reference never holds the numbers up.
    public func read() async {
        guard !isReading else { return }
        let scope = self.scope
        let bounced = mix
        var heard = host.playback
        heard.mix = bounced
        readingScope = scope
        isReading = true
        defer { isReading = false; readingScope = nil }
        do {
            // No section: every section in order, or the flat plan. See `Scope`.
            let (planar, rate) = try await host.bounce(mix: bounced, section: nil)
            let label = host.song?.title ?? "Song"
            let plan = heard
            // Read off the main actor: a whole song's STFT and true peak are a moment's work.
            let whole = await Task.detached { WholeSongReading.measure(planar, sampleRate: rate, plan: plan, label: label) }.value
            host.keep(whole)
            reading = Reading(observation: whole.observation, truePeakDBTP: whole.truePeakDBTP,
                              spectrumDB: Self.logSpectrum(whole.sheet.spectrum, sampleRate: rate),
                              readings: Self.engineerReadings(whole, reference: currentReference, genre: genre()),
                              lifts: whole.liftReadings, scope: scope, seconds: whole.seconds, mix: bounced, whole: whole)
            ownError = nil
        } catch {
            ownError = "The bounce could not be read: \(error)"
        }
        if let reference = host.reference, currentReference == nil, measuring != reference {
            Task { await measure(reference) }
        }
    }

    /// The Engineer's lines on a whole-song reading: the delivery numbers judged in the genre, then
    /// the balance against the reference.
    static func engineerReadings(_ whole: WholeSongReading, reference: ReferenceReading?, genre: GenreLens?) -> [PersonaReading] {
        GenreLens.judge(Engineer().read(whole.observation), by: Engineer.bible, in: genre) + whole.balanceReadings(against: reference, genre: genre)
    }

    // MARK: The reference

    /// What the mix is read against: picked from the crate or the library, kept with the song.
    public var reference: MixReference? { host.reference }
    public var referenceChoices: [ReferenceChoice] { host.referenceChoices }
    /// The picked reference, measured. Nil until it is, and with none picked.
    public private(set) var referenceReading: ReferenceReading?
    /// The reference being measured now, when one is.
    public private(set) var measuring: MixReference?
    public var isMeasuringReference: Bool { measuring != nil }
    /// Why the reference could not be measured, when it could not.
    public private(set) var referenceError: String?

    /// The measured reference, when it is still the one picked.
    private var currentReference: ReferenceReading? {
        guard let referenceReading, referenceReading.reference == host.reference else { return nil }
        return referenceReading
    }

    /// Picks what the mix is read against, or nothing, and measures it in the background: what the
    /// picker calls.
    public func setReference(_ reference: MixReference?) {
        Task { await chooseReference(reference) }
    }

    /// Picks what the mix is read against, or nothing, and measures it: a record at once, a song
    /// after one bounce of its own. The reading on screen is judged against it when it lands.
    public func chooseReference(_ reference: MixReference?) async {
        host.setReference(reference)
        referenceError = nil
        rejudge()
        if let reference, currentReference == nil, measuring != reference { await measure(reference) }
    }

    /// Measures a record picked as the reference last time, when it has not been: what a view asks
    /// for when it appears, a file read and nothing rendered. A song picked as the reference is
    /// bounced to be measured, so that waits for the next Read, or for being picked.
    public func loadReference() async {
        guard let reference = host.reference, reference.record != nil, currentReference == nil, measuring != reference else { return }
        await measure(reference)
    }

    private func measure(_ reference: MixReference) async {
        measuring = reference
        defer { if measuring == reference { measuring = nil } }
        do {
            let measured = try await host.measureReference(reference)
            // Something else picked meanwhile: this one is kept by the host, not drawn.
            guard host.reference == reference else { return }
            referenceReading = measured
            referenceError = nil
        } catch {
            guard host.reference == reference else { return }
            referenceError = "\(error)"
        }
        rejudge()
    }

    /// The Engineer's lines again, against the reference and the genre as they are now. Nothing is
    /// bounced: the reading's numbers stand, only what they are judged against moved.
    private func rejudge() {
        guard var current = reading else { return }
        current.readings = Self.engineerReadings(current.whole, reference: currentReference, genre: genre())
        reading = current
    }

    /// 48 log-spaced bars from 40 Hz to 16 kHz, in dB relative to the loudest bar.
    static func logSpectrum(_ power: [Double], sampleRate: Double, bars: Int = 48) -> [Double] {
        guard power.count > 1 else { return [] }
        let binHz = sampleRate / 2 / Double(power.count - 1)
        var out: [Double] = []
        for i in 0..<bars {
            let low = 40 * pow(16_000 / 40, Double(i) / Double(bars))
            let high = 40 * pow(16_000 / 40, Double(i + 1) / Double(bars))
            var sum = 0.0, n = 0
            var bin = max(1, Int(low / binHz))
            while Double(bin) * binHz < high, bin < power.count { sum += power[bin]; n += 1; bin += 1 }
            out.append(n > 0 ? 10 * log10(sum / Double(n) + 1e-20) : -120)
        }
        let top = out.max() ?? 0
        return out.map { $0 - top }
    }

    /// The gain that would put the last reading on the target.
    ///
    /// From the gain the reading was bounced at, not the gain on the lever now: the reading's
    /// loudness is what that gain gave, so the difference to the target is added to it. Counting
    /// from the lever would suggest the same correction again after it had been made.
    public var suggestedGainDB: Double? {
        guard let reading, reading.observation.integratedLUFS.isFinite else { return nil }
        return mix.master.targetLUFS - reading.observation.integratedLUFS + reading.mix.master.gainDB
    }

    // MARK: Levers

    // Heard while held, a version when let go — the same rule as every fader on the Mixer.
    public func setTarget(_ lufs: Double) { move { $0.master.targetLUFS = max(-30, min(-6, lufs)) } }
    public func setCeiling(_ dBTP: Double) { move { $0.master.ceilingDBTP = max(-12, min(0, dBTP)) } }
    public func setGain(_ dB: Double) { move { $0.master.gainDB = max(-24, min(24, dB)) } }

    /// How the song ends, kept at once: a fade over its last `bars`, or none.
    public func setFadeOut(bars: Int?) {
        if let mixer {
            mixer.setFadeOut(bars: bars)
            return
        }
        guard ownMix.master.fadeOutBars != bars else { return }
        ownMix.master.fadeOutBars = bars
        host.preview(ownMix)
        endGesture()
    }

    private func move(_ change: (inout Mix) -> Void) {
        if let mixer {
            // Through the Mixer's own lever, so its preview, its clamps and its next version's note
            // are the ones a move on its master row would have made.
            var moved = mixer.mix
            change(&moved)
            mixer.setMaster(gainDB: moved.master.gainDB, ceilingDBTP: moved.master.ceilingDBTP, targetLUFS: moved.master.targetLUFS)
            return
        }
        change(&ownMix)
        host.preview(ownMix)
    }

    /// Applies the suggested gain and keeps it.
    public func hitTheTarget() {
        guard let gain = suggestedGainDB else { return }
        setGain(gain)
        endGesture()
    }

    /// The gesture is over: what moved becomes a mix version. Following the Mixer, it is the
    /// Mixer's version, off the Mixer's base.
    @discardableResult
    public func endGesture() -> PartVersion? {
        if let mixer { return mixer.endGesture() }
        guard ownMix != committed else { return nil }
        let note = MixerModel.describe(from: committed, to: ownMix, labels: [:])
        guard let version = host.commit(ownMix, base: ownBase, note: note) else {
            ownError = "The move could not be kept."
            return nil
        }
        ownBase = version
        committed = ownMix
        ownNote = note
        ownError = nil
        return version
    }
}
