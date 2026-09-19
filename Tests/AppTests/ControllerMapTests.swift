import AudioEngine
import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// Inputs I7: a knob moves a fader; a stream of changes is one version; Learn rebinds and remembers.

private struct NoDevice: Error {}

@Suite("Controller map: knobs on the faders", .serialized) @MainActor
struct ControllerMapTests {

    @Test("the standard map, learning, and the value scales")
    func map() throws {
        var map = ControllerMap.standard
        #expect(map.target(of: 14) == .strip(0) && map.target(of: 21) == .strip(7) && map.target(of: 22) == .master && map.target(of: 74) == nil)
        map.learn(controller: 74, target: .strip(1))
        #expect(map.target(of: 74) == .strip(1) && map.target(of: 15) == nil, "the old control is unbound")
        #expect(map.controller(for: .strip(1)) == 74)
        #expect(ControllerMap.gainDB(for: 0) == -60 && ControllerMap.gainDB(for: 127) == 12)
        #expect(abs(ControllerMap.gainDB(for: 106) - 0.094) < 0.01, "unity near 106")
        #expect(ControllerMap.masterGainDB(for: 0) == -24 && abs(ControllerMap.masterGainDB(for: 64) - 0.19) < 0.01)

        let suite = "map-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ControllerMapSettings(defaults: defaults).map == .standard)
        ControllerMapSettings(defaults: defaults).map = map
        #expect(ControllerMapSettings(defaults: defaults).map == map)
    }

    /// The knob's stillness is 30 ms here; under a loaded test run the commit can land later, so
    /// the test waits for it rather than for a fixed time.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("a stream of CC 14 is one mix version at the final value; Learn binds CC 74 to the bass and a new control remembers it")
    func knobs() async throws {
        let directory = WiringFixture.temporaryDirectory("knobs")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory, song: FormFixture.build(tempo: 92).song)
        app.refreshPlayback()
        let suite = "knobs-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let kits = WiringFixture.temporaryDirectory("knob-kits")
        defer { WiringFixture.remove(kits) }
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: kits)
        let control = MIDIControl(app: app, service: service, defaults: defaults)
        let mixer = MixerModel(host: MixAdapter(app: app))
        control.mixer = { mixer }
        control.stillness = .milliseconds(30)
        #expect(mixer.rows.count >= 2, "\(mixer.rows.map(\.label))")
        let groove = mixer.rows[0].part, bass = mixer.rows[1].part

        let before = Guidance.mixes(in: app.song!).count
        for value in [10, 50, 100] {
            control.handle(MIDIEvent(kind: .controlChange(controller: 14, value: value), channel: 0, hostTime: 1, source: "Launchkey"))
        }
        #expect(control.lastControl?.target == .strip(0))
        #expect(abs(mixer.strip(groove).gainDB - ControllerMap.gainDB(for: 100)) < 1e-9, "live while the knob moves")
        #expect(Guidance.mixes(in: app.song!).count == before, "no version while it moves")
        await settle { Guidance.mixes(in: app.song!).count == before + 1 }
        let mixes = Guidance.mixes(in: app.song!)
        #expect(mixes.count == before + 1, "one version for the gesture")
        if case .mix(let mix) = mixes.last!.kind { #expect(abs(mix.strip(for: groove, label: "").gainDB - ControllerMap.gainDB(for: 100)) < 1e-9) }

        // Learn: the next control moved is the bass fader's.
        control.learn(.strip(1))
        #expect(control.learning == .strip(1))
        control.handle(MIDIEvent(kind: .controlChange(controller: 74, value: 64), channel: 0, hostTime: 2, source: "Launchkey"))
        #expect(control.learning == nil && control.map.target(of: 74) == .strip(1))
        #expect(abs(mixer.strip(bass).gainDB - ControllerMap.gainDB(for: 64)) < 1e-9, "the learning move already moves it")
        #expect(MIDIControl(app: app, service: service, defaults: defaults).map.target(of: 74) == .strip(1), "remembered")

        // The master.
        control.handle(MIDIEvent(kind: .controlChange(controller: 22, value: 127), channel: 0, hostTime: 3, source: "Launchkey"))
        #expect(mixer.mix.master.gainDB == 24)
        // A control bound to nothing moves nothing.
        control.handle(MIDIEvent(kind: .controlChange(controller: 99, value: 0), channel: 0, hostTime: 4, source: "Launchkey"))
        #expect(mixer.mix.master.gainDB == 24)
        await settle { Guidance.mixes(in: app.song!).count == before + 2 }
        #expect(Guidance.mixes(in: app.song!).count == before + 2, "the learn move and the master together were one gesture")
    }
}
