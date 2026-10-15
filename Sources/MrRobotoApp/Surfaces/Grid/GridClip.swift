import AppKit
import Foundation
import SongGraph

/// Steps lifted off the grid to be put down somewhere else: a bar of every row, or one row of
/// every bar. The grid has no selection and does not want one — its units are the bar and the
/// row, which is what a right-click on a bar number or a voice's name offers.
///
/// A clip goes through the pasteboard, so a bar can cross grids, machines and songs; and it goes
/// as text as well as itself, so pasted anywhere else it reads as a pattern — `kick: X---x---` —
/// and a pattern typed that way pastes back onto the grid.
public struct GridClip: Codable, Equatable, Sendable {
    public var stepsPerBar: Int
    public var bars: Int
    /// One pattern per row, each `stepsPerBar * bars` steps long.
    public var rows: [GroovePattern]

    public init(stepsPerBar: Int, bars: Int, rows: [GroovePattern]) {
        self.stepsPerBar = max(1, stepsPerBar)
        self.bars = max(1, bars)
        self.rows = rows
    }

    // MARK: The readable form

    /// A tier as one character: an accent `X`, a hit `x`, a ghost `o`, a rest `-`.
    public static func mark(for tier: VelocityTier) -> Character {
        switch tier {
        case .accent: return "X"
        case .normal: return "x"
        case .ghost: return "o"
        case .rest: return "-"
        }
    }

    /// The tier a character stands for. A dot is a rest too, as a pattern is often typed; anything
    /// else is nothing.
    public static func tier(for mark: Character) -> VelocityTier? {
        switch mark {
        case "X": return .accent
        case "x": return .normal
        case "o", "O": return .ghost
        case "-", ".", "_": return .rest
        default: return nil
        }
    }

    /// Every row on a line of its own, the voice's name then its bars with a `|` between them:
    /// `closed hat: x-x-x-x-x-x-x-x- | x-x-x-x-x-x-x-x-`.
    public var text: String {
        rows.map { row in
            let steps = (0..<stepsPerBar * bars).map { $0 < row.steps.count ? row.steps[$0] : VelocityTier.rest }
            let bars = stride(from: 0, to: steps.count, by: stepsPerBar).map { start in
                String(steps[start..<min(start + stepsPerBar, steps.count)].map(Self.mark(for:)))
            }
            return "\(GridModel.name(of: row.voice)): \(bars.joined(separator: " | "))"
        }.joined(separator: "\n")
    }

    /// The readable form read back. A line is a voice's name — as the grid says it, or as the
    /// graph spells it — a colon, and its steps, with spaces and `|` between bars ignored; a row's
    /// bars are as long as its longest, the clip as many bars as its longest row, the rest filled
    /// with rests. Nil when no line is a row.
    public init?(text: String) {
        var rows: [(voice: DrumVoice, bars: [[VelocityTier]])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard let voice = GridModel.knownVoices.first(where: { GridModel.name(of: $0) == name || $0.rawValue == name })
            else { continue }
            let bars = line[line.index(after: colon)...].split(separator: "|").map { bar in
                bar.compactMap { $0.isWhitespace ? nil : (Self.tier(for: $0) ?? .rest) }
            }.filter { !$0.isEmpty }
            guard !bars.isEmpty else { continue }
            rows.append((voice, bars))
        }
        guard !rows.isEmpty else { return nil }
        let stepsPerBar = rows.flatMap(\.bars).map(\.count).max() ?? 1
        let barCount = rows.map(\.bars.count).max() ?? 1
        self.init(stepsPerBar: stepsPerBar, bars: barCount, rows: rows.map { row in
            var steps: [VelocityTier] = []
            for bar in 0..<barCount {
                let given = bar < row.bars.count ? row.bars[bar] : []
                steps += (0..<stepsPerBar).map { $0 < given.count ? given[$0] : .rest }
            }
            return GroovePattern(voice: row.voice, steps: steps)
        })
    }

    // MARK: The pasteboard

    /// The clip as itself, beside its text.
    public static let pasteboardType = NSPasteboard.PasteboardType("com.mrroboto.grid-steps")

    public func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(self) {
            pasteboard.setData(data, forType: Self.pasteboardType)
        }
        pasteboard.setString(text, forType: .string)
    }

    /// What the pasteboard holds, as a clip: one written by a grid, or text that reads as one.
    public static func read(from pasteboard: NSPasteboard) -> GridClip? {
        if let data = pasteboard.data(forType: pasteboardType),
           let clip = try? JSONDecoder().decode(GridClip.self, from: data) {
            return clip
        }
        return pasteboard.string(forType: .string).flatMap(GridClip.init(text:))
    }
}

extension GridModel {
    /// Lifts one bar of every row onto the pasteboard.
    public func copy(bar: Int, to pasteboard: NSPasteboard = .general) {
        clip(bar: bar)?.write(to: pasteboard)
    }

    /// Lifts one row, every bar of it, onto the pasteboard.
    public func copy(row voice: DrumVoice, to pasteboard: NSPasteboard = .general) {
        clip(row: voice)?.write(to: pasteboard)
    }

    /// Whether the pasteboard holds anything the grid can put down.
    public func canPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        GridClip.read(from: pasteboard) != nil
    }

    /// What is on the pasteboard, put down from this bar. See `paste(_:intoBar:)`.
    public func paste(intoBar bar: Int, from pasteboard: NSPasteboard = .general) {
        guard let clip = GridClip.read(from: pasteboard) else { return }
        paste(clip, intoBar: bar)
    }

    /// What is on the pasteboard, put down on this row. See `paste(_:ontoRow:)`.
    public func paste(ontoRow voice: DrumVoice, from pasteboard: NSPasteboard = .general) {
        guard let clip = GridClip.read(from: pasteboard) else { return }
        paste(clip, ontoRow: voice)
    }
}
