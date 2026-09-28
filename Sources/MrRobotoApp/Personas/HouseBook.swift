import Foundation
import SongGraph

/// The house calls in force for one song: what the bibles shipped with, what this library has
/// decided since, and what the song decided for itself, the later over the earlier.
///
/// A call made on the Cast surface used to be kept with the one song it was made in, and the next
/// song started from the bible again, so a year of songs was a year of the same readings. The
/// library's calls are the house's taste and carry to every song; a song's own call is an
/// exception kept with that song.
public struct HouseBook: Equatable, Sendable {

    /// Where a call in force came from.
    public enum Scope: String, Equatable, Sendable {
        /// The call the app shipped with (`Beatmaker.houseCalls`).
        case shipped
        /// This library's, for every song.
        case house
        /// This song's own.
        case song
    }

    public struct Entry: Equatable, Sendable {
        public var call: HouseCall
        public var scope: Scope
    }

    /// One per question decided, in the order they were first decided.
    public private(set) var entries: [Entry]

    public init(shipped: [HouseCall] = Beatmaker.houseCalls, library: [HouseCallRecord]? = nil,
                song: [HouseCallRecord]? = nil) {
        entries = []
        for call in shipped { set(call, .shipped) }
        for record in library ?? [] { if let call = HouseCall(record) { set(call, .house) } }
        for record in song ?? [] { if let call = HouseCall(record) { set(call, .song) } }
    }

    /// The book for a song in a library.
    public static func of(_ library: Library, song: Song?) -> HouseBook {
        HouseBook(library: library.houseCalls, song: song?.houseCalls)
    }

    private mutating func set(_ call: HouseCall, _ scope: Scope) {
        if let index = entries.firstIndex(where: { $0.call.question == call.question }) {
            entries[index] = Entry(call: call, scope: scope)
        } else {
            entries.append(Entry(call: call, scope: scope))
        }
    }

    /// Questions a persona's own reading already turns on, so a note would say it twice: the
    /// Beatmaker's snare reads late or early by the call itself.
    public static let readInCode: Set<String> = ["beatmaker.oq.snare-direction"]

    /// Every call in force.
    public var calls: [HouseCall] { entries.map(\.call) }

    public func entry(for question: String) -> Entry? { entries.first { $0.call.question == question } }

    /// What a reading made under `rule` has to say about the house, when the house plays the
    /// alternative on a question that rule answers to. Nil when no call bears on it, or when the
    /// call kept the bible's reading. The rule's numbers are the bible's; this is the sentence
    /// that says the house has chosen otherwise, so nobody mistakes one for the other.
    public func note(on rule: String, in bible: PersonaBible) -> String? {
        for question in bible.openQuestions where question.affects.contains(rule) && !Self.readInCode.contains(question.id) {
            guard let entry = entry(for: question.id), entry.call.choice == .alternative else { continue }
            let whose = entry.scope == .song ? "This song plays" : "This house plays"
            return "\(whose) the other reading on \"\(question.question)\" (decided \(entry.call.decidedOn)): \(question.alternative)"
        }
        return nil
    }
}

extension HouseCall {
    /// A kept record, read back. Nil for a choice this build does not know.
    public init?(_ record: HouseCallRecord) {
        guard let choice = Choice(rawValue: record.choice) else { return nil }
        self.init(question: record.question, choice: choice, how: record.how, decidedOn: record.decidedOn)
    }
}
