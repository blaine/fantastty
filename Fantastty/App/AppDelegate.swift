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

    /// KVO observation for macOS appearance changes
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("applicationDidFinishLaunching")
        ghosttyApp.delegate = self

        // Install shell integration scripts (before session creation)
        ShellIntegration.shared.ensureInstalled()

        // Set up notification observers for Ghostty actions
        sessionManager.ghosttyApp = ghosttyApp
        sessionManager.setupNotificationObservers()

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

        // Apply saved appearance preference
        AppearanceMode.applyCurrent()
        applyGhosttyColorScheme()

        // When system appearance changes and we're in "system" mode,
        // update the Ghostty color scheme to match.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard AppearanceMode.current == .system else { return }
            self?.applyGhosttyColorScheme()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        sessionManager.flushActiveTimes()
        sessionManager.saveLayout()
        return .terminateNow
    }


    // MARK: - Appearance

    /// Update Ghostty's terminal color scheme to match the current appearance mode.
    private func applyGhosttyColorScheme() {
        guard let app = ghosttyApp.app else { return }
        let scheme: ghostty_color_scheme_e = AppearanceMode.current.isDark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(app, scheme)
    }

    // MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        return sessionManager.findSurface(forUUID: uuid)
    }
}
