# Mr. Roboto

Native Swift music-creation studio for macOS 27: a cast of AI collaborators composes, critiques, and finishes songs and albums with you. Not a DAW.

Milestones M0 through M7 are in: the foundations and the `m0` CLI, the surfaces (Record, Chop lane, Grid, Chords, Piano roll, Sound, Structure, Lyrics, Booth, Takes, Mixer, Master, Merge, Mashup, Album, Cast), the Director and the nine-member band, capture from the phone, the mix and the master, and the record with its cover. The app is `MrRobotoApp`; `make app` packages and signs it. It reopens the song you were in, saves on its own a few seconds after every change, and needs an Anthropic API key for the band, which the rail asks for.

    make check

Audio tests that must produce sound are run from a normal Terminal, not from an automated shell (see Bench/Corpus.md).
