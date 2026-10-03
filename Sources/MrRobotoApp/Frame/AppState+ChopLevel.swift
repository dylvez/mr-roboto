import Foundation
import SongGraph

// A chop's level (`ChopLevel`), as the frame keeps it: given when a quiet bar comes into the song,
// and moved afterwards as a version of the chop like any other change to it.

extension AppState {

    /// A chop's bar as its media holds it, measured. Nil for anything but a chop, and for a chop
    /// whose media this session cannot read.
    func chopReading(_ version: PartVersion) -> ChopLevel.Reading? {
        guard let song, case .sample(let sample) = version.kind else { return nil }
        return ChopLevel.read(sample, in: song) { [store] ref in try? store?.mediaURL(for: ref, song: song.id) }
    }

    /// A chop new to the song, at the level its bar asks for. A bar that is loud enough, a chop
    /// that already says how loud it plays, a later version of a chop and every other kind of
    /// part come back as they were.
    func levelledAsItComesIn(_ version: PartVersion) -> (version: PartVersion, reading: ChopLevel.Reading?) {
        guard let song, case .sample(var sample) = version.kind, sample.gainDB == nil,
              !song.versions.contains(where: { $0.partID == version.partID }),
              let reading = chopReading(version), let gain = reading.gainDB else { return (version, nil) }
        sample.gainDB = gain
        return (PartVersion(id: version.id, partID: version.partID, kind: .sample(sample), createdAt: version.createdAt,
                            author: version.author, parents: version.parents, operation: version.operation,
                            note: version.note, origin: version.origin, variation: version.variation), reading)
    }

    /// What the rail says when a quiet chop is brought up as it comes in.
    func noteLevelled(_ version: PartVersion, reading: ChopLevel.Reading) {
        guard case .sample(let sample) = version.kind, let gain = sample.gainDB else { return }
        note(.session, "\(PartLabel.title(of: version)) is quiet: brought up \(String(format: "%.0f", gain)) dB",
             detail: String(format: "Its loudest moment was at %.0f dBFS, where an instrument's sits at %.0f. ", reading.loudnessDBFS, ChopLevel.targetDBFS)
                 + "The chop plays that much louder wherever it is heard: its pads, its loop and a groove on its slices. "
                 + "Nothing in the mix moved." + stemLine(for: version))
    }

    /// " The other stem holds little of this record…", when a chop was cut from a stem that sits
    /// far under the record it came from. Empty otherwise.
    private func stemLine(for version: PartVersion) -> String {
        guard let song, case .sample(let sample) = version.kind,
              let stem = Guidance.stems(in: song).last(where: { Guidance.audio(of: $0)?.media == sample.media }),
              let name = Guidance.audio(of: stem)?.stem else { return "" }
        return " The \(name) stem holds little of this record where the bar was cut; another stem, or the record itself, may hold what you were after."
    }

    /// Gives a chop the level its bar asks for, as its next version, or puts it back as recorded.
    ///
    /// - Parameter gainDB: the level to play it at; nil measures the bar and takes what it asks
    ///   for; 0 is as recorded.
    /// - Returns: the level it now plays at (0 as recorded), or nil when nothing moved — not a
    ///   chop, unreadable, or already there.
    @discardableResult
    public func levelChop(_ part: PartID, to gainDB: Double? = nil, by author: Author = .user) -> Double? {
        guard let song, let version = song.latestVersion(of: part), case .sample(var sample) = version.kind else { return nil }
        let asked = gainDB ?? chopReading(version)?.gainDB ?? 0
        let level = max(-ChopLevel.mostDB, min(ChopLevel.mostDB, asked))
        guard abs(level - (sample.gainDB ?? 0)) > 0.05 else { return nil }
        sample.gainDB = level == 0 ? nil : level
        let name = PartLabel.title(of: version)
        let said = level == 0 ? "\(name), as recorded" : "\(name), \(ChopLevel.spoken(level))"
        guard record(version.deriving(.sample(sample), by: author, operation: Operation.level, note: version.note)) else { return nil }
        note(.session, level == 0 ? "\(name) plays as recorded" : "\(name) plays \(ChopLevel.spoken(level))",
             detail: "\(said): its pads, its loop and a groove on its slices, wherever they are heard. Nothing in the mix moved.")
        return level
    }
}
