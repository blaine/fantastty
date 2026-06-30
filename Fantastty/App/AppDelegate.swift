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

    /// The app's single main window, captured once SwiftUI creates it.
    private weak var mainWindow: NSWindow?

    /// Delegate that keeps the main window from being closed.
    private var windowCloseGuard: NonClosableWindowDelegate?

    static func shouldBootstrapSessions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment["XCTestConfigurationFilePath"] != nil else {
            return true
        }
        return environment["FANTASTTY_BOOTSTRAP_DURING_TESTS"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("applicationDidFinishLaunching")
        ghosttyApp.delegate = self

        guard Self.shouldBootstrapSessions() else {
            Self.logger.info("Skipping startup session bootstrap under XCTest")
            return
        }

        // Install shell integration scripts (before session creation)
        ShellIntegration.shared.ensureInstalled()

        // Set up notification observers for Ghostty actions
        sessionManager.ghosttyApp = ghosttyApp
        sessionManager.setupNotificationObservers()
        sessionManager.beginStartupThumbnailRefreshSuppression()
        defer { sessionManager.endStartupThumbnailRefreshSuppression() }

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

    // MARK: - Main window

    /// Capture the main window and make it non-closable. Called by
    /// `WindowAccessor` once SwiftUI has created the window. The app keeps
    /// running with sessions in memory when no window is shown, and SwiftUI's
    /// single `Window` scene can't be cleanly reopened, so rather than strand a
    /// windowless app we simply prevent the window from closing. Minimize and
    /// Quit are unaffected.
    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window

        // Disable the close button (greys it out) so the affordance is clear.
        window.styleMask.remove(.closable)

        // Backstop: block any programmatic/menu close path too.
        let guardDelegate = NonClosableWindowDelegate()
        guardDelegate.forwardingDelegate = window.delegate
        window.delegate = guardDelegate
        windowCloseGuard = guardDelegate
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
        sessionManager.findSurface(forUUID: uuid)
    }

    func handleOpenURL(_ url: URL) -> Bool {
        return false
    }
}

/// Window delegate that prevents the app's single window from closing, so the
/// app can't be left running with no window. Every other delegate callback is
/// forwarded to SwiftUI's own window delegate so its window management keeps
/// working unchanged.
final class NonClosableWindowDelegate: NSObject, NSWindowDelegate {
    weak var forwardingDelegate: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwardingDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return forwardingDelegate
    }
}
