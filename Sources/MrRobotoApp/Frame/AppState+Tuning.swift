import Analysis
import Foundation
import MusicTheory
import SongGraph

// A sung take tuned to the song's key: kept as a new version of the same part, where the take
// was, the take as sung its parent — so "back one" is the take as it was sung.

extension AppState {

    public enum TuneOutcome: Sendable {
        case tuned(PartVersion, PitchCorrection.Result, key: Key)
        case failed(String)
    }

    /// The key a take is tuned to: the song's, else the one its analysis heard.
    var tuningKey: Key? {
        guard let song else { return nil }
        return song.key ?? Guidance.analysis(in: song)?.dominantKey
    }

    /// Pulls `version` — a take or a comp — onto the notes of the song's key at `strength`, and keeps
    /// it as that part's newest version.
    public func tuneTake(_ version: PartVersion, strength: PitchCorrection.Strength, by author: Author = .user) async -> TuneOutcome {
        guard let song, let store else { return .failed("No song is open.") }
        guard case .audio(let audio) = version.kind, audio.role == .take else {
            return .failed("\(PartLabel.title(of: version)) is not a sung take or a comp.")
        }
        guard let key = tuningKey else {
            return .failed("The song has no key to tune to. Set one in the song's settings, or analyse its record.")
        }
        guard let url = try? store.mediaURL(for: audio.media, song: song.id),
              let read = try? BoothAdapter.planar(url), let first = read.planar.first, !first.isEmpty else {
            return .failed("\(PartLabel.title(of: version))'s audio could not be read.")
        }
        let classes = Set(key.pitchClasses.map(\.rawValue))
        let result: PitchCorrection.Result
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try PitchCorrection.correct(read.planar, sampleRate: read.sampleRate, pitchClasses: classes, strength: strength)
            }.value
        } catch {
            return .failed("\(error)")
        }
        // Seconds of work have passed: a take of this song is not kept into another one.
        guard self.song?.id == song.id else { return .failed("The song changed while the take was being tuned.") }
        guard let media = keepAudio(result.planar, sampleRate: read.sampleRate, what: "the tuned take") else {
            return .failed("There is nowhere to keep the tuned take. Save the song into a library first.")
        }
        var tuned = audio
        tuned.media = media
        tuned.duration = Double(result.planar.first?.count ?? 0) / read.sampleRate
        let note = String(format: "Tuned %@ to %@: %.0f cents off its notes on average, %.0f after",
                          strength.rawValue, key.name, result.centsBefore, result.centsAfter)
        let kept = PartVersion(partID: version.partID, kind: .audio(tuned), author: author, parents: [version.id],
                               operation: Operation.tuned, note: note)
        guard record(kept) else { return .failed("The tuned take could not be kept.") }
        return .tuned(kept, result, key: key)
    }
}
