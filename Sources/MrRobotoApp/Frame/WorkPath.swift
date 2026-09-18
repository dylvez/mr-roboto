import SongGraph
import SwiftUI

// MARK: - The path

/// Where you are in the work, as a row of steps: what is done, which one you are in, what is next.
///
/// The frame already said *what to do* — "What next" in the rail, the Next chip in the dock, a verb on
/// every ledger row — but never *where you are*. Without that, the idioms were a vocabulary with no
/// grammar: a record, stems, a chop, a groove, dust, each opened from a different place, with nothing
/// saying they are one chain and that each is made out of the one before it. The path is that
/// sentence, drawn.
///
/// Which path is worked out from the song, never asked for. A song that grew from a record is a
/// **flip** (record → stems → chop → groove → dust → arrange); anything else is a **beat** made from
/// scratch (groove → kit → dust → arrange). Like `Guidance`, every step is a pure function of the
/// song graph, and a step only offers an action the frame could actually carry out.
public enum WorkPath: String, Sendable, Equatable {
    case flip
    case beat

    /// What the strip calls it, before the steps.
    public var title: String {
        switch self {
        case .flip: return "Flip"
        case .beat: return "Beat"
        }
    }

    /// One line on what this path makes, for the strip's tooltip.
    public var summary: String {
        switch self {
        case .flip:
            return "A record becomes a beat: its stems are separated, a bar of one is chopped, the chop is "
                + "re-grooved onto a feel, the groove gets dust, and the parts are arranged into sections."
        case .beat:
            return "A beat from scratch: a groove painted on a feel, a kit to play it, dust, and then the "
                + "parts arranged into sections."
        }
    }

    public var steps: [PathStep.Kind] {
        switch self {
        case .flip: return [.record, .stems, .chop, .groove, .chords, .bass, .dust, .arrange]
        case .beat: return [.groove, .chords, .bass, .kit, .dust, .arrange]
        }
    }

    /// A song that grew from a record, or that holds one, is a flip. Everything else is a beat.
    public static func of(_ song: Song) -> WorkPath {
        let seeded = song.seeds.contains {
            if case .importedRecord = $0.kind { return true }
            return false
        }
        return seeded || Guidance.take(in: song) != nil ? .flip : .beat
    }
}

/// One step on the path, as the strip draws it.
public struct PathStep: Identifiable, Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case record, stems, chop, groove, chords, bass, kit, dust, arrange

        /// A step the path passes through without insisting on: it is never "next". The chords are
        /// this — the bass writes to the key when none are stated — so the path does not stall on
        /// a lead sheet nobody needs yet.
        public var isOptional: Bool { self == .chords }

        /// The idiom's own word, as the ledger groups and the field guide use it.
        public var title: String {
            switch self {
            case .record: return "Record"
            case .stems: return "Stems"
            case .chop: return "Chop"
            case .groove: return "Groove"
            case .chords: return "Chords"
            case .bass: return "Bass"
            case .kit: return "Kit"
            case .dust: return "Dust"
            case .arrange: return "Arrange"
            }
        }

        /// The drawn glyph, `Resources/Glyphs/glyph-<name>.svg`.
        public var glyph: String {
            switch self {
            case .record: return "record"
            case .stems: return "stems"
            case .chop: return "chop"
            case .groove: return "groove"
            case .chords: return "section"
            case .bass: return "stem-bass"
            case .kit: return "sound"
            case .dust: return "dust"
            case .arrange: return "section"
            }
        }

        /// The SF Symbol drawn when the glyph file is missing.
        public var symbol: String {
            switch self {
            case .record: return "record.circle"
            case .stems: return "square.3.layers.3d"
            case .chop: return "scissors"
            case .groove: return "square.grid.4x3.fill"
            case .chords: return "music.note.list"
            case .bass: return "waveform.path"
            case .kit: return "dial.medium"
            case .dust: return "waveform.path.badge.minus"
            case .arrange: return "rectangle.split.3x1"
            }
        }

        /// What this step makes, one line, for the tooltip.
        public var meaning: String {
            switch self {
            case .record: return "The record: its waveform, key, tempo, bars and form."
            case .stems: return "The record split into drums, bass, vocals and other."
            case .chop: return "A bar cut from a stem, sliced on its hits, playable on pads."
            case .groove: return "Steps, swing and ghosts for each drum voice, on a feel."
            case .chords: return "The progression, as a lead sheet says it. Optional: with none, the bass is written to the key."
            case .bass: return "A bass line under the groove, in a named player's hands, read by the Bassist."
            case .kit: return "The drum sounds a groove plays: synthesized 808, 909 and Linn voices."
            case .dust: return "A chop or groove played through a machine (SP-1200, MPC60, tape, vinyl, radio)."
            case .arrange: return "Parts stitched into sections, and sections into a song."
            }
        }
    }

    public let kind: Kind
    /// How many of this step's parts the song holds. Zero is "not yet".
    public let count: Int
    /// The surface you are working in is this step's.
    public let isHere: Bool
    /// The first step not yet done that the frame can carry out: where the work goes next.
    public let isNext: Bool
    /// Set when the step is part of the path but has no surface yet; says when it arrives.
    public let later: String?
    /// What pressing the step does. Nil when there is nothing to open.
    public let action: SurfaceAction?

    public var id: Kind { kind }
    public var isDone: Bool { count > 0 }

    /// The tooltip: what the step is, then what pressing it will do.
    public var help: String {
        var lines = [kind.meaning]
        if let later { lines.append(later) }
        else if let action { lines.append(isDone ? "Open \(action.title) in \(action.surface.rawValue)." : "Start here: \(action.surface.rawValue).") }
        return lines.joined(separator: " ")
    }
}

extension WorkPath {

    /// The path for a song, with `active` as the surface you are in.
    ///
    /// `canPerform` is the frame's own gate (`AppState.canPerform`), passed in so this stays a pure
    /// function a test can drive with a plain closure.
    public static func steps(for song: Song, active: (kind: SurfaceKind, bound: [VersionID])?,
                             canPerform: (SurfaceAction) -> Bool) -> (path: WorkPath, steps: [PathStep]) {
        let path = WorkPath.of(song)
        let here = active.flatMap { stepKind(for: $0.kind, bound: $0.bound, in: song, path: path) }

        var steps: [PathStep] = []
        var nextTaken = false
        for kind in path.steps {
            let count = self.count(kind, in: song)
            let action = self.action(kind, in: song).flatMap { canPerform($0) ? $0 : nil }
            let isNext = !nextTaken && count == 0 && action != nil && !kind.isOptional
            if isNext { nextTaken = true }
            // No step is "later" today: arranging arrived with M2's Gate C. The field stays for
            // the next milestone's steps, which is what it was drawn for.
            steps.append(PathStep(kind: kind, count: count, isHere: kind == here, isNext: isNext,
                                  later: nil, action: action))
        }
        return (path, steps)
    }

    /// Which step a surface belongs to. The Sound surface is two steps: bound to a chop or a groove
    /// it is putting dust on it; bound to a sound, or to nothing, it is shaping the kit.
    static func stepKind(for surface: SurfaceKind, bound: [VersionID], in song: Song,
                         path: WorkPath) -> PathStep.Kind? {
        switch surface {
        case .importRecord: return .record
        case .chopLane: return .chop
        case .grid: return .groove
        case .chords: return .chords
        case .pianoRoll: return .bass
        case .structure: return .arrange
        case .album, .merge, .cast, .lyrics: return nil
        case .sound:
            let carries = bound.compactMap { song.version($0) }.contains { $0.kind.canCarryDegradation }
            if carries { return .dust }
            return path.steps.contains(.kit) ? .kit : nil
        case .compare, .check:
            return nil
        }
    }

    /// Parts, not versions: a chop and its dusty version are one chop.
    static func count(_ kind: PathStep.Kind, in song: Song) -> Int {
        func parts(_ versions: [PartVersion]) -> Int { Set(versions.map(\.partID)).count }
        switch kind {
        case .record: return Guidance.canShowRecord(in: song) ? 1 : 0
        case .stems: return Guidance.stems(in: song).count
        case .chop: return parts(Guidance.samples(in: song))
        case .groove: return parts(Guidance.grooves(in: song))
        case .kit: return parts(Guidance.sounds(in: song))
        case .chords: return parts(Guidance.progressions(in: song))
        case .bass: return parts(Guidance.basslines(in: song))
        case .dust: return parts(song.versions.filter { !$0.kind.degradation.isEmpty })
        case .arrange: return song.sections.count
        }
    }

    /// What pressing a step opens: its newest part if it has one, otherwise the way to make one.
    static func action(_ kind: PathStep.Kind, in song: Song) -> SurfaceAction? {
        switch kind {
        case .record:
            if Guidance.canShowRecord(in: song) {
                return SurfaceAction(surface: .importRecord, title: song.title, bound: Guidance.boundRecord(in: song))
            }
            return SurfaceAction(surface: .importRecord, title: song.title)

        case .stems:
            guard let take = Guidance.take(in: song) else { return nil }
            if Guidance.stems(in: song).isEmpty {
                return SurfaceAction(surface: .importRecord, title: song.title,
                                     bound: Guidance.boundRecord(in: song), prepare: .separateStems(of: take.id))
            }
            return SurfaceAction(surface: .importRecord, title: song.title, bound: Guidance.boundRecord(in: song))

        case .chop:
            if let chop = Guidance.samples(in: song).last {
                return SurfaceAction(surface: .chopLane, title: PartLabel.title(of: chop), bound: [chop.id])
            }
            // The drums first: they are what a chop is usually cut from. Then any stem with a bar.
            let stems = Guidance.stems(in: song)
            let ordered = stems.filter { Guidance.audio(of: $0).flatMap(PartLabel.instrument(of:)) == .drums }
                + stems.filter { Guidance.audio(of: $0).flatMap(PartLabel.instrument(of:)) != .drums }
            for stem in ordered {
                if let bar = Guidance.barToChop(of: stem, in: song) {
                    return SurfaceAction(surface: .chopLane, title: "Bar \(bar.number) of \(song.title)",
                                         prepare: .chopBar(of: stem.id))
                }
            }
            return nil

        case .groove:
            if let groove = Guidance.grooves(in: song).last {
                return SurfaceAction(surface: .grid, title: PartLabel.title(of: groove), bound: [groove.id])
            }
            // A chop re-grooves in the lane; with no chop, a groove is painted from scratch.
            if let chop = Guidance.samples(in: song).last {
                return SurfaceAction(surface: .chopLane, title: PartLabel.title(of: chop), bound: [chop.id])
            }
            return SurfaceAction(surface: .grid, title: "New groove")

        case .chords:
            if let progression = Guidance.progressions(in: song).last {
                return SurfaceAction(surface: .chords, title: PartLabel.title(of: progression), bound: [progression.id])
            }
            return SurfaceAction(surface: .chords, title: "Chords")

        case .bass:
            if let line = Guidance.basslines(in: song).last {
                return SurfaceAction(surface: .pianoRoll, title: PartLabel.title(of: line), bound: [line.id])
            }
            // A new line is written under a groove; with none there is nothing to sit under.
            if let groove = Guidance.grooves(in: song).last {
                return SurfaceAction(surface: .pianoRoll, title: "Bass under \(PartLabel.title(of: groove))", bound: [groove.id])
            }
            return nil

        case .kit:
            if let sound = Guidance.sounds(in: song).last {
                return SurfaceAction(surface: .sound, title: PartLabel.title(of: sound), bound: [sound.id])
            }
            return SurfaceAction(surface: .sound, title: "Kit")

        case .dust:
            // The newest dusty part if there is one, else the newest thing that could carry dust —
            // a groove before a chop, since a groove is further along.
            if let dusty = song.versions.last(where: { !$0.kind.degradation.isEmpty }) {
                return SurfaceAction(surface: .sound, title: PartLabel.title(of: dusty), bound: [dusty.id])
            }
            if let target = Guidance.grooves(in: song).last ?? Guidance.samples(in: song).last {
                return SurfaceAction(surface: .sound, title: PartLabel.title(of: target), bound: [target.id])
            }
            return nil

        case .arrange:
            // The form is arranged from parts that play; with none there is nothing to stitch.
            guard !song.sections.isEmpty || !Guidance.grooves(in: song).isEmpty
                || !Guidance.basslines(in: song).isEmpty || !Guidance.samples(in: song).isEmpty else { return nil }
            return SurfaceAction(surface: .structure, title: song.title)
        }
    }
}

// MARK: - The strip

/// The path, drawn in the header between the song's name and its buttons.
///
/// Four looks, so the state reads without reading: **done** is ink with a count, **here** is filled
/// with the accent, **next** is outlined in the accent with an arrow, and **later** is dashed and
/// quiet. Not-yet steps with an action are plain outlines — pressable, just not suggested.
struct PathStrip: View {
    let app: AppState

    var body: some View {
        if let song = app.song, !song.versions.isEmpty || !song.seeds.isEmpty {
            let active = app.bench.active.map { (kind: $0.kind, bound: app.bound(for: $0.id)) }
            let result = WorkPath.steps(for: song, active: active, canPerform: app.canPerform)
            // Full words when the header has room; icons alone (named in their tooltips) when a narrow
            // window would otherwise push the song's name or the Save button off the edge.
            ViewThatFits(in: .horizontal) {
                strip(result, compact: false)
                strip(result, compact: true)
            }
        }
    }

    private func strip(_ result: (path: WorkPath, steps: [PathStep]), compact: Bool) -> some View {
        HStack(spacing: 4) {
            Text(result.path.title.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
                .help(result.path.summary)
                .padding(.trailing, 4)
            ForEach(Array(result.steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                StepChip(step: step, compact: compact) {
                    if let action = step.action { app.perform(action) }
                }
            }
        }
    }
}

private struct StepChip: View {
    let step: PathStep
    var compact = false
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: 5) {
                Glyph(name: step.kind.glyph, symbol: step.kind.symbol, size: 13)
                if !compact || step.isHere || step.isNext {
                    Text(step.kind.title)
                        .font(Design.Typography.ui(12, weight: step.isHere || step.isNext ? .semibold : .medium))
                }
                if step.isDone && !step.isHere {
                    if step.kind == .record {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Design.Palette.inkSecondary)
                    } else {
                        Text("\(step.count)")
                            .font(Design.Typography.numeric(10.5))
                            .foregroundStyle(Design.Palette.inkSecondary)
                    }
                }
                if step.isNext {
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: Design.Metric.hairline,
                                                             dash: step.later != nil ? [3, 2] : []))
            )
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(step.action == nil)
        .help(step.help)
        .accessibilityLabel("\(step.kind.title)\(step.isHere ? ", you are here" : "")\(step.isNext ? ", next" : "")")
    }

    private var foreground: Color {
        if step.isHere { return Design.Palette.panel }
        if step.isNext { return Design.Palette.accent }
        if step.later != nil { return Design.Palette.inkTertiary }
        return step.isDone ? Design.Palette.ink : Design.Palette.inkSecondary
    }

    private var background: Color {
        if step.isHere { return Design.Palette.accent }
        if step.isNext { return Design.Palette.accentSoft }
        return step.later != nil ? .clear : Design.Palette.panel
    }

    private var border: Color {
        if step.isHere || step.isNext { return Design.Palette.accent }
        if step.later != nil { return Design.Palette.lineStrong }
        return step.isDone ? Design.Palette.lineStrong : Design.Palette.line
    }
}
