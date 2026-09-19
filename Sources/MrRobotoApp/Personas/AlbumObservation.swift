import Foundation
import MusicTheory
import SongGraph

/// A record, read: every track's key, tempo, length, hook and last-released loudness; the
/// distance between neighbours on the circle of fifths and in tempo; the running time and the
/// loudness spread. Read from the songs' packages, not only the open one.
public struct AlbumObservation: Hashable, Sendable {

    public struct Track: Hashable, Sendable, Identifiable {
        public var id: SongID
        public var title: String
        public var key: Key?
        public var tempo: Double
        public var seconds: Double
        public var hookSeconds: Double?
        public var releasedLUFS: Double?
        public var partCount: Int
        /// The sampled sources the song uses, by name.
        public var sources: [String]
        /// The machines, sounds and feels it plays: the palette entries.
        public var palette: [String]
    }

    public struct Neighbours: Hashable, Sendable {
        public var from: String
        public var to: String
        /// Steps on the circle of fifths between the two key signatures, 0…6; nil when either is unknown.
        public var keyDistance: Int?
        public var tempoRatio: Double
        public var sameKey: Bool { keyDistance == 0 }
        public var isTempoJump: Bool { tempoRatio < 0.8 || tempoRatio > 1.25 }
    }

    public var label: String
    public var tracks: [Track]
    public var neighbours: [Neighbours]
    public var gapSeconds: Double
    public var targetLUFS: Double

    public var runningSeconds: Double { tracks.map(\.seconds).reduce(0, +) + gapSeconds }
    public var runningMinutes: Double { runningSeconds / 60 }
    public var sameKeyPairs: Int { neighbours.filter(\.sameKey).count }
    public var tempoJumps: Int { neighbours.filter(\.isTempoJump).count }
    public var openerHookSeconds: Double? { tracks.first?.hookSeconds }
    /// Max minus min of the released loudness, LU; 0 with fewer than two released.
    public var loudnessSpreadLU: Double {
        let released = tracks.compactMap(\.releasedLUFS)
        guard released.count >= 2, let low = released.min(), let high = released.max() else { return 0 }
        return high - low
    }
    /// Every palette entry with the tracks that use it, shared first.
    public var palette: [(entry: String, tracks: [String])] {
        var uses: [String: [String]] = [:]
        for track in tracks { for entry in Set(track.palette) { uses[entry, default: []].append(track.title) } }
        return uses.map { ($0.key, $0.value) }.sorted { ($0.1.count, $0.0) > ($1.1.count, $1.0) }
    }

    /// The key signature's place on the circle: a minor key by its relative major.
    static func signatureFifths(_ key: Key) -> Int {
        key.isMinor ? key.tonic.fifths - 3 : key.tonic.fifths
    }

    static func distance(_ a: Key?, _ b: Key?) -> Int? {
        guard let a, let b else { return nil }
        let d = abs(signatureFifths(a) - signatureFifths(b)) % 12
        return min(d, 12 - d)
    }

    public static func of(_ album: Album, songs: [Song]) -> AlbumObservation {
        var tracks: [Track] = []
        for id in album.songs {
            guard let song = songs.first(where: { $0.id == id }) else { continue }
            let seconds = Double(song.lengthInBars * song.timeSignature.beatsPerBar) * 60 / max(1, song.tempo)
            let form = FormObservation.of(song)
            var palette: [String] = []
            var sources: [String] = []
            for version in song.versions {
                switch version.kind {
                case .sound(let sound): palette.append(sound.preset.map { "\(sound.instrument) · \($0)" } ?? sound.instrument)
                case .groove(let groove):
                    if let machine = groove.degradation.last?.preset { palette.append("dust · \(machine)") }
                case .sample(let sample):
                    if let source = sample.sourceRecord.map({ $0.description }) { sources.append(source) }
                    if let machine = sample.degradation.last?.preset { palette.append("dust · \(machine)") }
                case .bassline(let line): if let sound = line.sound { palette.append("bass · \(sound)") }
                default: break
                }
            }
            for seed in song.seeds {
                if case .importedRecord(let record) = seed.kind { sources.append(record.description) }
            }
            tracks.append(Track(id: id, title: song.title, key: song.key, tempo: song.tempo, seconds: seconds,
                                hookSeconds: form.hookArrivalSeconds, releasedLUFS: album.releases[id]?.integratedLUFS,
                                partCount: Set(song.versions.map(\.partID)).count,
                                sources: Array(Set(sources)).sorted(), palette: Array(Set(palette)).sorted()))
        }
        var neighbours: [Neighbours] = []
        for (a, b) in zip(tracks, tracks.dropFirst()) {
            neighbours.append(Neighbours(from: a.title, to: b.title, keyDistance: distance(a.key, b.key), tempoRatio: b.tempo / max(1, a.tempo)))
        }
        let gaps = album.songs.dropFirst().map { album.gap(before: $0) }.reduce(0, +)
        return AlbumObservation(label: album.title, tracks: tracks, neighbours: neighbours, gapSeconds: gaps, targetLUFS: album.targets.integratedLUFS)
    }
}
