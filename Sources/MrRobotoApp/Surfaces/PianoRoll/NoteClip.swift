import AppKit
import Foundation
import MusicTheory
import SongGraph
import UniformTypeIdentifiers

/// Notes lifted off the Piano roll for the pasteboard: what ⌘C puts there and ⌘V reads back.
///
/// The notes are in beats from the beat the first of them sits in — not from the first note
/// itself, so a line that plays behind the kick keeps its lag through a paste — and they go onto
/// the pasteboard twice: as this type, so the roll gets them back exactly, and as words a person
/// can read, one note a line, so a clip pasted into a note to the band or a text file says what it
/// is. The words are read back too when they are all there is: a clip typed or edited by hand
/// pastes, so long as each line names a pitch, a place and a length.
public struct NoteClip: Codable, Equatable, Sendable {
    /// The notes, each starting so many beats into the clip.
    public var notes: [NoteEvent]
    /// What a bar is, for the places the words give.
    public var beatsPerBar: Int

    public init(notes: [NoteEvent], beatsPerBar: Int) {
        self.notes = notes
        self.beatsPerBar = max(1, beatsPerBar)
    }

    /// `picked` lifted off the line: moved so the clip starts on the beat the earliest of them
    /// sits in, in the order they sound.
    public init(lifting picked: [NoteEvent], beatsPerBar: Int) {
        let origin = (picked.map(\.start).min() ?? 0).rounded(.down)
        let lifted = picked
            .sorted { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
            .map { NoteEvent(pitch: $0.pitch, start: $0.start - origin, duration: $0.duration, velocity: $0.velocity) }
        self.init(notes: lifted, beatsPerBar: beatsPerBar)
    }

    /// How many beats the clip takes, whole: what a second paste lands after. A note that rings a
    /// hair over its last beat counts as ending on it, as it does for a duplicate.
    public var lengthInBeats: Double {
        max(1, ((notes.map(\.end).max() ?? 0) - PianoRollModel.ringOver).rounded(.up))
    }

    // MARK: As words

    /// The clip as words: a line saying what a bar is, then one note a line — its pitch, where it
    /// starts as a player counts, how long it is, and how hard it is struck.
    public var text: String {
        var lines = ["Notes from the Piano roll, \(beatsPerBar) beat\(beatsPerBar == 1 ? "" : "s") a bar"]
        for note in notes {
            let perBar = Double(beatsPerBar)
            let bar = Int(note.start / perBar)
            let beat = note.start - Double(bar) * perBar + 1
            lines.append("\(note.pitch.name())\tbar \(bar + 1), beat \(Self.number(beat))"
                         + "\t\(Self.number(note.duration)) beat\(note.duration == 1 ? "" : "s")\tvelocity \(note.velocity)")
        }
        return lines.joined(separator: "\n")
    }

    /// A number as a person writes it: up to four decimals, none when it is whole.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Words back into notes, where each line has a pitch, a bar and beat, and a length. Lines
    /// that do not — the heading, a blank, a remark — are passed over; words with no note in them
    /// are nil. A note with no velocity written is struck at 100.
    public init?(text: String) {
        var beatsPerBar = 4
        if let bar = text.firstMatch(of: #/(\d+) beats? a bar/#), let count = Int(bar.1) { beatsPerBar = max(1, count) }
        let line = #/^\s*([A-Ga-g][#b♯♭]*-?\d+)\s+bar\s+(\d+)\s*,\s*beat\s+([\d.]+)\s+([\d.]+)\s*beats?(?:\s+velocity\s+(\d+))?/#
        var notes: [NoteEvent] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let match = raw.firstMatch(of: line), let pitch = Pitch(name: String(match.1)),
                  let bar = Int(match.2), let beat = Double(match.3), let duration = Double(match.4),
                  bar >= 1, beat >= 1, duration > 0 else { continue }
            let start = Double(bar - 1) * Double(beatsPerBar) + beat - 1
            notes.append(NoteEvent(pitch: pitch, start: start, duration: duration, velocity: match.5.flatMap { Int($0) } ?? 100))
        }
        guard !notes.isEmpty else { return nil }
        self.init(notes: notes, beatsPerBar: beatsPerBar)
    }

    // MARK: On the pasteboard

    /// The clip's own type on the pasteboard.
    public static let typeIdentifier = "com.mrroboto.notes"
    public static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)
    /// The same as the Edit menu's Paste asks for it.
    public static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    /// Onto `pasteboard`, in both forms, in place of whatever was there.
    public func write(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(self) {
            pasteboard.setData(data, forType: Self.pasteboardType)
        }
        pasteboard.setString(text, forType: .string)
    }

    /// Off `pasteboard`: the clip's own type when it is there, else the words, else nil.
    public init?(reading pasteboard: NSPasteboard = .general) {
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let clip = try? JSONDecoder().decode(NoteClip.self, from: data) {
            self = clip
            return
        }
        if let words = pasteboard.string(forType: .string), let clip = NoteClip(text: words) {
            self = clip
            return
        }
        return nil
    }

    /// Whether `pasteboard` holds notes the roll can paste.
    public static func isOn(_ pasteboard: NSPasteboard = .general) -> Bool {
        NoteClip(reading: pasteboard) != nil
    }

    /// The clip as the item SwiftUI's Copy command puts on the pasteboard: this type and the words.
    public var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .all) { done in
                done(data, nil)
                return nil
            }
        }
        let words = Data(text.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { done in
            done(words, nil)
            return nil
        }
        return provider
    }
}
