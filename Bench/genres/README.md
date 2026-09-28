# Genres

What the app knows about a genre lives in `Sources/MrRobotoApp/Resources/Genres/<id>.json`: a
profile per genre — tempo, the numbers the band judges it by, feels, bass hands, sounds, a typical
form, progressions, notes, players, records, pitfalls — every claim cited or marked inferred.
`GenreMethod.lint` holds each to the method and `GenreTests` runs it over every shipped profile.

## Adding or redoing a genre

1. Research it to `BRIEF.md` (the brief the shipped profiles were written to; it lists the app's
   features, feels, bass hands and sound ids), into a scratch directory of `<id>.json` files.
2. `python3 Bench/genres/install_genres.py <scratch dir> Sources/MrRobotoApp/Resources/Genres`
   copies them in, dropping ranges on features that are the same in every genre (a machine's
   reach, a converter's ceiling) and refiling notes, and applies the fixes recorded in it.
3. `python3 Bench/genres/make_blind.py .` writes the genre blind sheets,
   `Bench/personas/blind/genre-<persona>.json`: each genre's own feels, bass hands, form and
   progressions, read in that genre, expected to hold on its style rules. `silent.json` lists the
   rules a persona does not speak to for an item; `findings.json` records the places canonical
   material does not meet its genre's numbers, each with why.
4. `make evals` runs them with the rest and writes `Bench/personas/evals.md`.

## What the findings say

A finding is not a failing test: it is the feel library, the writer, or a fragment disagreeing
with the genre's research, written down. Four feels play straight where their genre swings
(Boom-Bap, One-Chord Funk, Four on the Floor as house, the jazz waltz and Broadway ride); the
Neo-Soul Pocket is tighter than the one record the profile measures; three progressions borrow
chords a whole song's diatonic ratio would absorb.
