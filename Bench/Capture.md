# Capture: the phone, the inbox, and how a file becomes a take

**The inbox.** The Mac app watches two folders from launch (`InboxWatcher`):

- `~/Library/Mobile Documents/com~apple~CloudDocs/Mr. Roboto/Inbox` (iCloud Drive; `~/Music/Mr. Roboto/Inbox`
  when the Mac has no iCloud Drive) — every audio file that lands there.
- `~/Downloads` — only files named `roboto-capture…`, which is what AirDrop from the phone leaves there.

A file is taken when two looks three seconds apart see the same size (iCloud materialises files in
pieces). Taken files move to `Done/` beside the inbox.

**What the name says.** `roboto-capture--<song>--<section>--<pass>--<stamp>[--<lead>].m4a`, spaces as `_`.

- a song the library holds + a section → a take on that song, at the section's first bar, pass as
  given or the next; on the open song it lands live, on another song it is written into the package.
- a song the library does not hold, or no name at all → an idea in the library, with the file name
  in its note.
- a lead → seconds at the head of the file before the section's first beat: the guide's count-in,
  plus the latency the phone measured. The inbox trims them off (`AppState.trimmed`) before the take
  goes in, so its first frame is the section's first beat. A lead as long as the file is refused.

**The guides.** File ▸ Export ▸ Guides for the Phone (`PhoneGuides`) renders every section of the open
song — its own takes left out, as the Booth leaves them out — with a count-in of the Booth's click in
front (the Booth's count-in setting, else one bar), as AAC into `Mr. Roboto/Guides/<Song>/<Section>.m4a`,
and writes the song into `Guides/guides.json` beside the other songs': title, tempo, meter, and for
each section its name, bars, file, count-in in bars and seconds, and length. Rendered again, the
song's entry and files are replaced, not added to.

**Roboto Capture** (`Capture/`, an xcodegen project; `make capture` generates and builds it for the
simulator). One screen. Choose the Mr. Roboto folder once — the Files picker, in iCloud Drive; kept as
a bookmark (`MacFolder`) — and the song and section are picked from the guides, the guide plays in
the headphones while the take is sung, and the take is copied into the Inbox when it stops. The
player and the recorder start on the same instant of the device's clock, so the lead in the name is
the count-in plus the session's output and input latency, and a take sung to the click lands on the
beat. The audio session allows Bluetooth over A2DP, not the hands-free profile: the guide reaches
the headphones at full quality and the take comes in on the phone's own microphone. Without the
folder, the song and section are typed, captures live in the app's Documents (Files › On My iPhone ›
Roboto Capture), and a share — AirDrop to the Mac — gets one to the inbox. A device build is yours:
set `DEVELOPMENT_TEAM` in `project.yml`.
