import Foundation
import Instrument
import SongGraph
import Testing
@testable import MrRobotoApp

/// An offline host for a Shape popover's model.
///
/// The whole point of `SoundShapingHost` being three members wide is that this is the whole of it:
/// no engine, no audio device, no file store, no `AppState`. Every test in `SoundShaping*` runs
/// against this, which is what makes them runnable on a shell with no sound.
@MainActor
final class SoundShapingStub: SoundShapingHost {
    /// What the song has kept of each voice, by machine and voice: what a voice opens at.
    var kept: [PartVersion] = []

    /// Everything the shaping asked to play, in order.
    private(set) var auditions: [SoundAudition] = []

    /// Every version the shaping handed over. The shaping never mutates; it only ever adds here.
    private(set) var recorded: [PartVersion] = []

    /// Set false to make the host refuse a version, so the "keep the draft" path is real.
    var accepts = true

    var songMachine: String?

    init(kept: [PartVersion] = []) {
        self.kept = kept
    }

    func audition(_ audition: SoundAudition) { auditions.append(audition) }

    @discardableResult
    func record(_ version: PartVersion) -> Bool {
        guard accepts else { return false }
        recorded.append(version)
        kept.append(version)
        return true
    }

    func keptVoice(_ voice: SynthVoiceKind, on machine: String) -> PartVersion? {
        kept.last { SoundState($0).map { $0.machine == machine && $0.voice == voice } ?? false }
    }

    func newest(of part: PartID) -> PartVersion? { kept.last { $0.partID == part } }
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

    /// A shaping opened on one voice of one machine, with a clean chain, the voice kept once
    /// already at the machine preset's own positions.
    @MainActor
    static func shaping(_ machine: String = "tr808", _ voice: SynthVoiceKind = .kick,
                        sampleRate: Double = sampleRate) -> (SoundShaping, SoundShapingStub) {
        let host = SoundShapingStub(kept: [version(state(machine, voice))])
        return (SoundShaping(host: host, voice: voice, machine: machine, sampleRate: sampleRate), host)
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { Swift.max($0, abs($1)) }
    }
}
