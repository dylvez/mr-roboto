import Instrument
import Testing

@testable import MrRobotoApp

// The art is optional at runtime — a missing file draws nothing — which is exactly why a test has to
// say which files the app expects: otherwise a renamed PNG would vanish from the screen silently.

@Suite("Art") @MainActor
struct ArtTests {

    static let used = ["cast-director", "cast-beatmaker", "cast-sampler", "cast-critic", "cast-you",
                       "empty-first-launch", "empty-library", "empty-drop-record", "wait-separating", "wait-band"]

    @Test("every illustration the frame names is bundled")
    func bundled() {
        for name in Self.used { #expect(Art.image(name) != nil, "\(name).png is missing from Resources/Art") }
        // `clean` is the dry setting, not a machine; it stays a plain chip.
        for preset in DegradeSettings.Preset.allCases where preset != .clean {
            #expect(Art.image(Art.machine(preset.rawValue)) != nil, "no machine card for \(preset.rawValue)")
        }
    }

    @Test("a missing file is nil, not a crash")
    func missing() { #expect(Art.image("no-such-art") == nil) }

    @Test("each band member gets their own emblem; the app's own lines get none")
    func emblems() {
        #expect(Art.emblem(for: SessionEntry.Source.director) == "cast-director")
        #expect(Art.emblem(for: SessionEntry.Source.you) == "cast-you")
        #expect(Art.emblem(for: SessionEntry.Source.session) == nil)
        #expect(Art.emblem(for: SessionEntry.Source.persona("Beatmaker")) == "cast-beatmaker")
        #expect(Art.emblem(for: SessionEntry.Source.persona("Sampler")) == "cast-sampler")
        #expect(Art.emblem(for: SessionEntry.Source.persona("Cass")) == nil)
        #expect(Art.emblem(for: Proposal.Source.session) == nil)
    }
}
