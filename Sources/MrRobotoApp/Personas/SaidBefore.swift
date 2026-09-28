import Foundation
import SongGraph

/// What the band has said before, and how to say that it has.
///
/// A persona's readings are arithmetic: the same song gives the same sentence, and a house that
/// writes at 90 bpm with the hook at 40 seconds hears the Peer say the same thing about every song.
/// The numbers should not change — they are the point — but the tenth time is not the first, and
/// the Director should be able to say "that is the fourth song running" rather than repeat itself.
/// So every convening is counted, per rule and per whether it held, in the library.
public enum SaidBefore {

    /// The records with these readings added, and for each reading what had been said before it,
    /// in the readings' order: nil the first time. A rule read twice in one convening (a flag per
    /// bar) is counted once.
    public static func update(_ records: [SaidRecord], with readings: [(PersonaID, PersonaReading)],
                              song: SongID, title: String, today: String) -> (records: [SaidRecord], before: [SaidRecord?]) {
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var order = records.map(\.id)
        var before: [SaidRecord?] = []
        // What each rule had behind it when this convening began, so a second reading of the same
        // rule here is told the same history as the first, not the first's own count.
        var history: [String: SaidRecord?] = [:]
        for (persona, reading) in readings {
            let blank = SaidRecord(persona: persona.rawValue, rule: reading.rule, holds: reading.holds,
                                   times: 0, songs: [], lastTitle: title, lastSaid: today)
            if let seen = history[blank.id] {
                before.append(seen)
                continue
            }
            let prior = byID[blank.id]
            history[blank.id] = prior
            before.append(prior)
            byID[blank.id] = (prior ?? blank).saying(about: song, titled: title, on: today)
            if prior == nil { order.append(blank.id) }
        }
        return (order.compactMap { byID[$0] }, before)
    }

    /// One sentence for the Director: how often, across how many songs, and when last.
    public static func sentence(_ record: SaidRecord, now song: SongID) -> String {
        let times = record.times == 1 ? "once" : "\(record.times) times"
        let others = record.songs.filter { $0 != song }.count
        if others == 0 {
            return "Said \(times) before, all about this song, last on \(record.lastSaid)."
        }
        let where_ = record.songs.contains(song)
            ? "about this song and \(others) other\(others == 1 ? "" : "s")"
            : "about \(others) other song\(others == 1 ? "" : "s")"
        return "Said \(times) before, \(where_); last about \"\(record.lastTitle)\" on \(record.lastSaid)."
    }

    /// Today as the records keep it.
    public static func today(_ date: Date = Date()) -> String {
        String(ISO8601DateFormatter().string(from: date).prefix(10))
    }
}
