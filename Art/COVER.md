# A cover for a record

The app draws one for free: the Album surface's cover panel, four layouts (band, corner, stack,
monogram), the title and the artist in Plex on a two-colour field, rendered at 3000 × 3000 into
the release folder as `cover.png`. Drop an image on the Album surface and that is the cover
instead, copied into the library.

To generate one, that is your call and your credits — the app never spends them:

    Art/generate.py cover-<album> --model nano-banana-2 --count 2 --ref picked/cast-director.png --budget

with a `cover-<album>` entry in `Art/manifest.json` (a 1:1 prompt in the house idiom), then pick
into `Art/picks.json` and run `Art/make_art.py cover-<album>`; the PNG lands in `Art/out/`. Drop it
on the Album surface. The OpenArt Starter plan carries no commercial rights: upgrade before a
generated cover goes on a released record.
