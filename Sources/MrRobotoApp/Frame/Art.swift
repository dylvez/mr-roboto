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
        return nil
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
