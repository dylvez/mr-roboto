import CoreText
import Foundation
import os

/// The app ships its own typefaces rather than hoping the machine has them.
///
/// Both families are SIL Open Font License 1.1, which permits bundling inside an application; the
/// licence text travels with them in `Resources/Fonts/OFL-*.txt` as the licence requires. Provenance,
/// so the next person can re-fetch or bump them deliberately:
///
///   Karla-Variable.ttf            — upstream `Karla[wght].ttf`, version 2.004, wght 200–800.
///                                   google/fonts @ ea9bc40cb0323afec81e7f1005453eea36f51708,
///                                   path `ofl/karla/Karla[wght].ttf`. METADATA.pb: `license: "OFL"`.
///                                   Upstream project: github.com/googlefonts/karla @ 69b25f66.
///   Newsreader-Variable.ttf       — upstream `Newsreader[opsz,wght].ttf`, opsz 6–72, wght 200–800.
///   Newsreader-Italic-Variable.ttf— upstream `Newsreader-Italic[opsz,wght].ttf`, same axes.
///                                   Both google/fonts @ ea9bc40cb0323afec81e7f1005453eea36f51708,
///                                   path `ofl/newsreader/`. METADATA.pb: `license: "OFL"`.
///                                   Upstream project: github.com/productiontype/Newsreader.
///
/// The files are renamed only to drop the `[axis]` brackets, which are awkward in build systems and
/// URLs; the bytes are the upstream bytes.
///
/// Why the variable fonts and not the static instances: Newsreader's static TTFs carry the optical
/// size in the *family* name — CoreText reads `Newsreader16pt-Regular.ttf` as family "Newsreader 16pt",
/// so `Font.custom("Newsreader", …)` would never match one. The variable font registers as family
/// "Newsreader" with named instances for each weight, which is what `Design.Typography` asks for.
/// Karla follows the same form for consistency, and one 94 KB file covers every weight.
enum FontRegistration {

    /// A face the design depends on, and the file that provides it.
    struct BundledFace: Sendable {
        let family: String
        let resource: String
    }

    static let faces: [BundledFace] = [
        BundledFace(family: "Karla", resource: "Karla-Variable"),
        BundledFace(family: "Newsreader", resource: "Newsreader-Variable"),
        BundledFace(family: "Newsreader", resource: "Newsreader-Italic-Variable"),
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
