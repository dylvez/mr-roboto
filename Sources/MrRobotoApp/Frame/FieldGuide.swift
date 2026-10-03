import Instrument
import SwiftUI

/// Help ▸ Mr. Roboto Field Guide: every idiom, how they chain, and what each surface is for.
///
/// The same content as the primers and the path's tooltips, gathered in one place and drawn from the
/// same sources (`WorkPath`, `PathStep.Kind.meaning`, `Primer`), so the guide cannot drift from what
/// the frame actually says.
enum FieldGuide {

    struct Entry: Identifiable {
        let word: String
        let meaning: String
        var id: String { word }
    }

    static let glyphs: [String: String] = ["Library": "album", "Song": "song", "Version": "version",
                                           "Form": "record", "Section": "section", "Slice · Pad": "chop",
                                           "Feel": "feel", "Sample": "idea", "Critic": "check"]

    /// The words that are not steps or surfaces, in the order you tend to meet them.
    static let words: [Entry] = [
        Entry(word: "Library", meaning: "Everything saved: songs, albums, imported records, your samples, and ideas that belong to no song yet."),
        Entry(word: "Set aside", meaning: "A part taken out of the song without deleting it: out of every section that played it, off the Mixer and out of Structure, and not suggested by the band. Right-click it in Parts and choose Set Aside; it waits under Set aside at the bottom of Parts, and a click brings it back into the sections it left. A chop the band cuts only to read — a stem's hits, mapped — is set aside as reference from the start."),
        Entry(word: "Crate", meaning: "The library's Records: audio brought in as raw material, and no song made of it. File ▸ Import Records… (⌘I) takes any number of files; each is read for its key, tempo and bars and, if you ask, separated into its stems, one at a time in the background while you work — the header says how far. A record's row opens to its stems, each with how much of the record it is and where in it it plays; drag one onto the song or a section to bring it in through Sources, or start a song from the record. Bar lines a tracker misread are corrected from the row's Its Grid: half or double the tempo, move the downbeat a beat, or take the second tracker's grid; Fit again on Sources then tightens what came from it to the new bars."),
        Entry(word: "Song", meaning: "The document you work in. It keeps every version ever made for it, and its sections in order."),
        Entry(word: "Part", meaning: "One musical thing that changes over time — the drums stem, a chop, a groove. The Parts region lists them by stage, and each surface's title is a menu of the parts it works on: pick another groove in the Grid, or the tune in the Piano roll, and the surface turns to it, keeping what you did first. New groove, New bass line, New melody, New progression and New lyric start one from nothing."),
        Entry(word: "Version", meaning: "A snapshot of a part that never changes. It records who made it, from what, and how. An edit adds one; nothing is overwritten."),
        Entry(word: "Form", meaning: "The record's own intro, verse and chorus, as the analysis heard them. Not the same as your sections."),
        Entry(word: "Section", meaning: "A stretch of your song, such as “Verse, 8 bars”, naming the parts that play in it. A part's newest version is what sounds, so keeping a new take is heard where the old one was. Double-click a section in the transport to play from it."),
        Entry(word: "Playing", meaning: "How the chords are played, chosen on the Chords surface under the instrument: Played is the rhythm they are struck in — held, stabs, off-beats, backbeat, pushes, arpeggio, quarters, eighths, boom-chick, bossa — and Voiced is where the notes of each chord sit. Close is the chord as written; voice-led puts each chord in the inversion nearest the last, so the voices move by a step or stay; spread puts the root and fifth low and the colours above; rootless leaves the root to the bass. No voicing puts two notes a semitone apart when the chord can be played without. The chords stay chords: what changes is what is heard."),
        Entry(word: "Develop", meaning: "The loop, arranged into a song in one move: on the Structure surface, in the File menu (⇧⌘D), in the band's question, or by asking the band. The form is the song's own once you have arranged one, else its genre's usual one, else a verse-and-hook form. Each section then plays the loop its own way — the drums thinned for an intro, no kick under a breakdown, a roll through a build, a layer on top for a hook, the chords held where the song stands still, a bridge with chords of its own and the bass written to them — with a level of its own, and the master is brought to the loudness the genre is delivered at. Put it back undoes it."),
        Entry(word: "Variation", meaning: "A part played another way for a section: Thinned drums, Held bass, the tune an octave up. It is a part of its own, so a section names it, the Grid or the Piano roll edits it, and one you have changed by hand is never written over. It sounds through the strip, the machine and the instrument of the part it came from, so the Mixer still has one fader for the drums. A section plays a part or one of its variations, not both."),
        Entry(word: "Intensity", meaning: "How much is happening in a section, from the way in to where the song arrives: the line along the foot of each block on the Structure surface, set when a song is developed. Less and More on a section take it down or up a step — the drums a rung, then the bass and the tune, and its levels with them — and leave the rest of the song alone. Compare with before plays the section as it is against how it stood, and taking the earlier one puts it back."),
        Entry(word: "Slice · Pad", meaning: "A slice is the span between two markers in a chop; its pad plays it."),
        Entry(word: "Feel", meaning: "A named timing template (Boom-Bap Pocket, Dilla, Trip-Hop…). A groove is a feel you have made your own."),
        Entry(word: "Swing", meaning: "How late the offbeats land, on the MPC's 50–75% scale."),
        Entry(word: "Sample", meaning: "A one-shot or loop in your library. A piece cut from a stem is a chop; Save to Samples keeps it with its slices, tempo and source."),
        Entry(word: "Keeping", meaning: "Edits keep themselves: a moment after you stop, what is on a surface becomes a version in the song, and play, save and closing keep it at once. ⌘Z steps a surface back through its edits; right-click a part in Parts to go back a version; the song's tempo, key and meter are put back from their popover. Making something new — a groove from a chop, a comp from takes — is a button."),
        Entry(word: "What next", meaning: "Someone in the band always asks what you want to do next — the Director with no song open, the member whose step it is after that — at the top of the Band column, in the middle of an empty bench, or in the dock. The answers are ranked by the order the work goes in, what you just did, and what you usually choose at that point, marked Your usual. × on an answer offers it less there from now on; ⌘] takes the first; Surfaces ▸ Forget My Usual Choices starts over."),
        Entry(word: "Heard", meaning: "Every surface says whether its part plays in the song, and where. When it does not — a part in no section, an older groove in a song not yet arranged — it says why, and offers the one move that fixes it."),
        Entry(word: "Controller", meaning: "A MIDI keyboard or pad kit. Pick Kit, Bass or Keys beside the transport and it plays that instrument now. Press the record circle beside it (⌥⌘R) to play in against the song, a bar counted in, with no microphone needed; while the Booth records, the controller is captured too. What you play lands as a groove, a bass line or a melody on the section."),
        Entry(word: "Instrument", meaning: "What the chords and the tune play on, chosen on the Chords surface and in the Piano roll: \(InstrumentVoiceSpec.all.count) built in, by family — keys, organs, mallets and bells, guitars, basses, plucked and bowed strings, pads, winds, brass and synths. File ▸ Import Instrument… brings in an SFZ pack; its samples are copied into the library and it is listed with its family, among the recorded ones, or under Imported when its name does not say what it is. The bass has \(BassVoiceSpec.all.count) sounds of its own, played and synth, in the Piano roll, and can play an imported instrument that reaches low enough: a plucked contrabass, a recorded electric bass."),
        Entry(word: "Machine", meaning: "The drum kit a groove plays on, chosen in the Grid, by kind: drum machines (the TR-808 and TR-909, modelled from their circuits, the LinnDrum from its sampling, and the CR-78, TR-606, TR-707, DMX and Simmons built from them), samplers (SP-1200, MPC60), acoustic kits (studio, jazz brushes, rock, funk, vintage) and styles (trap, lo-fi). All of those are synthesized. File ▸ Import Drum Kit… brings in a kit of recordings from an SFZ laid out as General MIDI has it — kick on 36, snare on 38, hats on 42 and 46 — and lists it under Recorded kits; what it has no recording of, one of the app's own kits plays."),
        Entry(word: "Count-in", meaning: "Bars of click before the section the Booth records, so you come in on time. The transport's Click (⌘K) keeps a metronome going for the whole song."),
        Entry(word: "Idea", meaning: "A version kept in the library with no song around it. Keep as idea copies it out; dragging it into a song adopts it."),
        Entry(word: "Adopt", meaning: "Bring a library item into the open song as a new version of its own, audio copied into the song's package. The library copy stays."),
        Entry(word: "Album", meaning: "Songs in order, with delivery targets and a clearance state for every record their samples came from."),
        Entry(word: "Merge", meaning: "Two fragments in different keys or tempos brought to one: audio is shifted and stretched, a written part moves by arithmetic, a groove stays. The plan says the numbers; stitching makes a section."),
        Entry(word: "Clearance", meaning: "Whether a sampled record may be used: uncleared, pending, cleared, or not required. Said aloud, never assumed."),
        Entry(word: "Director", meaning: "Reads what you ask for, hands it to the right band member, and answers by opening a surface on real parts."),
        Entry(word: "Band", meaning: "The cast for this song: the Beatmaker for grooves and feels, the Sampler for chops, machines and sources, the Bassist for the low end, the Harmonist for the chords, the Melodist for the tune, the Lyricist for the words, the Producer for the whole, the Engineer for the mix and the master, and the Peer, who listens like a friend. Who is in the room is set on the Cast surface."),
        Entry(word: "Take", meaning: "What you sang or played in the Booth, on the bar you started it. With Keep going on, every pass through the section is a take of its own. Every take stays; the Takes surface flags them, bar by bar, and comps the best bars into one. Takes play in the song, where they were sung."),
        Entry(word: "Comp", meaning: "One version made from the best bar of each take, seams crossfaded. Hear the comp plays your choice before you make it; made, it stands in for its takes when the song plays."),
        Entry(word: "Mix", meaning: "A strip per part — level, pan, EQ, compressor, send — and a master with a target loudness and a ceiling. Every move you let go of is a version."),
        Entry(word: "Ending", meaning: "How the song ends: on its last bar, or fading over its last 2, 4 or 8 bars. Chosen on the Master tab, heard as the song plays to its end, and written into the master. A loop never ends, so it never fades."),
        Entry(word: "API key", meaning: "Your Anthropic API key, kept in the keychain: what the band runs on. Set it from the rail, under the field you ask the band from."),
        Entry(word: "Voice", meaning: "The lyrics this house has written, imported once (File ▸ Import Voice…). The Lyricist reads new words against them and names the images that repeat."),
        Entry(word: "Bible", meaning: "Everything a persona knows, as data: named lineages, measurable features, cited rules with thresholds, refusals, goldens and open questions. A document the method checks."),
        Entry(word: "Genre", meaning: "What the song is — house, boom-bap, salsa — set in the song's settings (the title in the header) or guessed from the feel its newest groove was written in. Each genre is a researched profile: its tempo, the numbers the band judges it by, the feels, bass players and sounds that fit, a typical form, and the records it comes from. The band then says both numbers: its own, and the genre's."),
        Entry(word: "Brief", meaning: "What the song is about, in a sentence, written in the song's settings (the title in the header) or told to the Director. The Producer holds every part to it, and says “No brief” until there is one."),
        Entry(word: "House call", meaning: "What this house decided on a persona's open question, by ear — the snare late, not early. Kept for every song, unless a song keeps its own, and apart from the evidence."),
        Entry(word: "Critic", meaning: "A rule that looks for one kind of problem. It flags and never fixes."),
        Entry(word: "Lever", meaning: "At most two controls the Director puts on a surface, so you can move the one thing it is asking about."),
    ]
}

struct FieldGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Wordmark(size: 15)
                    Text("Field Guide")
                        .font(Design.Typography.ui(24, weight: .semibold))
                    Text("Everything in a song descends from something else, and nothing has to come first. The bar above the bench holds every surface, each with how many of its parts the song has; open any of them, in any order. The band asks what next, and you can always say something else.")
                        .font(Design.Typography.prose(14))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SmallLabel("Surfaces", color: Design.Palette.accent)
                    ForEach(SurfaceKind.allCases, id: \.self) { kind in
                        let primer = Primer.text(for: kind)
                        entry(glyph: kind.glyph, word: primer.title, meaning: primer.body)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SmallLabel("Words", color: Design.Palette.accent)
                    ForEach(FieldGuide.words) { word in
                        entry(glyph: FieldGuide.glyphs[word.word].map { ($0, "circle") }, word: word.word, meaning: word.meaning)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 480, idealHeight: 720)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
    }

    private func entry(glyph: (name: String, symbol: String)?, word: String, meaning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let glyph { Glyph(name: glyph.name, symbol: glyph.symbol, size: 16) } else { Color.clear }
            }
            .foregroundStyle(Design.Palette.inkSecondary)
            .frame(width: 18, height: 18, alignment: .leading)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(word).font(Design.Typography.ui(14, weight: .semibold))
                Text(meaning)
                    .font(Design.Typography.prose(13.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
