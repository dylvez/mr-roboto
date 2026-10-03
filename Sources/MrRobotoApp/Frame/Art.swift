import AppKit
import SwiftUI

/// The generated illustrations, bundled under `Resources/Art` by `Art/make_art.py`.
///
/// Art is decoration on top of a frame that already works without it, so a missing file is never an
/// error: `ArtImage` draws nothing and the layout around it holds; the Sound surface's machine cards
/// fall back to plain chips.
/// That is what lets art arrive a piece at a time. Provenance for every file — which model, which
/// prompt, which references, what it cost — is in `Art/ledger.jsonl` and `Art/picks.json`.
enum Art {

    static let subdirectory = "Resources/Art"

    /// `NSCache` is documented thread-safe; it is only its Objective-C heritage that keeps it from
    /// being `Sendable`.
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String) -> NSImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let url = FontRegistration.resourceBundle?.url(forResource: name, withExtension: "png",
                                                              subdirectory: subdirectory),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// The band member's emblem for a line in the rail. Nil for the app's own lines, and for a persona
    /// the cast has no emblem for yet.
    static func emblem(for source: SessionEntry.Source) -> String? {
        switch source {
        case .you: return "cast-you"
        case .session: return nil
        case .director: return "cast-director"
        case .persona(let name): return emblem(forPersona: name)
        }
    }

    static func emblem(for source: Proposal.Source) -> String? {
        switch source {
        case .session: return nil
        case .director: return "cast-director"
        case .persona(let name): return emblem(forPersona: name)
        }
    }

    static func emblem(forPersona name: String) -> String? {
        let key = name.lowercased()
        if key.contains("beat") { return "cast-beatmaker" }
        if key.contains("sampl") { return "cast-sampler" }
        if key.contains("bass") { return "cast-bassist" }
        if key.contains("critic") || key.contains("check") { return "cast-critic" }
        if key.contains("harmon") { return Art.image("cast-harmonist") == nil ? nil : "cast-harmonist" }
        if key.contains("melod") { return Art.image("cast-melodist") == nil ? nil : "cast-melodist" }
        if key.contains("produc") { return Art.image("cast-producer") == nil ? nil : "cast-producer" }
        if key.contains("engineer") { return Art.image("cast-engineer") == nil ? nil : "cast-engineer" }
        if key.contains("peer") { return Art.image("cast-peer") == nil ? nil : "cast-peer" }
        if key.contains("lyric") { return Art.image("cast-lyricist") == nil ? nil : "cast-lyricist" }
        return nil
    }

    /// An idiom glyph from `Resources/Glyphs`, as a template image so the theme colours it.
    static func glyph(_ name: String) -> NSImage? {
        let key = "glyph-\(name)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let url = FontRegistration.resourceBundle?.url(forResource: key, withExtension: "svg",
                                                              subdirectory: "Resources/Glyphs"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// The machine card for a chain preset, by its raw name.
    static func machine(_ preset: String) -> String { "machine-\(preset.lowercased())" }
}

/// A bundled illustration at a fixed size, or nothing at all when the file is not there.
struct ArtImage: View {
    let name: String
    var width: CGFloat
    var height: CGFloat

    init(_ name: String, width: CGFloat, height: CGFloat? = nil) {
        self.name = name
        self.width = width
        self.height = height ?? width
    }

    var body: some View {
        if let image = Art.image(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }
}

/// An idiom glyph at a point size, in the current foreground style. Falls back to the SF Symbol
/// that stood in for it before the set was drawn, so a missing file never leaves a hole.
struct Glyph: View {
    let name: String
    var symbol: String
    var size: CGFloat = 12

    var body: some View {
        if let image = Art.glyph(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.85, weight: .medium))
                .accessibilityHidden(true)
        }
    }
}

extension SurfaceKind {
    /// Each surface's glyph: the idiom it works on.
    var glyph: (name: String, symbol: String) {
        switch self {
        case .importRecord: return ("record", "record.circle")
        case .chopLane: return ("chop", "scissors")
        case .grid: return ("groove", "square.grid.4x3.fill")
        case .sound: return ("sound", "dial.medium")
        case .chords: return ("chords", "music.note.list")
        case .pianoRoll: return ("stem-bass", "waveform.path")
        case .structure: return ("section", "rectangle.split.3x1")
        case .album: return ("album", "square.stack")
        case .merge: return ("merge", "arrow.triangle.merge")
        case .cast: return ("cast", "person.3")
        case .lyrics: return ("lyrics", "text.quote")
        case .booth: return ("booth", "mic")
        case .takes: return ("takes", "waveform.badge.mic")
        case .mixer: return ("mixer", "slider.vertical.3")
        case .master: return ("master", "gauge.with.needle")
        case .mashup: return ("mashup", "circle.lefthalf.filled.righthalf.striped.horizontal")
        case .sources: return ("stems", "square.stack.3d.down.right")
        case .compare: return ("compare", "chart.bar")
        case .check: return ("check", "checkmark.magnifyingglass")
        }
    }
}
