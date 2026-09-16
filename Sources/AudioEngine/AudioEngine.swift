import MusicTheory
/// AudioEngine — the playback graph for M0.
///
/// Everything that touches `AVAudioEngine` lives on the `AudioActor` global actor so
/// the same graph can be driven from the UI (via `await`) or from an offline render loop
/// without data races. The main types are:
///
/// - `Engine`: owns the `AVAudioEngine`, main mixer, sampler and player nodes, and the
///   `Transport` that maps musical time onto the render timeline in both realtime and
///   manual-rendering (offline) mode.
/// - `TransportClock` / `BeatGrid`: musical time. A clock is tempo + time signature +
///   optional host-time anchor; a grid is an explicit list of beat and bar times in
///   seconds (the shape Music Understanding results will take).
/// - `Metronome`, `LoopPlayer`, `SamplerKit`: `ScheduledSource`s that schedule audio /
///   MIDI ahead of the transport, driven by a look-ahead timer in realtime or by the
///   render loop when offline.
/// - `OfflineRenderer`: renders the scheduled graph to a WAV file or a buffer.
public enum AudioEngineModule {
    public static let version = "0.0.1"
}

/// The global actor that owns every AVFAudio object in this module.
///
/// `AVAudioEngine` is not thread-safe; serialising all access through one actor keeps the
/// graph, scheduling and rendering consistent without taking locks in Swift 6.
@globalActor
public actor AudioActor {
    public static let shared = AudioActor()
}
