import AppKit
import SwiftUI

/// "Mr. Roboto" in Plex Sans SemiBold, the full stop drawn as a lit step key.
struct Wordmark: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text("Mr")
            RoundedRectangle(cornerRadius: size * 0.05)
                .fill(AppIconArt.orange)
                .frame(width: size * 0.2, height: size * 0.2)
                .padding(.horizontal, size * 0.05)
                .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
            Text(" Roboto")
        }
        .font(Design.Typography.ui(size, weight: .semibold))
        .foregroundStyle(Design.Palette.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mr. Roboto")
    }
}

/// The app icon: a drum machine whose step keys make a face — two lit orange keys for eyes, a lit
/// bar for a mouth — under a knob and a display showing a waveform. Drawn in code on Apple's 1024
/// grid (an 824-point body, 100 in from each edge), so it is exact at every size, and set as the
/// Dock icon at launch. A packaged build would carry the same drawing in an asset catalog; the
/// PNG export for that is `FrameRenderTests`.
struct AppIconArt: View {
    static let orange = Color(red: 0.976, green: 0.498, blue: 0.137)
    static let blue = Color(red: 0.471, green: 0.663, blue: 1.0)
    static let graphite = Color(red: 0.078, green: 0.090, blue: 0.102)

    var body: some View {
        Canvas { context, size in
            let s = size.width / 1024
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            // Body.
            let body = Path(roundedRect: r(100, 100, 824, 824), cornerRadius: 185 * s, style: .continuous)
            context.fill(body, with: .linearGradient(Gradient(colors: [Color(red: 0.19, green: 0.21, blue: 0.24), Self.graphite]),
                                                     startPoint: CGPoint(x: 0, y: 100 * s), endPoint: CGPoint(x: 0, y: 924 * s)))
            context.stroke(Path(roundedRect: r(112, 112, 800, 800), cornerRadius: 175 * s, style: .continuous),
                           with: .color(.white.opacity(0.08)), lineWidth: 3 * s)

            // Knob, with its scale and a pointer.
            let knob = r(236, 196, 116, 116)
            context.fill(Path(ellipseIn: knob), with: .color(Color(red: 0.56, green: 0.59, blue: 0.62)))
            context.stroke(Path(ellipseIn: knob.insetBy(dx: -14 * s, dy: -14 * s)), with: .color(.white.opacity(0.25)), lineWidth: 4 * s)
            var pointer = Path()
            pointer.move(to: CGPoint(x: knob.midX, y: knob.midY))
            pointer.addLine(to: CGPoint(x: knob.midX - 34 * s, y: knob.midY - 34 * s))
            context.stroke(pointer, with: .color(Self.graphite), style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))

            // Display with a waveform.
            let display = r(412, 212, 376, 84)
            context.fill(Path(roundedRect: display, cornerRadius: 12 * s), with: .color(Color(red: 0.10, green: 0.14, blue: 0.20)))
            var wave = Path()
            for i in 0...60 {
                let x = display.minX + 18 * s + CGFloat(i) / 60 * (display.width - 36 * s)
                let y = display.midY + CGFloat(sin(Double(i) / 3.2) * (0.4 + 0.6 * sin(Double(i) / 19))) * 24 * s
                if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(wave, with: .color(Self.blue), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round, lineJoin: .round))

            // Sixteen keys, four by four. Row 2 carries the eyes; row 4's middle pair is the mouth.
            let key: CGFloat = 104, gap: CGFloat = 22, left: CGFloat = 271, top: CGFloat = 368
            for row in 0..<4 {
                for column in 0..<4 {
                    if row == 3 && column == 2 { continue }   // the mouth spans columns 1 and 2
                    let x = left + CGFloat(column) * (key + gap)
                    let y = top + CGFloat(row) * (key + gap)
                    let isEye = row == 1 && (column == 0 || column == 3)
                    let isMouth = row == 3 && column == 1
                    let rect = isMouth ? r(x, y + 26, key * 2 + gap, key - 52) : r(x, y, key, key)
                    // Unlit keys stay dark, so the lit ones read as a face and not as a keypad.
                    let fill: Color = isEye ? Self.orange : isMouth ? Self.blue : Color(red: 0.30, green: 0.33, blue: 0.37)
                    // A darker lip under each key, so they read as keys rather than tiles.
                    context.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 8 * s), cornerRadius: 14 * s),
                                 with: .color(.black.opacity(0.35)))
                    context.fill(Path(roundedRect: rect, cornerRadius: 14 * s), with: .color(fill))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The icon as an image, for the Dock.
    @MainActor
    static func image(size: CGFloat = 1024) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconArt().frame(width: size, height: size))
        renderer.scale = 1
        return renderer.nsImage
    }
}

/// Roboto Capture's icon, the Mac icon's sibling: the same graphite and the same two lit orange keys
/// for eyes, a record button for a nose, and for a mouth a display with a take on it — a waveform
/// coloured the way a song's form is, an intro's green, a verse's blue, a hook's gold, a bridge's
/// magenta, an outro's teal — glowing in the hook's gold, as Vibrant's display glows in the colour
/// of the section playing. Full bleed on the 1024 grid: iOS rounds the corners itself.
///
/// Drawn here, beside its sibling, so the two share a hand; `FrameRenderTests` exports it into the
/// phone's asset catalog (`Capture/RobotoCapture/Assets.xcassets`).
struct CaptureIconArt: View {
    /// The take, bar by bar: its height out of one and the section it is in, by lane.
    static let take: [(height: Double, lane: Int)] = [
        (0.28, 5), (0.5, 5), (0.36, 5),
        (0.62, 1), (0.84, 1), (0.55, 1),
        (1.0, 2), (0.78, 2), (0.94, 2),
        (0.6, 6), (0.74, 6),
        (0.46, 3), (0.3, 3),
    ]

    var body: some View {
        Canvas { context, size in
            let s = size.width / 1024
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            func hex(_ value: UInt32) -> Color {
                Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                      blue: Double(value & 0xff) / 255)
            }

            // The body, the Mac icon's graphite, to the edge.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Color(red: 0.19, green: 0.21, blue: 0.24), AppIconArt.graphite]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Two lit keys for eyes, each with the darker lip that makes it a key.
            for x in [232.0, 636.0] {
                let eye = r(x, 214, 156, 156)
                context.fill(Path(roundedRect: eye.offsetBy(dx: 0, dy: 10 * s), cornerRadius: 24 * s), with: .color(.black.opacity(0.4)))
                context.fill(Path(roundedRect: eye, cornerRadius: 24 * s), with: .color(AppIconArt.orange))
            }

            // A record button for a nose: the red, in a ring.
            let nose = r(458, 422, 108, 108)
            context.stroke(Path(ellipseIn: nose), with: .color(Color(red: 0.56, green: 0.59, blue: 0.62)), lineWidth: 10 * s)
            context.fill(Path(ellipseIn: nose.insetBy(dx: 20 * s, dy: 20 * s)), with: .color(hex(SharedPalette.Vibrant.danger)))

            // The mouth: a display with the take on it, glowing in the hook's gold.
            let display = r(150, 590, 724, 250)
            let gold = hex(SharedPalette.Vibrant.lanes[SharedPalette.PartLane.groove])
            context.drawLayer { glow in
                glow.addFilter(.shadow(color: gold.opacity(0.55), radius: 34 * s))
                glow.fill(Path(roundedRect: display, cornerRadius: 34 * s), with: .color(hex(SharedPalette.Vibrant.plate)))
            }
            context.stroke(Path(roundedRect: display.insetBy(dx: 2 * s, dy: 2 * s), cornerRadius: 32 * s),
                           with: .color(gold.opacity(0.6)), lineWidth: 4 * s)
            let bar: CGFloat = 34, gap: CGFloat = 16
            let count = CGFloat(Self.take.count)
            let left = display.minX / s + (display.width / s - (count * bar + (count - 1) * gap)) / 2
            let tallest = display.height / s - 76
            for (index, step) in Self.take.enumerated() {
                let height = max(bar, tallest * step.height)
                let x = left + CGFloat(index) * (bar + gap)
                let y = display.midY / s - height / 2
                let hue = hex(SharedPalette.Vibrant.lanes[step.lane])
                context.drawLayer { lit in
                    lit.addFilter(.shadow(color: hue.opacity(0.7), radius: 10 * s))
                    lit.fill(Path(roundedRect: r(x, y, bar, height), cornerRadius: bar / 2 * s), with: .color(hue))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
