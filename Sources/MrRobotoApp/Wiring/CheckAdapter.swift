import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// `AppState` seen through `CheckHosting`.
///
/// The shape of this adapter is the catalog's fourth rule made mechanical: **flags, never fixes.**
/// Four calls, and only one of them changes anything.
///
/// * `auditionProblem` plays the stretch the finding is about, from the version it is about —
///   `Locus.start`/`.end` are seconds into that part, so hearing a finding is reading a span of one
///   file. Nothing is rendered and nothing is recorded.
/// * `auditionFix` is the one that could most easily lie. A preview has to be the *fixed* audio, and
///   this host can only produce that for the changes it can actually apply to a buffer in place. So
///   `canPreview` says no for the rest, the card disables the button, and the unfixed audio is never
///   played as though it were the fix.
/// * `apply` exists at the end of a chain that starts with a click. It derives a new version from
///   the one the finding is about, records it, and then asks the same critic again — which is why
///   `CheckOutcome` has three cases rather than being a `Bool`. "Applied and the check still fires"
///   is the interesting answer, and it is the one the user has to be told.
@MainActor
final class CheckAdapter: CheckHosting {

    private let app: AppState
    private let service: AuditionService
    /// The version the finding is about, so a fix derives from the right parent.
    private let subject: VersionID?

    init(app: AppState, service: AuditionService, subject: VersionID?) {
        self.app = app
        self.service = service
        self.subject = subject
    }

    // MARK: Hearing it

    func auditionProblem(_ finding: Finding) async {
        // As the version sounds: a dusty chop's problem is heard through its own chain.
        await playSpan(from: finding.locus.start, to: finding.locus.end, named: finding.subject.named,
                       through: subjectKind?.degradation ?? [])
    }

    func auditionFix(_ fix: Fix, of finding: Finding) async {
        guard canPreview(fix) else {
            app.note(.session, "That fix cannot be previewed here",
                     detail: "\(fix.title) changes how the part is cut or played, which this surface "
                         + "cannot render without committing it. Nothing was played.")
            return
        }
        // The one change this host can honestly preview: the chain is a buffer transform, so the
        // fixed audio is the same span with the new settings over it.
        await playSpan(from: finding.locus.start, to: finding.locus.end,
                       named: finding.subject.named,
                       through: CheckAdapter.previewPasses(for: fix.change, over: subjectKind))
    }

    /// True only for the changes this host can render without applying them. Everything else says so
    /// on the button — a card that cannot preview is better than a card that plays the problem and
    /// lets you believe it is the fix.
    func canPreview(_ fix: Fix) -> Bool {
        switch fix.change {
        case .setDegradeMix, .setDegradePreset: return true
        case .accept: return true
        default: return false
        }
    }

    func stopAudition() {
        Task { [service] in await service.stop() }
    }

    // MARK: Acting on it

    func apply(_ fix: Fix, of finding: Finding) async -> CheckOutcome {
        guard let subject, let version = app.version(subject) else {
            return .refused("This song no longer holds the part that finding is about.")
        }
        guard let changed = CheckAdapter.applying(fix.change, to: version.kind) else {
            // Everything else moves a level, a lag or the chain, none of which a part version
            // carries: they are render settings, and they belong on the surface that renders them.
            // A Check that pretended otherwise would record a version that changed nothing.
            return .refused("\(fix.title) is a setting on the \(surfaceName(for: finding)) rather than "
                + "something the part itself carries, so it cannot be recorded from here. "
                + "Nothing was changed.")
        }
        let applied = version.deriving(changed, by: .user,
                                       operation: CheckAdapter.operation(for: fix.change),
                                       note: "\(finding.criticName) at \(finding.subject.named): "
                                           + "\(fix.title.lowercased())")
        guard app.record(applied) else {
            return .refused("The song would not take that version.")
        }
        // The honest half. The critic's own measurement is arithmetic over the thing the fix just
        // moved, so the new value is known exactly without re-running the critic or touching the
        // audio — and when it still trips, the card says so rather than closing.
        guard let remeasured = CheckAdapter.remeasured(finding, after: fix.change) else {
            return .resolved
        }
        return remeasured.trips ? .stillFires(remeasured) : .resolved
    }

    /// The change, as a new part payload — or nil when this part does not carry the thing it moves.
    ///
    /// Three of the shipped critics' fixes are properties of a part version and the rest are
    /// properties of a *render*. A `.sample` carries its slice markers, so moving or dropping a cut
    /// is a new sample; a `.groove` carries its swing, so setting the swing is a new groove. A slice
    /// gain, a voice lag and the degradation chain are none of them in the graph, and this returns
    /// nil for those rather than recording a version that is identical to its parent.
    static func applying(_ change: EngineChange, to kind: PartKind) -> PartKind? {
        switch (change, kind) {
        case (.moveSliceStart(let index, let by), .sample(var sample)):
            guard sample.slices.indices.contains(index) else { return nil }
            sample.slices[index].position = max(0, sample.slices[index].position + by)
            sample.slices.sort { $0.position < $1.position }
            return .sample(sample)
        case (.dropSlice(let index), .sample(var sample)):
            guard sample.slices.indices.contains(index) else { return nil }
            sample.slices.remove(at: index)
            return .sample(sample)
        case (.setSwing(let percent), .groove(var groove)):
            groove.swing = Swing(percent: percent).factor
            return .groove(groove)
        case (.setDegradeMix(let mix), _) where !kind.degradation.isEmpty:
            // A dirtied part carries its chain, so moving the chain *is* a new version of it: the
            // top pass — the one the chain check is about — at the new mix, everything beneath kept.
            var passes = kind.degradation
            let top = passes.removeLast()
            var settings = DegradeSettings(top)
            settings.mix = min(1, max(0, mix))
            passes.append(settings.degradation(from: top.preset.flatMap(DegradeSettings.Preset.init(rawValue:))))
            return kind.withDegradation(passes)
        case (.setDegradePreset(let name), _) where !kind.degradation.isEmpty:
            // Nil takes the top pass off; a name replaces it with that preset, seed and all.
            var passes = kind.degradation
            passes.removeLast()
            if let name, let preset = DegradeSettings.Preset(rawValue: name), preset != .clean {
                passes.append(DegradeSettings(preset: preset).degradation(from: preset))
            }
            return kind.withDegradation(passes)
        case (.accept, _):
            // Accepting changes nothing about the part and everything about the record of it: the
            // version note is the point, which is why this is a version rather than a rail line.
            return kind
        default:
            return nil
        }
    }

    /// What the critic now measures, when the change's own arithmetic says exactly.
    ///
    /// Nil means "the fix removed the thing that was measured" — a dropped slice, an accepted
    /// finding — and the card resolves. It never guesses: a change whose effect on the measurement
    /// is not arithmetic gets nil rather than an invented number.
    static func remeasured(_ finding: Finding, after change: EngineChange) -> Measurement? {
        var measurement = finding.measurement
        switch change {
        case .moveSliceStart(_, let by) where measurement.feature == .attackShaveMS:
            // The shave is how far the cut sits *after* its transient, in milliseconds; moving the
            // cut earlier subtracts from it and it cannot go below zero.
            measurement.measured = max(0, measurement.measured + by * 1000)
            return measurement
        case .setSwing(let percent) where measurement.feature == .swingPercent:
            measurement.measured = percent
            return measurement
        default:
            return nil
        }
    }

    /// The chain a fix's preview plays through. Over a dirtied part it is the part's own chain with
    /// the fix applied — exactly the version `apply` would record. Over a dry one it is the fix's
    /// chain on its own, which for the mix is the `dust` lever at that amount (`Dust.pass`).
    static func previewPasses(for change: EngineChange, over kind: PartKind?) -> [Degradation] {
        if let kind, !kind.degradation.isEmpty, let changed = applying(change, to: kind) {
            return changed.degradation
        }
        switch change {
        case .setDegradeMix(let mix):
            return mix > 0 ? [Dust.pass(mix)] : []
        case .setDegradePreset(let name):
            guard let name, let preset = DegradeSettings.Preset(rawValue: name) else { return [] }
            return [DegradeSettings(preset: preset).degradation(from: preset)]
        default:
            return kind?.degradation ?? []
        }
    }

    static func operation(for change: EngineChange) -> String {
        switch change {
        case .moveSliceStart, .dropSlice: return Operation.chop
        case .setSwing: return Operation.regroove
        case .setDegradeMix, .setDegradePreset: return Operation.degrade
        default: return Operation.edit
        }
    }

    /// Which surface a fix belongs on, so the refusal names it rather than shrugging.
    private func surfaceName(for finding: Finding) -> String {
        switch finding.subject {
        case .slice, .source: return SurfaceKind.chopLane.rawValue.lowercased()
        case .step, .bar: return SurfaceKind.grid.rawValue.lowercased()
        }
    }

    // MARK: Reading the audio a finding is about

    private func playSpan(from start: Double, to end: Double, named name: String,
                          through passes: [Degradation]) async {
        guard let media = subjectMedia else {
            app.note(.session, "There is no audio behind \(name) to play",
                     detail: "The finding is about a part this session cannot read samples for.")
            return
        }
        guard let store = app.store else {
            app.note(.session, "This session has no library directory, so \(name) cannot be read")
            return
        }
        let songID = app.song?.id
        // A finding with no extent is still a thing you want to hear: half a second around it.
        let from = max(0, start)
        let to = max(from + 0.5, min(end, from + CompareAdapter.maximumSeconds))
        let span: AudioRegion.Span
        do {
            let url = try store.mediaURL(for: media, song: songID)
            span = try await Task.detached(priority: .userInitiated) {
                try AudioRegion.read(url, from: from, to: to)
            }.value
        } catch {
            app.note(.session, "\(name) could not be read", detail: "\(error)")
            return
        }
        guard !span.planar.isEmpty else { return }
        await service.play(planar: span.planar, sampleRate: span.sampleRate, through: passes)
    }

    private var subjectKind: PartKind? {
        guard let subject else { return nil }
        return app.version(subject)?.kind
    }

    private var subjectMedia: MediaRef? {
        guard let subject, let version = app.version(subject) else { return nil }
        switch version.kind {
        case .sample(let sample): return sample.media
        case .audio(let audio): return audio.media
        default: return nil
        }
    }
}

// MARK: - Building the surface

/// What the bench draws for a Check.
enum CheckFilling {
    /// A critic's finding, whole: the measurement, the locus and the two fixes.
    case finding(CheckModel)
    /// Something the Director noticed and said in words. Drawn as what it is, with no arithmetic
    /// and no fixes, because no critic measured it and nobody wrote them.
    case stated(title: String, text: String, about: String?)
    case unfilled(title: String, reason: String)
}

extension SurfaceWiring {

    /// The Check surface for a bench item, built once and kept for as long as the bench holds it.
    func checkFilling(for item: BenchItem, app: AppState) -> CheckFilling {
        prune(app)
        if let existing = checks[item.id] { return existing }
        let bound = app.bound(for: item.id)
        let built: CheckFilling
        switch app.answer(for: item.id) {
        case .check(let finding):
            let adapter = CheckAdapter(app: app, service: service(for: app), subject: bound.first)
            let model = CheckModel(id: item.id, finding: finding, bound: bound, host: adapter)
            checkAdapters[item.id] = adapter
            built = .finding(model)
        case .stated(let text):
            built = .stated(title: item.title, text: text,
                            about: bound.first.flatMap { app.version($0) }.map(PartLabel.title(of:)))
        case .compare, .none:
            built = .unfilled(title: item.title,
                              reason: "A Check shows one finding about one part, and this surface was "
                                  + "opened without one. Nothing was measured, so there is nothing to show.")
        }
        checks[item.id] = built
        return built
    }
}

// MARK: - The panel

/// The Check surface as a bench panel.
struct CheckPanel: View {
    let filling: CheckFilling

    var body: some View {
        switch filling {
        case .finding(let model):
            CheckSurfaceView(model: model)
        case .stated(let title, let text, let about):
            StatedCheck(title: title, text: text, about: about)
        case .unfilled(let title, let reason):
            EmptyNote(title: "\(title) has nothing to check.", detail: reason)
                .padding(Design.Metric.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Design.Palette.panelAlt)
        }
    }
}

/// A Check the Director opened in words.
///
/// Deliberately not the critic's card. That card prints who found it, the bar, the arithmetic and
/// two fixes, and every one of those is a claim about a measurement — printing them for a sentence
/// nobody measured would be the app inventing provenance. So this draws exactly what there is: the
/// part, the sentence, and the fact that it came from the band rather than from a check.
struct StatedCheck: View {
    let title: String
    let text: String
    let about: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SurfaceKind.check.rawValue.uppercased())
                    .font(Design.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Text("the Director, in words")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
                Spacer()
            }
            Text(title)
                .font(Design.Typography.prose(17, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
            Text(text)
                .font(Design.Typography.prose(15))
                .foregroundStyle(Design.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let about {
                Text("About \(about).")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            Text("No critic ran, so there is no measurement behind this and no fix to press.")
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }
}
