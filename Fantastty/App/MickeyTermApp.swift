import SwiftUI
import GhosttyKit
import Sparkle

struct FantasttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Fantastty", id: "main") {
            MainWindow()
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.ghosttyApp)
                .environmentObject(appDelegate.sessionManager)
        }
        .commands {
            AppCommands(
                sessionManager: appDelegate.sessionManager,
                updater: updaterController.updater
            )
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.ghosttyApp)
        }
    }
}
