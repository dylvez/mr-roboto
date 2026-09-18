import SwiftUI

/// The faint drawing behind each surface's header, so a surface is recognisable before its title is
/// read: a waveform with section brackets for the Record, cut lines and pads for the Chop lane, the
/// 808's four key colours for the Grid, knobs over a circuit trace for Sound, a ruler for Compare, a
/// flagged tick for Check.
///
/// Drawn rather than generated. The image model drew these as small centred objects rather than as
/// textures, and a texture wants to be exact anyway: crisp at any width, in the theme's own line
/// colour, and confined to the header's free space so the header's words and buttons always win.
struct SurfaceBand: View {
    let kind: SurfaceKind

    var body: some View {
        Canvas { context, size in
            let ink = Design.Palette.lineStrong
            switch kind {
            case .importRecord: record(context, size, ink)
            case .chopLane: chop(context, size, ink)
            case .grid: grid(context, size)
            case .sound: sound(context, size, ink)
            case .chords: chords(context, size, ink)
            case .pianoRoll: roll(context, size, ink)
            case .structure: structure(context, size, ink)
            case .album: album(context, size, ink)
            case .merge: merge(context, size, ink)
            case .compare: compare(context, size, ink)
            case .check: check(context, size, ink)
            }
        }
        // Soft at both ends, so it eases out of the title and into the buttons rather than butting
        // against them.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.25),
                                     .init(color: .black, location: 0.9),
                                     .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A deterministic waveform: the same shape every launch, so the band is a texture and not noise.
    private func waveform(width: CGFloat, midY: CGFloat, amplitude: CGFloat, step: CGFloat = 2) -> Path {
        var path = Path()
        var x: CGFloat = 0
        while x <= width {
            let t = Double(x)
            let envelope = 0.35 + 0.65 * abs(sin(t / 57)) * (0.6 + 0.4 * sin(t / 13.7))
            let v = sin(t / 2.3) * 0.6 + sin(t / 5.1) * 0.3 + sin(t / 0.9) * 0.1
            let h = CGFloat(abs(v * envelope)) * amplitude
            path.move(to: CGPoint(x: x, y: midY - h))
            path.addLine(to: CGPoint(x: x, y: midY + h))
            x += step
        }
        return path
    }

    private func record(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let mid = size.height * 0.6
        context.stroke(waveform(width: size.width, midY: mid, amplitude: size.height * 0.28), with: .color(ink), lineWidth: 1)
        // Section brackets along the top, a form's worth of them.
        var brackets = Path()
        let widths: [CGFloat] = [0.12, 0.2, 0.14, 0.2, 0.16, 0.18]
        var x: CGFloat = 0
        for w in widths {
            let span = w * size.width
            brackets.move(to: CGPoint(x: x + 3, y: 6))
            brackets.addLine(to: CGPoint(x: x + 3, y: 2))
            brackets.addLine(to: CGPoint(x: x + span - 3, y: 2))
            brackets.addLine(to: CGPoint(x: x + span - 3, y: 6))
            x += span
        }
        context.stroke(brackets, with: .color(ink), lineWidth: 1)
    }

    private func chop(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let mid = size.height * 0.42
        context.stroke(waveform(width: size.width, midY: mid, amplitude: size.height * 0.24), with: .color(ink), lineWidth: 1)
        let spacing: CGFloat = 46
        var x: CGFloat = spacing / 2
        var index = 0
        while x < size.width {
            var cut = Path()
            cut.move(to: CGPoint(x: x, y: 4))
            cut.addLine(to: CGPoint(x: x, y: size.height - 14))
            context.stroke(cut, with: .color(Design.Palette.accent.opacity(0.45)), lineWidth: 1)
            let pad = CGRect(x: x + spacing / 2 - 4, y: size.height - 11, width: 8, height: 6)
            let lit = index % 5 == 2
            context.fill(Path(roundedRect: pad, cornerRadius: 1),
                         with: .color(lit ? Color(red: 0.976, green: 0.498, blue: 0.137).opacity(0.55) : ink))
            x += spacing
            index += 1
        }
    }

    /// The 808's step keys: red-orange, orange, yellow, cream, four to a group.
    private func grid(_ context: GraphicsContext, _ size: CGSize) {
        let colours: [Color] = [Color(red: 0.91, green: 0.30, blue: 0.18), Color(red: 0.976, green: 0.498, blue: 0.137),
                                Color(red: 0.95, green: 0.76, blue: 0.19), Color(red: 0.93, green: 0.90, blue: 0.81)]
        let key = CGSize(width: 12, height: 14)
        let gap: CGFloat = 6
        var x: CGFloat = 4
        var index = 0
        while x < size.width {
            let colour = colours[(index / 4) % 4]
            let rect = CGRect(x: x, y: (size.height - key.height) / 2, width: key.width, height: key.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(colour.opacity(0.18)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(colour.opacity(0.3)), lineWidth: 0.75)
            x += key.width + gap + (index % 4 == 3 ? 6 : 0)
            index += 1
        }
    }

    private func sound(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let radius: CGFloat = 6
        let y = size.height * 0.36
        var x: CGFloat = 14
        var index = 0
        while x < size.width {
            context.stroke(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(ink), lineWidth: 1)
            let angle = -2.3 + Double(index % 7) * 0.62
            var pointer = Path()
            pointer.move(to: CGPoint(x: x, y: y))
            pointer.addLine(to: CGPoint(x: x + CGFloat(cos(angle)) * radius, y: y + CGFloat(sin(angle)) * radius))
            context.stroke(pointer, with: .color(ink), lineWidth: 1)
            x += 40
            index += 1
        }
        // A circuit trace underneath: runs, steps and vias.
        var trace = Path()
        let base = size.height - 8
        trace.move(to: CGPoint(x: 0, y: base))
        var tx: CGFloat = 0
        var up = false
        while tx < size.width {
            tx += 34
            trace.addLine(to: CGPoint(x: tx, y: up ? base - 5 : base))
            tx += 5
            up.toggle()
            trace.addLine(to: CGPoint(x: tx, y: up ? base - 5 : base))
        }
        context.stroke(trace, with: .color(ink), lineWidth: 1)
    }

    /// Bar brackets with a chord's worth of stacked dots in each.
    private func chords(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        var path = Path()
        let barWidth: CGFloat = 56
        var x: CGFloat = 0
        var index = 0
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 4)); path.addLine(to: CGPoint(x: x, y: size.height - 4))
            for (i, dy) in [0, 5, 10, 14].enumerated() where i < 3 + index % 2 {
                let dot = CGRect(x: x + 10 + CGFloat(i) * 2, y: size.height - 8 - CGFloat(dy), width: 4, height: 3)
                context.fill(Path(ellipseIn: dot), with: .color(ink))
            }
            x += barWidth
            index += 1
        }
        context.stroke(path, with: .color(ink), lineWidth: 1)
    }

    /// Two lines converging on one: the merge.
    private func merge(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let mid = size.height / 2
        var upper = Path(), lower = Path(), joined = Path()
        var x: CGFloat = 0
        while x < size.width {
            upper.move(to: CGPoint(x: x, y: 4)); upper.addLine(to: CGPoint(x: x + 36, y: mid))
            lower.move(to: CGPoint(x: x, y: size.height - 4)); lower.addLine(to: CGPoint(x: x + 36, y: mid))
            joined.move(to: CGPoint(x: x + 36, y: mid)); joined.addLine(to: CGPoint(x: x + 64, y: mid))
            x += 72
        }
        context.stroke(upper, with: .color(ink), lineWidth: 1)
        context.stroke(lower, with: .color(ink), lineWidth: 1)
        context.stroke(joined, with: .color(Design.Palette.accent.opacity(0.7)), lineWidth: 2)
    }

    /// Tracks: numbered ticks of unequal length, like the back of a sleeve.
    private func album(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let widths: [CGFloat] = [48, 36, 60, 30, 54, 42]
        var x: CGFloat = 0
        var index = 0
        while x < size.width {
            let width = widths[index % widths.count]
            let y = size.height / 2
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: y)); $0.addLine(to: CGPoint(x: x + width, y: y)) },
                           with: .color(ink), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Design.Palette.accent))
            x += width + 10
            index += 1
        }
    }

    /// Section blocks of a form's proportions — a short intro, long verses, shorter hooks.
    private func structure(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let widths: [CGFloat] = [22, 64, 40, 64, 40, 28]
        var x: CGFloat = 0
        var index = 0
        while x < size.width {
            let width = widths[index % widths.count]
            let rect = CGRect(x: x, y: 5, width: width, height: size.height - 10)
            let path = Path(roundedRect: rect, cornerRadius: 2)
            if index % widths.count == 2 || index % widths.count == 4 {
                context.fill(path, with: .color(Design.Palette.accent.opacity(0.35)))
            }
            context.stroke(path, with: .color(ink), lineWidth: 1)
            x += width + 4
            index += 1
        }
    }

    /// Note bars at bass pitches, a kick tick under each beat.
    private func roll(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        let beat: CGFloat = 28
        var x: CGFloat = 2
        var index = 0
        let heights: [CGFloat] = [0.55, 0.35, 0.45, 0.6, 0.3, 0.5, 0.4]
        while x < size.width {
            let h = heights[index % heights.count]
            let width = index % 3 == 2 ? beat * 0.45 : beat * 0.85
            let rect = CGRect(x: x + 3, y: size.height * (1 - h) - 8, width: width, height: 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Design.Palette.accent.opacity(0.45)))
            if index % 2 == 0 {
                context.fill(Path(CGRect(x: x + 1, y: size.height - 6, width: 2, height: 5)), with: .color(ink))
            }
            x += beat
            index += 1
        }
    }

    private func compare(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        var ruler = Path()
        let base = size.height - 8
        ruler.move(to: CGPoint(x: 0, y: base))
        ruler.addLine(to: CGPoint(x: size.width, y: base))
        var x: CGFloat = 0
        var index = 0
        while x < size.width {
            let height: CGFloat = index % 10 == 0 ? 16 : (index % 5 == 0 ? 10 : 5)
            ruler.move(to: CGPoint(x: x, y: base))
            ruler.addLine(to: CGPoint(x: x, y: base - height))
            x += 8
            index += 1
        }
        context.stroke(ruler, with: .color(ink), lineWidth: 1)
    }

    private func check(_ context: GraphicsContext, _ size: CGSize, _ ink: Color) {
        var line = Path()
        let base = size.height - 8
        line.move(to: CGPoint(x: 0, y: base))
        line.addLine(to: CGPoint(x: size.width, y: base))
        let flagX = size.width * 0.82
        line.move(to: CGPoint(x: flagX, y: base))
        line.addLine(to: CGPoint(x: flagX, y: 6))
        context.stroke(line, with: .color(ink), lineWidth: 1)
        var flag = Path()
        flag.move(to: CGPoint(x: flagX, y: 6))
        flag.addLine(to: CGPoint(x: flagX + 18, y: 11))
        flag.addLine(to: CGPoint(x: flagX, y: 16))
        flag.closeSubpath()
        context.fill(flag, with: .color(Design.Palette.warn.opacity(0.35)))
    }
}
