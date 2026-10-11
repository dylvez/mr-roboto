import SongGraph
import SwiftUI

/// One stem of a record: its name, how much of the record it is, and where in it it plays.
struct StemRow: View {
    let stem: RecordStem
    let record: Record

    var body: some View {
        HStack(spacing: 6) {
            Text(stem.name.capitalized)
                .font(Design.Typography.ui(11.5))
                .foregroundStyle(Design.Palette.ink)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
            // Fainter the less of the record it is: a stem 30 dB down draws a quarter as dark.
            StemPresence(levels: stem.barLevels ?? [], strength: stem.relativeDB.map { max(0.25, min(1, 1 + $0 / 40)) } ?? 1)
                .frame(height: 12)
                .frame(maxWidth: .infinity)
            Text(stem.relativeDB.map { String(format: "%+.0f", $0) } ?? (stem.lufs == nil ? "—" : ""))
                .font(Design.Typography.numeric(10.5))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stem.name) stem of \(record.title), \(stem.relativeDB.map { String(format: "%.0f dB against the record", $0) } ?? "level unknown")")
    }

    private var help: String {
        var pieces = ["Drag onto the song or a section to bring it in through Sources."]
        if let relative = stem.relativeDB {
            pieces.append(String(format: "%.1f dB against the whole record%@.", relative,
                                 relative > -3 ? ": nearly all of it" : relative < -18 ? ": hardly there" : ""))
        }
        if let first = stem.barLevels.flatMap(RecordStems.firstPlayedBar) { pieces.append("It comes in at bar \(first + 1).") }
        return pieces.joined(separator: " ")
    }
}

/// A stem's level bar by bar: one tick per bar, taller where it is louder, absent where it rests.
struct StemPresence: View {
    let levels: [Double]
    var strength: Double = 1

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else {
                context.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)), with: .color(Design.Palette.line))
                return
            }
            let loudest = max(-60, levels.max() ?? -60)
            let width = size.width / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                // The top 36 dB below its loudest bar, so a quiet stem still draws its shape.
                let share = max(0, min(1, (level - (loudest - 36)) / 36))
                guard share > 0.02 else { continue }
                let height = max(1, size.height * CGFloat(share))
                let rect = CGRect(x: CGFloat(index) * width, y: size.height - height, width: max(0.8, width - 0.4), height: height)
                context.fill(Path(rect), with: .color(Design.Palette.inkSecondary.opacity(strength)))
            }
        }
        .accessibilityHidden(true)
    }
}
