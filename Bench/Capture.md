# Capture: the phone, the inbox, and how a file becomes a take

**The inbox.** The Mac app watches two folders from launch (`InboxWatcher`):

- `~/Library/Mobile Documents/com~apple~CloudDocs/Mr. Roboto/Inbox` (iCloud Drive; `~/Music/Mr. Roboto/Inbox`
  when the Mac has no iCloud Drive) — every audio file that lands there.
- `~/Downloads` — only files named `roboto-capture…`, which is what AirDrop from the phone leaves there.

A file is taken when two looks three seconds apart see the same size (iCloud materialises files in
pieces). Taken files move to `Done/` beside the inbox.

**What the name says.** `roboto-capture--<song>--<section>--<pass>--<stamp>.m4a`, spaces as `_`.

- a song the library holds + a section → a take on that song, at the section's first bar, pass as
  given or the next; on the open song it lands live, on another song it is written into the package.
- a song the library does not hold, or no name at all → an idea in the library, with the file name
  in its note.

**Roboto Capture** (`Capture/`, an xcodegen project; `make capture` generates and builds it for the
simulator). One screen: song and section, the button, the level, the captures with a share button.
Captures live in the app's Documents (Files › On My iPhone › Roboto Capture). AirDrop a capture to
the Mac and the inbox takes it. A device build is yours: set `DEVELOPMENT_TEAM` in `project.yml`.
