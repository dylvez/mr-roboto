import SongGraph
import SwiftUI

// One rule for keeping, on every surface that edits a part.
//
// There used to be three. The Grid, Chords, the Piano roll, Lyrics and Structure held a draft until
// you pressed Keep; Sound and the Mixer kept on every let-go; the Chop lane had two Keeps that had
// to be pressed in order. A person had to know which surface they were on to know whether their
// work was safe, and a draft that was never kept was never heard in the song.
//
// Now: **an edit keeps itself.** A surface keeps what is on screen a moment after the last edit
// settles, and at once whenever the frame is about to read the song — play, save, switching song,
// closing the surface, quitting. Every keep is a version, so nothing is overwritten, and ⌘Z steps
// the surface back through its own edits. **Making something new is still a button** — a groove
// out of a chop, a comp out of takes, a candidate taken from a Compare — because that is a
// decision, not an edit.

/// A surface model that keeps its work as it goes.
@MainActor
public protocol KeepsAsItGoes: AnyObject {
    /// What is on screen differs from the last version kept.
    var hasUnkeptChanges: Bool { get }
    /// Keeps what is on screen, now, if there is anything to keep. False when the song refused it.
    @discardableResult
    func keepNow() -> Bool
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func undo()
    func redo()
    /// What the status line says.
    var keepLine: KeepLine { get }
}

/// Where a surface's work stands, as its status line says it.
public enum KeepLine: Equatable, Sendable {
    /// Nothing made yet, or opened on a version and not touched.
    case untouched
    /// Edited; the keep is a moment away.
    case pending
    /// In the song as this version.
    case kept(title: String)
    /// The song would not take it. The surface still holds it and says why.
    case refused(String)
}

// MARK: - Undo

/// A surface's own edits, back and forward.
///
/// Held as whole states rather than as operations: every model here is small enough to copy, and a
/// state can never be half-undone. Capped, because an evening in the Grid should not hold ten
/// thousand copies of a pattern.
public struct EditHistory<State: Equatable>: Sendable where State: Sendable {
    private var past: [State] = []
    private var future: [State] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Call with the state *before* an edit. An edit that changes nothing is not remembered.
    public mutating func record(_ before: State, now after: State? = nil) {
        if let after, after == before { return }
        if past.last == before { return }
        past.append(before)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    /// The state to go back to, given where the surface is now.
    public mutating func undo(from current: State) -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    public mutating func redo(from current: State) -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    public mutating func clear() {
        past.removeAll()
        future.removeAll()
    }
}

// MARK: - The moment after an edit

/// Keeps a surface's work a moment after its last edit. Every edit resets the moment, so a burst
/// of steps painted, or a phrase typed, is one version and not forty.
@MainActor
public final class AutoKeep {
    /// How long an edit settles before it is kept. Nil keeps only when the frame asks (tests).
    public var delay: Duration?
    private var pending: Task<Void, Never>?

    /// The default for every surface. Long enough that a drag or a phrase is one version; short
    /// enough that pressing play a breath later hears it — and play keeps first anyway.
    public static let standardDelay: Duration = .milliseconds(1_500)

    public init(delay: Duration? = AutoKeep.standardDelay) { self.delay = delay }

    public var isScheduled: Bool { pending != nil }

    /// Asks for `keep` to run once the edits stop.
    public func schedule(_ keep: @escaping @MainActor () -> Void) {
        pending?.cancel()
        guard let delay else { pending = nil; return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            keep()
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}

// MARK: - The status line

/// What every editing surface shows where its Keep button used to be: whether the work is in the
/// song, and the way back through it.
struct KeepStatusBar: View {
    let line: KeepLine
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    /// Pressed on a refusal: try the keep again.
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ChipButton(systemImage: "arrow.uturn.backward", help: "Undo the last edit here (⌘Z)",
                       isEnabled: canUndo, action: undo)
                .accessibilityLabel("Undo")
            ChipButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)",
                       isEnabled: canRedo, action: redo)
                .accessibilityLabel("Redo")
            status
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch line {
        case .untouched:
            Text("Edits here keep themselves.")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .help("A moment after you stop, what is on screen becomes a version in the song. Play, save and closing keep it at once.")
        case .pending:
            Text("Keeping…")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .help("Kept a moment after the last edit, or at once when you press play.")
        case .kept(let title):
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(Design.Typography.ui(9.5, weight: .bold))
                Text("In the song as \(title)")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Design.Palette.inkSecondary)
            .help("Every keep is a version. The one before it is a step back in Parts, and ⌘Z steps back here.")
            .accessibilityElement(children: .combine)
        case .refused(let why):
            HStack(spacing: 6) {
                Text(why)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .lineLimit(2)
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(.plain)
                        .font(Design.Typography.ui(11.5, weight: .medium))
                        .foregroundStyle(Design.Palette.accent)
                }
            }
        }
    }
}

extension KeepsAsItGoes {
    /// The status bar for this model.
    var statusBar: KeepStatusBar {
        KeepStatusBar(line: keepLine, canUndo: canUndo, canRedo: canRedo,
                      undo: { [weak self] in self?.undo() }, redo: { [weak self] in self?.redo() },
                      retry: { [weak self] in self?.keepNow() })
    }
}
