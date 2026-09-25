import AppKit
import Foundation
import SongGraph

/// One release started from the Album surface: where it goes, how far it has got, and what
/// stopped it.
///
/// The same call the Director's `release` tool makes — `Export.release` into a folder named after
/// the album under the export directory — with the progress and the failure kept here, on the
/// surface that started it, rather than only in the rail. Release used to be the Director's alone.
@MainActor
@Observable
final class AlbumReleaseModel {
    private(set) var isReleasing = false
    /// "Releasing… track 2 of 5, Exit Interview" while it runs; nil otherwise.
    private(set) var progressLine: String?
    /// Why the last release stopped, until the next one starts.
    private(set) var failure: String?
    /// Where the last release from this surface landed.
    private(set) var folder: URL?

    /// Where a release goes: the export directory you set, else ~/Music/Mr. Roboto/Exports, with
    /// a folder per album. The Director's `release` tool lands in the same place, so a record
    /// released either way is found in one.
    static func folder(for album: Album, app: AppState) -> URL {
        let base = app.exportDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Mr. Roboto/Exports", isDirectory: true)
        return base.appendingPathComponent(Export.safe(album.title), isDirectory: true)
    }

    /// Releases the album and shows the folder in Finder. Nil, with `failure` set and a line in
    /// the rail, when it could not.
    @discardableResult
    func release(_ id: AlbumID, app: AppState, reveal: Bool = true) async -> URL? {
        guard !isReleasing else { return nil }
        failure = nil
        folder = nil
        guard let album = app.library.album(id) else {
            failure = "\(Export.ReleaseFailure.noAlbum)"
            return nil
        }
        isReleasing = true
        progressLine = "Releasing…"
        defer { isReleasing = false; progressLine = nil }
        do {
            let result = try await Export.release(app, album: id, to: Self.folder(for: album, app: app)) { [weak self] track, of, title in
                self?.progressLine = "Releasing… track \(track) of \(of), \(title)"
            }
            folder = result.folder
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
            return result.folder
        } catch {
            failure = "\(error)"
            app.note(.session, "Could not release \(album.title)", detail: "\(error)")
            return nil
        }
    }

    func reveal() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
