# The persona method

How a role becomes a bible, and what a bible has to be before it gets a seat. This is the written
form of `BibleMethod.lint` (Sources/MrRobotoApp/Personas/BibleMethod.swift) and of the tests in
`PersonaBibleTests` — the same rules, in the order you meet them when writing one.

A bible is data (`PersonaBible`, a JSON document under `Resources/Bibles/` or a project's
`bibles/`). A persona is a bible plus an opinion about a proposal; a document-only persona gets its
opinion from `RuleEngine`, the three shipped ones also carry hand-written prose. Nothing in a bible
is a mood. Every claim says whether anybody wrote it down.

## The fixed sections

1. **Identity** — `id` (one word, lowercase; every rule id is prefixed with it), `name`, `owns`
   (one sentence: what this persona owns and nothing more).
2. **Lineages** (three or four) — named practitioners, machines or records the persona descends
   from, each with a `period` and a `why` longer than a sentence that says *what is documented
   about how they worked*. A lineage chosen because the music is good cannot be checked against
   anything; one chosen because the method is written down can.
3. **Listens for** (four or more, priority 1 first) — what it hears before anything else, each
   over features the vocabulary defines. The order is the persona.
4. **Vocabulary** — `FeatureDefinition`s: the feature, its unit, one sentence of meaning, the
   **engine field** it is read from (a real property of a real type in Performance, Instrument,
   SongGraph, Analysis or MusicTheory), and `noticeable`, the smallest change worth marking.
5. **Ranges** — per lineage, per feature, low and high (and `typical` when the record says), two
   or more per lineage. This is what lets a persona say "that is a trap number in a boom-bap
   groove" instead of "that feels wrong", and what `RuleEngine` uses in place of a rule's general
   threshold when a proposal names the lineage.
6. **Rules** (ten or more, most with a threshold) — `when` / `then` in the persona's own words,
   the `threshold` that is the arithmetic behind the *when*, the `engineAction` that is the
   arithmetic behind the *then*, and `evidence`. Say which way the threshold cuts
   (`firesWhen`: most state the allowed range and fire when a value falls outside it; a few state
   the condition — "the kick decays past 400 ms" — and fire when it holds) and any precondition
   (`applies`) on another feature.
7. **Voice** — register, sentence shape, words it uses, words it will not, three lines it would
   say.
8. **Refusals** (three or more) — what it will not do, why in one sentence, and what to do
   instead. A refusal with no alternative is an obstacle, not a role.
9. **Disagreements** — one with every other persona in the roster: what they fight about, this
   position, theirs stated fairly, and what settles it (a measurement, or a stated rule about
   who wins).
10. **References** (four or more) — records that demonstrate a rule, down to the bars, with what
    to listen for there in a sentence and the features it shows.
11. **Goldens** (five or more; one ends `pushes-back`) — a premise, a pass criterion long enough
    to check, the rules exercised, and — for at least half of them — the `proposal` the persona
    is actually asked and the `expects` shape of its verdict (`agree`, `caveat`, `refuse` by
    rule, `defer` to whom). `GoldenRunner` executes these; `make evals` reports them.
12. **Open questions** (four or more) — where the sources disagree or are silent: the question,
    what was encoded and why, the alternative stated fairly enough that flipping to it is a small
    edit, and which rules it affects. A house call (kept with the song, not the bible) is what
    this house chose.

## Evidence

Every lineage, feature, range, rule, reference and open question carries `evidence`:
`{"cited": ["https://…"]}` with the sources in reading order, or `{"inferred": "what it was derived
from"}` — never "taste", which is not a reason. Cited must outnumber inferred, and inferred must
not be zero: a bible with nothing inferred did not admit anything.

## Research by extraction, not reading

For each role, run the extraction prompt in `research-<role>.md`: it names the sources to read and
the sections to fill, and the bar each has to clear. Work from the sources to the sections, not
the other way round; a section you cannot fill from the sources is an open question, not a guess.
Producers and engineers talk (interview archives, published conversations); lyricists have
codified craft (Pattison, Webb, Davis); players are harder, which is where transcription comes in.

## What a rule needs to earn a threshold

- A feature the engine measures (`engineField` names it).
- A number from the record — a published spec, a measured recording, a stated practice — or an
  inference from one, marked as such.
- A direction: what the persona does when the number is on the wrong side.
- A range per lineage where the lineages differ, so the threshold is not one player's habit.

## Checking a bible

- In the app: a bible dropped on the Cast surface is linted before it gets a seat.
- From the tests: `swift test --filter BibleDocumentTests` lints every shipped bible;
  `MRROBOTO_BIBLE=/path/to/bible.json swift test --filter BibleLint` lints one file.
- `make evals` runs every golden, blind and disagreement eval and writes the report.

## The three evals

`make evals` runs three kinds over every bible and writes `evals.md` beside this file:

- **golden** — every `GoldenTest` that carries a `proposal` and an `expects` shape is put to its
  persona through the rule engine, and the verdict has to take that shape. Prose-only goldens are
  listed as such, and at least half of a bible's goldens must execute.
- **disagreement** — every `PersonaDisagreement` carries (on at least one side of the pair) a
  `proposal`, a `rule` on its front line, and `expects: {mine, theirs}`. The proposal is put to
  both personas; the two shapes must differ, must not both be deferrals, and must be the shapes
  the bible declared. A declared disagreement nobody can provoke is a sentence, not a rule, and
  it fails. The Director uses the same `rule` pairs to see a disagreement showing in a song: this
  persona's front-line reading failing while the other's holds opens a Compare of the two.
- **blind** — `blind/<persona>.json` names material the persona reads with its label hidden (a feel
  from the library; a line the writer writes under a feel) and, per rule, whether the reading
  should hold. The sheet is authored from what is knowable about the material — a trap feel's
  ghosts sit 4 dB under a hit; a sub 30 ms off the kick is two low notes fighting — not copied
  from what the persona happened to say. Pilots: the Bassist on the writer's own lines, the
  Beatmaker on the feel library. Corpus records join the sheets as they arrive.

## Genres

A bible is written from its lineages, and every shipped bible's lineages come from one idiom — the
sampled, behind-the-beat hip-hop and neo-soul the app started in. So a persona's numbers are that
idiom's numbers, and a house track or a country master judged by them is judged by the wrong
genre. The genre profiles (`Resources/Genres/`, `Bench/genres/`) are the other half: a genre's
ranges on the same features, researched to the same standard of evidence.

A song is placed in a genre (the song's settings, or `set_genre`) or has one guessed from the
feel its newest groove was written in. `GenreLens` then re-judges every reading and refusal whose
rule thresholds a feature the genre ranges: the side the rule draws moves to the genre's number
(a ceiling stays a ceiling), the verdict follows the genre, and the reading says both numbers.
Rules that name a condition rather than a norm, and features that are the same in every genre —
a machine's reach, a converter's ceiling, how a sample was cut — are never moved.

The genre blind sheets (`blind/genre-<persona>.json`) test the lens against canonical material:
a genre's own feels, bass hands, form and progressions, read in that genre, should hold on its
style rules. Where they do not, the item records why (`notes`), and the finding is about the
feel library or the fragment, not a failure to hide.
