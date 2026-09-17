import AppKit
import CoreText
import Foundation
import Testing

@testable import MrRobotoApp

/// The app ships Newsreader and Karla instead of hoping the machine has them. These tests are the
/// guard on that: they fail if a font file goes missing from the bundle, if a face stops resolving,
/// or if a weight the design actually asks for quietly stops matching.
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

    /// The licence has to travel with the fonts.
    @Test("The OFL text ships alongside the fonts")
    func licenceIsBundled() throws {
        for name in ["OFL-Karla", "OFL-Newsreader"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt",
                                                     subdirectory: FontRegistration.subdirectory),
                                   "\(name).txt is missing from the bundle")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("SIL Open Font License"))
        }
    }

    @Test("Karla and Newsreader resolve after registration")
    func familiesResolve() throws {
        register()

        let karla = try #require(NSFont(name: "Karla", size: 13), "Karla did not resolve")
        #expect(karla.familyName == "Karla")

        let newsreader = try #require(NSFont(name: "Newsreader", size: 15), "Newsreader did not resolve")
        #expect(newsreader.familyName == "Newsreader")
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
        #expect(second == Set(["Karla", "Newsreader"]))

        // And the family is still a single family, not two copies of one.
        let karlaFamilies = NSFontManager.shared.availableFontFamilies.filter { $0 == "Karla" }
        #expect(karlaFamilies.count == 1)
        let newsreaderFamilies = NSFontManager.shared.availableFontFamilies.filter { $0 == "Newsreader" }
        #expect(newsreaderFamilies.count == 1)
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

    /// The weights `Design.Typography` actually passes: `.regular`, `.medium` and `.semibold` for
    /// Karla (`ui`, `label`), `.regular` and `.medium` for Newsreader (`prose`).
    @Test("Every weight the design asks for resolves within its own family",
          arguments: [("Karla", 0.0), ("Karla", 0.23), ("Karla", 0.3),
                      ("Newsreader", 0.0), ("Newsreader", 0.23)])
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
        let karla = try [0.0, 0.23, 0.3].map { try #require(match(family: "Karla", weight: $0)) }
        #expect(Set(karla).count == 3, "Karla weights collapsed onto \(Set(karla))")

        let newsreader = try [0.0, 0.23].map { try #require(match(family: "Newsreader", weight: $0)) }
        #expect(Set(newsreader).count == 2, "Newsreader weights collapsed onto \(Set(newsreader))")
    }

    /// The conversation rail's italic. Newsreader ships a separate italic file; it has to be there.
    @Test("Newsreader italic resolves")
    func italicResolves() throws {
        register()
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: "Newsreader",
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitItalic.rawValue],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let matched = try #require(CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil),
                                   "no italic face matched in Newsreader")

        let traits = CTFontDescriptorCopyAttribute(matched, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = traits?[kCTFontSymbolicTrait] as? UInt32 ?? 0
        #expect(symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0,
                "Newsreader matched a face, but not an italic one")

        let name = CTFontDescriptorCopyAttribute(matched, kCTFontNameAttribute) as? String
        #expect(name?.localizedCaseInsensitiveContains("italic") == true)
    }

    /// With the bundled fonts registered, the design should be resolving to them and not to a
    /// fallback — and the fallback stacks should still name faces that actually exist, since PNG
    /// and PDF export run outside this registration.
    @Test("The design resolves to the bundled families, and the fallbacks are real")
    func fallbacksAreSane() {
        register()

        #expect(Design.Typography.proseFamily == "Newsreader")
        #expect(Design.Typography.uiFamily == "Karla")

        // Every name in each stack past the first must be a family this machine can render.
        for name in Design.Typography.proseStack.dropFirst() + Design.Typography.uiStack.dropFirst() {
            #expect(NSFont(name: name, size: 12) != nil, "fallback \(name) does not exist")
        }

        // And the advertised fallback for each family is one of those real names, not the family itself.
        let proseFallback = Design.Typography.fallbackName(for: "Newsreader")
        #expect(proseFallback != "Newsreader")
        #expect(Design.Typography.proseStack.contains(proseFallback))

        let uiFallback = Design.Typography.fallbackName(for: "Karla")
        #expect(uiFallback != "Karla")
        #expect(Design.Typography.uiStack.contains(uiFallback))
    }
}
