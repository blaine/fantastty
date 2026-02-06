import SwiftUI
import GhosttyKit
import os

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, GhosttyAppDelegate {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "app"
    )

    /// The Ghostty application state
    let ghosttyApp = Ghostty.App()

    /// Session manager owns all terminal sessions
    let sessionManager = SessionManager()

    /// Undo manager for the application
    let undoManager = UndoManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("applicationDidFinishLaunching")
        ghosttyApp.delegate = self

        // Set up notification observers for Ghostty actions
        sessionManager.ghosttyApp = ghosttyApp
        sessionManager.setupNotificationObservers()

        // Create the initial session
        let readiness = self.ghosttyApp.readiness
        Self.logger.info("ghosttyApp.readiness = \(String(describing: readiness))")
        if ghosttyApp.readiness == .ready {
            Self.logger.info("Creating initial session")
            sessionManager.createSession()
        } else {
            Self.logger.warning("Ghostty not ready, cannot create session")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    // MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        return sessionManager.findSurface(forUUID: uuid)
    }
}
