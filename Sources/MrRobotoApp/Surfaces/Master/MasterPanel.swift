import Performance
import SongGraph
import SwiftUI

// What the Master shows, drawn wherever the Master is: on the Master surface, and as the Mixer's
// Master tab. One view for both, so the two can never read differently — they used to be one
// surface's body, and a second copy for the tab would have been two sets of numbers to keep level.

/// The reading against the target, the spectrum, the levers and the Engineer's lines.
///
/// Lays itself out for the width it is given: the Engineer beside the numbers when there is room,
/// under them when there is not — at the bench's minimum the numbers alone take nearly all of it.
struct MasterPanel: View {
    @Bindable var model: MasterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readBar
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Design.Metric.gutter) {
                    measures
                    engineer.frame(minWidth: 220, idealWidth: 240, maxWidth: 320, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    measures
                    engineer.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            sectionsBlock
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // A reference picked last time is measured as the panel appears, so its balance is there
        // when the first reading lands.
        .task { await model.loadReference() }
    }

    // MARK: What was read, and reading it

    /// Which stretch the numbers describe, whether they still describe the mix, and the Read.
    private var readBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            scopeLine
            Spacer(minLength: 8)
            if let line = model.progressLine {
                ProgressView().controlSize(.small).tint(Design.Palette.accent)
                    .accessibilityLabel(line)
                Text(line)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(model.isReading ? "Reading…" : (model.reading == nil ? "Read the bounce" : "Read again")) {
                Task { await model.read() }
            }
            .font(Design.Typography.ui(12))
            .disabled(model.isReading)
            .help(readHelp)
            .fixedSize()
        }
    }

    /// What Read will measure, said before it is pressed.
    private var readHelp: String {
        "Bounces the whole song (\(model.scope.detail)) through the mix and reads it. A long song takes a moment."
    }

    @ViewBuilder
    private var scopeLine: some View {
        if let reading = model.reading {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MixLabel(reading.scope.label)
                Text("\(reading.scope.detail) · \(Self.duration(reading.seconds))")
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
                if model.isStale {
                    Text("· the mix moved since; read again")
                        .font(Design.Typography.ui(11))
                        .foregroundStyle(Design.Palette.warn)
                        .lineLimit(1)
                }
            }
            .help(model.isStale
                  ? "The numbers are of the whole song through the mix as it was when read. Something that changes the sound has moved since."
                  : "The numbers are of the whole song, every section in order: the loudness it will be delivered at.")
        } else if !model.isReading {
            Text("Not read yet. Read bounces the whole song, \(model.scope.detail).")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .lineLimit(1)
        }
    }

    /// "1:04", "0:31".
    static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: The numbers, the spectrum, the levers

    private var measures: some View {
        VStack(alignment: .leading, spacing: 12) {
            numbers
            spectrum
            levers
        }
    }

    private var numbers: some View {
        HStack(spacing: 10) {
            number("Integrated", model.reading.map { String(format: "%.1f", $0.observation.integratedLUFS) } ?? "—", unit: "LUFS",
                   off: model.reading.map { abs($0.observation.integratedLUFS - model.mix.master.targetLUFS) > 2 } ?? false)
            number("True peak", model.reading.map { String(format: "%.1f", $0.truePeakDBTP) } ?? "—", unit: "dBTP",
                   off: model.reading.map { $0.truePeakDBTP > model.mix.master.ceilingDBTP + 0.05 } ?? false)
            number("Crest", model.reading.map { String(format: "%.1f", $0.observation.crestDB) } ?? "—", unit: "dB", off: false)
            number("Tilt", model.reading.map { String(format: "%.0f", $0.observation.tiltDB) } ?? "—", unit: "dB", off: false)
            number("Top end", model.reading.map { String(format: "%.1f", $0.observation.bandwidthHz / 1000) } ?? "—", unit: "kHz", off: false)
        }
        // Dimmed once the mix has moved: still true of the mix they were read from, not of this one.
        .opacity(model.isStale ? 0.5 : 1)
    }

    private func number(_ label: String, _ value: String, unit: String, off: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MixLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Design.Typography.numeric(20, weight: .medium)).foregroundStyle(off ? Design.Palette.warn : Design.Palette.ink)
                Text(unit).font(Design.Typography.numeric(10)).foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .frame(width: 96, alignment: .leading)
        .padding(8)
        .background(off ? Design.Palette.warnSoft : Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        .accessibilityElement(children: .combine)
    }

    private var spectrum: some View {
        VStack(alignment: .leading, spacing: 4) {
            MixLabel("Spectrum · 40 Hz – 16 kHz")
            Canvas { context, size in
                let bars = model.reading?.spectrumDB ?? []
                guard !bars.isEmpty else {
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Design.Palette.panelAlt))
                    return
                }
                let width = size.width / CGFloat(bars.count)
                // The bars run through the music's colours from the lows to the highs — violet, blue,
                // teal, green, gold — and glow, the way a hardware analyser's do.
                let spectrumGradient = Gradient(colors: [Design.Palette.lane(4), Design.Palette.lane(1), Design.Palette.lane(3),
                                                         Design.Palette.lane(5), Design.Palette.lane(2)])
                var bodies = Path()
                for (i, dB) in bars.enumerated() {
                    let h = size.height * CGFloat(max(0, min(1, (dB + 60) / 60)))
                    let rect = CGRect(x: CGFloat(i) * width + 1, y: size.height - h, width: max(1, width - 2), height: h)
                    bodies.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
                }
                var glow = context
                glow.addFilter(.shadow(color: Design.Palette.lane(1).opacity(0.45), radius: 5))
                glow.fill(bodies, with: .linearGradient(spectrumGradient, startPoint: .zero,
                                                         endPoint: CGPoint(x: size.width, y: 0)))
            }
            .frame(maxWidth: 560)
            .frame(height: 110)
            .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .opacity(model.isStale ? 0.5 : 1)
            .accessibilityLabel("Spectrum of the last reading")
        }
    }

    private var levers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MixLabel("Levers")
                // Beside the label rather than after the sliders: three sliders already take the
                // width of the bench at its minimum.
                if let suggested = model.suggestedGainDB, abs(suggested - model.mix.master.gainDB) >= 0.05 {
                    Button(String(format: "Hit the target (%+.1f dB)", suggested)) { model.hitTheTarget() }
                        .font(Design.Typography.ui(12))
                        .help("Sets the master gain to what puts the last reading on the target, and keeps it.")
                }
            }
            HStack(spacing: 12) {
                lever("Target", value: model.mix.master.targetLUFS, range: -30 ... -6, format: "%.0f LUFS") { model.setTarget($0) }
                    .layoutPriority(1)
                lever("Ceiling", value: model.mix.master.ceilingDBTP, range: -12...0, format: "%.1f dBTP") { model.setCeiling($0) }
                lever("Gain", value: model.mix.master.gainDB, range: -24...24, format: "%+.1f dB") { model.setGain($0) }
            }
            ending
        }
    }

    /// How the song ends. Songs used to stop dead on the last bar's downbeat, in the transport and
    /// in the export alike; a fade is the ending most songs reach for.
    private var ending: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Ending").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkSecondary)
            SegmentedChoice(options: endings, selection: model.mix.master.fadeOutBars,
                            title: { (bars: Int?) in bars.map { "Fade \($0) bars" } ?? "Stop" },
                            help: { (bars: Int?) in
                                bars.map { "The last \($0) bars of the form fade to silence, as it plays to its end and in the master. A loop never ends, so it never fades." }
                                    ?? "The song stops on its last bar"
                            }) { model.setFadeOut(bars: $0) }
        }
    }

    /// Stop, then each fade on offer, in bars: nil is no fade.
    private var endings: [Int?] { [nil] + FadeOut.choices.map { Optional($0) } }

    private func lever(_ label: String, value: Double, range: ClosedRange<Double>, format: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkSecondary)
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in if !editing { model.endGesture() } }
                .controlSize(.small).tint(Design.Palette.accent).frame(width: 170)
                .accessibilityLabel("Master \(label.lowercased())")
                .help("\(label): heard while held, a mix version when let go.")
            Text(String(format: format, value)).font(Design.Typography.numeric(10)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    // MARK: The whole song, section by section

    /// A row per section of the form, in its own colour: loudness, crest, how far its 3-second
    /// loudness moves, and its energy in five bands against the whole song's — every row on one
    /// scale, so a fuller chorus stands taller. Then the balance beside the reference's, and the
    /// Peer on whether each hook lifts. All of it off the one bounce Read made.
    private var sectionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                MixLabel("Section by section")
                Spacer(minLength: 8)
                referencePicker
            }
            if let reading = model.reading {
                if reading.sections.isEmpty {
                    Text("The song has no form yet, so the whole song is its only section.")
                        .font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.inkTertiary)
                }
                sectionTable(reading)
                balance(reading)
                peer(reading)
            } else if !model.isReading {
                Text("Read the bounce and every section is read off it too: loudness, crest, spread and five bands.")
                    .font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.referenceError {
                Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
            }
        }
        // Dimmed once the mix has moved, as the numbers above are.
        .opacity(model.isStale ? 0.6 : 1)
    }

    /// What the mix is read against: nothing, a record in the crate, or another song.
    private var referencePicker: some View {
        HStack(spacing: 6) {
            if model.isMeasuringReference {
                ProgressView().controlSize(.small).tint(Design.Palette.accent)
                    .accessibilityLabel("Measuring the reference")
            }
            ChipMenu(referenceTitle) {
                MenuChoice("No reference", isOn: model.reference == nil, help: "Read the song on its own.") { model.setReference(nil) }
                let choices = model.referenceChoices
                let records = choices.filter { $0.kind == .record }, songs = choices.filter { $0.kind == .song }
                if !records.isEmpty {
                    Section("Records in the crate") {
                        ForEach(records) { choice in
                            MenuChoice(choice.title, isOn: model.reference == choice.reference, help: choice.detail) { model.setReference(choice.reference) }
                        }
                    }
                }
                if !songs.isEmpty {
                    Section("Songs in the library") {
                        ForEach(songs) { choice in
                            MenuChoice(choice.title, isOn: model.reference == choice.reference, help: choice.detail) { model.setReference(choice.reference) }
                        }
                    }
                }
            }
            .help("What the mix is read against: its balance is drawn beside the song's, and the Engineer says where a band is more than 3 dB off it. A record is read from its file; a song is bounced once and kept.")
        }
    }

    private var referenceTitle: String {
        guard let picked = model.reference else { return "No reference" }
        let name = model.referenceReading?.reference == picked ? model.referenceReading?.name
            : model.referenceChoices.first { $0.reference == picked }?.title
        return "Against \(name ?? "the reference")"
    }

    /// The rows: each section, then the whole song, then the reference's whole when it is read.
    private func sectionTable(_ reading: MasterModel.Reading) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                MixLabel("Section")
                MixLabel("At")
                MixLabel("LUFS").gridColumnAlignment(.trailing)
                MixLabel("Crest").gridColumnAlignment(.trailing)
                MixLabel("Spread").gridColumnAlignment(.trailing)
                MixLabel("20 Hz – 16 kHz")
            }
            ForEach(Array(reading.sections.enumerated()), id: \.offset) { _, row in
                sectionRow(row, title: row.name, at: Self.duration(row.startSeconds), hue: SectionHue.color(for: row.name))
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            // The song in the accent and the reference quiet, as the balance below draws them.
            sectionRow(reading.whole.sheet.whole, title: "Whole song", at: "", hue: Design.Palette.accent)
            if let reference = shownReference {
                sectionRow(reference.sheet.whole, title: reference.name, at: "", hue: Design.Palette.inkQuiet)
            }
        }
    }

    /// The reference as measured, while it is still the one picked.
    private var shownReference: ReferenceReading? {
        guard let measured = model.referenceReading, measured.reference == model.reference else { return nil }
        return measured
    }

    private func sectionRow(_ row: SectionMeter.Reading, title: String, at: String, hue: Color) -> some View {
        GridRow(alignment: .center) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(hue).frame(width: 4, height: 16)
                    .accessibilityHidden(true)
                // Its own width, so the grid's column takes the longest name whole; a record's long
                // title is cut here rather than squeezed there.
                Text(Self.clipped(title)).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.ink)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 90, alignment: .leading)
            Text(at).font(Design.Typography.numeric(11)).foregroundStyle(Design.Palette.inkTertiary)
            Text(row.integratedLUFS.map { String(format: "%.1f", $0) } ?? "—")
                .font(Design.Typography.numeric(12.5, weight: .medium)).foregroundStyle(Design.Palette.ink)
            Text(row.crestDB.map { String(format: "%.1f", $0) } ?? "—")
                .font(Design.Typography.numeric(11.5)).foregroundStyle(Design.Palette.inkSecondary)
            Text(row.spreadLU.map { String(format: "%.1f", $0) } ?? "—")
                .font(Design.Typography.numeric(11.5)).foregroundStyle(Design.Palette.inkSecondary)
            BandBars(levels: row.bandsDB, colour: hue)
                .frame(width: 100, height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(row, title: title))
        .help(Self.spoken(row, title: title))
    }

    /// A title cut to fit the table's first column: "Fisk Jubilee Singers - Swing Low Sw…".
    static func clipped(_ title: String, to length: Int = 30) -> String {
        title.count <= length ? title : String(title.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A row read out: "Coro: -13.2 LUFS, crest 11.4 dB, spread 3.1 LU; against the whole: 20–120 -6 dB, …".
    static func spoken(_ row: SectionMeter.Reading, title: String) -> String {
        var parts = [row.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "silent"]
        if let crest = row.crestDB { parts.append(String(format: "crest %.1f dB", crest)) }
        if let spread = row.spreadLU { parts.append(String(format: "spread %.1f LU", spread)) }
        let bands = zip(SectionMeter.bands, row.bandsDB).map { String(format: "%@ %.0f dB", $0.name, $1) }.joined(separator: ", ")
        return "\(title): " + parts.joined(separator: ", ") + "; against the whole: " + bands
    }

    /// The whole song's five bands beside the reference's, each against its own whole: where the
    /// song's balance and the reference's part.
    @ViewBuilder
    private func balance(_ reading: MasterModel.Reading) -> some View {
        let song = reading.whole.sheet.whole.bandsDB
        let reference = shownReference
        // Room over the bars for the tallest one's number.
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MixLabel(reference.map { "Balance · beside \($0.name)" } ?? "Balance · pick a reference to read it against")
                Spacer(minLength: 8)
                if reference != nil {
                    legend("This song", Design.Palette.accent)
                    legend("Reference", Design.Palette.inkQuiet)
                }
            }
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(Array(SectionMeter.bands.enumerated()), id: \.offset) { index, band in
                    VStack(spacing: 3) {
                        HStack(alignment: .bottom, spacing: 5) {
                            balanceBar(song[safe: index], colour: Design.Palette.accent)
                            if let theirs = reference?.sheet.whole.bandsDB[safe: index] {
                                balanceBar(theirs, colour: Design.Palette.inkQuiet)
                            }
                        }
                        .frame(height: 74, alignment: .bottom)
                        Text(band.name).font(Design.Typography.numeric(10)).foregroundStyle(Design.Palette.inkTertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.balanceLine(band: band.name, song: song[safe: index], reference: reference.flatMap { $0.sheet.whole.bandsDB[safe: index] }, name: reference?.name))
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// "2k–6k Hz: 15.2 dB under the whole, 8.1 in Mirror Ball, 1923".
    static func balanceLine(band: String, song: Double?, reference: Double?, name: String?) -> String {
        var line = "\(band) Hz: " + (song.map { String(format: "%.1f dB under the whole", -$0) } ?? "nothing")
        if let reference, let name { line += String(format: ", %.1f in %@", -reference, name) }
        return line
    }

    private func balanceBar(_ level: Double?, colour: Color) -> some View {
        let level = level ?? SectionMeter.floorDB
        // −48 dB under the whole is the floor of the drawing: a band that far down is a stub.
        let height = 74 * max(0.04, min(1, (level + 48) / 48))
        return VStack(spacing: 2) {
            Text(String(format: "%.0f", level)).font(Design.Typography.numeric(9.5)).foregroundStyle(Design.Palette.inkTertiary)
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 22, height: height)
        }
    }

    private func legend(_ title: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 9)
            Text(title).font(Design.Typography.ui(10.5)).foregroundStyle(Design.Palette.inkTertiary)
        }
        .accessibilityHidden(true)
    }

    /// The Peer, on whether each hook lifts off the verse before it.
    @ViewBuilder
    private func peer(_ reading: MasterModel.Reading) -> some View {
        if !reading.lifts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                MixLabel("The Peer")
                ForEach(Array(reading.lifts.enumerated()), id: \.offset) { _, lift in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(lift.holds ? Design.Palette.ok : Design.Palette.warn).frame(width: 6, height: 6).padding(.top, 5)
                            .accessibilityHidden(true)
                        Text(lift.says).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(lift.holds ? "Holds" : "Change"): \(lift.says)")
                }
            }
        }
    }

    // MARK: The Engineer

    private var engineer: some View {
        VStack(alignment: .leading, spacing: 6) {
            MixLabel("The Engineer")
            if let first = model.reading?.firstToChange {
                Text("Change first: \(first.says)")
                    .font(Design.Typography.ui(12.5, weight: .medium)).foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.reading != nil {
                Text("Nothing to change: every reading holds.").font(Design.Typography.ui(12.5, weight: .medium)).foregroundStyle(Design.Palette.emphasis)
            }
            ForEach(model.reading?.readings ?? []) { reading in
                HStack(alignment: .top, spacing: 6) {
                    // A reading that holds is green, "kept, fine"; one that does not, amber.
                    Circle().fill(reading.holds ? Design.Palette.ok : Design.Palette.warn).frame(width: 6, height: 6).padding(.top, 5)
                        .accessibilityHidden(true)
                    Text(reading.says).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(reading.holds ? "Holds" : "Change"): \(reading.says)")
            }
            if model.reading == nil {
                Text("Read the bounce and the Engineer says what holds and what to change first.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(model.isStale ? 0.6 : 1)
    }
}

/// The Master's last line: what was kept, or why not, and the export.
///
/// Apart from `MasterPanel` so a host can pin it under a scrolling panel, where the export stays
/// in reach however far down the Engineer runs.
struct MasterFooter: View {
    let model: MasterModel
    /// The frame, when the registry hands one over: what an export needs. A view built from its
    /// model alone (a render, a test) has none, and points at the menu instead.
    var app: AppState?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let error = model.lastError {
                    Text(error).foregroundStyle(Design.Palette.danger)
                } else if let note = model.lastNote {
                    Text("Kept: \(note)").foregroundStyle(Design.Palette.inkTertiary)
                } else {
                    Text("The target and the ceiling are \(model.targets.targetLUFS == -14 && model.targets.ceilingDBTP == -1 ? "the delivery defaults" : "the album's"); a lever let go of is a mix version.")
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
            }
            .font(Design.Typography.ui(11))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The export, from the surface that reads the master: the same call the File menu
            // makes. A view built from its model alone has no frame to ask and points at the menu.
            if let app {
                // Beside it, the same master as an MP3: the one to send rather than to keep.
                FrameButton(title: "MP3…", isEnabled: app.song != nil && app.busy == nil) {
                    MrRobotoApp.export(app, what: "Exporting the master as MP3…") { try await Export.masterMP3(app, to: $0) }
                }
                .help("The same master as a 320 kbps MP3, tagged with the title, the artist and the album with its cover. Asks where first.")
                .fixedSize()
                // The primary here: the master is what this tab exists to send somewhere.
                FrameButton(title: "Export master…", emphasis: .accent, isEnabled: app.song != nil && app.busy == nil) {
                    MrRobotoApp.export(app, what: "Exporting the master…") { try await Export.master(app, to: $0).wav }
                }
                .help("The whole song through the mix, limited at the ceiling, as a 24-bit WAV beside a report. Asks where first.")
                .fixedSize()
            } else {
                Text("Export from File ▸ Export ▸ Master…")
                    .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize()
            }
        }
    }
}

/// Five bars, one a band, from 48 dB under the whole up to the whole: a section's energy across
/// the spectrum on the scale every row of the Master's table shares.
struct BandBars: View {
    let levels: [Double]
    let colour: Color

    var body: some View {
        Canvas { context, size in
            let count = max(1, levels.count)
            let width = size.width / CGFloat(count)
            var bars = Path()
            for (i, level) in levels.enumerated() {
                let h = size.height * CGFloat(max(0.06, min(1, (level + 48) / 48)))
                bars.addRoundedRect(in: CGRect(x: CGFloat(i) * width + 1, y: size.height - h, width: max(1, width - 3), height: h),
                                    cornerSize: CGSize(width: 1.5, height: 1.5))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Design.Palette.panelAlt))
            context.fill(bars, with: .color(colour))
        }
        .accessibilityHidden(true)
    }
}
