# Persona evals

Written by `make evals` on 2026-09-19T01:32:13Z. Goldens run through `GoldenRunner`, disagreements through `DisagreementRunner`, blind sheets through `BlindRunner` (`Bench/personas/blind/`).

| Eval | Passed | Of |
|---|---:|---:|
| Goldens | 46 | 46 |
| Disagreements | 43 | 43 |
| Blind | 16 | 16 |

## Beatmaker

### Goldens (8/8 executable, 0 prose-only)

- ✔ beatmaker.golden.dilla-direction: expected agree with a caveat, got agree with a caveat
- ✔ beatmaker.golden.default-swing: expected agree, got agree
- ✔ beatmaker.golden.sub-perceptual: expected refuse by beatmaker.below-perception, got refuse by beatmaker.below-perception
- ✔ beatmaker.golden.thirty-second-grid: expected refuse by beatmaker.swing-domain, got refuse by beatmaker.swing-domain
- ✔ beatmaker.golden.machine-reach: expected refuse by beatmaker.machine-reach, got refuse by beatmaker.machine-reach
- ✔ beatmaker.golden.tempo-independence: expected agree, got agree
- ✔ beatmaker.golden.pushes-back: expected refuse by beatmaker.hard-quantise-kills-it, got refuse by beatmaker.hard-quantise-kills-it
- ✔ beatmaker.golden.defers: expected defer to the sampler, got defer to the sampler

### Disagreements (6/6)

- ✔ beatmaker ↔ producer: whether a groove that is right by the pocket's numbers is right for the song — defer to the producer vs refuse by producer.fewer-parts
- ✔ beatmaker ↔ engineer: whether the drums should be squashed to sit in the mix — defer to the engineer vs refuse by engineer.drums-keep-their-crest
- ✔ beatmaker ↔ peer: whether the groove should change when the section does — defer to the peer vs refuse by peer.hook-inside-thirty
- ✔ beatmaker ↔ lyricist: whether a stressed syllable on a swung offbeat is a problem — defer to the lyricist vs refuse by lyricist.lines-share-a-shape
- ✔ beatmaker ↔ sampler: whether the swing lives in the grid or in the audio — agree vs defer to the beatmaker
- ✔ beatmaker ↔ bassist: who the downbeat is measured against — agree vs defer to the beatmaker

### Blind (8/8 items, 23/23 readings)

- ✔ feel-1 (Neo-Soul Pocket) — 5/5
- ✔ feel-2 (Boom-Bap Pocket) — 3/3
- ✔ feel-3 (Trap Rolling Hats) — 3/3
- ✔ feel-4 (Four on the Floor) — 2/2
- ✔ feel-5 (Lo-Fi Hip-Hop) — 3/3
- ✔ feel-6 (Trip-Hop) — 3/3
- ✔ feel-7 (Lo-Fi House) — 2/2
- ✔ feel-8 (Breakbeat (Amen)) — 2/2

## Sampler

### Goldens (9/9 executable, 1 prose-only)

- ✔ sampler.golden.late-cut: expected refuse by sampler.cut-before-not-after, got refuse by sampler.cut-before-not-after
- ✔ sampler.golden.corner-above-source: expected refuse by sampler.corner-above-the-source, got refuse by sampler.corner-above-the-source
- ✔ sampler.golden.no-stacking: expected refuse by sampler.one-effect, got refuse by sampler.one-effect
- ✔ sampler.golden.eight-pads: expected refuse by sampler.fewer-than-the-detector-wants, got refuse by sampler.fewer-than-the-detector-wants
- ✔ sampler.golden.leave-it-alone: expected agree, got agree
- ✔ sampler.golden.pushes-back: expected refuse by sampler.one-effect, got refuse by sampler.one-effect
- ✔ sampler.golden.defers: expected defer to the beatmaker, got defer to the beatmaker
- ✔ sampler.golden.too-far-transposed: expected refuse by sampler.past-four-semitones, got refuse by sampler.past-four-semitones
- ✔ sampler.golden.two-drum-sources: expected refuse by sampler.one-drum-source, got refuse by sampler.one-drum-source

### Disagreements (6/6)

- ✔ sampler ↔ producer: whether a second source belongs in the song — refuse by sampler.one-drum-source vs defer to the sampler
- ✔ sampler ↔ engineer: whether the chain's bandwidth is a fault — agree vs defer to the sampler
- ✔ sampler ↔ peer: whether the break should vary across the form — defer to the peer vs refuse by peer.form-turns
- ✔ sampler ↔ lyricist: whether a vocal sample counts as a lyric — defer to the lyricist vs refuse by lyricist.image-is-a-tic
- ✔ sampler ↔ beatmaker: whether the swing lives in the grid or in the audio — defer to the beatmaker vs agree
- ✔ sampler ↔ bassist: pitching a source down — refuse by sampler.past-four-semitones vs defer to the sampler

## Bassist

### Goldens (4/4 executable, 1 prose-only)

- ✔ bassist.g1.voodoo-lag: expected agree, got agree
- ✔ bassist.g2.lagging-drummer-pushes-back: expected refuse by bassist.straight-reference, got refuse by bassist.straight-reference
- ✔ bassist.g3.808-ownership: expected refuse by bassist.808-is-the-bass, got refuse by bassist.808-is-the-bass
- ✔ bassist.g4.thundercat-harmony: expected agree, got agree

### Disagreements (7/7)

- ✔ bassist ↔ producer: whether the bass line is a part or the song's floor — defer to the producer vs agree
- ✔ bassist ↔ engineer: who owns 80 Hz — defer to the engineer vs refuse by engineer.who-owns-eighty
- ✔ bassist ↔ peer: whether the bass should change at the hook — defer to the peer vs agree
- ✔ bassist ↔ lyricist: whether the bass should leave room under the vocal — defer to the lyricist vs refuse by lyricist.a-line-is-a-breath
- ✔ bassist ↔ beatmaker: who moves — defer to the beatmaker vs agree
- ✔ bassist ↔ beatmaker: a busier kick — defer to the beatmaker vs refuse by beatmaker.hard-quantise-kills-it
- ✔ bassist ↔ sampler: retuning a sampled bass — defer to the sampler vs refuse by sampler.past-four-semitones

### Blind (8/8 items, 21/21 readings)

- ✔ line-1 (Palladino, 40 ms, neo-soul at 92) — 5/5
- ✔ line-2 (Palladino, 65 ms, the edge of the window) — 2/2
- ✔ line-3 (Palladino, 10 ms, under the window) — 2/2
- ✔ line-4 (Thundercat, on the kick at 130) — 3/3
- ✔ line-5 (Thundercat, 40 ms, boom-bap at 96) — 2/2
- ✔ line-6 (Programmed 808 on the kick, trap at 140) — 3/3
- ✔ line-7 (Programmed sub 30 ms off the kick) — 2/2
- ✔ line-8 (Palladino ahead of the kick) — 2/2

## Producer

### Goldens (6/6 executable, 0 prose-only)

- ✔ producer.golden.too-many-parts: expected refuse by producer.fewer-parts, got refuse by producer.fewer-parts
- ✔ producer.golden.orphan: expected refuse by producer.no-orphans, got refuse by producer.no-orphans
- ✔ producer.golden.room-to-add: expected agree, got agree
- ✔ producer.golden.pushes-back: expected refuse by producer.reference-has-bars, got refuse by producer.reference-has-bars
- ✔ producer.golden.reference-with-bars: expected agree, got agree
- ✔ producer.golden.defers: expected defer to the beatmaker, got defer to the beatmaker

### Disagreements (6/6)

- ✔ producer ↔ beatmaker: whether a groove that is right by the pocket's numbers is right for the song — refuse by producer.fewer-parts vs defer to the producer
- ✔ producer ↔ sampler: whether a second source belongs in the song — defer to the sampler vs refuse by sampler.one-drum-source
- ✔ producer ↔ bassist: whether the bass line is a part or the song's floor — agree vs defer to the producer
- ✔ producer ↔ engineer: whether loudness is a decision or a delivery spec — defer to the engineer vs refuse by engineer.delivery-loudness
- ✔ producer ↔ peer: whether the outside ear outranks the brief — refuse by producer.reference-has-bars vs defer to the producer
- ✔ producer ↔ lyricist: whether the words serve the brief or the brief serves the words — defer to the lyricist vs refuse by lyricist.not-a-nursery-rhyme

## Engineer

### Goldens (6/6 executable, 0 prose-only)

- ✔ engineer.golden.hot-master: expected refuse by engineer.delivery-loudness, got refuse by engineer.delivery-loudness
- ✔ engineer.golden.delivery: expected agree, got agree
- ✔ engineer.golden.pushes-back: expected refuse by engineer.drums-keep-their-crest, got refuse by engineer.drums-keep-their-crest
- ✔ engineer.golden.crest-kept: expected agree, got agree
- ✔ engineer.golden.fighting-low-end: expected refuse by engineer.who-owns-eighty, got refuse by engineer.who-owns-eighty
- ✔ engineer.golden.defers: expected defer to the bassist, got defer to the bassist

### Disagreements (6/6)

- ✔ engineer ↔ beatmaker: whether the drums should be squashed to sit in the mix — refuse by engineer.drums-keep-their-crest vs defer to the engineer
- ✔ engineer ↔ sampler: whether the chain's bandwidth is a fault — defer to the sampler vs agree
- ✔ engineer ↔ bassist: who owns 80 Hz — refuse by engineer.who-owns-eighty vs defer to the engineer
- ✔ engineer ↔ producer: whether loudness is a decision or a delivery spec — refuse by engineer.delivery-loudness vs defer to the engineer
- ✔ engineer ↔ peer: whether a lift is a layer or a level — agree vs defer to the engineer
- ✔ engineer ↔ lyricist: whether the vocal should be loud enough to read — agree vs defer to the engineer

## Peer

### Goldens (6/6 executable, 0 prose-only)

- ✔ peer.golden.late-hook: expected refuse by peer.hook-inside-thirty, got refuse by peer.hook-inside-thirty
- ✔ peer.golden.early-hook: expected agree, got agree
- ✔ peer.golden.pushes-back: expected refuse by peer.form-turns, got refuse by peer.form-turns
- ✔ peer.golden.turning-form: expected agree, got agree
- ✔ peer.golden.churning-form: expected refuse by peer.not-too-many-sections, got refuse by peer.not-too-many-sections
- ✔ peer.golden.defers: expected defer to the sampler, got defer to the sampler

### Disagreements (6/6)

- ✔ peer ↔ beatmaker: whether the groove should change when the section does — refuse by peer.hook-inside-thirty vs defer to the peer
- ✔ peer ↔ sampler: whether the break should vary across the form — refuse by peer.form-turns vs defer to the peer
- ✔ peer ↔ bassist: whether the bass should change at the hook — agree vs defer to the peer
- ✔ peer ↔ producer: whether the outside ear outranks the brief — defer to the producer vs refuse by producer.reference-has-bars
- ✔ peer ↔ engineer: whether a lift is a layer or a level — defer to the engineer vs agree
- ✔ peer ↔ lyricist: whether the hook is the words or the section — agree with a caveat vs defer to the peer

## Lyricist

### Goldens (7/7 executable, 0 prose-only)

- ✔ lyricist.golden.shape-mismatch: expected refuse by lyricist.lines-share-a-shape, got refuse by lyricist.lines-share-a-shape
- ✔ lyricist.golden.shape-holds: expected agree, got agree
- ✔ lyricist.golden.pushes-back: expected refuse by lyricist.not-a-nursery-rhyme, got refuse by lyricist.not-a-nursery-rhyme
- ✔ lyricist.golden.loose-rhyme: expected agree, got agree
- ✔ lyricist.golden.tic: expected refuse by lyricist.image-is-a-tic, got refuse by lyricist.image-is-a-tic
- ✔ lyricist.golden.long-line: expected refuse by lyricist.a-line-is-a-breath, got refuse by lyricist.a-line-is-a-breath
- ✔ lyricist.golden.defers: expected defer to the bassist, got defer to the bassist

### Disagreements (6/6)

- ✔ lyricist ↔ beatmaker: whether a stressed syllable on a swung offbeat is a problem — refuse by lyricist.lines-share-a-shape vs defer to the lyricist
- ✔ lyricist ↔ sampler: whether a vocal sample counts as a lyric — refuse by lyricist.image-is-a-tic vs defer to the lyricist
- ✔ lyricist ↔ bassist: whether the bass should leave room under the vocal — refuse by lyricist.a-line-is-a-breath vs defer to the lyricist
- ✔ lyricist ↔ producer: whether the words serve the brief or the brief serves the words — refuse by lyricist.not-a-nursery-rhyme vs defer to the lyricist
- ✔ lyricist ↔ engineer: whether the vocal should be loud enough to read — defer to the engineer vs agree
- ✔ lyricist ↔ peer: whether the hook is the words or the section — agree vs defer to the lyricist

