import Foundation
import Instrument
import SongGraph
import Testing
@testable import MrRobotoApp

/// An offline host for the Sound surface.
///
/// The whole point of `SoundSurfaceHost` being three members wide is that this is the whole of it:
/// no engine, no audio device, no file store, no `AppState`. Every test in `Sound*` runs against
/// this, which is what makes them runnable on a shell with no sound.
@MainActor
final class SoundHostStub: SoundSurfaceHost {
    var selectedPart: PartVersion?

    /// Everything the surface asked to play, in order.
    private(set) var auditions: [SoundAudition] = []

    /// Every version the surface handed over. The surface never mutates; it only ever adds here.
    private(set) var recorded: [PartVersion] = []

    /// Set false to make the host refuse a version, so the surface's "keep the draft" path is real.
    var accepts = true

    init(selectedPart: PartVersion? = nil) {
        self.selectedPart = selectedPart
    }

    func audition(_ audition: SoundAudition) { auditions.append(audition) }

    @discardableResult
    func record(_ version: PartVersion) -> Bool {
        guard accepts else { return false }
        recorded.append(version)
        return true
    }
}

enum SoundFixture {
    static let sampleRate: Double = 48_000

    /// A first version of a Sound part holding this state.
    static func version(_ state: SoundState) -> PartVersion {
        PartVersion(partID: PartID(), kind: .sound(state.sound),
                    author: .user, operation: Operation.written)
    }

    static func state(_ machine: String, _ voice: SynthVoiceKind) -> SoundState {
        SoundState(machine: machine, voice: voice)
    }

    /// A surface opened on one voice of one machine, with a clean chain.
    @MainActor
    static func surface(_ machine: String = "tr808", _ voice: SynthVoiceKind = .kick,
                        sampleRate: Double = sampleRate) -> (SoundSurface, SoundHostStub) {
        let host = SoundHostStub(selectedPart: version(state(machine, voice)))
        return (SoundSurface(host: host, sampleRate: sampleRate), host)
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { Swift.max($0, abs($1)) }
    }
}
