# Mr. Roboto

Native Swift music-creation studio for macOS 27: a cast of AI collaborators composes, critiques, and finishes songs and albums with you. Not a DAW.

Milestones M0 through M7 are in: the foundations and the `m0` CLI, the surfaces (Record, Chop lane, Grid, Chords, Piano roll, Sound, Structure, Lyrics, Booth, Takes, Mixer, Master, Merge, Mashup, Album, Cast), the Director and the nine-member band, capture from the phone, the mix and the master, and the record with its cover. The app is `MrRobotoApp`; `make app` packages and signs it. It reopens the song you were in, saves on its own a few seconds after every change, and needs an Anthropic API key for the band, which the rail asks for.

## Install

You need:

- An Apple silicon Mac on macOS 27 (MLX and the Metal kernels do not run on Intel)
- Xcode 27 (Swift 6.4), with its command-line tools selected: `xcode-select -p` should point into Xcode
- An [Anthropic API key](https://console.anthropic.com/) for the band

Build and install:

    git clone https://github.com/dylvez/mr-roboto.git
    cd mr-roboto
    make app

The first build fetches its Swift packages (MLX, Demucs on MLX, ONNX Runtime) and takes a few minutes. `make app` builds a release, packages `Mr. Roboto.app`, signs it, and installs it to `~/Applications`. It signs with the first Apple Development identity in your keychain; without one it signs ad hoc, which works but means the keychain asks again for the API key after every rebuild. `scripts/make-app.sh --no-install` leaves the app in `.build/app/` instead.

On first launch the rail asks for your Anthropic key and keeps it in your login keychain. `ANTHROPIC_API_KEY` in the environment is used first if it is set.

### Optional: the models

The stem separator (Demucs) downloads its weights from Hugging Face the first time you separate a track, into `~/Library/Application Support/MrRoboto/models/`.

Beat This!, the second beat tracker the import checks its grid against, is not downloaded by the app. Without it the import uses Music Understanding alone. To install it you need [uv](https://docs.astral.sh/uv/):

    cd Bench/python
    uv run fetch_models.py

That downloads `beat_this.onnx` (83 MB, checked by SHA-256) and converts it to Core ML for the GPU. The conversion pulls in PyTorch and coremltools; `--no-coreml` skips it and leaves the slower ONNX Runtime path.

### Optional: sampled instruments

The built-in instruments are all synthesized. SFZ instruments (for example the [Salamander Grand](https://sfzinstruments.github.io/pianos/salamander) or [VCSL](https://github.com/sgossner/VCSL)) come in through File → Import Instrument…, and File → Import VCSL Percussion…, pointed at VCSL's `sfz` branch, gives every kit recorded hand percussion.

## Development

    make check

runs every build and test, including the MLX tests under `xcodebuild` and the `m0` CLI. Audio tests that must produce sound are run from a normal Terminal, not from an automated shell (see Bench/Corpus.md).

## License

MIT; see [LICENSE](LICENSE). Vendored code and bundled fonts and data keep their own licenses, next to them in `Sources/`.
