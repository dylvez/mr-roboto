import Foundation
import Performance
import SongGraph

/// Where a clip of a record's voice ends: on a rest, or mid-line.
///
/// A clip loops from the top of every section that plays it and stops when the section does, so
/// the bar it ends on is heard twice over — at each turn of the loop and at the section's edge —
/// and a line still going there is cut off with a few milliseconds' fade. Which bars a voice rests
/// after is read from the record's stem (`RecordStems.rests`); this says what that means for the
/// bars chosen, and for the sections that play them.
enum ClipSeams {

    /// The stems whose cuts are said: a line cut off is heard as a cut. A bass or a band looping
    /// mid-phrase is what a loop is.
    static func says(_ stem: String) -> Bool { stem == "vocals" }

    /// What the plan says of some bars of a record's voice, before they are brought in: whether
    /// they end where it rests, and where it does when they do not. Empty for another stem, a
    /// whole stem, or a record not measured yet.
    static func lines(for bars: Range<Int>, of record: Record, stem name: String) -> [String] {
        guard says(name), !bars.isEmpty, let stem = record.stem(named: name), let rests = RecordStems.rests(of: stem),
              let endsSounding = RecordStems.soundsAtEnd(of: bars.upperBound - 1, in: stem) else { return [] }
        var out: [String] = []
        if endsSounding {
            out.append("Ends mid-line: the voice is still going as bar \(bars.upperBound) ends, so each turn of the loop cuts it off. "
                       + restLine(rests, in: bars))
        } else {
            out.append("Ends where the voice rests, so the loop turns clean.")
        }
        if bars.lowerBound > 0, RecordStems.soundsAtEnd(of: bars.lowerBound - 1, in: stem) == true, !rests.contains(bars.lowerBound - 1) {
            out.append("Comes in mid-line: the voice is already going as bar \(bars.lowerBound + 1) begins.")
        }
        return out
    }

    /// "It rests after bar 20.", or that it rests nowhere in them.
    static func restLine(_ rests: [Int], in bars: Range<Int>) -> String {
        if let last = rests.last(where: { bars.contains($0) && $0 < bars.upperBound - 1 }) {
            return "It rests after bar \(last + 1): end there and it turns clean."
        }
        if let next = rests.first(where: { $0 >= bars.upperBound }) {
            return "It rests nowhere in bars \(bars.lowerBound + 1)–\(bars.upperBound); next after bar \(next + 1)."
        }
        return "It rests nowhere in bars \(bars.lowerBound + 1)–\(bars.upperBound)."
    }

    /// A clip a section cuts off mid-line.
    struct Cut: Hashable, Sendable {
        var part: PartID
        var sentence: String
    }

    /// The clips of a record's voice this section cuts off mid-line: at its end, where the section
    /// stops the clip part way through or on a bar the voice runs past, or where the clip loops
    /// inside it. A clip read through an older grid than its record has now is left alone: its
    /// bars are not the bars the record was measured on.
    static func cuts(in section: Section, song: Song, record: (RecordID) -> Record?) -> [Cut] {
        var seen = Set<PartID>()
        var out: [Cut] = []
        for lane in section.stitch where seen.insert(lane.part).inserted {
            guard let version = song.version(playing: lane), case .sample = version.kind,
                  let fit = SourceFitting.fit(of: version), says(fit.stem),
                  let from = fit.fromBar, let to = fit.toBar, to > from, let id = fit.record, let found = record(id),
                  (found.grid ?? RecordGrid()) == (fit.grid ?? RecordGrid()),
                  let stem = found.stem(named: fit.stem), let rests = RecordStems.rests(of: stem) else { continue }
            let length = to - from, bars = max(1, section.lengthInBars)
            let reached = bars % length == 0 ? length : bars % length
            let end = from + reached - 1
            let endCut = RecordStems.soundsAtEnd(of: end, in: stem) == true
            let loopCut = bars > length && RecordStems.soundsAtEnd(of: to - 1, in: stem) == true
            guard endCut || loopCut else { continue }
            let title = PartLabel.title(of: version)
            var sentence: String
            if endCut, reached < length {
                sentence = "\(section.name) stops \(title) at its bar \(reached) of \(length), mid-line: the voice is still going as bar \(end + 1) ends."
            } else if endCut {
                sentence = "\(section.name) ends \(title) mid-line: the voice is still going as bar \(end + 1) ends."
            } else {
                sentence = "\(title) loops mid-line in \(section.name): the voice is still going as bar \(to) ends."
            }
            if endCut, loopCut, reached < length { sentence += " It is cut at each turn of the loop too." }
            sentence += " " + restLine(rests, in: from..<(endCut ? end + 1 : to))
            out.append(Cut(part: lane.part, sentence: sentence))
        }
        return out
    }
}

extension AppState {
    /// The clips of a record's voice a section cuts off mid-line (`ClipSeams.cuts`). A record read
    /// before where its lines rest was kept is measured in the background, and the section says
    /// so once it lands.
    func clipCuts(in section: Section) -> [ClipSeams.Cut] {
        guard let song else { return [] }
        for lane in section.stitch {
            guard let fit = song.latestVersion(of: lane.part).flatMap(SourceFitting.fit(of:)), ClipSeams.says(fit.stem), fit.fromBar != nil,
                  let id = fit.record, library.record(id)?.stem(named: fit.stem)?.barHeads == nil, !measuringRests.contains(id) else { continue }
            Task { await measureRestsIfUnmeasured(.record(id)) }
        }
        return ClipSeams.cuts(in: section, song: song) { library.record($0) }
    }
}
