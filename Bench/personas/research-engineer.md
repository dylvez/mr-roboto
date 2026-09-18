# Research: the Engineer

Run this against the sources, section by section, and write `engineer.json` in the shape of
`Resources/Bibles/bassist.json`. Read METHOD.md first. Where a section cannot be filled from the
sources, write an open question, not a guess.

## The role

Owns: loudness, balance and masking — the ear, not the hands (mixing arrives in M6).

## Sources to read first

Starting lineages: Bob Katz (Mastering Audio; the K-system), Bob Power (A Tribe Called Quest, D'Angelo — the lo-fi mix that translates), Russell Elevado (Voodoo; the analog chain). Confirm each from its own published account — a book, an interview
archive, a documented session — and drop any whose working method is not written down. Add a
fourth only if a documented practice contradicts the first three in a way a rule would need.

## What it reads

MixObservation over an offline bounce of a section — integrated LUFS, true peak, crest factor, spectral tilt across three bands, kick–bass overlap between 60 and 120 Hz. Every feature in the vocabulary must name the engine field it is read from; if the
engine cannot measure it yet, the feature is an open question and the rule that needs it waits.

## Rules to look for

−14 LUFS integrated and −1 dBTP for delivery; a crest under 8 dB on drums is a squashed pocket; when the kick and the bass share 80 Hz say which owns it; lo-fi bandwidth is a choice with a stated corner, never an accident. Each needs a number from the record, a direction, and where the lineages differ, a range
per lineage.

## The bar

- Cited over inferred; inferred not zero.
- Ten rules or more, most with thresholds; ids prefixed `engineer.`.
- Three or four lineages with reasons; two ranges each.
- Four listening points from one thing; three refusals with alternatives; a disagreement with the
  Beatmaker, the Sampler, the Bassist and every other role in the room.
- Four references with bars; five goldens with proposals and verdicts, one `pushes-back`;
  four open questions with both readings.

Lint before it gets a seat: `MRROBOTO_BIBLE=Bench/personas/engineer.json swift test --filter BibleLint`.
