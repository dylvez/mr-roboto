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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from a terminal the app is not the frontmost process, so it also has to take
        // focus, or the window appears behind the shell that started it.
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// One window, one app: closing it should quit rather than leaving a menu bar with nothing
    /// under it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
