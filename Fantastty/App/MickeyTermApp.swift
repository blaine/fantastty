import SwiftUI
import GhosttyKit

struct FantasttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appDelegate.ghosttyApp)
                .environmentObject(appDelegate.sessionManager)
        }
        .commands {
            AppCommands(sessionManager: appDelegate.sessionManager)
        }
    }
}
