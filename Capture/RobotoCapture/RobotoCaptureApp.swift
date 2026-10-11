import SwiftUI

@main
struct RobotoCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            // Vibrant is drawn for a dark screen: menus, pickers and the keyboard go dark with it.
            CaptureView()
                .preferredColorScheme(.dark)
        }
    }
}
