import Analysis
import AudioEngine
import CryptoKit
import Foundation
import SongGraph

/// Where sung audio sits in the song now, and the audio as the song plays it.
///
/// A take is kept as it was sung: its bytes, the second it was aligned at, the section and bar it
/// was sung to, and the tempo. The song moves on — a section lengthened before it, the tempo
/// changed — and every reader of a take (the transport and a bounce, the Takes lanes, a comp, a
/// Check) asks here where it is now rather than working it out again. Each used to: the lanes and
/// the transport agreed about a moved section, and none of them knew about a tempo.
enum TakePlacement {

    /// The audio with the placement it plays by: its own take or comp, or — for a take corrected
    /// from a Check, which is kept with neither so it is not counted as another pass — the take it
    /// was corrected from. Nil for a version that is not audio, or audio that was never sung: the
    /// record (`Guidance.take(in:)`) is the audio this is nil for.
    static func audio(of version: PartVersion, in song: Song) -> Audio? {
        guard var audio = Guidance.audio(of: version) else { return nil }
        if audio.take != nil || audio.comp != nil { return audio }
        guard audio.role == .take else { return nil }
        var parents = version.parents
        var seen: Set<VersionID> = [version.id]
        while let id = parents.first {
            parents.removeFirst()
            guard seen.insert(id).inserted, let parent = song.versions.first(where: { $0.id == id }),
                  let from = Guidance.audio(of: parent) else { continue }
            if from.take != nil || from.comp != nil {
                audio.take = from.take
                audio.comp = from.comp
                return audio
            }
            parents += parent.parents
        }
        return nil
    }

    /// Song seconds at which the audio's first frame sounds now: where it was sung, at the tempo
    /// the song has now, moved with its section.
    static func alignment(of audio: Audio, in song: Song?, clock: TransportClock) -> Double {
        placement(of: audio, in: song, clock: clock).audio
    }

    /// Where the audio's first frame sounds now, and where the take itself begins — the bar the
    /// Booth recorded for, after the count-in the audio starts in — in song seconds.
    ///
    /// Both are measured from the section the take was sung to, in the take's own frame — the
    /// tempo and meter it was sung at — and laid from where that section starts now, a beat of
    /// then to a beat of now. So a section moved, a tempo changed and a meter changed are one rule.
    /// The seconds it was aligned at were counted in bars of the meter it was sung in; read in bars
    /// of another, a Hook take landed seven bars late, or lost its first ten seconds.
    static func placement(of audio: Audio, in song: Song?, clock: TransportClock) -> (audio: Double, take: Double?) {
        let sung = self.sung(audio, in: song, clock: clock)
        let stretch = song.map(audio.stretch(in:)) ?? 1
        var then = 0.0, now = 0.0
        if let song, let section = audio.take?.section ?? audio.comp?.section,
           let startedOn = audio.take?.sectionStartBar ?? audio.comp?.sectionStartBar,
           let startsOn = song.startBar(of: section) {
            then = sung.seconds(forBar: startedOn)
            now = clock.seconds(forBar: startsOn)
        }
        let take = audio.take.map { now + (sung.seconds(forBar: $0.startBar, beat: $0.startBeat) - then) * stretch }
        let first = audio.alignmentOffset.map { now + ($0 - then) * stretch } ?? take ?? now
        return (first, take)
    }

    /// The clock the audio was sung against: the tempo and meter its take or comp says, else the
    /// song's now — a take from before either was kept is read as if nothing has changed.
    static func sung(_ audio: Audio, in song: Song?, clock: TransportClock) -> TransportClock {
        TransportClock(tempo: audio.take?.tempo ?? audio.comp?.tempo ?? song?.tempo ?? clock.tempo,
                       timeSignature: audio.take?.meter ?? audio.comp?.meter ?? song?.timeSignature ?? clock.timeSignature)
    }

    /// How long the audio plays in the song now.
    static func duration(of audio: Audio, in song: Song?) -> Double {
        audio.duration * (song.map(audio.stretch(in:)) ?? 1)
    }

    // MARK: The audio, stretched

    /// Where stretched takes are kept between plays. A cache: anything in it can be made again
    /// from the take, and a take's bytes never change, so a file here is never stale for its key.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto/stretched", isDirectory: true)
    }

    /// The file to play for `source` at `stretch` of its length: the file itself at 1, else the
    /// take stretched with its pitch kept, made once and read from the cache after. Only the
    /// newest stretch of a take is kept: a song has one tempo at a time, and a minute of stereo
    /// take is 23 MB, so every tempo tried along the way would otherwise stay on disk.
    static func url(_ source: URL, stretch: Double) throws -> URL {
        guard stretch != 1 else { return source }
        let take = key(source)
        let target = directory.appendingPathComponent("\(take)-\(String(format: "%.6f", stretch)).wav")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let (planar, sampleRate) = try BoothAdapter.planar(source)
        let stretched = try self.stretched(planar, sampleRate: sampleRate, by: stretch)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Written aside and moved in, so a play started while another is writing never reads half.
        let scratch = directory.appendingPathComponent("writing-\(UUID().uuidString).wav")
        try BoothAdapter.write(stretched, sampleRate: sampleRate, to: scratch)
        do {
            try FileManager.default.moveItem(at: scratch, to: target)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            guard FileManager.default.fileExists(atPath: target.path) else { throw error }
        }
        let others = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in others where name.hasPrefix(take + "-") && name != target.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return target
    }

    /// The take's samples as the song plays them.
    static func planar(_ source: URL, stretch: Double) throws -> (planar: [[Float]], sampleRate: Double) {
        try BoothAdapter.planar(url(source, stretch: stretch))
    }

    /// Audio at `stretch` of its length, its pitch kept. The stretcher's default blocks: a voice is
    /// held notes and consonants, and the percussive preset a chop uses blurs a held note's pitch.
    static func stretched(_ planar: [[Float]], sampleRate: Double, by stretch: Double) throws -> [[Float]] {
        guard stretch != 1, let frames = planar.first?.count, frames > 0 else { return planar }
        return try SignalsmithTimeStretcher(preset: .default).stretch(planar: planar, sampleRate: sampleRate, ratio: stretch)
    }

    /// The source's path, size and modification date, hashed: a different file at the same path
    /// is a different take.
    private static func key(_ source: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let text = "\(source.standardizedFileURL.path)|\(size)|\(modified)"
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
