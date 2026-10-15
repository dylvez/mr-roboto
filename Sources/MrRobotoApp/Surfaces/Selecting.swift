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

/// A surface with a selection the Edit menu's Delete (⌫) removes: the Piano roll's notes, so far.
///
/// The lane answers the Delete key itself once it has keyboard focus, but focus is a thing a click
/// may or may not win — a text field keeps it, Full Keyboard Access changes what can take it — and
/// a key that works only sometimes is a key that does not work. So Delete is a menu item too, and
/// reaches the surface in front as ⌘Z does, whatever has focus; a text field being typed in keeps
/// the key, since a letter going back is what ⌫ means there.
@MainActor
public protocol DeletesItsSelection: AnyObject {
    var canDelete: Bool { get }
    /// The selection goes, as one step of ⌘Z.
    func deleteSelection()
}
