# Mr. Roboto

Native Swift music-creation studio for macOS 27: a cast of AI collaborators composes, critiques, and finishes songs and albums with you. Not a DAW.

M0 (foundations) is the current milestone. Done when `m0 analyze`, `m0 separate`, `m0 loop`, and `m0 bounce` work on the test corpus and the parity suite passes.

    make check

Audio tests that must produce sound are run from a normal Terminal, not from an automated shell (see Bench/Corpus.md).
