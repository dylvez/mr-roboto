import CoreText
import Foundation
import os

/// The app ships its own typefaces rather than hoping the machine has them.
///
/// Both families are SIL Open Font License 1.1, which permits bundling inside an application; the
/// licence text travels with them in `Resources/Fonts/OFL-*.txt` as the licence requires. The
/// licence was read before the files were fetched: both are "Copyright © 2017 IBM Corp. with
/// Reserved Font Name \"Plex\"", licensed under OFL 1.1. The reserved name binds *modified*
/// versions; these bytes are unmodified, so the families keep their names.
///
/// Provenance, so the next person can re-fetch or bump them deliberately. Everything comes from
/// google/fonts @ a54f7446f84a1125ef6bf08baa46f3639e8905e0; both METADATA.pb files say
/// `license: "OFL"`:
///
///   IBMPlexSans-Variable.ttf        — upstream `IBMPlexSans[wdth,wght].ttf`, version 3.201,
///                                     wght 100–700, wdth 75–100. Path `ofl/ibmplexsans/`.
///   IBMPlexSans-Italic-Variable.ttf — upstream `IBMPlexSans-Italic[wdth,wght].ttf`, same axes.
///                                     Path `ofl/ibmplexsans/`.
///   IBMPlexMono-Regular.ttf         — upstream `IBMPlexMono-Regular.ttf`, version 2.3.
///   IBMPlexMono-Medium.ttf          — upstream `IBMPlexMono-Medium.ttf`, version 2.3.
///                                     Both path `ofl/ibmplexmono/`.
///                                     Upstream project for all four: github.com/IBM/plex, by way of
///                                     the googlefonts/plex fork Google Fonts builds from.
///
/// The sans files are renamed only to drop the `[axis]` brackets, which are awkward in build systems
/// and URLs; the bytes are the upstream bytes.
///
/// Why the variable font for the sans: one 525 KB file covers every weight the design asks for, and
/// CoreText registers it as the single family "IBM Plex Sans" with a named instance per weight,
/// which is what `Design.Typography` asks for. The condensed end of the `wdth` axis does not leak
/// out as a separate family. The mono has no variable build on Google Fonts, so it ships as the two
/// static instances the design actually uses — Regular for every numeric column, Medium for the few
/// places a column is emphasised — rather than all fourteen.
///
/// What is *not* here any more: Newsreader and Karla. The serif carried as much of the old warmth as
/// the paper did, and with Plex covering prose and UI alike there is no second family for Karla to
/// be. Both were removed with their licence files.
enum FontRegistration {

    /// A face the design depends on, and the file that provides it.
    struct BundledFace: Sendable {
        let family: String
        let resource: String
    }

    static let faces: [BundledFace] = [
        BundledFace(family: "IBM Plex Sans", resource: "IBMPlexSans-Variable"),
        BundledFace(family: "IBM Plex Sans", resource: "IBMPlexSans-Italic-Variable"),
        BundledFace(family: "IBM Plex Mono", resource: "IBMPlexMono-Regular"),
        BundledFace(family: "IBM Plex Mono", resource: "IBMPlexMono-Medium"),
    ]

    /// `.copy("Resources")` keeps the tree verbatim, so the fonts sit here inside the bundle.
    static let subdirectory = "Resources/Fonts"

    private static let log = Logger(subsystem: "com.mrroboto.app", category: "fonts")

    /// Everything below is serialized through this lock, and the result is cached under it.
    ///
    /// Not merely an optimisation. Asking CoreText to resolve a family (`NSFont(name:)` and friends)
    /// goes out to `fontd` over XPC, and doing that *while* a registration is in flight on another
    /// thread deadlocks inside libFontRegistry. A plain "already done?" flag is not enough: it lets a
    /// second caller past while the first is still registering, which is exactly the losing
    /// interleaving. So the flag and the work live under one lock, and late callers block until
    /// registration has finished and then read the cached answer without touching `fontd` at all.
    ///
    /// `NSLock` rather than an unfair lock: the critical section makes XPC calls, so a waiter should
    /// sleep rather than spin.
    private static let lock = NSLock()

    /// nil until `registerBundledFonts()` has run to completion. Only ever touched under `lock`.
    private nonisolated(unsafe) static var cachedFamilies: Set<String>?

    /// Used only to ask `Bundle(for:)` which bundle this code was loaded from.
    private final class BundleToken {}

    /// The SwiftPM resource bundle for this target — the same `MrRoboto_MrRobotoApp.bundle` that
    /// `Bundle.module` names, located by hand.
    ///
    /// It has to be `Bundle.module`'s bundle and not `Bundle.main`: MrRobotoApp is a bare SwiftPM
    /// executable rather than an `.app`, so its resources live in a sibling bundle next to the
    /// binary. `Bundle.main` is the executable itself and has none of them.
    ///
    /// The generated `Bundle.module` accessor is deliberately not used: it calls `fatalError` when
    /// the bundle is absent, which would take the whole app down over a missing font file. A font
    /// must degrade to the fallback stack, never crash the instrument. Same search order the
    /// generated accessor uses, minus the trap.
    static let resourceBundle: Bundle? = {
        let name = "MrRoboto_MrRobotoApp.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL,
        ]
        for case let root? in candidates {
            if let bundle = Bundle(url: root.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    /// The URL a face's file has inside the resource bundle, or nil if it is not there.
    static func url(for face: BundledFace) -> URL? {
        resourceBundle?.url(forResource: face.resource, withExtension: "ttf", subdirectory: subdirectory)
    }

    /// Register every bundled face with this process. Call before the first view renders.
    ///
    /// Safe to call more than once. Returns the families that are usable afterwards, so a caller —
    /// or a test — can assert on the outcome rather than trust it.
    @discardableResult
    static func registerBundledFonts() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cachedFamilies { return cachedFamilies }

        if resourceBundle == nil {
            // The whole bundle is gone — a packaging mistake, not a runtime condition. The app keeps
            // running on the fallback stacks; the per-face lines below name each family it affects.
            log.error("""
                Resource bundle MrRoboto_MrRobotoApp.bundle not found next to the executable. \
                No bundled fonts will be registered.
                """)
            FileHandle.standardError.write(Data(
                "[fonts] resource bundle MrRoboto_MrRobotoApp.bundle not found — no bundled fonts\n".utf8))
        }

        for face in faces {
            guard let url = url(for: face) else {
                // A missing file is a packaging mistake, not a runtime condition. Say so loudly:
                // the whole point of bundling was to stop the silent slide to a system font.
                log.error("""
                    Bundled font missing from the resource bundle: \(face.resource, privacy: .public).ttf \
                    for family \(face.family, privacy: .public). Text in this family will fall back to \
                    \(Design.Typography.fallbackName(for: face.family), privacy: .public).
                    """)
                FileHandle.standardError.write(Data("""
                    [fonts] missing resource \(face.resource).ttf (family \(face.family)) — \
                    falling back to \(Design.Typography.fallbackName(for: face.family))\n
                    """.utf8))
                continue
            }

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { continue }

            let cfError = error?.takeRetainedValue()

            // Registering the same URL twice is not a failure; it is this function being called again.
            if let cfError {
                let code = CTFontManagerError(rawValue: CFErrorGetCode(cfError))
                if code == .alreadyRegistered || code == .duplicatedName { continue }
            }

            let reason = cfError.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
            log.error("""
                Failed to register bundled font \(face.resource, privacy: .public).ttf for family \
                \(face.family, privacy: .public): \(reason, privacy: .public). Text in this family will \
                fall back to \(Design.Typography.fallbackName(for: face.family), privacy: .public).
                """)
            FileHandle.standardError.write(Data("""
                [fonts] could not register \(face.resource).ttf (family \(face.family)): \(reason) — \
                falling back to \(Design.Typography.fallbackName(for: face.family))\n
                """.utf8))
        }

        // Resolved once, here, while the lock is still held — so this is the only thread talking to
        // `fontd` and no one can observe a half-registered state.
        let families = Set(faces.map(\.family).filter { Design.Typography.isAvailable($0) })
        cachedFamilies = families
        return families
    }
}
