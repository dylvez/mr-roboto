import MusicTheory

/// `BeatGrid` and `TimeSignature` live in MusicTheory so analysis, the song graph, and the engine share one
/// definition. This file keeps the analysis-side conveniences that need `TimeRange`.
public typealias TimeSignatureGuess = TimeSignature

extension BeatGrid {
    /// The time range of bar `index`.
    public func range(ofBar index: Int) -> TimeRange? {
        bounds(ofBar: index).map { TimeRange(start: $0.start, end: $0.end) }
    }

    /// The time range of bars `first..<last` (bar indices), e.g. `range(ofBars: 8..<16)`.
    public func range(ofBars indices: Range<Int>) -> TimeRange? {
        bounds(ofBars: indices).map { TimeRange(start: $0.start, end: $0.end) }
    }
}
