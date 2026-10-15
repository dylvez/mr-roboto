import Foundation

/// A surface with a selection the Edit menu's Duplicate (⌘D) lays again right after itself: the
/// Piano roll's notes, so far.
///
/// Cut, Copy and Paste reach the surface another way — through the view that has keyboard focus,
/// as every text field's do — because the pasteboard is theirs. Duplicate touches no pasteboard,
/// so it reaches the surface in front as ⌘Z and ⌘= do; a surface with nothing to duplicate leaves
/// the item greyed.
@MainActor
public protocol DuplicatesItsSelection: AnyObject {
    var canDuplicate: Bool { get }
    /// The selection again, right after itself, and the copies selected.
    func duplicateSelection()
}
