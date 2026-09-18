import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// What the Gate B wiring tests share.
//
// The same two rules the Gate A wiring tests hold to: a *real* `AppState` over a temporary library,
// because the whole point of an adapter is that it meets the frame as it actually is; and no audio
// device anywhere, so anything that would make a sound is either handed an engine provider that
// refuses or driven through the engine's offline manual-rendering mode.
//
// A third rule is this gate's own: **nothing here needs a key and nothing here reaches the
// network.** The cast and the critics are pure functions, the reader is a parser, and the one test
// that exercises the Director's audition drives the rig directly rather than through a model.

enum BandFixture {

    // MARK: A song with something to compare

    /// A song holding a take, a chopped bar and three real grooves off the feel library.
    ///
    /// Real feels rather than hand-written patterns: the readings a derived Compare prints come out
    /// of `GrooveObservation`, and two grooves that differ only because a test made them differ
    /// would prove nothing about whether the surface can tell them apart.
    @MainActor
    static func song(title: String = "Arrival") -> Song {
        var song = Song(title: title, artist: "Vessel", tempo: 90)
        try? song.append(take())
        try? song.append(chop())
        for version in grooves() { try? song.append(version) }
        return song
    }

    static func take() -> PartVersion {
        let audio = Audio(media: media, role: .take, sampleRate: 44_100, channelCount: 2, duration: 180)
        return PartVersion(partID: PartID(), kind: .audio(audio), author: .user,
                           operation: Operation.imported, note: "the record, as imported")
    }

    static func chop(downbeats: [Double] = [8, 8.7, 9.4, 10.1]) -> PartVersion {
        let sample = Sample(media: media, slices: downbeats.map { SliceMarker(position: $0) },
                            detectedTempo: 90)
        return PartVersion(partID: PartID(), kind: .sample(sample), author: .user,
                           operation: Operation.chop, note: "Bar 9 of the drums")
    }

    /// Three grooves from three different feels, so the columns actually differ.
    static func grooves() -> [PartVersion] {
        feelNames.enumerated().map { index, name in
            let groove = FeelLibrary.standard.feel(named: name)?.groove ?? Groove(patterns: [])
            return PartVersion(partID: PartID(), kind: .groove(groove),
                               author: index == 0 ? .user : .persona("Beatmaker"),
                               operation: Operation.regroove, note: "\(name), slower")
        }
    }

    /// Three feels the shipped library actually has, whatever it is called this week.
    static var feelNames: [String] {
        let library = FeelLibrary.standard
        return Array(library.feels.map(\.name).prefix(3))
    }

    static var media: MediaRef {
        MediaRef(hash: ContentHash(hex: String(repeating: "c", count: 64))!, fileExtension: "wav")
    }

    // MARK: The frame

    @MainActor
    static func app(in directory: URL, song: Song? = nil) -> AppState {
        AppState(library: Library(), song: song ?? BandFixture.song(),
                 store: LibraryStore(directoryURL: directory),
                 transportHost: StubTransportHost())
    }

    @MainActor
    static func item(_ kind: SurfaceKind, in app: AppState, title: String = "Answer",
                     bound: [VersionID] = []) -> BenchItem {
        let id = app.openSurface(kind, title: title, bound: bound)
        return app.bench.items.first { $0.id == id } ?? BenchItem(id: id, kind: kind, title: title)
    }

    // MARK: A real finding

    /// A cut snapped 9 ms past its transient, out of the shipped critic rather than hand-written.
    static func lateCut(shave: Double = 0.009) -> Finding {
        let rate: Double = 48_000
        let slices = [
            Slice(index: 0, start: 0, end: Int(0.5 * rate), sampleRate: rate,
                  origin: .onset, peak: 0.8, rms: 0.3),
            Slice(index: 1, start: Int(0.5 * rate), end: Int(1.0 * rate), sampleRate: rate,
                  origin: .snapped, peak: 0.7, rms: 0.28, snapOffset: shave),
        ]
        let chop = Chop(slices: slices, sampleRate: rate, sourceFrameCount: Int(rate), detectedTempo: 90)
        return TransientCutCritic().review(ChopReview(label: "Bar 9 of Arrival", chop: chop))[0]
    }
}
