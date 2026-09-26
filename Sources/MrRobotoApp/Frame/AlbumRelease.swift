import AppKit
import Foundation
import Performance
import SongGraph
import SwiftUI

// M7 L4/L7: the release folder, and the cover the app draws.

/// The title and the artist on a two-colour field, in one of four layouts.
struct CoverView: View {
    let design: CoverDesign
    let title: String
    let artist: String
    let side: CGFloat

    private var paper: Color { Color(hex: design.paper) }
    private var ink: Color { Color(hex: design.ink) }

    var body: some View {
        ZStack {
            paper
            switch design.layout {
            case .band:
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(ink).frame(height: side * 0.22).overlay(
                        VStack(alignment: .leading, spacing: side * 0.01) {
                            Text(title).font(.custom("IBM Plex Sans", size: side * 0.07).weight(.semibold))
                            Text(artist.uppercased()).font(.custom("IBM Plex Mono", size: side * 0.028)).tracking(side * 0.004)
                        }
                        .foregroundStyle(paper)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, side * 0.08))
                    Spacer().frame(height: side * 0.12)
                }
            case .corner:
                VStack(alignment: .leading, spacing: side * 0.012) {
                    Text(title).font(.custom("IBM Plex Sans", size: side * 0.09).weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(artist).font(.custom("IBM Plex Sans", size: side * 0.04))
                }
                .foregroundStyle(ink)
                .padding(side * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .stack:
                VStack(spacing: side * 0.02) {
                    ForEach(Array(title.split(separator: " ").enumerated()), id: \.offset) { _, word in
                        Text(String(word).uppercased()).font(.custom("IBM Plex Sans", size: side * 0.12).weight(.semibold))
                    }
                    Text(artist).font(.custom("IBM Plex Mono", size: side * 0.03)).padding(.top, side * 0.03)
                }
                .foregroundStyle(ink)
            case .monogram:
                ZStack {
                    Circle().stroke(ink, lineWidth: side * 0.012).frame(width: side * 0.6, height: side * 0.6)
                    Text(String(title.prefix(1)).uppercased()).font(.custom("IBM Plex Sans", size: side * 0.36).weight(.semibold)).foregroundStyle(ink)
                    VStack {
                        Spacer()
                        Text("\(title) · \(artist)").font(.custom("IBM Plex Mono", size: side * 0.028)).foregroundStyle(ink).padding(.bottom, side * 0.08)
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }
}

extension Color {
    /// "#rrggbb", else the ink.
    init(hex: String) {
        var value: UInt64 = 0x14171A
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if cleaned.count == 6, let parsed = UInt64(cleaned, radix: 16) { value = parsed }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

public enum CoverRenderer {
    /// The cover as PNG data, `pixels` square.
    @MainActor
    public static func png(_ design: CoverDesign, title: String, artist: String, pixels: Int = 3_000) -> Data? {
        let side: CGFloat = 1_000
        let renderer = ImageRenderer(content: CoverView(design: design, title: title, artist: artist, side: side))
        renderer.scale = CGFloat(pixels) / side
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension Export {

    /// What left with the record.
    public struct AlbumReport: Codable, Sendable {
        public struct TrackEntry: Codable, Sendable {
            public var number: Int
            public var title: String
            public var file: String
            public var gapBefore: Double
            public var durationSeconds: Double
            public var integratedLUFS: Double
            public var truePeakDBTP: Double
            public var trimDB: Double
            public var mixVersion: String?
            public var key: String?
            public var tempo: Double
        }
        public var album: String
        public var artist: String
        public var targetLUFS: Double
        public var ceilingDBTP: Double
        public var runningSeconds: Double
        public var tracks: [TrackEntry]
        public var clearances: [MasterReport.Clearance]
        public var notes: String
        public var cover: String
        public var releasedAt: String
        /// The album released, so a second album with the same title is not released over it.
        public var albumID: String?
    }

    public enum ReleaseFailure: Error, CustomStringConvertible {
        case noAlbum, noTracks, unplayable(String), missingTrack(Int)
        public var description: String {
            switch self {
            case .noAlbum: return "That album is not in the library."
            case .noTracks: return "The album has no songs."
            case .unplayable(let title): return "\(title) plays nothing, so it cannot be released."
            case .missingTrack(let number):
                return "Track \(number) is a song the library does not hold — never saved, or removed. "
                    + "Save it, or take it off the album, and release again."
            }
        }
    }

    /// The files a release before this one left in `directory`, as its `album.json` lists them:
    /// removed, so a record re-sequenced is not a folder of both orders. Only what that report
    /// named, and only plain names inside the folder.
    static func clearPreviousRelease(in directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("album.json")),
              let previous = try? JSONDecoder().decode(AlbumReport.self, from: data) else { return }
        for name in previous.tracks.map(\.file) + [previous.cover]
        where !name.contains("/") && name != "." && name != ".." && !name.isEmpty {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Every track bounced through its own mix, trimmed to the album's target, limited at its
    /// ceiling, written as `NN — Title.wav` beside `cover.png` and `album.json`. The album
    /// records what each track was cut as. `progress` is told each track as it starts, one-based,
    /// so a surface can say "track 2 of 5" while the bounce runs.
    @MainActor
    public static func release(_ app: AppState, album albumID: AlbumID, to directory: URL,
                               progress: (@MainActor (_ track: Int, _ of: Int, _ title: String) -> Void)? = nil) async throws -> (folder: URL, report: AlbumReport) {
        // What is on screen, first: a fader let go of a moment ago is in the mix that goes out.
        app.keepSurfaceWork()
        guard let store = app.store, let album = app.library.album(albumID) else { throw ReleaseFailure.noAlbum }
        guard !album.songs.isEmpty else { throw ReleaseFailure.noTracks }
        // Every track is there before any is bounced: one missing used to be skipped without a
        // word, and the rest renumbered around the hole.
        for (index, id) in album.songs.enumerated() where app.song?.id != id && app.library.song(id) == nil {
            throw ReleaseFailure.missingTrack(index + 1)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clearPreviousRelease(in: directory)
        // The cover first, so a cover that cannot be read stops the release before any track is
        // bounced rather than after, and is a PNG whatever it was chosen as.
        let coverURL = directory.appendingPathComponent("cover.png")
        switch album.cover {
        case .image(let media):
            let source = try store.mediaURL(for: media)
            let data = try Data(contentsOf: source)
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            try png.write(to: coverURL)
        case .drawn(let design):
            if let png = CoverRenderer.png(design, title: album.title, artist: album.artist) { try png.write(to: coverURL) }
        }
        var entries: [AlbumReport.TrackEntry] = []
        /// Tracks that went out without audio their package no longer holds.
        var incomplete: [String] = []
        var releases: [SongID: TrackRelease] = [:]
        var running = 0.0
        for (index, id) in album.songs.enumerated() {
            guard let song = app.song?.id == id ? app.song : app.library.song(id) else { throw ReleaseFailure.missingTrack(index + 1) }
            progress?(index + 1, album.songs.count, song.title)
            let plan = SongPlayback.plan(for: song) { ref in try? store.mediaURL(for: ref, song: song.id) }.looping(false)
            guard plan.isPlayable else { throw ReleaseFailure.unplayable(song.title) }
            if plan.missingMedia { incomplete.append(song.title) }
            let stems = try await SectionBounce.render(plan, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory,
                                                       onlyTheMix: true)
            let measured = MixMeter.integratedLoudness(stems.mix, sampleRate: stems.sampleRate)
            var trim = measured.isFinite ? album.targets.integratedLUFS - measured : 0
            func cut(_ trimDB: Double) -> [[Float]] {
                let gain = Float(pow(10, trimDB / 20))
                return Limiter.apply(stems.mix.map { lane in lane.map { $0 * gain } }, sampleRate: stems.sampleRate, ceilingDBTP: album.targets.truePeakDBTP)
            }
            var limited = cut(trim)
            var lufs = MixMeter.integratedLoudness(limited, sampleRate: stems.sampleRate)
            // The limiter takes loudness off a hot track: one more pass by the shortfall.
            if lufs.isFinite, album.targets.integratedLUFS - lufs > 0.3 {
                trim += album.targets.integratedLUFS - lufs
                limited = cut(trim)
                lufs = MixMeter.integratedLoudness(limited, sampleRate: stems.sampleRate)
            }
            let truePeak = MixMeter.truePeakDB(limited, sampleRate: stems.sampleRate)
            let seconds = Double(limited.first?.count ?? 0) / stems.sampleRate
            let file = unique(directory.appendingPathComponent(String(format: "%02d — %@.wav", index + 1, safe(song.title)))).lastPathComponent
            try writeWAV24(limited, sampleRate: stems.sampleRate, to: directory.appendingPathComponent(file))
            let gap = index == 0 ? 0 : album.gap(before: id)
            running += gap + seconds
            entries.append(.init(number: index + 1, title: song.title, file: file, gapBefore: gap, durationSeconds: seconds,
                                 integratedLUFS: lufs, truePeakDBTP: truePeak, trimDB: trim, mixVersion: plan.mixVersion?.description,
                                 key: song.key.map { "\($0)" }, tempo: song.tempo))
            releases[id] = TrackRelease(mixVersion: plan.mixVersion, integratedLUFS: lufs, truePeakDBTP: truePeak, durationSeconds: seconds, trimDB: trim)
        }
        let report = AlbumReport(album: album.title, artist: album.artist, targetLUFS: album.targets.integratedLUFS, ceilingDBTP: album.targets.truePeakDBTP,
                                 runningSeconds: running, tracks: entries,
                                 clearances: app.sources(of: album).map { .init(source: $0.source, status: $0.status.rawValue) },
                                 notes: album.notes, cover: "cover.png", releasedAt: ISO8601DateFormatter().string(from: Date()),
                                 albumID: album.id.description)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("album.json"))
        app.recordReleases(releases, for: albumID)
        if !incomplete.isEmpty {
            app.note(.session, "Released without some of its audio: \(incomplete.joined(separator: ", "))",
                     detail: "A take or a stem's file is missing from the song's package, so it is not on the record. Re-import it or record it again, then release again.")
        }
        app.note(.session, "Released \(album.title)", detail: String(format: "%d tracks, %.0f:%02d, target %.0f LUFS → %@", entries.count, running / 60, Int(running) % 60, album.targets.integratedLUFS, directory.path))
        return (directory, report)
    }
}
