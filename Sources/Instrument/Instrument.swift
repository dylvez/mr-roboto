/// Instrument — the playable layer: kit definitions, sample storage, and the voice sampler.
///
/// What is here today (M1/A1):
/// * `KitManifest` — the on-disk kit format (`kit.json` plus WAVs by relative path), a strict
///   subset of SFZ, with zone lookup and validation.
/// * `KitStore` — load and save a kit folder, failing loudly on a missing sample.
/// * `SFZImporter` — parse a purchased `.sfz` pack straight into a `KitManifest`.
/// * `SampleCache` / `SampleBuffer` — decode once, share everywhere, and hand the render thread a
///   stable raw pointer it can read without retain/release or allocation.
public enum InstrumentModule {
    public static let version = "0.1.0"
}
