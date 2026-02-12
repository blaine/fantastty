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

    /// Event monitor for intercepting key equivalents (e.g. ⌘W)
    private var localEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("applicationDidFinishLaunching")
        ghosttyApp.delegate = self

        // Install shell integration scripts (before session creation)
        ShellIntegration.shared.ensureInstalled()

        // Set up notification observers for Ghostty actions
        sessionManager.ghosttyApp = ghosttyApp
        sessionManager.setupNotificationObservers()

        // Intercept ⌘W / ⌘⇧W before macOS sends performClose: to the window
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.charactersIgnoringModifiers == "w" else { return event }

            if flags == .command {
                // ⌘W → close the current tab (or workspace if last tab)
                self.sessionManager.closeSelectedTab()
                return nil
            }
            if flags == [.command, .shift] {
                // ⌘⇧W → close the current workspace
                if let id = self.sessionManager.selectedSessionID {
                    self.sessionManager.closeSession(id: id)
                }
                return nil
            }
            return event
        }

        // Create or restore sessions
        let readiness = self.ghosttyApp.readiness
        Self.logger.info("ghosttyApp.readiness = \(String(describing: readiness))")
        if ghosttyApp.readiness == .ready {
            // Try to restore tmux sessions first
            let restored = sessionManager.restoreTmuxSessions()
            if !restored {
                // No sessions restored, create a new one
                Self.logger.info("Creating initial session")
                sessionManager.createSession()
            }
        } else {
            Self.logger.warning("Ghostty not ready, cannot create session")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sessionManager.saveLayout()
        return .terminateNow
    }


    // MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        return sessionManager.findSurface(forUUID: uuid)
    }
}
