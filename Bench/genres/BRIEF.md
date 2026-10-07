# Genre profile research brief

You are researching music genres for **Mr. Roboto**, a native macOS music-making app with a band of
AI "personas" (Beatmaker, Bassist, Engineer, Harmonist, Melodist, Peer, Producer, Lyricist, Sampler).
Each persona measures a song with numeric **features** and judges them against ranges. Today those
ranges are all taken from one genre (sample-based hip-hop / neo-soul), so a house track or a country
song is judged by D'Angelo's numbers. Your job: write a **genre profile** per genre, as JSON, that
gives the app its own understanding of the genre — numbers on the app's features, plus structured
notes — with sources.

## Method (non-negotiable)

- **Research by extraction, not reading.** Use web search and fetch real sources: interviews with
  producers/players, published tutorials from reputable outlets (Sound on Sound, MusicRadar,
  Attack Magazine, Reverb, Berklee, Point Blank, Ableton, iZotope, Mix Online), academic papers,
  musicology books, loudness measurement studies, genre histories. Prefer sources that state a
  number or a method.
- **Every claim carries `evidence`**, exactly one of:
  - `{"cited": ["https://…", "https://…"]}` — URLs you actually opened that support it, in reading order.
  - `{"inferred": "what it was derived from"}` — e.g. "median of the tempos of the six reference records listed" or "from the cited 124 bpm norm plus the ±4 variation the cited tutorials allow". Never "taste", never "common knowledge".
- **Cited must outnumber inferred** in every profile, and at least one claim must be inferred (a profile that admits nothing is not honest).
- Numbers must be in **the feature's own unit** (listed below). If you cannot find a basis for a
  feature's range in a genre, **leave that feature out**. A missing range is fine; a guessed one is not.
- Ranges are what is *normal* in the genre — where a practitioner would not blink — not extremes.
  `typical` is optional; give it when a source states one.
- Do not invent URLs. If a fetch fails, do not cite it.

## Output

Write one file per genre to `OUTDIR/<id>.json` (OUTDIR is given in your task). UTF-8, 2-space
indent, valid JSON exactly in this shape:

```json
{
  "id": "house",
  "name": "House",
  "aliases": ["chicago house", "deep house", "classic house"],
  "family": "electronic",
  "parent": null,
  "summary": "Two or three sentences on what makes it this genre, musically.",
  "summaryEvidence": {"cited": ["https://…"]},
  "idioms": ["house", "electronic"],
  "feels": ["Classic House", "Four on the Floor"],
  "meters": ["4/4"],
  "ranges": [
    {"feature": "tempo.bpm", "low": 118, "high": 128, "typical": 124, "unit": "BPM", "evidence": {"cited": ["https://…"]}},
    {"feature": "mix.lufs.integrated", "low": -9, "high": -6, "unit": "LUFS", "evidence": {"cited": ["https://…"]}}
  ],
  "notes": [
    {"area": "groove", "text": "Kick on every quarter note; clap or snare on 2 and 4; open hat on every off-beat eighth.", "evidence": {"cited": ["https://…"]}},
    {"area": "form", "text": "…", "evidence": {…}},
    {"area": "harmony", "text": "…", "evidence": {…}},
    {"area": "bass", "text": "…", "evidence": {…}},
    {"area": "arrangement", "text": "…", "evidence": {…}},
    {"area": "sound", "text": "…", "evidence": {…}},
    {"area": "mix", "text": "…", "evidence": {…}},
    {"area": "melody", "text": "…", "evidence": {…}},
    {"area": "lyrics", "text": "…", "evidence": {…}}
  ],
  "form": {
    "sections": [{"name": "Intro", "bars": 16}, {"name": "Groove", "bars": 32}, {"name": "Breakdown", "bars": 16}, {"name": "Drop", "bars": 32}, {"name": "Outro", "bars": 16}],
    "evidence": {"cited": ["https://…"]}
  },
  "progressions": [
    {"roman": "i - VII - VI - VII", "mode": "aeolian", "text": "The minor loop that never resolves.", "evidence": {…}}
  ],
  "bassHands": ["octave", "programmed"],
  "sounds": {"machines": ["tr909"], "bass": ["sub", "acid"], "instruments": ["stab", "rhodes", "strings"]},
  "lineages": [
    {"name": "Frankie Knuckles", "period": "1977–1990", "why": "What is documented about how they worked (two sentences or more).", "evidence": {"cited": ["https://…"]}}
  ],
  "references": [
    {"artist": "Mr. Fingers", "title": "Can You Feel It", "year": 1986, "listenFor": "What to listen for, where (bars or timestamp), in one sentence.", "features": ["tempo.bpm"], "evidence": {"cited": ["https://…"]}}
  ],
  "pitfalls": [
    {"text": "What someone new to the genre gets wrong, and what to do instead.", "evidence": {…}}
  ]
}
```

Bars in `form.sections` are a typical arrangement, in bars of the genre's meter; say in a note if
forms vary a lot. `progressions` use roman numerals relative to the key (upper case major, lower
case minor, `b` for flats, `7`/`maj7`/`m7` suffixes allowed). `mode` is one of the church modes
(ionian, dorian, phrygian, lydian, mixolydian, aeolian, locrian) or one of these scales the app
also keys songs in: harmonic minor, melodic minor, phrygian dominant, double harmonic,
hungarian minor, ukrainian dorian. Aim for: 3–4 lineages, 4–6 references,
2–5 progressions (0 if the genre is not harmony-driven — then say so in a harmony note), 8–15 notes
covering most areas, 6–15 ranges, 2–4 pitfalls.

`idioms` — which of the app's style tags this profile covers (used to guess the genre from the feel
a groove was written in). Use only these: hip-hop, boom-bap, lo-fi, trap, trip-hop, neo-soul, soul,
motown, funk, house, electronic, disco, breakbeat, drum-and-bass, rock, pop, blues, jazz, latin,
reggae, country, folk, ballad, musical-theatre, waltz, uk-garage, odd-meter, new-orleans,
jersey-club, gospel, dubstep, drill, amapiano, afrobeats, afrobeat, afro-cuban, swing, ska, dub,
dancehall, rnb, cinematic, ambient, flamenco, klezmer, middle-eastern.

`feels` — names from the app's feel library that belong to this genre (exact names, only these):
Ballad Brushes; Pop Piano Backbeat; Travis Shaker; Folk Strum; Broadway Ride; Soul Tambourine;
Oom-Pah Waltz; Lo-Fi Hip-Hop; Boom-Bap Pocket; Trap Rolling Hats; Lo-Fi House; Trip-Hop; Neo-Soul
Pocket; Standard Rock; Four on the Floor; Boom-Bap; Shuffle; Bossa Nova; Train Beat; Reggae One Drop;
Motown; Breakbeat (Amen); Waltz; Jazz Waltz; 3/4 Ballad; Disco; Classic House; UK Garage 2-Step;
Drum & Bass; Halftime; Jersey Club; Afrobeats; Amapiano; Afrobeat; Second Line; UK Drill; One-Chord
Funk; Gospel Shout; Country Two-Step; Slow Blues 12/8; Afro-Cuban 6/8; Five Four; Seven Eight; Son
Clave 3-2; Son Clave 2-3; Rumba Clave; Salsa Tumbao; Cha-Cha-Chá; Samba; Baião; Dembow; Cumbia;
Cajón Groove; Maqsum; Big Band Swing; Ska; Steppers; Rockers; Dancehall; New Jack Swing; Slow Jam;
Cinematic Toms; Rumba Flamenca; Bulerías; Bulgar; Saidi.
An empty list is allowed if none fits (a genre with no drums at all, such as much ambient music).

`bassHands` — which of the app's bass-writing styles fit (the app will implement all of these):
- `palladino` — behind the kick 20–65 ms, roots and slides, note-off on the beat (neo-soul, D'Angelo).
- `thundercat` — harmonic, voicings and register on the chord change.
- `programmed` — an 808 that follows the kick pattern, re-pitched, long sub notes (trap, drill).
- `octave` — pumping eighth-note octaves on the root, on the grid (disco, house).
- `one-drop` — melodic bass leaving beat one empty, sitting with the kick on 3 (reggae).
- `tumbao` — anticipated bass on the and-of-2 and on 4, tied over, rarely on 1 (salsa, son).
- `walking` — quarter notes, chord tones on strong beats, chromatic approach notes (jazz, swing blues).
- `root-fifth` — root on 1, fifth on 3, walk-up at changes (country, folk, polka).
- `motown` — Jamerson-style melodic eighths with chromatic passing tones and syncopated pickups.
- `rolling` — long sustained sub or reese notes moving under breakbeats, one or two per bar (drum & bass, dubstep, UK garage).
- `log-drum` — amapiano log-drum figures: short pitched percussive hits syncopated off the beat.
- `dub` — heavy, sparse, melodic riff of roots, fifths and octaves, half-time in feel, leaving space (dub, roots reggae, trip-hop).
- `afrobeat` — a one- or two-bar syncopated ostinato that repeats under the whole section, many rests, interlocking with the guitars (Fela, afrobeat).
- `pedal` — one long held root per chord, or a drone under several chords (ambient, film score, ballads).
- `boom-bap` — a played bass that follows the kick with short roots and a pentatonic pickup, cut short (boom-bap, lo-fi hip-hop).

`sounds` — only these ids:
- machines: tr808, tr909, linn, cr78, tr606, tr707, dmx, simmons, sp1200, mpc60, studio, jazz, rock, funk, vintage, trap, lofi
- bass: sub, finger, picked, slap, upright, fretless, muted, 808, acid, analogue, reese, square, fm, rubber, pluck, log-drum
- instruments (an acoustic sound is played on the library's recording of it when there is one, and `horns`/`brass`
  on its horn section; `organ`, `rock-organ`, `jazz-organ` and `gospel-organ` are tonewheel organs through a
  rotating speaker): grand-piano, fm-piano, felt-piano, clavinet, harpsichord, toy-piano, rock-organ, jazz-organ, gospel-organ, pipe-organ, harmonium, combo-organ, vibraphone, xylophone, glockenspiel, kalimba, steel-drum, music-box, tubular-bells, nylon-guitar, steel-guitar, clean-electric, overdrive-guitar, distorted-guitar, muted-guitar, harp, koto, banjo, pizzicato, strings, slow-strings, violin, cello, oohs, glass-pad, dark-pad, air-pad, sweep-pad, flute, clarinet, oboe, tenor-sax, alto-sax, pan-flute, synth-brass, trumpet, horns, bell-pluck, stab, saw-lead, sine-lead, chip-square, chip-pulse, chip-triangle, rhodes, wurlitzer, bell, marimba, juno, pad, choir, pluck, organ, lead, brass

## The features (the only ones `ranges` may use; units exactly as stated)

- `bass.kick.offset.ms` (bassist; unit: ms, positive = behind the kick) — the median bass onset minus its nearest kick onset
- `bass.kick.offset.max.ms` (bassist; unit: ms, signed) — the furthest any onset sits from its kick
- `bass.note.length.ratio` (bassist; unit: fraction of the interval to the next onset) — how much of the space a note fills before the next attack
- `bass.noteoff.onbeat.rate` (bassist; unit: fraction of note-offs) — note-offs landing within 15 ms of a beat line — note-off as timing
- `bass.rest.ratio` (bassist; unit: fraction of the loop) — silence over the loop's length
- `bass.attacks.per.bar` (bassist; unit: attacks per bar) — distinct onsets a bar, voicings counted once
- `bass.syncopation` (bassist; unit: fraction of onsets) — onsets off the quarter-note grid
- `bass.approach.rate` (bassist; unit: fraction of root moves ≥ a third) — root moves preceded by the half-step below on the last eighth
- `bass.ghost.rate` (bassist; unit: fraction of attacks) — muted attacks — short, under the normal velocity — over all attacks
- `bass.register.low` (bassist; unit: MIDI note) — the lowest note
- `bass.register.high` (bassist; unit: MIDI note) — the highest note
- `bass.downbeat.coverage` (bassist; unit: fraction of bars) — bars whose downbeat carries a bass attack
- `bass.early.alternation` (bassist; unit: 1 or 0) — every other onset ahead of the grid by no more than 25 ms — the one sanctioned early pattern
- `reference.lag.ms` (bassist; unit: ms) — how far the groove's hats — the straight reference — have themselves moved
- `pocket.kick.ms` (bassist; unit: ms) — the kick's own displacement
- `kick.decay.s` (bassist; unit: s, T60) — how long the kick rings; past 0.4 s it is an 808
- `bass.is.sub` (bassist; unit: 1 or 0) — whether the line plays through the sub voice rather than a played bass
- `tempo.bpm` (bassist; unit: BPM) — the tempo the line is read at
- `swing.percent` (bassist; unit: MPC percent) — the swing a programmed line is placed on
- `pocket.snare.ms` (beatmaker; unit: ms, positive = late) — the snare's constant displacement from its grid line
- `pocket.hat.ms` (beatmaker; unit: ms, positive = late) — the same for the hats, which in this idiom usually should not move
- `pocket.spread.ms` (beatmaker; unit: ms) — the distance between the earliest and latest voice — the width of the pocket rather than its centre
- `ghost.ratio` (beatmaker; unit: fraction of sounding steps) — how much of the groove is played under the normal tier
- `ghost.depth.db` (beatmaker; unit: dB under the normal tier) — how far a ghost note sits under a normal hit
- `humanize.timing.ms` (beatmaker; unit: ms, ± at its widest) — seeded jitter — the difference between a programmed bar and a played one
- `grid.subdivision` (beatmaker; unit: steps per beat) — 4 for sixteenths, 8 for thirty-seconds, 3 for triplet eighths
- `backbeat.count` (beatmaker; unit: hits per groove) — how many of the 2s and 4s are actually struck, ghosts excluded
- `mix.lufs.integrated` (engineer; unit: LUFS) — integrated loudness as ITU-R BS.1770 defines it: K-weighted, gated at −70 and −10
- `mix.peak.dbfs` (engineer; unit: dBFS) — the sample peak of the bounce — not oversampled, so up to half a dB under the true peak
- `mix.crest.db` (engineer; unit: dB) — peak over RMS: how far the transients stand above the body; drums live above 8
- `mix.tilt.db` (engineer; unit: dB) — energy above 2 kHz over energy below 200 Hz: positive is bright, negative is dark
- `mix.lowend.separation.db` (engineer; unit: dB) — the gap between the drums' energy and the bass's energy at 60–120 Hz, whoever is louder
- `mix.bandwidth.hz` (engineer; unit: Hz) — where 99% of the energy stops: the top end, and the corner a chain put there
- `mix.move.gain.db` (engineer; unit: dB) — how far one move takes a strip's fader, unsigned
- `mix.move.eq.db` (engineer; unit: dB) — one move's EQ change at its band, signed: a boost is positive
- `mix.move.count` (engineer; unit: moves) — how many things one mix version changes
- `mix.master.ceiling.dbtp` (engineer; unit: dBTP) — the limiter's ceiling on the master
- `mix.master.target.lufs` (engineer; unit: LUFS) — the integrated loudness the song is delivered at
- `harmony.changes.per.bar` (harmonist; unit: changes per bar) — how many chords a bar carries on average — the harmonic rhythm
- `harmony.voice-leading.semitones` (harmonist; unit: semitones) — the mean distance a voice travels between consecutive chords, each note taking the nearest note of the next chord
- `harmony.diatonic.ratio` (harmonist; unit: fraction) — chords the stated key owns, over all chords; 1 never leaves the key
- `harmony.chords.distinct` (harmonist; unit: chords) — how many different chords the progression uses
- `harmony.cadence.ratio` (harmonist; unit: fraction) — phrase endings that land on the tonic or are approached by a fourth or a fifth, over endings
- `harmony.root.motion.fifths` (harmonist; unit: fraction) — root movements by a perfect fourth or fifth, over all movements — the strongest motion there is
- `harmony.bass.agreement` (harmonist; unit: fraction) — chord changes where the bass line is sounding a note of that chord, over the changes it played under
- `lyric.pattern.match` (lyricist; unit: fraction) — how well consecutive lines of a stanza share a stress pattern — Pattison's prosody, as one number from 0 (nothing in common) to 1 (the same shape)
- `lyric.perfect.rhyme.rate` (lyricist; unit: fraction) — lines of a stanza ending in a perfect rhyme with another line of it, over the stanza's lines
- `lyric.image.reuse` (lyricist; unit: songs) — the most songs of the house corpus that one of this lyric's images already appears in
- `lyric.syllables.per.line` (lyricist; unit: syllables) — mean syllables in a sung line
- `lyric.lines` (lyricist; unit: lines) — sung lines in the lyric
- `melody.range.semitones` (melodist; unit: semitones) — the lowest note to the highest — what a singer is being asked for
- `melody.leap.max.semitones` (melodist; unit: semitones) — the widest jump between two consecutive notes
- `melody.stepwise.ratio` (melodist; unit: fraction) — moves of a tone or less, over all moves; 1 is a scale, 0 is all jumps
- `melody.chord.tone.ratio` (melodist; unit: fraction) — notes sounding a note of the chord under them, over the notes with a chord under them
- `melody.notes.per.bar` (melodist; unit: notes per bar) — how busy the tune is
- `melody.rest.ratio` (melodist; unit: fraction) — the share of the tune's length with nothing sounding — where a singer breathes
- `melody.peak.count` (melodist; unit: notes) — how many times the highest note is struck; a climax is one note, not a ceiling
- `melody.motif.ratio` (melodist; unit: fraction) — the longest run of intervals that occurs twice, over all the tune's moves — the figure you sing back
- `form.hook.seconds` (peer; unit: seconds) — when the first section named as a hook or chorus starts, as a listener times it
- `form.repetition` (peer; unit: fraction) — sections that repeat a name already heard, over all sections; 0 never repeats, 1 is one section over and over
- `form.sections` (peer; unit: sections) — how many sections the form holds
- `form.turns` (peer; unit: turns) — distinct section names: the number of different places the form goes
- `form.density.spread` (peer; unit: layers) — layers in the densest section minus the sparsest — whether anything lifts
- `form.minutes` (peer; unit: minutes) — the length of the form at the song's tempo
- `form.album.opener.hook.seconds` (peer; unit: seconds) — where the first track's hook arrives
- `form.album.tempo.jumps` (peer; unit: jumps) — neighbouring tracks whose tempo ratio leaves 0.8–1.25
- `song.parts` (producer; unit: parts) — distinct parts in the song — the things that could be subtracted
- `song.parts.orphaned` (producer; unit: parts) — parts stitched into no section once the song has sections — made, and not used
- `song.churn` (producer; unit: versions) — versions of the most-revised part: how many times one thing has been redone
- `song.reference.bars` (producer; unit: bars) — how many bars the reference names; a reference with none is an adjective
- `song.brief.words` (producer; unit: words) — the length of the brief; zero is no brief, which is the most common fault
- `song.album.minutes` (producer; unit: minutes) — the record's running time, gaps included
- `song.album.loudness.spread.lu` (producer; unit: LU) — max minus min of the tracks' released integrated loudness
- `song.album.same-key.pairs` (producer; unit: pairs) — neighbouring tracks whose key signatures sit at the same place on the circle of fifths
- `chop.shave.ms` (sampler; unit: ms, positive = the cut is late) — how far a cut sits after the transient it was taken from, which is the amount of attack left on the previous pad
- `chop.density` (sampler; unit: slices per bar) — how finely the bar was cut
- `merge.transpose.semitones` (sampler; unit: semitones, absolute) — how far a sample is moved from the key it was cut in to sit with something else — past four the formants give the shift away
- `merge.drum.sources` (sampler; unit: sources) — how many of the fragments stitched into one section carry drums — two records' drums in one bar is two rooms, two kits and two pockets
- `chop.deviation.ms` (sampler; unit: ms) — how far the average cut had to move to reach a grid line — a measure of how far off the grid the source was played
- `degrade.bits` (sampler; unit: bits) — the quantiser's width; 12 is both the SP-1200 and the MPC60, 24 and up is the stage off
- `degrade.rate.hz` (sampler; unit: Hz) — the rate the decimator holds to — 26.04 kHz is the SP-1200's, 40 kHz the MPC60's, and the difference between them is a Nyquist at 13 kHz against one at 20
- `source.bandwidth.hz` (sampler; unit: Hz) — the frequency below which 95% of the source's energy already sits
- `source.slice.floor.db` (sampler; unit: dBFS) — the peak of the quietest sounding slice
- `source.slice.spread.db` (sampler; unit: dB) — loudest minus quietest inside one class — what decides whether a rotating policy produces a groove or a groove that ducks
- `degrade.wow.percent` (sampler; unit: % peak pitch deviation) — the transport's slow wobble; a real Portastudio is specified at 0.05–0.06% WRMS for wow and flutter together
- `degrade.crackle.hz` (sampler; unit: events per second) — surface noise events; this app's vinyl preset runs twelve a second
- `degrade.drive` (sampler; unit: linear gain) — gain into the saturation curve; the SP-1200 preset uses 1.40 and the MPC60 preset 1.20 as stand-ins for the machines' output stages


Features worth the most effort, because a wrong genre norm there produces a wrong verdict today:
`tempo.bpm`, `swing.percent` (MPC swing: 50 = straight, 66.7 = triplet), `mix.lufs.integrated`,
`mix.crest.db`, `form.hook.seconds`, `form.minutes`, `form.repetition`, `harmony.cadence.ratio`,
`harmony.changes.per.bar`, `harmony.chords.distinct`, `harmony.diatonic.ratio`,
`melody.range.semitones`, `melody.notes.per.bar`, `lyric.syllables.per.line`,
`lyric.perfect.rhyme.rate`, `bass.kick.offset.ms`, `bass.attacks.per.bar`, `bass.syncopation`,
`kick.decay.s`, `ghost.ratio`, `humanize.timing.ms`, `pocket.snare.ms`, `grid.subdivision`.

Loudness: find published measurements of commercial releases by genre (e.g. mastering engineers'
articles, loudness surveys, papers measuring LUFS/crest of chart music). Distinguish the master as
released from streaming-normalised playback; the feature is the released master.

## When done

Reply with, per genre: the file path, counts (ranges, notes, lineages, references, cited vs
inferred), and anything you could not find or are unsure of. Keep the reply short; the files are
the work.
