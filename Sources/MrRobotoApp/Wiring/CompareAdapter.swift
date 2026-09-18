import AVFAudio
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// `AppState` seen through `CompareHosting`.
///
/// The Compare surface's whole contract is one promise — **every candidate auditions in place, with
/// no round trip** — and the adapter is where that promise meets the one engine. Three things fall
/// out of that and they are the whole of this type:
///
/// * **A row is played, not described.** `audition(_:levers:)` takes the candidate's own
///   `PartVersion` and turns it into sound: a groove is rendered through `GrooveRenderer` onto the
///   shared sampler's kit; a chop or a stem is read off disk and played as samples. Neither goes
///   near the Director.
/// * **The levers are applied on the way out, to every row alike.** They arrive as an argument
///   rather than being read off the adapter, which is the surface's own design and the reason a
///   lever move is just the same call again with one number changed — `tempo` and `swing` re-render
///   the groove, `ghostLevel` moves the velocity map under it, `dust` runs the chain over a sample.
/// * **The reference is played by a different call.** `auditionReference` exists so that the thing
///   the candidates are judged against can never be selected as one of them, and the split is kept
///   here: it resolves a `VersionID` rather than a candidate.
///
/// Taking a row goes through `AppState.record`, which appends a *new* version rather than moving
/// one: choosing in a Compare is a commit, and the losing candidates stay in the graph where their
/// notes still say what they were.
@MainActor
final class CompareAdapter: CompareHosting {

    private let app: AppState
    private let service: AuditionService
    private let surface: SurfaceID
    /// The longest a single row is allowed to play. A Compare is judged in its first seconds — the
    /// Komma lesson — and a candidate that runs for a minute is a candidate you stop listening to.
    static let maximumSeconds: Double = 8

    /// Set once a candidate has been taken, so a second press does not append a second copy.
    private(set) var chosen: VersionID?

    init(app: AppState, service: AuditionService, surface: SurfaceID) {
        self.app = app
        self.service = service
        self.surface = surface
    }

    // MARK: Playing

    func audition(_ candidate: CompareCandidate, levers: [CompareLever: Double]) async {
        guard let version = candidate.version else {
            app.note(.session, "\(candidate.title) has no version behind it, so there is nothing to play",
                     detail: "A candidate that is only a label is a row you cannot judge.")
            return
        }
        await play(version, named: candidate.title, levers: levers)
    }

    func auditionReference(_ reference: CompareReference, levers: [CompareLever: Double]) async {
        guard let id = reference.version, let version = app.version(id) else {
            app.note(.session, "There is nothing behind \(reference.title) to play",
                     detail: "The reference is what the song already has; this one is not in the graph.")
            return
        }
        await play(version, named: reference.title, levers: levers)
    }

    func stopAudition() {
        Task { [service] in await service.stop() }
    }

    @discardableResult
    func choose(_ candidate: CompareCandidate) async -> Bool {
        guard let version = candidate.version else { return false }
        if chosen == version.id { return true }
        // The candidate is already a version in the song — the Director made it with
        // create_part_version before the Compare could name it — so taking it selects it and says
        // so rather than appending a duplicate under a second id.
        if app.version(version.id) != nil {
            app.select(version.id)
            app.note(.you, "Took \(candidate.title)",
                     detail: candidate.rationale.isEmpty ? nil : candidate.rationale)
            chosen = version.id
            return true
        }
        guard app.record(version) else { return false }
        chosen = version.id
        return true
    }

    // MARK: How a version becomes a sound

    private func play(_ version: PartVersion, named name: String, levers: [CompareLever: Double]) async {
        switch version.kind {
        case .groove(let groove):
            await playGroove(groove, levers: levers)
        case .sample(let sample):
            await playAudio(sample.media, from: 0, named: name, levers: levers)
        case .audio(let audio):
            await playAudio(audio.media, from: 0, named: name, levers: levers)
        default:
            app.note(.session, "A \(version.type.rawValue) cannot be auditioned here",
                     detail: "The Compare plays grooves, chops and recordings; \(name) is neither.")
        }
    }

    /// A groove, rendered at the levers' tempo and swing onto the song's own machine.
    private func playGroove(_ groove: Groove, levers: [CompareLever: Double]) async {
        let machine = SynthMachine.preset(id: app.playback.machine) ?? .tr808
        do {
            try await service.prepare(machine: machine)
        } catch {
            app.note(.session, "Could not load \(machine.name) to play that", detail: "\(error)")
            return
        }
        let hits = CompareAdapter.hits(for: groove, levers: levers,
                                       tempo: app.song?.tempo ?? 90,
                                       timeSignature: app.song?.timeSignature ?? .fourFour)
        guard !hits.isEmpty else {
            app.note(.session, "That groove has no hits in it", detail: "Nothing was played.")
            return
        }
        await service.play(hits)
    }

    /// A chop or a stem, read off disk and played as samples, through the chain when a `dust` lever
    /// asks for one.
    private func playAudio(_ media: MediaRef, from start: Double, named name: String,
                           levers: [CompareLever: Double]) async {
        guard let store = app.store else {
            app.note(.session, "This session has no library directory, so \(name) cannot be read")
            return
        }
        let songID = app.song?.id
        let seconds = CompareAdapter.maximumSeconds
        let mix = levers[.degradeMix]
        let span: AudioRegion.Span
        do {
            let url = try store.mediaURL(for: media, song: songID)
            span = try await Task.detached(priority: .userInitiated) {
                try AudioRegion.read(url, from: start, to: start + seconds)
            }.value
        } catch {
            app.note(.session, "\(name) could not be read", detail: "\(error)")
            return
        }
        guard !span.planar.isEmpty else { return }
        let planar = mix.map { CompareAdapter.dusted(span.planar, sampleRate: span.sampleRate, mix: $0) }
            ?? span.planar
        await service.play(planar: planar, sampleRate: span.sampleRate)
    }

    // MARK: The levers, as arithmetic

    /// One pass of `groove` under the levers. A pure function so `BandWiringTests` can assert what a
    /// lever does to the hits without an audio device.
    static func hits(for groove: Groove, levers: [CompareLever: Double],
                     tempo: Double, timeSignature: TimeSignature) -> [VoiceSampler.Hit] {
        let bpm = levers[.tempo].map { CompareLever.tempo.clamp($0) } ?? tempo
        var options = GrooveRenderOptions()
        if let swing = levers[.swing] { options.swing = Swing(percent: CompareLever.swing.clamp(swing)) }
        if let ghost = levers[.ghostLevel] {
            // The ghost tier as a fraction of the normal one, which is what the lever says it is.
            // Clamped to at least 1 so "no ghosts" is a quiet hit rather than a dropped one: a row
            // that silently loses its ghosts is a row that reads as a different pattern.
            let normal = VelocityMap.standard.normal
            let level = max(1, min(normal, Int((Double(normal) * CompareLever.ghostLevel.clamp(ghost)).rounded())))
            options.velocities = VelocityMap(ghost: level, normal: normal,
                                             accent: VelocityMap.standard.accent)
        }
        let timeline = GrooveTimeline.tempo(max(20, bpm), timeSignature: timeSignature)
        return GrooveRenderer.render(groove, on: timeline, options: options)
    }

    /// The degradation chain at one mix, over planar floats. `sp1200` because that is what "dustier"
    /// means in this instrument's own vocabulary — twelve bits and a 26 kHz hold — rather than a
    /// number invented here.
    static func dusted(_ planar: [[Float]], sampleRate: Double, mix: Double) -> [[Float]] {
        guard mix > 0, let frames = planar.first?.count, frames > 0 else { return planar }
        var settings = DegradeSettings(preset: .sp1200)
        settings.mix = min(1, max(0, mix))
        guard let chain = try? DegradeChain(sampleRate: sampleRate, channelCount: planar.count,
                                            settings: settings) else { return planar }
        // Planar scratch the chain can write through. Allocated rather than borrowed from the
        // arrays: `dg_process` wants every channel pointer live at once, and nesting one
        // `withUnsafeMutableBufferPointer` per channel to get that is a recursion, not a loop.
        let channels = planar.count
        let scratch = (0..<channels).map { channel -> UnsafeMutablePointer<Float> in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buffer.initialize(repeating: 0, count: frames)
            buffer.update(from: planar[channel], count: min(frames, planar[channel].count))
            return buffer
        }
        defer { for buffer in scratch { buffer.deinitialize(count: frames); buffer.deallocate() } }
        var pointers: [UnsafeMutablePointer<Float>?] = scratch
        pointers.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            chain.processInPlace(base, channelCount: channels, frameCount: frames)
        }
        return scratch.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }
}

// MARK: - Building the surface

/// What the bench draws for a Compare: the surface, or the reason it is not one.
enum CompareFilling {
    case ready(CompareModel)
    /// A Compare that cannot be one: fewer than two candidates, or bindings the song no longer
    /// holds. Says which, rather than drawing an empty table.
    case unfilled(title: String, reason: String)
}

extension SurfaceWiring {

    /// The Compare surface for a bench item, built once and kept for as long as the bench holds it.
    ///
    /// Two sources, in order:
    ///
    /// 1. the **brief** the asker filed (`AppState.answer(for:)`) — the reference, the columns, who
    ///    proposed each row and why. This is the normal path and the only one that carries a
    ///    rationale, because a rationale is not in the graph;
    /// 2. failing that, the **binding**: reference first, candidates after, with readings measured
    ///    off the versions themselves. A restored session and a Compare opened by hand land here,
    ///    and it is a real comparison rather than a placeholder — it simply has no prose in it.
    func compareFilling(for item: BenchItem, app: AppState) -> CompareFilling {
        prune(app)
        if let existing = compares[item.id] { return existing }
        let built = Self.buildCompare(for: item, app: app)
        if case .ready(let model) = built {
            let adapter = CompareAdapter(app: app, service: service(for: app), surface: item.id)
            model.adopt(adapter)
            compareAdapters[item.id] = adapter
        }
        compares[item.id] = built
        return built
    }

    private static func buildCompare(for item: BenchItem, app: AppState) -> CompareFilling {
        let brief = CompareBriefing.brief(for: item, app: app)
        guard let brief else {
            return .unfilled(title: item.title,
                             reason: "A comparison needs something to judge against and at least two "
                                 + "things to judge. This surface is bound to "
                                 + "\(app.bound(for: item.id).count) version(s).")
        }
        do {
            let model = try CompareModel(id: item.id, title: brief.title,
                                         reference: brief.reference,
                                         candidates: brief.candidates,
                                         features: brief.features,
                                         levers: brief.levers,
                                         vocabulary: brief.vocabulary)
            return .ready(model)
        } catch {
            return .unfilled(title: item.title, reason: "\(error)")
        }
    }
}

// MARK: - A comparison read off the graph

/// Turning a binding into a comparison, when nobody filed a brief.
///
/// The readings come from the same observations the personas read — `GrooveObservation` is
/// arithmetic over a groove and its options — so a derived Compare marks its differences against the
/// same thresholds a critic would, rather than against numbers invented for the table.
enum CompareBriefing {

    /// The features a comparison of grooves is judged on, in the order the Beatmaker listens for
    /// them. Capped at four: the layout drops the ones past what fits, and past four the eye starts
    /// comparing pairs of columns instead of rows.
    static let grooveFeatures: [Feature] = [.swingPercent, .ghostRatio, .pocketSpreadMS, .backbeatCount]
    static let sampleFeatures: [Feature] = [.sliceDensity, .tempoBPM]

    @MainActor
    static func brief(for item: BenchItem, app: AppState) -> CompareBrief? {
        if case .compare(let filed)? = app.answer(for: item.id) { return filed }
        let bound = app.bound(for: item.id).compactMap { app.version($0) }
        guard let reference = bound.first, bound.count >= 1 + CompareModel.minimumCandidates else {
            return nil
        }
        let candidates = Array(bound.dropFirst())
        let tempo = app.song?.tempo ?? 90
        let features = self.features(for: reference)
        return CompareBrief(
            title: item.title,
            reference: CompareReference(title: headline(of: reference),
                                        kind: reference.note ?? "what the song already has",
                                        readings: readings(of: reference, tempo: tempo, features: features),
                                        version: reference.id),
            candidates: candidates.map { version in
                let title = headline(of: version)
                let note = version.note ?? ""
                return CompareCandidate(id: version.id.description,
                                        title: title,
                                        proposedBy: persona(of: version),
                                        // The row already carries the headline; repeating it
                                        // underneath is a rationale that explains nothing.
                                        rationale: note == title ? "" : note,
                                        readings: readings(of: version, tempo: tempo, features: features),
                                        version: version)
            },
            features: features,
            // The levers the Director put on the surface, in the surface's own vocabulary. Without
            // this a Compare opened by `open_surface` draws no levers at all: the frame stores them
            // as `SurfaceLever`, the surface takes `CompareLever`, and nothing translated between
            // the two — the live run opened a Compare carrying "Dustier · 0.45" and "Slower still ·
            // 82 bpm" and the surface showed neither.
            levers: app.levers(for: item.id).compactMap(CompareLever.init(quantity:)))
    }

    /// The row's own line: short enough to read across a table, and never the whole note.
    ///
    /// A version's note is written for the ledger — a sentence or two about what it is and why —
    /// and the Compare needs a label. So the headline is the note up to its first colon or full
    /// stop, which is where these notes put the name of the thing before they explain it.
    static func headline(of version: PartVersion) -> String {
        let full = PartLabel.title(of: version)
        if let stop = full.firstIndex(where: { $0 == ":" || $0 == "." }), stop > full.startIndex {
            let head = String(full[full.startIndex..<stop]).trimmingCharacters(in: .whitespaces)
            if head.count >= 8 { return head }
        }
        return full
    }

    static func features(for version: PartVersion) -> [Feature] {
        switch version.kind {
        case .groove: return grooveFeatures
        case .sample: return sampleFeatures
        default: return []
        }
    }

    /// Every feature this version can actually be measured on. A feature it cannot answer is left
    /// out rather than reported as zero — `CompareModel.differences` skips a column the reference
    /// does not carry, and a fabricated zero would turn that into a difference nobody can hear.
    static func readings(of version: PartVersion, tempo: Double, features: [Feature]) -> [CompareReading] {
        let values: (Feature) -> Double?
        switch version.kind {
        case .groove(let groove):
            let observation = GrooveObservation(label: PartLabel.title(of: version), groove: groove,
                                                options: GrooveRenderOptions(), tempo: tempo)
            values = { observation.value(of: $0) }
        case .sample(let sample):
            let observation = SourceObservation(label: PartLabel.title(of: version),
                                                sampleRate: 0, duration: 0,
                                                tempo: sample.detectedTempo ?? tempo,
                                                sliceCount: sample.slices.count)
            values = { feature in
                feature == .sliceDensity ? Double(sample.slices.count) : observation.value(of: feature)
            }
        default:
            return []
        }
        return features.compactMap { feature in
            guard let value = values(feature) else { return nil }
            return CompareReading(feature, value, unit: unit(of: feature))
        }
    }

    /// The unit the bibles already wrote down, so a column header and a persona's rule agree.
    static func unit(of feature: Feature) -> String {
        for bible in Cast.standard.bibles {
            if let definition = bible.definition(of: feature) { return definition.unit }
        }
        return ""
    }

    /// Who made it, when the graph says a persona did. This is what puts "the Beatmaker's" on a row.
    static func persona(of version: PartVersion) -> PersonaID? {
        if case .persona(let name) = version.author { return PersonaID(name.lowercased()) }
        return nil
    }
}

// MARK: - The panel

/// The Compare surface as a bench panel: the comparison, or the honest reason there is not one.
struct ComparePanel: View {
    let filling: CompareFilling

    var body: some View {
        switch filling {
        case .ready(let model):
            CompareSurfaceView(model: model)
        case .unfilled(let title, let reason):
            EmptyNote(title: "\(title) is not a comparison.", detail: reason)
                .padding(Design.Metric.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Design.Palette.panelAlt)
        }
    }
}
