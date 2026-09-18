import SongGraph
import SwiftUI

/// The cast: who is in the room for this song, what each owns and listens for first, and the
/// house calls. Reads the song through the app on every render; every change is a setting on the
/// song, not a version.
struct CastSurfaceView: View {
    let app: AppState

    private var roster: [any Persona] { Cast.standard.personas }
    private var inRoom: Set<String> {
        let ids = app.song?.cast ?? []
        return ids.isEmpty ? Set(roster.map(\.bible.id.rawValue)) : Set(ids)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            ForEach(roster, id: \.bible.id) { persona in
                row(persona)
            }
            // The open questions run long; the roster stays put and they scroll under it.
            ScrollView { houseCalls.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(app.song.map { "\($0.title)'s cast" } ?? "Cast").font(Design.Typography.prose(16, weight: .medium))
            Text("\(inRoom.count) of \(roster.count) in the room")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            if app.song?.cast?.isEmpty == false {
                Button("Everyone") { app.setCast([]) }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.accent)
            }
        }
    }

    private func row(_ persona: any Persona) -> some View {
        let bible = persona.bible
        let present = inRoom.contains(bible.id.rawValue)
        return HStack(alignment: .top, spacing: 12) {
            if let emblem = Art.emblem(forPersona: bible.name) {
                ArtImage(emblem, width: 44, height: 44)
                    .opacity(present ? 1 : 0.35)
            } else {
                Circle().fill(Design.Palette.panelAlt).frame(width: 44, height: 44)
                    .overlay(Text(String(bible.name.prefix(1))).font(Design.Typography.ui(16, weight: .semibold)))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(bible.name)
                        .font(Design.Typography.ui(14, weight: .semibold))
                        .foregroundStyle(present ? Design.Palette.ink : Design.Palette.inkTertiary)
                    Text(bible.lineages.map(\.name).joined(separator: " · "))
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .lineLimit(1)
                }
                Text(bible.owns)
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = bible.listensFor.first {
                    Text("Listens first for \(first.what.prefix(1).lowercased() + first.what.dropFirst())")
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(bible.rules.count) rules · \(bible.goldens.count) goldens · \(bible.openQuestions.count) open questions")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            Spacer()
            CastChip(present ? "In the room" : "Out", isOn: present) { toggle(bible.id) }
                .disabled(app.song == nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private func toggle(_ id: PersonaID) {
        var ids = inRoom
        if ids.contains(id.rawValue) { ids.remove(id.rawValue) } else { ids.insert(id.rawValue) }
        // Keep roster order, and an empty room is not a room: the last one stays.
        let ordered = roster.map(\.bible.id).filter { ids.contains($0.rawValue) }
        guard !ordered.isEmpty else { return }
        app.setCast(ordered.count == roster.count ? [] : ordered)
    }

    /// The open questions of everyone in the room, each with what the house chose, if it has.
    private var houseCalls: some View {
        let calls = Dictionary(uniqueKeysWithValues: (app.song?.houseCalls ?? []).map { ($0.question, $0) })
        let questions = roster.filter { inRoom.contains($0.bible.id.rawValue) }.flatMap { persona in
            persona.bible.openQuestions.map { (persona.bible.name, $0) }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("HOUSE CALLS").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
            if questions.isEmpty {
                Text("Nobody in the room has an open question.")
                    .font(Design.Typography.ui(12, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(Array(questions.enumerated()), id: \.offset) { _, entry in
                let (name, question) = entry
                let call = calls[question.id]
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name) · \(question.question)")
                            .font(Design.Typography.ui(12.5, weight: .medium))
                            .foregroundStyle(Design.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(call.map { "This house: \($0.choice), \($0.decidedOn) — \($0.how)" } ?? "Not decided: the bible's own reading stands.")
                            .font(Design.Typography.ui(11, weight: .regular))
                            .foregroundStyle(call == nil ? Design.Palette.inkTertiary : Design.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    CastChip("Encoded", isOn: call?.choice == "encoded") {
                        app.recordHouseCall(question: question.id, choice: .encoded, how: "by ear, on the Cast surface")
                    }
                    CastChip("Alternative", isOn: call?.choice == "alternative") {
                        app.recordHouseCall(question: question.id, choice: .alternative, how: "by ear, on the Cast surface")
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

private struct CastChip: View {
    let title: String
    var isOn = false
    let action: () -> Void
    init(_ title: String, isOn: Bool = false, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panel,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}
