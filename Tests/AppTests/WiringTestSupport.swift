import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// What the wiring tests share.
//
// Two rules hold across all of them. First, a *real* `AppState` on a *real* (temporary) library
// directory: the whole point of the adapters is that they meet the frame as it actually is, so a
// double for `AppState` would test nothing. Second, no audio device — this shell has none. Anything
// that would make a sound is either handed an engine provider that refuses (the adapter tests,
// which care about the graph edges, not the sound) or driven through the engine's offline
// manual-rendering mode (`WiringAuditionTests`).

enum WiringFixture {

    /// A temporary library directory. Removed by `remove(_:)`; a leftover is a temp file, not a bug.
    static func temporaryDirectory(_ label: String = "wiring") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrRoboto-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A song with one melody in it, so the ledger is not empty before the test does anything.
    static func song(title: String = "Arrival") -> Song {
        var song = Song(title: title, artist: "Vessel", tempo: 96)
        try? song.append(PartVersion(partID: PartID(), kind: .melody(Melody(notes: [])),
                                     author: .user, operation: Operation.hummed, note: "8 bars"))
        return song
    }

    /// A real `AppState` over a temp library, with audio that never reaches a device.
    @MainActor
    static func app(in directory: URL, song: Song? = WiringFixture.song()) -> AppState {
        AppState(library: Library(), song: song,
                 store: LibraryStore(directoryURL: directory),
                 transportHost: StubTransportHost())
    }

    /// An audition service whose engine never arrives. Every audition path through it therefore
    /// records a failure and makes no sound, which is exactly what a machine with no output device
    /// does — and it means an adapter test asserts the wiring, never the audio.
    static func silentService() -> AuditionService {
        AuditionService(engine: { throw NoAudioDevice() },
                        kitsDirectory: temporaryDirectory("kits"))
    }

    // MARK: Part versions the adapters hand over

    @MainActor
    static func groove() -> PartVersion {
        PartVersion(partID: PartID(), kind: .groove(GridModel.emptyGroove()),
                    author: .user, operation: Operation.written, note: "empty, 96 bpm")
    }

    @MainActor
    static func sound() -> PartVersion {
        PartVersion(partID: PartID(), kind: .sound(SoundState().sound),
                    author: .user, operation: Operation.written, note: "tr808 kick")
    }

    /// A promoted region: what `ImportModel.promote` hands its host, with the downbeats it cut on.
    static func promotedBar(downbeats: [Double] = [8, 10.5, 13], tempo: Double = 96) -> PartVersion {
        let sample = Sample(media: media, slices: downbeats.map { SliceMarker(position: $0) },
                            detectedTempo: tempo)
        return PartVersion(partID: PartID(), kind: .sample(sample), author: .user,
                           operation: Operation.chop, note: "Bar 5 of Arrival")
    }

    static var media: MediaRef {
        MediaRef(hash: ContentHash(hex: String(repeating: "b", count: 64))!, fileExtension: "wav")
    }

    // MARK: Signals

    /// A short cosine burst, loud enough that "did anything come out" is not a judgement call.
    static func tone(frequency: Double = 440, seconds: Double = 0.25, sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            let envelope = min(1, t * 200) * exp(-t * 4)
            return Float(cos(2 * .pi * frequency * t) * envelope * 0.5)
        }
    }

    /// One channel of a rendered buffer, as plain floats.
    static func channel(_ buffer: AVAudioPCMBuffer, _ index: Int = 0) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.format.channelCount > AVAudioChannelCount(index) else {
            return []
        }
        let stride = buffer.stride
        return (0..<Int(buffer.frameLength)).map { data[index][$0 * stride] }
    }

    static func peak(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> Float {
        guard let data = buffer.floatChannelData, buffer.format.channelCount > AVAudioChannelCount(channel) else {
            return 0
        }
        let stride = buffer.stride
        return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(data[channel][$1 * stride])) }
    }
}
