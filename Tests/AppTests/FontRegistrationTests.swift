import AppKit
import CoreText
import Foundation
import Testing

@testable import MrRobotoApp

/// The app ships IBM Plex Sans and IBM Plex Mono instead of hoping the machine has them. These tests
/// are the guard on that: they fail if a font file goes missing from the bundle, if a face stops
/// resolving, or if a weight the design actually asks for quietly stops matching.
@Suite("Bundled font registration")
struct FontRegistrationTests {

    /// Registration is process-wide and idempotent, so every test can just ask for it.
    private func register() {
        FontRegistration.registerBundledFonts()
    }

    /// `FontRegistration` locates the resource bundle by hand rather than through the generated
    /// `Bundle.module` accessor, which traps when the bundle is absent. It must still find exactly
    /// the bundle `Bundle.module` names.
    @Test("The hand-rolled bundle lookup finds the same bundle as Bundle.module")
    func resourceBundleMatchesBundleModule() throws {
        let located = try #require(FontRegistration.resourceBundle, "resource bundle was not found")
        #expect(located.bundleURL == Bundle.module.bundleURL)
    }

    @Test("Every bundled font file is present in Bundle.module")
    func resourceURLsExist() throws {
        // Belt and braces: the same lookup the app uses, and the accessor the brief names.
        for face in FontRegistration.faces {
            #expect(Bundle.module.url(forResource: face.resource, withExtension: "ttf",
                                      subdirectory: FontRegistration.subdirectory) != nil,
                    "\(face.resource).ttf is not reachable through Bundle.module")
        }

        for face in FontRegistration.faces {
            let url = try #require(FontRegistration.url(for: face),
                                   "\(face.resource).ttf is not in Bundle.module at \(FontRegistration.subdirectory)")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 10_000, "\(face.resource).ttf is suspiciously small at \(size) bytes")
        }
    }

    /// Nothing from the old pairing should still be in the bundle. Newsreader and Karla went out
    /// with the warm palette; a leftover file would ship 600 KB of dead weight and, worse, would let
    /// a stale `Design.Typography` stack keep resolving and hide the mistake.
    @Test("The families that were dropped are actually gone")
    func retiredFamiliesAreNotBundled() {
        for resource in ["Karla-Variable", "Newsreader-Variable", "Newsreader-Italic-Variable"] {
            #expect(Bundle.module.url(forResource: resource, withExtension: "ttf",
                                      subdirectory: FontRegistration.subdirectory) == nil,
                    "\(resource).ttf is still in the bundle")
        }
        for licence in ["OFL-Karla", "OFL-Newsreader"] {
            #expect(Bundle.module.url(forResource: licence, withExtension: "txt",
                                      subdirectory: FontRegistration.subdirectory) == nil,
                    "\(licence).txt is still in the bundle")
        }
    }

    /// The licence has to travel with the fonts.
    @Test("The OFL text ships alongside the fonts")
    func licenceIsBundled() throws {
        for name in ["OFL-IBMPlexSans", "OFL-IBMPlexMono"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt",
                                                     subdirectory: FontRegistration.subdirectory),
                                   "\(name).txt is missing from the bundle")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("SIL Open Font License"))
            #expect(text.contains("IBM Corp."), "\(name).txt is not IBM's copy of the licence")
        }
    }

    @Test("Both Plex families resolve after registration")
    func familiesResolve() throws {
        register()

        let sans = try #require(NSFont(name: "IBM Plex Sans", size: 13), "IBM Plex Sans did not resolve")
        #expect(sans.familyName == "IBM Plex Sans")

        let mono = try #require(NSFont(name: "IBM Plex Mono", size: 12), "IBM Plex Mono did not resolve")
        #expect(mono.familyName == "IBM Plex Mono")
    }

    /// The sans is a variable font with a `wdth` axis as well as `wght`. If CoreText ever decided to
    /// surface the condensed end as its own family, `Font.custom("IBM Plex Sans", …)` would still
    /// work but the family list would gain a sibling nobody asked for.
    @Test("The variable sans registers as one family, not a family per width")
    func widthAxisDoesNotLeakFamilies() {
        register()
        let plex = NSFontManager.shared.availableFontFamilies.filter {
            $0.localizedCaseInsensitiveContains("plex")
        }
        #expect(Set(plex) == Set(["IBM Plex Sans", "IBM Plex Mono"]),
                "unexpected Plex families registered: \(plex)")
    }

    /// `registerBundledFonts()` is called once from `MrRobotoApp.init()`, but a test calling it again
    /// must not throw, must not report a duplicate, and must leave the same families standing.
    @Test("Registering twice is harmless")
    func doubleRegistrationIsSafe() {
        let first = FontRegistration.registerBundledFonts()
        let second = FontRegistration.registerBundledFonts()
        let third = FontRegistration.registerBundledFonts()

        #expect(first == second)
        #expect(second == third)
        #expect(second == Set(["IBM Plex Sans", "IBM Plex Mono"]))

        // And each family is still a single family, not two copies of one — the mono in particular
        // arrives as two separate files, which is exactly how a family gets registered twice.
        for family in ["IBM Plex Sans", "IBM Plex Mono"] {
            let matches = NSFontManager.shared.availableFontFamilies.filter { $0 == family }
            #expect(matches.count == 1, "\(family) registered \(matches.count) times")
        }
    }

    /// Resolve a family + weight the way SwiftUI's `.custom(_:size:).weight(_:)` does, and report
    /// which concrete face came back.
    private func match(family: String, weight: CGFloat) -> String? {
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil) else { return nil }
        guard CTFontDescriptorCopyAttribute(matched, kCTFontFamilyNameAttribute) as? String == family else {
            return nil  // Matched something, but outside the family — that is a fallback, not a hit.
        }
        return CTFontDescriptorCopyAttribute(matched, kCTFontNameAttribute) as? String
    }

    /// The weights `Design.Typography` actually passes: `.regular`, `.medium` and `.semibold` for the
    /// sans (`prose`, `ui`, `label`), `.regular` and `.medium` for the mono (`numeric`).
    @Test("Every weight the design asks for resolves within its own family",
          arguments: [("IBM Plex Sans", 0.0), ("IBM Plex Sans", 0.23), ("IBM Plex Sans", 0.3),
                      ("IBM Plex Mono", 0.0), ("IBM Plex Mono", 0.23)])
    func designWeightsResolve(family: String, weight: CGFloat) throws {
        register()
        let face = try #require(match(family: family, weight: weight),
                                "\(family) at weight \(weight) fell out of its family")
        #expect(!face.isEmpty)
    }

    /// Distinct weights must give distinct faces. If they collapse onto one, the family registered
    /// but the weight axis is not reachable — which looks fine and renders wrong.
    @Test("Weights are distinct faces, not one face three times")
    func weightsAreDistinct() throws {
        register()
        let sans = try [0.0, 0.23, 0.3].map { try #require(match(family: "IBM Plex Sans", weight: $0)) }
        #expect(Set(sans).count == 3, "IBM Plex Sans weights collapsed onto \(Set(sans))")

        let mono = try [0.0, 0.23].map { try #require(match(family: "IBM Plex Mono", weight: $0)) }
        #expect(Set(mono).count == 2, "IBM Plex Mono weights collapsed onto \(Set(mono))")
    }

    /// The sans ships a separate italic file; it has to be there, or `.italic()` gets a synthesised
    /// oblique that slants the mono columns beside it differently.
    @Test("The sans italic resolves")
    func italicResolves() throws {
        register()
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: "IBM Plex Sans",
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitItalic.rawValue],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let matched = try #require(CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil),
                                   "no italic face matched in IBM Plex Sans")

        let traits = CTFontDescriptorCopyAttribute(matched, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = traits?[kCTFontSymbolicTrait] as? UInt32 ?? 0
        #expect(symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0,
                "IBM Plex Sans matched a face, but not an italic one")

        let name = CTFontDescriptorCopyAttribute(matched, kCTFontNameAttribute) as? String
        #expect(name?.localizedCaseInsensitiveContains("italic") == true)
    }

    /// With the bundled fonts registered, the design should be resolving to them and not to a
    /// fallback — and the fallback stacks should still name faces that actually exist, since PNG
    /// and PDF export run outside this registration.
    @Test("The design resolves to the bundled families, and the fallbacks are real")
    func fallbacksAreSane() {
        register()

        // Prose and UI are one family told apart by size and weight, not two families.
        #expect(Design.Typography.proseFamily == "IBM Plex Sans")
        #expect(Design.Typography.uiFamily == "IBM Plex Sans")
        #expect(Design.Typography.numericFamily == "IBM Plex Mono")

        // Every name in every stack past the first must be a family this machine can render.
        for stack in Design.Typography.allStacks {
            for name in stack.dropFirst() {
                #expect(NSFont(name: name, size: 12) != nil, "fallback \(name) does not exist")
            }
        }

        // And the advertised fallback for each bundled family is one of those real names, not the
        // family itself.
        for family in Set(FontRegistration.faces.map(\.family)) {
            let fallback = Design.Typography.fallbackName(for: family)
            #expect(fallback != family, "\(family) advertises itself as its own fallback")
            #expect(Design.Typography.allStacks.contains { $0.contains(fallback) },
                    "\(family) falls back to \(fallback), which is in no stack")
        }
    }

    /// Whatever theme is current, the families it asks for are families that resolve. A theme that
    /// named a face nobody bundled would degrade silently to Helvetica everywhere.
    @Test("Every theme's typeface stack resolves to a bundled family",
          arguments: Design.Theme.allCases)
    func themeFacesResolve(theme: Design.Theme) {
        register()
        let bundled = Set(FontRegistration.faces.map(\.family))
        for stack in theme.typeface.all {
            let head = stack[0]
            #expect(bundled.contains(head), "\(theme.displayName) asks for \(head), which is not bundled")
            #expect(Design.Typography.firstAvailable(in: stack) == head,
                    "\(theme.displayName) falls back off \(head)")
        }
    }
}
