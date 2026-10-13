import SwiftUI

/// Record, on a surface the controller records into: the Grid, the Piano roll, the Chords sheet.
///
/// Pressed, the controller is the surface's — it sounds the surface's own kit, bass or instrument,
/// whatever the transport bar's MIDI switch says — and what is played lands on the surface as it is
/// played. Pressed again, or at the section's end, the take is an edit like any other: one step of
/// ⌘Z, kept a moment later. Before it, a controller could only be played in from the transport bar,
/// as a new part, and nothing on these surfaces said they could take anything from it.
struct TakeButton: View {
    let midi: MIDIControl
    let target: any TakesFromController
    /// What a take does on this surface, for the tooltip.
    let help: String
    /// What the surface has to say while it takes — the chord just written — when it has a line.
    var line: String? = nil

    var body: some View {
        let isOn = midi.isTaking(into: target.surfaceID)
        HStack(spacing: 8) {
            Button {
                Task { await midi.record(into: target) }
            } label: {
                StudioChip(tone: isOn ? .danger : .plain) {
                    HStack(spacing: 5) {
                        Image(systemName: isOn ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Design.Palette.danger)
                        ChipText(isOn ? "Stop" : "Record MIDI", isOn: isOn)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isOn ? "Stop, and keep what you played" : help)
            .accessibilityLabel(isOn ? "Stop recording into \(target.takeName)" : "Record the controller into \(target.takeName)")
            if let status = status(isOn: isOn) {
                // Whole or not at all: on a narrow bench the line gives way to the surface's own
                // header, rather than leaving a lone "…" beside the button.
                ViewThatFits(in: .horizontal) {
                    Text(status)
                        .font(Design.Typography.ui(11.5))
                        .foregroundStyle(isOn ? Design.Palette.inkSecondary : Design.Palette.inkTertiary)
                        .lineLimit(1)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
        }
        // A controller plugged in is listed whatever the switch says, so this can say whether there
        // is one to record.
        .onAppear { midi.connectIfNeeded() }
    }

    private func status(isOn: Bool) -> String? {
        if isOn {
            if let line { return line }
            let count = midi.takeNotes
            return target.takesInTime
                ? (count == 0 ? "Recording — play along" : "Recording · \(count) note\(count == 1 ? "" : "s")")
                : "Play a chord: it is written as the next bar"
        }
        if let line { return line }
        return midi.sources.isEmpty ? "No controller connected" : nil
    }
}
