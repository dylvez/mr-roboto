import AppKit

/// Makes a bare executable behave like an application.
///
/// The app is a SwiftPM executable rather than an `.app` bundle, which keeps everything in the
/// package and inside `make check`. The cost is that macOS does not treat it as a foreground app:
/// launched from a shell it gets the default `.prohibited`/`.accessory` treatment, so **the window
/// is created and never shown**, there is no Dock tile and no menu bar, and the process just sits
/// there looking like it failed. Nothing is wrong with the view code; the process simply never
/// asked to be an app.
///
/// `setActivationPolicy(.regular)` is what asks. It has to run before the first window is ordered
/// front, hence the `NSApplicationDelegateAdaptor` rather than a call inside `body`.
///
/// This goes away when the app is packaged as a real bundle with an `Info.plist`, which is the
/// point at which it also gets an icon, a bundle identifier and somewhere to hang entitlements.
final class ActivationDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // Before the first window is ordered front: a theme that pins the appearance (Petrol) has to
        // have done so already, or the window opens with light AppKit furniture over a dark ground
        // and then corrects itself in view of the user.
        Design.applyPinnedAppearance()
        // A bare executable has no bundle icon; draw ours. See `AppIconArt`.
        if let icon = AppIconArt.image() { NSApplication.shared.applicationIconImage = icon }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from a terminal the app is not the frontmost process, so it also has to take
        // focus, or the window appears behind the shell that started it.
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Song packages handed to the app by Finder. They can arrive before the window — and the
    /// `AppState` that opens them — exist, so they wait here until `opener` is set.
    private var waiting: [URL] = []
    var opener: ((URL) -> Void)? {
        didSet {
            guard let opener else { return }
            let urls = waiting
            waiting = []
            urls.forEach(opener)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let packages = urls.filter { $0.pathExtension == "roboto" }
        if let opener { packages.forEach(opener) } else { waiting += packages }
    }

    /// What to do on the way out: keep the open song's unsaved work and let the session file finish.
    /// Set by the app once its state exists. Work the band made must not vanish because you quit.
    var onQuit: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) { onQuit?() }

    /// One window, one app: closing it should quit rather than leaving a menu bar with nothing
    /// under it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
