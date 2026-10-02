import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// `AppState` and the audition service, seen through `MergeHosting`.
///
/// An audition moves the fragment in memory and plays it the way its surface would: a chop
/// through its chain on the player node, a bass line on the bass sampler, a groove on the drum
/// sampler — three different nodes, which is what lets "Both" be both at once. A render does the
/// same move for keeps: the audio goes into the song's package as new media and a new version
/// derived from the original, so the original is one parent back and untouched.
@MainActor
final class MergeAdapter: MergeHosting {
    private let app: AppState
    private let service: AuditionService

    init(app: AppState, service: AuditionService) {
        self.app = app
        self.service = service
    }

    // MARK: Auditioning

    func audition(_ version: PartVersion, move: MergeMove) async {
        await play(version, move: move)
    }

    func audition(_ a: (PartVersion, MergeMove), with b: (PartVersion, MergeMove)) async {
        // Both are scheduled against "now" on different nodes; the second call follows the first
        // by the time it takes to read and move the first, which for a bar is well under a beat.
        await play(a.0, move: a.1)
        await play(b.0, move: b.1)
    }

    func stop() async { await service.stop() }

    private func play(_ version: PartVersion, move: MergeMove) async {
        let song = app.song
        let tempo = song?.tempo ?? 92
        let signature = song?.timeSignature ?? .fourFour
        switch version.kind {
        case .sample(let sample):
            guard let span = await read(sample, named: PartLabel.title(of: version)) else { return }
            do {
                let moved = try MergeRender.audio(span.planar, sampleRate: span.sampleRate, move: move)
                await service.play(planar: moved, sampleRate: span.sampleRate, through: sample.degradation)
            } catch {
                app.note(.session, "Could not move \(PartLabel.title(of: version))", detail: "\(error)")
            }
        case .bassline(let line):
            let moved = MergeRender.bassline(line, move: move)
            let voice = moved.sound.flatMap(BassVoiceSpec.resolve(id:)) ?? .finger
            if await service.currentBassID != voice.id {
                do { try await service.prepare(bass: voice) } catch {
                    app.note(.session, "Could not load the \(voice.name) bass", detail: "\(error)")
                    return
                }
            }
            let timeline = GrooveTimeline.tempo(tempo, timeSignature: signature)
            await service.playBass(BasslinePlayer.hits(for: moved, on: timeline, offsetBeats: 0))
        case .groove(let groove):
            let machine = song.map { SongPlayback.machine(in: $0) } ?? .tr808
            do { try await service.prepare(machine: machine) } catch {
                app.note(.session, "Could not load \(machine.name) to play that", detail: "\(error)")
                return
            }
            await service.play(CompareAdapter.hits(for: groove, levers: [:], tempo: tempo, timeSignature: signature))
        case .progression(let progression):
            // A lead sheet is read, not played here: its first chord, so the ear has the key.
            let moved = MergeRender.progression(progression, move: move)
            guard let chord = moved.chords.first else { return }
            if await service.currentBassID != BassVoiceSpec.finger.id {
                do { try await service.prepare(bass: .finger) } catch { return }
            }
            let root = Pitch(chord.root.transposed(by: 0).rawValue + 48)
            let pitches = chord.pitchClasses.map { Pitch(root.midi + ((chord.root.distance(to: $0)))) }
            await service.playBass(pitches.map { VoiceSampler.Hit(note: $0.midi, velocity: 92, at: 0, duration: 1.2) })
        default:
            app.note(.session, "\(PartLabel.title(of: version)) is not something a merge plays")
        }
    }

    /// The bar of the record a chop covers, read off disk.
    private func read(_ sample: Sample, named name: String) async -> AudioRegion.Span? {
        guard let store = app.store else {
            app.note(.session, "This session has no library directory, so \(name) cannot be read")
            return nil
        }
        let songID = app.song?.id
        let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: app.song)?.bars ?? [],
                                            tempo: sample.detectedTempo ?? app.song?.tempo)
        do {
            let url = try store.mediaURL(for: sample.media, song: songID)
            let span = try await Task.detached(priority: .userInitiated) {
                try AudioRegion.read(url, from: region.start, to: max(region.start, region.end))
            }.value
            guard !span.planar.isEmpty, span.planar[0].count > 0 else {
                app.note(.session, "\(name) is empty between \(String(format: "%.2f s and %.2f s", region.start, region.end))")
                return nil
            }
            return span
        } catch {
            app.note(.session, "\(name) could not be read", detail: "\(error)")
            return nil
        }
    }

    // MARK: Rendering

    enum Failure: Error, CustomStringConvertible {
        case noSong
        case noStore
        case unreadable(String)
        case notMergeable(String)

        var description: String {
            switch self {
            case .noSong: return "no song is open"
            case .noStore: return "this session has no library directory to render into"
            case .unreadable(let what): return "\(what) could not be read"
            case .notMergeable(let what): return "\(what) is not something a merge moves"
            }
        }
    }

    func render(_ version: PartVersion, move: MergeMove) async throws -> PartVersion {
        try await render(version, move: move, by: .user)
    }

    func render(_ version: PartVersion, move: MergeMove, by author: Author) async throws -> PartVersion {
        guard let song = app.song else { throw Failure.noSong }
        guard move.movesPitch || move.movesTime else { return version }
        let moved: PartKind
        switch version.kind {
        case .sample(let sample):
            moved = .sample(try await renderSample(sample, named: PartLabel.title(of: version), move: move, song: song))
        case .bassline(let line):
            moved = .bassline(MergeRender.bassline(line, move: move))
        case .progression(let progression):
            moved = .progression(MergeRender.progression(progression, move: move))
        case .groove:
            return version
        default:
            throw Failure.notMergeable(PartLabel.title(of: version))
        }
        let derived = version.deriving(moved, by: author, operation: Operation.merge, note: move.sentence)
        // Rendered into this song's package: recorded into this song, even if another is open now.
        guard app.song?.id == song.id ? app.record(derived) : app.record(derived, intoLibrarySong: song.id) else { throw Failure.noSong }
        return derived
    }

    /// The chop's bar through Signalsmith, as new media in the song's package: a sample that *is*
    /// the bar (`span` says so), its slices re-timed with the stretch, its key and tempo moved.
    private func renderSample(_ sample: Sample, named name: String, move: MergeMove, song: Song) async throws -> Sample {
        guard let store = app.store else { throw Failure.noStore }
        // The package has to exist to hold media; a song never saved has none yet.
        if (try? store.songStore(for: song.id)) == nil { app.save() }
        let package = try store.songStore(for: song.id)
        let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: song)?.bars ?? [],
                                            tempo: sample.detectedTempo ?? song.tempo)
        let url = try store.mediaURL(for: sample.media, song: song.id)
        let (media, seconds): (MediaRef, Double) = try await Task.detached(priority: .userInitiated) {
            let span = try AudioRegion.read(url, from: region.start, to: max(region.start, region.end))
            guard !span.planar.isEmpty, span.planar[0].count > 0 else { throw Failure.unreadable(name) }
            let out = try MergeRender.audio(span.planar, sampleRate: span.sampleRate, move: move)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mrroboto-merge-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: scratch) }
            try ChopAudio.writeWAV(out, to: scratch, sampleRate: span.sampleRate)
            // The span is what was actually rendered: the region clipped to the media, then moved.
            return (try package.addMedia(copying: scratch), Double(out[0].count) / span.sampleRate)
        }.value
        return Sample(media: media,
                      slices: MergeRender.slices(sample.slices, region: region, ratio: move.ratio),
                      rootPitch: sample.rootPitch,
                      detectedTempo: move.tempo ?? sample.detectedTempo,
                      sourceRecord: sample.sourceRecord,
                      degradation: sample.degradation,
                      key: move.key ?? sample.key,
                      span: SongGraph.TimeRange(start: 0, end: seconds),
                      pads: Self.pads(sample, region: region))
    }

    /// The pads' trims, carried to the merged chop: each follows its slice's marker into the list
    /// `MergeRender.slices` keeps, which drops the markers outside the region. A merge used to
    /// drop them all, so a chop tuned and reversed on its pads merged flat.
    nonisolated static func pads(_ sample: Sample, region: SongGraph.TimeRange) -> [PadTrim] {
        var kept: [Int: Int] = [:]
        var next = 0
        for (index, marker) in sample.slices.enumerated() where marker.position >= region.start && marker.position < region.end {
            kept[index] = next
            next += 1
        }
        return sample.pads.compactMap { pad in
            kept[pad.slice].map { var moved = pad; moved.slice = $0; return moved }
        }
    }

    func stitch(_ section: Section) async -> Bool {
        guard let song = app.song else { return false }
        return app.arrange(song.sections + [section])
    }
}
