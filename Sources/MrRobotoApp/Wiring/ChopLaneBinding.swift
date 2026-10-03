import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// What it takes to open a Chop lane on a bench item.
///
/// The lane is the one surface that cannot be built from the binding alone: `ChopLaneSurface` needs
/// the *audio* of the bar, and a `.sample` part version carries a media hash and slice markers, not
/// samples and not a region. So this resolves the bar — find the media, work out which span of the
/// record the promotion covered, read that span — and only then builds the lane. It is observable
/// so the panel can say which of those steps it is on, and honest when one of them fails.
@MainActor
@Observable
final class ChopLaneBinding {

    enum State {
        /// Nothing is bound: opened from the Surfaces menu with no bar.
        case unbound
        case loading(String)
        case ready(ChopLaneSurface)
        case failed(String)
    }

    private(set) var state: State = .unbound

    @ObservationIgnored private let app: AppState
    @ObservationIgnored private let item: BenchItem
    /// Held strongly: `ChopLaneSurface.host` is `weak`, so nothing else keeps the adapter alive.
    @ObservationIgnored private let adapter: ChopLaneAdapter
    @ObservationIgnored private var loaded: VersionID?
    @ObservationIgnored private var resolving: Task<Void, Never>?

    init(item: BenchItem, app: AppState, service: AuditionService) {
        self.app = app
        self.item = item
        self.adapter = ChopLaneAdapter(app: app, service: service, surface: item.id)
        load()
    }

    /// The version this lane was opened against, if the binding names a chopable one.
    private var boundSample: PartVersion? {
        for id in app.bound(for: item.id) {
            guard let version = app.version(id), case .sample = version.kind else { continue }
            return version
        }
        return nil
    }

    /// Resolve the bound bar, if there is one. Re-entrant and idempotent: reopening the same
    /// version does nothing, a different one reloads.
    func load() {
        guard let version = boundSample, case .sample(let sample) = version.kind else {
            state = .unbound
            loaded = nil
            return
        }
        guard loaded != version.id else { return }
        loaded = version.id

        guard let store = app.store else {
            state = .failed("This session has no library directory, so the bar's audio cannot be read.")
            return
        }
        let song = app.song
        let label = version.note.map { String($0.prefix(60)) } ?? item.title
        state = .loading(label)

        let songID = song?.id
        let analysis = Self.analysis(in: song)
        let region = Self.region(of: sample, bars: analysis?.bars ?? [],
                                 tempo: sample.detectedTempo ?? song?.tempo)

        resolving = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AudioRegion.Span, any Error> in
                do {
                    let url = try store.mediaURL(for: sample.media, song: songID)
                    // At the chop's own level, so the pads are as loud as the song plays them.
                    return .success(try AudioRegion.read(url, from: region.start, to: region.end).levelled(by: sample.gainDB))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(let error):
                self.state = .failed("\(error)")
            case .success(let span):
                // Analysis and drawing read the dry bar; the pads play it through the chop's own
                // chain. A dusty chop's slices are found on the clean transients — the noise bed
                // would otherwise read as onsets — and heard the way the version says it sounds.
                let mono = ChopAudio.mono(span.planar)
                let playing = (try? Dust.render(span.planar, sampleRate: span.sampleRate,
                                                passes: sample.degradation)) ?? span.planar
                guard !mono.isEmpty else {
                    self.state = .failed("The bar's audio is empty: \(sample.media.fileName) held nothing between "
                        + String(format: "%.2f s and %.2f s.", region.start, region.end))
                    return
                }
                let source = ChopLaneSource(media: sample.media,
                                            partID: version.partID,
                                            record: sample.sourceRecord,
                                            mono: mono,
                                            planar: playing,
                                            sampleRate: span.sampleRate,
                                            sourceOffset: region.start,
                                            grid: analysis.flatMap(Self.grid(of:)),
                                            tempo: sample.detectedTempo ?? song?.tempo,
                                            label: label)
                let lane = ChopLaneSurface(id: self.item.id, source: source,
                                           host: self.adapter, version: version.id)
                // The cut the version kept, not a fresh detection of it. A bar just promoted from
                // the record holds no cut yet — one marker at its start — and is detected as before.
                if sample.slices.count > 1 { lane.restore(sample.slices, pads: sample.pads) }
                self.state = .ready(lane)
                self.app.retitleSurface(self.item.id, to: lane.headline)
            }
        }
    }

    /// Awaits whatever `load()` started. Tests use this; so does anything that wants the lane
    /// before it draws. Mirrors `ImportModel.waitForCompletion()`.
    func waitForLoad() async {
        await resolving?.value
    }

    /// Hands the lane a critic's marks.
    ///
    /// `ChopLaneSurface.marks` has existed since Gate A and nothing has ever written one — the
    /// surface draws them in the warn colour and never acts on them, which is "flags, never fixes"
    /// at the only place it could be broken. This is the single writer, and it replaces rather than
    /// appends: a re-review of the same lane is the current set of findings, not the union of every
    /// set anybody has ever produced.
    ///
    /// - Returns: false when the lane has no bar loaded, so the caller can say so rather than
    ///   believing marks landed somewhere.
    @discardableResult
    func mark(_ marks: [ChopLaneMark]) -> Bool {
        guard case .ready(let lane) = state else { return false }
        // `ChopLaneSurface` is an `@Observable` class, so the waveform redraws off this assignment
        // without the enum around it being touched.
        lane.marks = marks
        return true
    }

    // MARK: Working out which bar was promoted

    /// The whole-track analysis the import recorded, if the song still holds one.
    static func analysis(in song: Song?) -> MusicAnalysis? {
        song?.versions.reversed().compactMap { version -> MusicAnalysis? in
            if case .analysis(let analysis) = version.kind { return analysis }
            return nil
        }.first
    }

    /// The span of the record a promoted sample covers.
    ///
    /// `Sample` models markers, not extent — it carries the downbeats inside the promoted region
    /// and nothing that says where the region began or ended. So the span is reconstructed: the
    /// bars of the record's own analysis that the markers fall in, which is exactly what
    /// `ImportModel.promote` cut on. With no analysis to hand, one bar at the detected tempo per
    /// marker is the honest approximation; with no markers at all, the first eight seconds.
    nonisolated static func region(of sample: Sample, bars: [SongGraph.TimeRange], tempo: Double?) -> SongGraph.TimeRange {
        // A chop that says what it covers — a merged render is the whole bar — is believed.
        if let span = sample.span, span.end > span.start { return span }
        let markers = sample.slices.map(\.position).sorted()
        guard let first = markers.first, let last = markers.last else {
            return SongGraph.TimeRange(start: 0, end: 8)
        }
        let covered = bars.filter { bar in markers.contains { bar.contains($0) } }
        if let start = covered.first?.start, let end = covered.last?.end, end > start {
            return SongGraph.TimeRange(start: start, end: end)
        }
        let barLength = 4 * 60 / max(20, tempo ?? 120)
        return SongGraph.TimeRange(start: first, end: last + barLength)
    }

    /// The record's beat grid, in the record's own time — what the lane snaps to.
    static func grid(of analysis: MusicAnalysis) -> BeatGrid? {
        guard !analysis.beats.isEmpty else { return nil }
        return BeatGrid(beats: analysis.beats.map(\.time),
                        bars: analysis.beats.filter(\.isDownbeat).map(\.time),
                        bpm: analysis.dominantTempo)
    }
}

/// The Chop lane as a bench panel: the lane once its bar is loaded, and an honest line until then.
///
/// "Until then" used to be an explanation of why the panel was empty. It is now an offer: a lane
/// with no bar knows what a bar would have to come from, and the song either has one or has the stem
/// a bar is cut out of. Both are one press away, and when the song has neither the panel says so
/// rather than pointing at a lever that is not there.
struct ChopLanePanel: View {
    @Bindable var binding: ChopLaneBinding
    let app: AppState

    var body: some View {
        Group {
            switch binding.state {
            case .unbound:
                unbound
            case .loading(let label):
                note("Reading \(label)…", "Finding the bar in the record and loading its audio.")
            case .ready(let lane):
                ChopLaneView(surface: lane)
            case .failed(let reason):
                note("This bar could not be opened.", reason)
            }
        }
        .onAppear { binding.load() }
    }

    /// The ways into a lane, in the order they are worth trying. Every one of these is filtered by
    /// `canPerform`, so an offer on screen is an offer that works.
    private var offers: [Proposal] {
        guard let song = app.song else { return [] }
        let chops = Guidance.samples(in: song).reversed().compactMap { PartActions.primary(for: $0, in: song) }
        let stems = Guidance.stems(in: song).compactMap { PartActions.primary(for: $0, in: song) }
        return (chops + stems).filter { app.canPerform($0.action) && $0.action.surface == .chopLane }
    }

    private var unbound: some View {
        let offers = self.offers
        return VStack(alignment: .leading, spacing: 12) {
            EmptyNote(title: "No bar is bound to this lane.",
                      detail: offers.isEmpty
                          ? "A lane chops a bar of a record. This song has no chop and no stem to cut one from "
                            + "— open the record and promote a region, or separate its stems first."
                          : "A lane chops a bar of a record. Here is what this song can give it:")
            ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                ProposalButton(proposal: offer, isLeading: index == 0) {
                    app.perform(offer.action)
                }
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
    }

    private func note(_ title: String, _ detail: String) -> some View {
        EmptyNote(title: title, detail: detail)
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Palette.panelAlt)
    }
}

extension ChopLaneBinding.State {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
    var isUnbound: Bool { if case .unbound = self { return true } else { return false } }
}
