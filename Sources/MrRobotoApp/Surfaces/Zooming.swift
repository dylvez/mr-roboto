import Foundation

/// A surface whose work can be looked at closer or whole, from the View menu's Zoom In, Zoom Out
/// and Zoom to Fit. The Piano roll's lane, so far: a bar or two fill it, or the whole line does.
///
/// Zoom is how a surface is looked at, not what it holds: no step of undo, nothing kept with the
/// part. The menu reaches the surface in front, as ⌘Z does; a surface that is not looked at closer
/// leaves the items greyed.
@MainActor
public protocol ZoomsItsWork: AnyObject {
    var canZoomIn: Bool { get }
    var canZoomOut: Bool { get }
    /// One level closer. Nothing past the closest.
    func zoomIn()
    /// One level wider, up to the whole.
    func zoomOut()
    /// The whole of it across, as the surface opens.
    func zoomToFit()
}
