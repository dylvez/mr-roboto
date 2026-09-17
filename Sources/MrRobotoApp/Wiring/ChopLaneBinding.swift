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
                    return .success(try AudioRegion.read(url, from: region.start, to: region.end))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(let error):
                self.state = .failed("\(error)")
            case .success(let span):
                let mono = ChopAudio.mono(span.planar)
                guard !mono.isEmpty else {
                    self.state = .failed("The bar's audio is empty: \(sample.media.fileName) held nothing between "
                        + String(format: "%.2f s and %.2f s.", region.start, region.end))
                    return
                }
                let source = ChopLaneSource(media: sample.media,
                                            partID: version.partID,
                                            record: sample.sourceRecord,
                                            mono: mono,
                                            planar: span.planar,
                                            sampleRate: span.sampleRate,
                                            sourceOffset: region.start,
                                            grid: analysis.flatMap(Self.grid(of:)),
                                            tempo: sample.detectedTempo ?? song?.tempo,
                                            label: label)
                let lane = ChopLaneSurface(id: self.item.id, source: source,
                                           host: self.adapter, version: version.id)
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
    static func region(of sample: Sample, bars: [SongGraph.TimeRange], tempo: Double?) -> SongGraph.TimeRange {
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
struct ChopLanePanel: View {
    @Bindable var binding: ChopLaneBinding

    var body: some View {
        Group {
            switch binding.state {
            case .unbound:
                note("No bar is bound to this lane.",
                     "A lane chops a bar of a record. Promote a region in the Import surface — the "
                     + "lane opens on it — or select a chopped part in the ledger and open one here.")
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
