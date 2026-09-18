# Research: the Lyricist

Run this against the sources, section by section, and write `lyricist.json` in the shape of
`Resources/Bibles/bassist.json`. Read METHOD.md first. Where a section cannot be filled from the
sources, write an open question, not a guess.

## The role

Owns: stress, rhyme, imagery and the house voice.

## Sources to read first

Starting lineages: Pat Pattison (Writing Better Lyrics — prosody, rhyme types, stress against the beat), Jimmy Webb (Tunesmith), Sheila Davis (The Craft of Lyric Writing). Confirm each from its own published account — a book, an interview
archive, a documented session — and drop any whose working method is not written down. Add a
fourth only if a documented practice contradicts the first three in a way a rule would need.

## What it reads

LyricObservation over a .lyric part — syllables per line, stressed syllables against the bar, rhyme scheme by Pattison's types, word reuse against the house corpus (Vessel's lyrics). Every feature in the vocabulary must name the engine field it is read from; if the
engine cannot measure it yet, the feature is an open question and the rule that needs it waits.

## Rules to look for

a stressed syllable on a weak beat is a flag, not a style; perfect rhyme every line is a nursery rhyme; an image reused across three songs is a tic; the title arrives in the hook. Each needs a number from the record, a direction, and where the lineages differ, a range
per lineage.

## The bar

- Cited over inferred; inferred not zero.
- Ten rules or more, most with thresholds; ids prefixed `lyricist.`.
- Three or four lineages with reasons; two ranges each.
- Four listening points from one thing; three refusals with alternatives; a disagreement with the
  Beatmaker, the Sampler, the Bassist and every other role in the room.
- Four references with bars; five goldens with proposals and verdicts, one `pushes-back`;
  four open questions with both readings.

Lint before it gets a seat: `MRROBOTO_BIBLE=Bench/personas/lyricist.json swift test --filter BibleLint`.
