import AVFAudio
import AudioEngine
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

    /// The longest a tune or the chords play. A phrase is longer than a bar of drums: a tune cut
    /// at eight seconds is cut before its answer, which is the half you judge it by.
    static let maximumPitchedSeconds: Double = 16

    /// Set once a candidate has been taken, so a second press does not append a second copy.
    private(set) var chosen: VersionID?

    init(app: AppState, service: AuditionService, surface: SurfaceID) {
        self.app = app
        self.service = service
        self.surface = surface
    }

    // MARK: Playing

    func audition(_ candidate: CompareCandidate, levers: [CompareLever: Double]) async {
        if let state = candidate.state {
            await playSection(state, named: candidate.title)
            return
        }
        guard let version = candidate.version else {
            app.note(.session, "\(candidate.title) has no version behind it, so there is nothing to play",
                     detail: "A candidate that is only a label is a row you cannot judge.")
            return
        }
        await play(version, named: candidate.title, levers: levers)
    }

    func auditionReference(_ reference: CompareReference, levers: [CompareLever: Double]) async {
        if let state = reference.state {
            await playSection(state, named: reference.title)
            return
        }
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

    /// A whole section as it stood, through the mix: bounced the first time and kept.
    private func playSection(_ state: SectionState, named name: String) async {
        guard let bounce = await app.audio(of: state) else {
            app.note(.session, "\(name) could not be played", detail: "Nothing in it sounds, or the section is no longer in the song.")
            return
        }
        let frames = min(bounce.planar.first?.count ?? 0, Int(CompareAdapter.maximumSectionSeconds * bounce.sampleRate))
        await service.play(planar: bounce.planar.map { Array($0.prefix(frames)) }, sampleRate: bounce.sampleRate)
    }

    /// The longest a section plays: long enough for eight bars at a slow tempo.
    static let maximumSectionSeconds: Double = 32

    @discardableResult
    func choose(_ candidate: CompareCandidate) async -> Bool {
        if let state = candidate.state {
            // The row that is the section as it is: taking it is leaving it.
            if app.standing(state.section)?.sounds(like: state) == true {
                app.note(.you, "\(state.name) stays as it is")
                return true
            }
            return app.restore(state)
        }
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
        // What goes with it: the bass that follows the chords taken.
        for companion in candidate.companions where app.version(companion.id) == nil {
            if app.record(companion) { app.refreshSurfaces(showing: companion.partID, now: companion.id) }
        }
        if !candidate.companions.isEmpty { app.select(version.id) }
        app.refreshSurfaces(showing: version.partID, now: version.id)
        chosen = version.id
        return true
    }

    // MARK: How a version becomes a sound

    private func play(_ version: PartVersion, named name: String, levers: [CompareLever: Double]) async {
        let passes = CompareAdapter.passes(for: version, levers: levers)
        switch version.kind {
        case .groove(let groove):
            await playGroove(groove, levers: levers, through: passes)
        case .sample(let sample):
            let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: app.song)?.bars ?? [],
                                                tempo: sample.detectedTempo ?? app.song?.tempo)
            await playAudio(sample.media, from: region.start,
                            to: min(region.end, region.start + CompareAdapter.maximumSeconds),
                            named: name, through: passes, gainDB: sample.gainDB)
        case .audio(let audio):
            await playAudio(audio.media, from: 0, to: CompareAdapter.maximumSeconds, named: name, through: passes)
        case .bassline(let line):
            await playBassline(line, levers: levers)
        case .melody(let melody):
            await playPitched(melody.notes, part: version.partID, named: name, levers: levers)
        case .progression(let progression):
            await playPitched(Voicing.notes(for: progression), part: version.partID, named: name, levers: levers)
        default:
            app.note(.session, "A \(version.type.rawValue) cannot be auditioned here",
                     detail: "The Compare plays grooves, bass lines, tunes, chords, chops and recordings; \(name) is none of them.")
        }
    }

    /// A tune or the chords, on the instrument its part plays on, at the song's tempo or the
    /// `tempo` lever's. These were the two kinds a Compare could hold and not play: three
    /// counter-melodies side by side, and no way to hear which.
    private func playPitched(_ notes: [NoteEvent], part: PartID, named name: String,
                             levers: [CompareLever: Double]) async {
        let hits = CompareAdapter.hits(for: notes, levers: levers, tempo: app.song?.tempo ?? 90,
                                       timeSignature: app.song?.timeSignature ?? .fourFour)
        guard !hits.isEmpty else {
            app.note(.session, "\(name) has no notes in it", detail: "Nothing was played.")
            return
        }
        let spec = app.song.flatMap { InstrumentVoiceSpec.preset(id: SongPlayback.instrumentID(for: part, in: $0)) } ?? .rhodes
        do {
            try await service.prepare(instrument: spec)
        } catch {
            app.note(.session, "Could not load \(spec.name) to play that", detail: "\(error)")
            return
        }
        await service.playInstrument(hits)
    }

    /// Written notes as hits under the levers, the first `maximumPitchedSeconds` of them.
    static func hits(for notes: [NoteEvent], levers: [CompareLever: Double],
                     tempo: Double, timeSignature: TimeSignature) -> [VoiceSampler.Hit] {
        let bpm = levers[.tempo].map { CompareLever.tempo.clamp($0) } ?? tempo
        let clock = TransportClock(tempo: max(20, bpm), timeSignature: timeSignature)
        return notes.map { note in
            VoiceSampler.Hit(note: note.pitch.midi, velocity: note.velocity,
                             at: clock.seconds(forBeat: note.start),
                             duration: clock.seconds(forBeat: note.duration))
        }.filter { $0.time < maximumPitchedSeconds }
    }

    /// A bass line, with the song's newest groove under it so the lag is heard against a kick:
    /// the line on the bass sampler, the groove live on the drum sampler, both anchored now. The
    /// `lag` lever moves every onset by its amount at the song's tempo, and the `tempo` lever
    /// re-times both.
    private func playBassline(_ line: Bassline, levers: [CompareLever: Double]) async {
        let tempo = levers[.tempo].map { CompareLever.tempo.clamp($0) } ?? app.song?.tempo ?? 90
        let signature = app.song?.timeSignature ?? .fourFour
        let shifted = CompareAdapter.shifted(line, lagMS: levers[.lag], tempo: tempo)
        let timeline = GrooveTimeline.tempo(max(20, tempo), timeSignature: signature)
        let bassHits = BasslinePlayer.hits(for: shifted, on: timeline, offsetBeats: 0)
            .filter { $0.time < CompareAdapter.maximumSeconds }
        guard !bassHits.isEmpty else {
            app.note(.session, "That bass line has no notes in it", detail: "Nothing was played.")
            return
        }
        let voice = line.sound.flatMap(BassVoiceSpec.resolve(id:)) ?? .finger
        do {
            try await service.prepare(bass: voice)
        } catch {
            app.note(.session, "Could not load the \(voice.name) bass to play that", detail: "\(error)")
            return
        }
        // The groove, when the song has one and it is dry: the reference the lag is against.
        if let song = app.song, let grooveVersion = Guidance.grooves(in: song).last,
           case .groove(let groove) = grooveVersion.kind, groove.degradation.isEmpty {
            let machine = app.song.map { SongPlayback.machine(in: $0) } ?? .tr808
            var drumLevers = levers
            drumLevers[.lag] = nil
            let drumHits = CompareAdapter.hits(for: groove, levers: drumLevers, tempo: tempo, timeSignature: signature)
                .filter { $0.time < CompareAdapter.maximumSeconds }
            if !drumHits.isEmpty, (try? await service.prepare(machine: machine)) != nil {
                await service.play(drumHits)
            }
        }
        await service.playBass(bassHits)
    }

    /// The line with every onset moved by `lagMS` at `tempo`: what the `lag` lever means.
    static func shifted(_ line: Bassline, lagMS: Double?, tempo: Double) -> Bassline {
        guard let lagMS, tempo > 0 else { return line }
        // The lever states where the line should sit, not an extra shift: it replaces the line's
        // own median displacement so 40 on the lever is 40 behind the kick whatever was written.
        let beats = CompareLever.lag.clamp(lagMS) / 1000 * tempo / 60
        let starts = line.notes.map(\.start)
        let median = BassObservation.median(starts.map { $0 - ($0 * 4).rounded() / 4 })
        return Bassline(notes: line.notes.map { note in
            NoteEvent(pitch: note.pitch, start: max(0, note.start - median + beats),
                      duration: note.duration, velocity: note.velocity)
        }, sound: line.sound, key: line.key, lengthInBars: line.lengthInBars)
    }

    /// The chain a row plays through.
    ///
    /// The `dust` lever means exactly what dust means everywhere else: `Dust.pass(_:)`, the pass a
    /// Sound surface commits when it is set to the same amount. With the lever on the surface every
    /// row plays its **dry** part through that one pass — a lever is applied to every row alike, so
    /// a row that was already dusty does not get a second machine on top of the lever's and win the
    /// comparison for being louder in the noise. With no lever, each row plays as its version says
    /// it sounds, which for a dusty chop is through its own chain.
    static func passes(for version: PartVersion, levers: [CompareLever: Double]) -> [Degradation] {
        if let amount = levers[.degradeMix] { return amount > 0 ? [Dust.pass(amount)] : [] }
        return Dust.passes(of: version)
    }

    /// A groove, rendered at the levers' tempo and swing onto the song's own machine — live on the
    /// shared sampler when it is dry, bounced and put through its chain when it is not.
    private func playGroove(_ groove: Groove, levers: [CompareLever: Double],
                            through passes: [Degradation]) async {
        let machine = app.song.map { SongPlayback.machine(in: $0) } ?? .tr808
        let hits = CompareAdapter.hits(for: groove, levers: levers,
                                       tempo: app.song?.tempo ?? 90,
                                       timeSignature: app.song?.timeSignature ?? .fourFour)
        guard !hits.isEmpty else {
            app.note(.session, "That groove has no hits in it", detail: "Nothing was played.")
            return
        }
        guard passes.isEmpty else {
            let seconds = min(CompareAdapter.maximumSeconds, (hits.map(\.time).max() ?? 0) + Dust.tail)
            do {
                let dry = try await service.bounce(hits, machine: machine, seconds: seconds)
                await service.play(planar: dry.planar, sampleRate: dry.sampleRate, through: passes)
            } catch {
                app.note(.session, "Could not bounce that groove through its chain", detail: "\(error)")
            }
            return
        }
        do {
            try await service.prepare(machine: machine)
        } catch {
            app.note(.session, "Could not load \(machine.name) to play that", detail: "\(error)")
            return
        }
        await service.play(hits)
    }

    /// A chop or a stem, read off disk and played as samples, through its chain.
    private func playAudio(_ media: MediaRef, from start: Double, to end: Double, named name: String,
                           through passes: [Degradation], gainDB: Double? = nil) async {
        guard let store = app.store else {
            app.note(.session, "This session has no library directory, so \(name) cannot be read")
            return
        }
        let songID = app.song?.id
        let span: AudioRegion.Span
        do {
            let url = try store.mediaURL(for: media, song: songID)
            span = try await Task.detached(priority: .userInitiated) {
                try AudioRegion.read(url, from: start, to: max(start, end)).levelled(by: gainDB)
            }.value
        } catch {
            app.note(.session, "\(name) could not be read", detail: "\(error)")
            return
        }
        guard !span.planar.isEmpty else { return }
        await service.play(planar: span.planar, sampleRate: span.sampleRate, through: passes)
    }

    // MARK: The levers, as arithmetic

    /// One pass of `groove` under the levers. A pure function so `BandWiringTests` can assert what a
    /// lever does to the hits without an audio device.
    static func hits(for groove: Groove, levers: [CompareLever: Double],
                     tempo: Double, timeSignature: TimeSignature) -> [VoiceSampler.Hit] {
        let bpm = levers[.tempo].map { CompareLever.tempo.clamp($0) } ?? tempo
        var options = GrooveRenderOptions.stored(groove)
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

    /// The `dust` lever at one amount, over planar floats: `Dust.pass(mix)` through `Dust.render`,
    /// which is what a dusty version at that amount sounds like everywhere else in the app.
    static func dusted(_ planar: [[Float]], sampleRate: Double, mix: Double) -> [[Float]] {
        guard mix > 0 else { return planar }
        return (try? Dust.render(planar, sampleRate: sampleRate, passes: [Dust.pass(mix)])) ?? planar
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
        // The columns are the candidates' own kind: a Compare of bass lines against the groove they
        // sit under measures the lines, and the groove row simply has no numbers in those columns.
        let features = self.features(for: candidates.first ?? reference)
        let song = app.song
        return CompareBrief(
            title: item.title,
            reference: CompareReference(title: headline(of: reference),
                                        kind: reference.note ?? "what the song already has",
                                        readings: readings(of: reference, tempo: tempo, features: features, in: song),
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
                                        readings: readings(of: version, tempo: tempo, features: features, in: song),
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
        case .bassline: return bassFeatures
        default: return []
        }
    }

    /// The Bassist's columns: where the line sits, how much it plays, how long the notes are, how
    /// the roots are reached.
    static let bassFeatures: [Feature] = [.bassKickOffsetMS, .bassAttacksPerBar, .bassRestRatio,
                                          .bassNoteLengthRatio, .bassChromaticApproachRate]

    /// Every feature this version can actually be measured on. A feature it cannot answer is left
    /// out rather than reported as zero — `CompareModel.differences` skips a column the reference
    /// does not carry, and a fabricated zero would turn that into a difference nobody can hear.
    static func readings(of version: PartVersion, tempo: Double, features: [Feature],
                         in song: Song? = nil) -> [CompareReading] {
        let values: (Feature) -> Double?
        switch version.kind {
        case .bassline(let line):
            // Measured against the groove the song holds and the chords it states, like the tool did.
            guard let song, let grooveVersion = Guidance.grooves(in: song).last,
                  case .groove(let groove) = grooveVersion.kind else { return [] }
            var chords: [ChordSpan] = []
            if let p = Guidance.progressions(in: song).last, case .progression(let stored) = p.kind { chords = stored.spans }
            let heard = line.lengthInBars.map { groove.tiled(toBars: $0) } ?? groove
            let observation = BassObservation(label: PartLabel.title(of: version), bassline: line, groove: heard,
                                              chords: chords, tempo: tempo, timeSignature: song.timeSignature,
                                              kickDecaySeconds: SurfaceWiring.kickDecay(in: song))
            values = { observation.value(of: $0) }
        case .groove(let groove):
            let observation = GrooveObservation(label: PartLabel.title(of: version), groove: groove,
                                                options: .stored(groove), tempo: tempo)
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
