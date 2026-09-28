# Persona evals

Written by `make evals` on 2026-09-28T20:18:54Z. Goldens run through `GoldenRunner`, disagreements through `DisagreementRunner`, blind sheets through `BlindRunner` (`Bench/personas/blind/`).

| Eval | Passed | Of |
|---|---:|---:|
| Goldens | 71 | 71 |
| Disagreements | 73 | 73 |
| Blind | 87 | 87 |

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

### Disagreements (8/8)

- ✔ beatmaker ↔ producer: whether a groove that is right by the pocket's numbers is right for the song — defer to the producer vs refuse by producer.fewer-parts
- ✔ beatmaker ↔ engineer: whether the drums should be squashed to sit in the mix — defer to the engineer vs refuse by engineer.drums-keep-their-crest
- ✔ beatmaker ↔ peer: whether the groove should change when the section does — defer to the peer vs refuse by peer.hook-inside-thirty
- ✔ beatmaker ↔ lyricist: whether a stressed syllable on a swung offbeat is a problem — defer to the lyricist vs refuse by lyricist.lines-share-a-shape
- ✔ beatmaker ↔ sampler: whether the swing lives in the grid or in the audio — agree vs defer to the beatmaker
- ✔ beatmaker ↔ bassist: who the downbeat is measured against — agree vs defer to the beatmaker
- ✔ beatmaker ↔ harmonist: whether a chord may change off the grid — defer to the harmonist vs refuse by harmonist.harmonic-rhythm
- ✔ beatmaker ↔ melodist: whether a tune may sit off the grid — defer to the melodist vs refuse by melodist.it-breathes

### Blind (29/29 items, 49/49 readings)

- ✔ feel-1 (Neo-Soul Pocket) — 5/5
- ✔ feel-2 (Boom-Bap Pocket) — 3/3
- ✔ feel-3 (Trap Rolling Hats) — 3/3
- ✔ feel-4 (Four on the Floor) — 2/2
- ✔ feel-5 (Lo-Fi Hip-Hop) — 3/3
- ✔ feel-6 (Trip-Hop) — 3/3
- ✔ feel-7 (Lo-Fi House) — 2/2
- ✔ feel-8 (Breakbeat (Amen)) — 2/2
- ✔ amapiano-Amapiano (Amapiano as Amapiano) — 1/1
- ✔ blues-Shuffle (Shuffle as Blues) — 1/1
- ✔ blues-Slow Blues 12/8 (Slow Blues 12/8 as Blues) — 1/1
- ✔ boom-bap-Boom-Bap (Boom-Bap as Boom-bap hip-hop) — 1/1
- ✔ boom-bap-Boom-Bap Pocket (Boom-Bap Pocket as Boom-bap hip-hop) — 2/2
- ✔ country-Country Two-Step (Country Two-Step as Country) — 1/1
- ✔ country-Train Beat (Train Beat as Country) — 1/1
- ✔ drill-UK Drill (UK Drill as Drill) — 1/1
- ✔ drill-Trap Rolling Hats (Trap Rolling Hats as Drill) — 1/1
- ✔ drum-and-bass-Drum & Bass (Drum & Bass as Drum & bass / jungle) — 1/1
- ✔ funk-One-Chord Funk (One-Chord Funk as Funk) — 2/2
- ✔ house-Classic House (Classic House as House) — 1/1
- ✔ house-Four on the Floor (Four on the Floor as House) — 1/1
- ✔ jazz-Jazz Waltz (Jazz Waltz as Jazz — small-group swing and post-bop) — 1/1
- ✔ jazz-Broadway Ride (Broadway Ride as Jazz — small-group swing and post-bop) — 1/1
- ✔ lo-fi-hip-hop-Lo-Fi Hip-Hop (Lo-Fi Hip-Hop as Lo-fi hip-hop) — 1/1
- ✔ neo-soul-Neo-Soul Pocket (Neo-Soul Pocket as Neo-soul / contemporary R&B) — 4/4
- ✔ techno-Four on the Floor (Four on the Floor as Techno) — 1/1
- ✔ trap-Trap Rolling Hats (Trap Rolling Hats as Trap) — 1/1
- ✔ trap-Halftime (Halftime as Trap) — 1/1
- ✔ uk-garage-UK Garage 2-Step (UK Garage 2-Step as UK garage / 2-step) — 1/1

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

### Disagreements (8/8)

- ✔ sampler ↔ producer: whether a second source belongs in the song — refuse by sampler.one-drum-source vs defer to the sampler
- ✔ sampler ↔ engineer: whether the chain's bandwidth is a fault — agree vs defer to the sampler
- ✔ sampler ↔ peer: whether the break should vary across the form — defer to the peer vs refuse by peer.form-turns
- ✔ sampler ↔ lyricist: whether a vocal sample counts as a lyric — defer to the lyricist vs refuse by lyricist.image-is-a-tic
- ✔ sampler ↔ beatmaker: whether the swing lives in the grid or in the audio — defer to the beatmaker vs agree
- ✔ sampler ↔ bassist: pitching a source down — refuse by sampler.past-four-semitones vs defer to the sampler
- ✔ sampler ↔ harmonist: whether the sample's harmony may be overruled — agree with a caveat vs defer to the sampler
- ✔ sampler ↔ melodist: whether a sampled phrase counts as the tune — defer to the melodist vs refuse by melodist.a-figure-comes-back

## Bassist

### Goldens (4/4 executable, 1 prose-only)

- ✔ bassist.g1.voodoo-lag: expected agree, got agree
- ✔ bassist.g2.lagging-drummer-pushes-back: expected refuse by bassist.straight-reference, got refuse by bassist.straight-reference
- ✔ bassist.g3.808-ownership: expected refuse by bassist.808-is-the-bass, got refuse by bassist.808-is-the-bass
- ✔ bassist.g4.thundercat-harmony: expected agree, got agree

### Disagreements (9/9)

- ✔ bassist ↔ producer: whether the bass line is a part or the song's floor — defer to the producer vs agree
- ✔ bassist ↔ engineer: who owns 80 Hz — defer to the engineer vs refuse by engineer.who-owns-eighty
- ✔ bassist ↔ peer: whether the bass should change at the hook — defer to the peer vs agree
- ✔ bassist ↔ lyricist: whether the bass should leave room under the vocal — defer to the lyricist vs refuse by lyricist.a-line-is-a-breath
- ✔ bassist ↔ beatmaker: who moves — defer to the beatmaker vs agree
- ✔ bassist ↔ beatmaker: a busier kick — defer to the beatmaker vs refuse by beatmaker.hard-quantise-kills-it
- ✔ bassist ↔ sampler: retuning a sampled bass — defer to the sampler vs refuse by sampler.past-four-semitones
- ✔ bassist ↔ harmonist: whether the bass may sit on a note the chord does not hold — defer to the harmonist vs agree
- ✔ bassist ↔ melodist: whether the tune and the bass may move together — defer to the melodist vs refuse by melodist.mostly-steps

### Blind (15/15 items, 28/28 readings)

- ✔ line-1 (Palladino, 40 ms, neo-soul at 92) — 5/5
- ✔ line-2 (Palladino, 65 ms, the edge of the window) — 2/2
- ✔ line-3 (Palladino, 10 ms, under the window) — 2/2
- ✔ line-4 (Thundercat, on the kick at 130) — 3/3
- ✔ line-5 (Thundercat, 40 ms, boom-bap at 96) — 2/2
- ✔ line-6 (Programmed 808 on the kick, trap at 140) — 3/3
- ✔ line-7 (Programmed sub 30 ms off the kick) — 2/2
- ✔ line-8 (Palladino ahead of the kick) — 2/2
- ✔ blues-walking (walking under Shuffle as Blues) — 1/1
- ✔ bossa-nova-root-fifth (root-fifth under Bossa Nova as Bossa nova) — 1/1
- ✔ folk-root-fifth (root-fifth under Folk Strum as Folk / singer-songwriter) — 1/1
- ✔ funk-motown (motown under One-Chord Funk as Funk) — 1/1
- ✔ jazz-walking (walking under Jazz Waltz as Jazz — small-group swing and post-bop) — 1/1
- ✔ salsa-tumbao (tumbao under Son Clave 2-3 as Salsa / son) — 1/1
- ✔ techno-rolling (rolling under Four on the Floor as Techno) — 1/1

## Producer

### Goldens (8/8 executable, 0 prose-only)

- ✔ producer.golden.too-many-parts: expected refuse by producer.fewer-parts, got refuse by producer.fewer-parts
- ✔ producer.golden.orphan: expected refuse by producer.no-orphans, got refuse by producer.no-orphans
- ✔ producer.golden.room-to-add: expected agree, got agree
- ✔ producer.golden.pushes-back: expected refuse by producer.reference-has-bars, got refuse by producer.reference-has-bars
- ✔ producer.golden.reference-with-bars: expected agree, got agree
- ✔ producer.golden.a-record: expected agree, got agree
- ✔ producer.golden.loud-and-quiet: expected refuse by producer.loudness-spread, got refuse by producer.loudness-spread
- ✔ producer.golden.defers: expected defer to the beatmaker, got defer to the beatmaker

### Disagreements (8/8)

- ✔ producer ↔ beatmaker: whether a groove that is right by the pocket's numbers is right for the song — refuse by producer.fewer-parts vs defer to the producer
- ✔ producer ↔ sampler: whether a second source belongs in the song — defer to the sampler vs refuse by sampler.one-drum-source
- ✔ producer ↔ bassist: whether the bass line is a part or the song's floor — agree vs defer to the producer
- ✔ producer ↔ engineer: whether loudness is a decision or a delivery spec — defer to the engineer vs refuse by engineer.delivery-loudness
- ✔ producer ↔ peer: whether the outside ear outranks the brief — refuse by producer.reference-has-bars vs defer to the producer
- ✔ producer ↔ lyricist: whether the words serve the brief or the brief serves the words — defer to the lyricist vs refuse by lyricist.not-a-nursery-rhyme
- ✔ producer ↔ harmonist: whether a progression counts as a part worth keeping — defer to the harmonist vs refuse by harmonist.enough-chords
- ✔ producer ↔ melodist: whether a song needs a tune at all — defer to the melodist vs refuse by melodist.not-too-busy

## Engineer

### Goldens (11/11 executable, 0 prose-only)

- ✔ engineer.golden.hot-master: expected refuse by engineer.delivery-loudness, got refuse by engineer.delivery-loudness
- ✔ engineer.golden.delivery: expected agree, got agree
- ✔ engineer.golden.pushes-back: expected refuse by engineer.drums-keep-their-crest, got refuse by engineer.drums-keep-their-crest
- ✔ engineer.golden.crest-kept: expected agree, got agree
- ✔ engineer.golden.fighting-low-end: expected refuse by engineer.who-owns-eighty, got refuse by engineer.who-owns-eighty
- ✔ engineer.golden.a-move: expected agree, got agree
- ✔ engineer.golden.a-boost: expected refuse by engineer.cut-before-boost, got refuse by engineer.cut-before-boost
- ✔ engineer.golden.two-moves: expected refuse by engineer.one-move-at-a-time, got refuse by engineer.one-move-at-a-time
- ✔ engineer.golden.master-set: expected agree, got agree
- ✔ engineer.golden.ceiling-at-zero: expected refuse by engineer.master-ceiling, got refuse by engineer.master-ceiling
- ✔ engineer.golden.defers: expected defer to the bassist, got defer to the bassist

### Disagreements (8/8)

- ✔ engineer ↔ beatmaker: whether the drums should be squashed to sit in the mix — refuse by engineer.drums-keep-their-crest vs defer to the engineer
- ✔ engineer ↔ sampler: whether the chain's bandwidth is a fault — defer to the sampler vs agree
- ✔ engineer ↔ bassist: who owns 80 Hz — refuse by engineer.who-owns-eighty vs defer to the engineer
- ✔ engineer ↔ producer: whether loudness is a decision or a delivery spec — refuse by engineer.delivery-loudness vs defer to the engineer
- ✔ engineer ↔ peer: whether a lift is a layer or a level — agree vs defer to the engineer
- ✔ engineer ↔ lyricist: whether the vocal should be loud enough to read — agree vs defer to the engineer
- ✔ engineer ↔ harmonist: whether a clash is harmonic or a mix problem — defer to the harmonist vs refuse by harmonist.voice-leading
- ✔ engineer ↔ melodist: whether a tune that disappears is a mix problem — defer to the melodist vs refuse by melodist.singable-range

## Peer

### Goldens (8/8 executable, 0 prose-only)

- ✔ peer.golden.late-hook: expected refuse by peer.hook-inside-thirty, got refuse by peer.hook-inside-thirty
- ✔ peer.golden.early-hook: expected agree, got agree
- ✔ peer.golden.pushes-back: expected refuse by peer.form-turns, got refuse by peer.form-turns
- ✔ peer.golden.turning-form: expected agree, got agree
- ✔ peer.golden.churning-form: expected refuse by peer.not-too-many-sections, got refuse by peer.not-too-many-sections
- ✔ peer.golden.late-opener: expected refuse by peer.opener-hooks-early, got refuse by peer.opener-hooks-early
- ✔ peer.golden.an-arc: expected agree, got agree
- ✔ peer.golden.defers: expected defer to the sampler, got defer to the sampler

### Disagreements (8/8)

- ✔ peer ↔ beatmaker: whether the groove should change when the section does — refuse by peer.hook-inside-thirty vs defer to the peer
- ✔ peer ↔ sampler: whether the break should vary across the form — refuse by peer.form-turns vs defer to the peer
- ✔ peer ↔ bassist: whether the bass should change at the hook — agree vs defer to the peer
- ✔ peer ↔ producer: whether the outside ear outranks the brief — defer to the producer vs refuse by producer.reference-has-bars
- ✔ peer ↔ engineer: whether a lift is a layer or a level — defer to the engineer vs agree
- ✔ peer ↔ lyricist: whether the hook is the words or the section — agree with a caveat vs defer to the peer
- ✔ peer ↔ harmonist: whether a progression that never lands is a problem — defer to the harmonist vs refuse by harmonist.phrases-land
- ✔ peer ↔ melodist: whether a tune that repeats has stopped developing — defer to the melodist vs refuse by melodist.a-figure-comes-back

### Blind (11/11 items, 19/19 readings)

- ✔ boom-bap-form (Boom-bap hip-hop form) — 2/2
- ✔ country-form (Country form) — 1/1
- ✔ drum-and-bass-form (Drum & bass / jungle form) — 2/2
- ✔ dubstep-form (Dubstep form) — 3/3
- ✔ folk-form (Folk / singer-songwriter form) — 2/2
- ✔ neo-soul-form (Neo-soul / contemporary R&B form) — 1/1
- ✔ pop-form (Contemporary pop form) — 1/1
- ✔ samba-form (Samba form) — 2/2
- ✔ synth-pop-form (Synth-pop / EDM pop form) — 2/2
- ✔ trap-form (Trap form) — 1/1
- ✔ trip-hop-form (Trip-hop form) — 2/2

## Lyricist

### Goldens (7/7 executable, 0 prose-only)

- ✔ lyricist.golden.shape-mismatch: expected refuse by lyricist.lines-share-a-shape, got refuse by lyricist.lines-share-a-shape
- ✔ lyricist.golden.shape-holds: expected agree, got agree
- ✔ lyricist.golden.pushes-back: expected refuse by lyricist.not-a-nursery-rhyme, got refuse by lyricist.not-a-nursery-rhyme
- ✔ lyricist.golden.loose-rhyme: expected agree, got agree
- ✔ lyricist.golden.tic: expected refuse by lyricist.image-is-a-tic, got refuse by lyricist.image-is-a-tic
- ✔ lyricist.golden.long-line: expected refuse by lyricist.a-line-is-a-breath, got refuse by lyricist.a-line-is-a-breath
- ✔ lyricist.golden.defers: expected defer to the bassist, got defer to the bassist

### Disagreements (8/8)

- ✔ lyricist ↔ beatmaker: whether a stressed syllable on a swung offbeat is a problem — refuse by lyricist.lines-share-a-shape vs defer to the lyricist
- ✔ lyricist ↔ sampler: whether a vocal sample counts as a lyric — refuse by lyricist.image-is-a-tic vs defer to the lyricist
- ✔ lyricist ↔ bassist: whether the bass should leave room under the vocal — refuse by lyricist.a-line-is-a-breath vs defer to the lyricist
- ✔ lyricist ↔ producer: whether the words serve the brief or the brief serves the words — refuse by lyricist.not-a-nursery-rhyme vs defer to the lyricist
- ✔ lyricist ↔ engineer: whether the vocal should be loud enough to read — defer to the engineer vs agree
- ✔ lyricist ↔ peer: whether the hook is the words or the section — agree vs defer to the lyricist
- ✔ lyricist ↔ harmonist: whether the words or the chords decide where a phrase ends — defer to the harmonist vs refuse by harmonist.phrases-land
- ✔ lyricist ↔ melodist: whether the tune or the line decides where a phrase breathes — defer to the melodist vs refuse by melodist.it-breathes

## Harmonist

### Goldens (8/8 executable, 0 prose-only)

- ✔ harmonist.golden.plain-progression: expected agree, got agree
- ✔ harmonist.golden.pushes-back: expected refuse by harmonist.voice-leading, got refuse by harmonist.voice-leading
- ✔ harmonist.golden.too-busy: expected refuse by harmonist.harmonic-rhythm, got refuse by harmonist.harmonic-rhythm
- ✔ harmonist.golden.undeclared-modulation: expected refuse by harmonist.stays-in-key, got refuse by harmonist.stays-in-key
- ✔ harmonist.golden.borrowed-holds: expected agree, got agree
- ✔ harmonist.golden.a-drone: expected refuse by harmonist.enough-chords, got refuse by harmonist.enough-chords
- ✔ harmonist.golden.never-lands: expected refuse by harmonist.phrases-land, got refuse by harmonist.phrases-land
- ✔ harmonist.golden.defers: expected defer to the beatmaker, got defer to the beatmaker

### Disagreements (8/8)

- ✔ harmonist ↔ bassist: whether the bass may sit on a note the chord does not hold — agree vs defer to the harmonist
- ✔ harmonist ↔ beatmaker: whether a chord may change off the grid — refuse by harmonist.harmonic-rhythm vs defer to the harmonist
- ✔ harmonist ↔ sampler: whether the sample's harmony may be overruled — defer to the sampler vs agree with a caveat
- ✔ harmonist ↔ producer: whether a progression counts as a part worth keeping — refuse by harmonist.enough-chords vs defer to the harmonist
- ✔ harmonist ↔ engineer: whether a clash is harmonic or a mix problem — refuse by harmonist.voice-leading vs defer to the harmonist
- ✔ harmonist ↔ peer: whether a progression that never lands is a problem — refuse by harmonist.phrases-land vs defer to the harmonist
- ✔ harmonist ↔ lyricist: whether the words or the chords decide where a phrase ends — refuse by harmonist.phrases-land vs defer to the harmonist
- ✔ harmonist ↔ melodist: whether a note outside the chord is a wrong note or the point — defer to the melodist vs refuse by melodist.lands-on-the-chord

### Blind (32/32 items, 32/32 readings)

- ✔ bossa-nova-prog1 (Imaj7 - II7 - ii7 - bII7 as Bossa nova) — 1/1
- ✔ bossa-nova-prog2 (iii7 - bIII7 - ii7 - bII7 as Bossa nova) — 1/1
- ✔ bossa-nova-prog3 (IVmaj7 - bVII7 as Bossa nova) — 1/1
- ✔ bossa-nova-prog4 (iim7b5 - V7 - i as Bossa nova) — 1/1
- ✔ breakbeat-prog1 (bVII - IV - I as Breakbeat / big beat) — 1/1
- ✔ breakbeat-prog2 (i - IV as Breakbeat / big beat) — 1/1
- ✔ country-prog1 (I - IV - V - I as Country) — 1/1
- ✔ country-prog2 (I - V - vi - IV as Country) — 1/1
- ✔ country-prog3 (I - ii7 - I - IV as Country) — 1/1
- ✔ country-prog4 (ii - V - I as Country) — 1/1
- ✔ cumbia-prog1 (I - V7 as Cumbia) — 1/1
- ✔ cumbia-prog2 (I - IV - V7 - I as Cumbia) — 1/1
- ✔ cumbia-prog3 (i - bVII - bVI - bVII as Cumbia) — 1/1
- ✔ disco-prog1 (i7 - IV7 as Disco) — 1/1
- ✔ disco-prog2 (i - iv7 - VII7 - IIImaj7 - VImaj7 - ii - V7 as Disco) — 1/1
- ✔ disco-prog3 (i7 - VImaj7 - v7 as Disco) — 1/1
- ✔ house-prog1 (i - VImaj7 - VII as House) — 1/1
- ✔ house-prog2 (v7 - VImaj7 - iv7 - VII7 - i as House) — 1/1
- ✔ jazz-prog1 (iim7 - V7 - Imaj7 as Jazz — small-group swing and post-bop) — 1/1
- ✔ jazz-prog2 (iim7 - bII7 - Imaj7 as Jazz — small-group swing and post-bop) — 1/1
- ✔ jazz-prog3 (Imaj7 - VI7 - iim7 - V7 as Jazz — small-group swing and post-bop) — 1/1
- ✔ jazz-prog4 (III7 - VI7 - II7 - V7 as Jazz — small-group swing and post-bop) — 1/1
- ✔ jazz-prog5 (im7 - bIIm7 - im7 as Jazz — small-group swing and post-bop) — 1/1
- ✔ pop-prog1 (I - V - vi - IV as Contemporary pop) — 1/1
- ✔ pop-prog2 (i - VII - VI - iv as Contemporary pop) — 1/1
- ✔ pop-prog3 (i - iv - VI - VII as Contemporary pop) — 1/1
- ✔ pop-prog4 (IV7 - vi - V as Contemporary pop) — 1/1
- ✔ rock-prog1 (I - IV - V - I as Rock) — 1/1
- ✔ rock-prog2 (I - bVII - IV - I as Rock) — 1/1
- ✔ rock-prog3 (i - iv - III - VI as Rock) — 1/1
- ✔ rock-prog4 (V - IV - I as Rock) — 1/1
- ✔ uk-garage-prog1 (i7 - v - VImaj7 as UK garage / 2-step) — 1/1

## Melodist

### Goldens (8/8 executable, 0 prose-only)

- ✔ melodist.golden.singable: expected agree, got agree
- ✔ melodist.golden.pushes-back: expected refuse by melodist.singable-range, got refuse by melodist.singable-range
- ✔ melodist.golden.a-leap-too-far: expected refuse by melodist.leap-and-step, got refuse by melodist.leap-and-step
- ✔ melodist.golden.wonder-leaps: expected agree with a caveat, got agree with a caveat
- ✔ melodist.golden.an-arpeggio: expected refuse by melodist.mostly-steps, got refuse by melodist.mostly-steps
- ✔ melodist.golden.never-breathes: expected refuse by melodist.it-breathes, got refuse by melodist.it-breathes
- ✔ melodist.golden.a-walk: expected refuse by melodist.a-figure-comes-back, got refuse by melodist.a-figure-comes-back
- ✔ melodist.golden.defers: expected defer to the beatmaker, got defer to the beatmaker

### Disagreements (8/8)

- ✔ melodist ↔ harmonist: whether a note outside the chord is a wrong note or the point — refuse by melodist.lands-on-the-chord vs defer to the melodist
- ✔ melodist ↔ lyricist: whether the tune or the line decides where a phrase breathes — refuse by melodist.it-breathes vs defer to the melodist
- ✔ melodist ↔ peer: whether a tune that repeats has stopped developing — refuse by melodist.a-figure-comes-back vs defer to the melodist
- ✔ melodist ↔ bassist: whether the tune and the bass may move together — refuse by melodist.mostly-steps vs defer to the melodist
- ✔ melodist ↔ beatmaker: whether a tune may sit off the grid — refuse by melodist.it-breathes vs defer to the melodist
- ✔ melodist ↔ sampler: whether a sampled phrase counts as the tune — refuse by melodist.a-figure-comes-back vs defer to the melodist
- ✔ melodist ↔ producer: whether a song needs a tune at all — refuse by melodist.not-too-busy vs defer to the melodist
- ✔ melodist ↔ engineer: whether a tune that disappears is a mix problem — refuse by melodist.singable-range vs defer to the melodist

