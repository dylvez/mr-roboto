# A cover for a record

The app draws one for free: the Album surface's cover panel, four layouts (band, corner, stack,
monogram), the title and the artist in Plex on a two-colour field, rendered at 3000 × 3000 into
the release folder as `cover.png`. Drop an image on the Album surface and that is the cover
instead, copied into the library.

To generate one, that is your call and your credits — the app never spends them:

    Art/generate.py cover-<album> --model nano-banana-2 --count 2 --ref Art/picked/machine-vinyl.png --budget 100

with a `cover-<album>` entry in `Art/manifest.json` (a 1:1 brief in the house idiom, 3000 × 3000,
`cutout: false`). Lay the candidates out with `Art/contact.py cover-<album>`, copy the one you want to
`Art/picked/cover-<album>.png`, name it in `Art/picks.json`, and run `Art/make_art.py cover-<album>`:
the cover is written whole, square, at the spec's size, to `Art/out/cover-<album>.png` — never into
the app's bundle. Drop it on the Album surface. Shellac's was made this way on 2026-10-09: four
candidates over two models for 120 credits, the first nano-banana-2 one picked. The OpenArt Starter
plan carries no commercial rights: upgrade before a generated cover goes on a released record.
