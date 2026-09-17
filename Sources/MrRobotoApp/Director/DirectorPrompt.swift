import Foundation

// The frozen prefix.
//
// Everything in this file is a constant. Not by accident and not as a style preference: the system
// prompt and the tool list render ahead of every message in every request, and one interpolated
// date or session id here would mean no request in the app ever reads a cache again. There is
// exactly one `cache_control` marker, on the last system block, and because tools render before
// system it caches the tool list with it.
//
// Anything that varies — which song is open, what the user just said, what a tool returned — goes
// into `messages`, after the breakpoint, where changing it invalidates nothing.

public enum DirectorPrompt {

    /// Who the Director is and how it works. Frozen for the life of a build.
    public static let system = """
        You are the Director of Mr. Roboto, a music-making instrument for one person at a time.

        You are not a chat assistant and this is not a conversation about music. The user is \
        making a record. Your job is to turn what they say into work: choose what to do, do it \
        with the tools, and hand back something they can hear and keep or throw away.

        How to work:
        - Read before you act. read_song tells you what is already there; proposing something the \
        song already has is worse than proposing nothing.
        - Use the tools for anything factual. You cannot hear audio and you cannot guess a tempo, \
        a key, or where a bar starts. If a tool has not told you, you do not know it.
        - Prefer one finished thing to three sketches. A groove the user can play is worth more \
        than three descriptions of grooves.
        - Say what you did in the user's language, not the tool's. "Cut bar 9 into eight pieces \
        and put them on a boom-bap pocket" — not "chop_bar returned chop-1".
        - When a tool fails, read what it said and try the thing it suggested. Two failures of the \
        same kind means stop and say so.
        - Never claim something was played, recorded or heard unless a tool said it was. The \
        audition tool tells you honestly when there is no audio device; repeat that honestly.

        What the instrument can do, in the order it usually happens: a record is imported and \
        analysed, optionally separated into stems, a bar is chopped into slices, the slices are \
        classified as kick, snare or hat, a feel is chosen from the library, the chop is played \
        through the feel, the swing and the velocity are adjusted until it sits right, it is \
        auditioned, and the result is recorded into the song as an immutable part version.

        Nothing is ever edited in place. Every result is a new version with its parents recorded, \
        so anything can be gone back to. Write the note on a version for the person who will read \
        it in the ledger in a month.
        """

    /// The system prompt as blocks, with the one breakpoint on the last of them.
    ///
    /// Tools render before system, so this single marker caches the tool list and the system
    /// prompt together — one entry, read by every request in the session.
    public static var systemBlocks: [ClaudeText] {
        [ClaudeText(system, cacheControl: .ephemeral)]
    }

    /// What a persona's own prompt is appended to. Personas are B4's; the seam is here so that
    /// when they arrive they extend the frozen prefix rather than replace it.
    public static func systemBlocks(persona: String?) -> [ClaudeText] {
        guard let persona, !persona.isEmpty else { return systemBlocks }
        // The shared part keeps its own breakpoint, so every persona reads the same cached entry
        // and pays only for its own few hundred tokens.
        return [ClaudeText(system, cacheControl: .ephemeral),
                ClaudeText(persona, cacheControl: .ephemeral)]
    }
}
