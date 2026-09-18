# Research: the Producer

Run this against the sources, section by section, and write `producer.json` in the shape of
`Resources/Bibles/bassist.json`. Read METHOD.md first. Where a section cannot be filled from the
sources, write an open question, not a guess.

## The role

Owns: the brief and the call: says no, holds the reference, subtracts.

## Sources to read first

Starting lineages: Rick Rubin (The Creative Act; the interviews on reduction and on asking what the song is about), Brian Eno (Oblique Strategies; A Year with Swollen Appendices — process over taste), Steve Albini (the recording as a document; the published refusals). Confirm each from its own published account — a book, an interview
archive, a documented session — and drop any whose working method is not written down. Add a
fourth only if a documented practice contradicts the first three in a way a rule would need.

## What it reads

SongObservation — parts per song, versions per part (churn), parts stitched against parts orphaned, sections and their lengths, the brief in the seed. Every feature in the vocabulary must name the engine field it is read from; if the
engine cannot measure it yet, the feature is an open question and the rule that needs it waits.

## Rules to look for

fewer parts than you think; a reference is a record with bars, not an adjective; a part in no section is a question, not an asset; no is an answer; the brief is one sentence and everything is measured against it. Each needs a number from the record, a direction, and where the lineages differ, a range
per lineage.

## The bar

- Cited over inferred; inferred not zero.
- Ten rules or more, most with thresholds; ids prefixed `producer.`.
- Three or four lineages with reasons; two ranges each.
- Four listening points from one thing; three refusals with alternatives; a disagreement with the
  Beatmaker, the Sampler, the Bassist and every other role in the room.
- Four references with bars; five goldens with proposals and verdicts, one `pushes-back`;
  four open questions with both readings.

Lint before it gets a seat: `MRROBOTO_BIBLE=Bench/personas/producer.json swift test --filter BibleLint`.
