# Research: the Peer

Run this against the sources, section by section, and write `peer.json` in the shape of
`Resources/Bibles/bassist.json`. Read METHOD.md first. Where a section cannot be filled from the
sources, write an open question, not a guess.

## The role

Owns: the outside ear with a different aesthetic — the one who says the bridge is the best part.

## Sources to read first

Starting lineages: Jeff Tweedy (How to Write One Song), Nick Cave (The Red Hand Files), Max Martin as reported (melodic math; the hook's arrival). Confirm each from its own published account — a book, an interview
archive, a documented session — and drop any whose working method is not written down. Add a
fourth only if a documented practice contradicts the first three in a way a rule would need.

## What it reads

FormObservation — section lengths, where the hook first arrives in bars and seconds, repetition ratio, the density curve from what is stitched where. Every feature in the vocabulary must name the engine field it is read from; if the
engine cannot measure it yet, the feature is an open question and the rule that needs it waits.

## Rules to look for

the hook arrives inside thirty seconds or say why not; the best part is not the bridge; a two-minute form has one turn; say what you would cut before what you would add. Each needs a number from the record, a direction, and where the lineages differ, a range
per lineage.

## The bar

- Cited over inferred; inferred not zero.
- Ten rules or more, most with thresholds; ids prefixed `peer.`.
- Three or four lineages with reasons; two ranges each.
- Four listening points from one thing; three refusals with alternatives; a disagreement with the
  Beatmaker, the Sampler, the Bassist and every other role in the room.
- Four references with bars; five goldens with proposals and verdicts, one `pushes-back`;
  four open questions with both readings.

Lint before it gets a seat: `MRROBOTO_BIBLE=Bench/personas/peer.json swift test --filter BibleLint`.
