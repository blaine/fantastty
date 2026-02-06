import SwiftUI
import GhosttyKit
import os
import Combine
import AppKit

/// Central orchestrator for all terminal sessions.
/// Routes libghostty notifications to the correct session/tab.
class SessionManager: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "session-manager"
    )

    /// Debug log to file for easier debugging
    private static func debugLog(_ message: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fantastty_debug.log")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// All sessions (sidebar items)
    @Published var sessions: [Session] = []

    /// Currently selected session ID (sidebar selection)
    @Published var selectedSessionID: UUID?

    /// Whether to show the SSH connection sheet
    @Published var showSSHSheet: Bool = false

    /// Reference to the Ghostty app state
    var ghosttyApp: Ghostty.App?

    private var titleCancellables = Set<AnyCancellable>()

    /// The currently selected session
    var selectedSession: Session? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    /// The currently selected tab within the selected session
    var selectedTab: TerminalTab? {
        return selectedSession?.selectedTab
    }

    /// The currently focused surface view
    var focusedSurfaceView: Ghostty.SurfaceView? {
        return selectedTab?.focusedSurface
    }

    // MARK: - Session Management (Sidebar)

    /// Create a new session (sidebar item) with an initial tab.
    @discardableResult
    func createSession(type: SessionType = .local, config: Ghostty.SurfaceConfiguration? = nil) -> Session? {
        guard let app = ghosttyApp?.app else {
            Self.logger.error("Cannot create session: ghostty app not initialized")
            return nil
        }

        var surfaceConfig = config ?? Ghostty.SurfaceConfiguration()
        if let command = type.command {
            surfaceConfig.command = command
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: surfaceConfig)
        let session = Session(type: type, surfaceView: surfaceView)

        sessions.append(session)
        selectedSessionID = session.id

        // Observe title changes
        if let tab = session.selectedTab {
            setupTitleObserver(for: tab, surfaceView: surfaceView)
        }

        Self.logger.info("Created session \(session.id) type=\(type.displayName)")
        return session
    }

    /// Close a session by ID.
    func closeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        sessions.remove(at: index)

        // Update selection
        if selectedSessionID == id {
            if !sessions.isEmpty {
                let newIndex = min(index, sessions.count - 1)
                selectedSessionID = sessions[newIndex].id
            } else {
                selectedSessionID = nil
                // Create a new session if all are closed
                createSession()
            }
        }

        Self.logger.info("Closed session \(id)")
    }

    /// Select the next session in the sidebar.
    func selectNextSession() {
        guard let currentID = selectedSessionID,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentID }),
              sessions.count > 1 else { return }

        let nextIndex = (currentIndex + 1) % sessions.count
        selectedSessionID = sessions[nextIndex].id
    }

    /// Select the previous session in the sidebar.
    func selectPreviousSession() {
        guard let currentID = selectedSessionID,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentID }),
              sessions.count > 1 else { return }

        let prevIndex = (currentIndex - 1 + sessions.count) % sessions.count
        selectedSessionID = sessions[prevIndex].id
    }

    /// Select a session by index (0-based).
    func selectSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        selectedSessionID = sessions[index].id
    }

    // MARK: - Tab Management (Top tabs within session)

    /// Create a new tab in the current session.
    @discardableResult
    func createTab(type: SessionType = .local, config: Ghostty.SurfaceConfiguration? = nil) -> TerminalTab? {
        guard let session = selectedSession,
              let app = ghosttyApp?.app else {
            Self.logger.error("Cannot create tab: no session or ghostty app")
            return nil
        }

        var surfaceConfig = config ?? Ghostty.SurfaceConfiguration()
        if let command = type.command {
            surfaceConfig.command = command
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: surfaceConfig)
        let tab = TerminalTab(type: type, surfaceView: surfaceView)

        session.addTab(tab)
        setupTitleObserver(for: tab, surfaceView: surfaceView)

        Self.logger.info("Created tab \(tab.id) in session \(session.id)")
        return tab
    }

    /// Close a tab within its session. If last tab, closes the session.
    func closeTab(id: UUID) {
        guard let session = sessions.first(where: { $0.tabs.contains { $0.id == id } }) else { return }

        let shouldCloseSession = session.closeTab(id: id)
        if shouldCloseSession {
            closeSession(id: session.id)
        }

        Self.logger.info("Closed tab \(id)")
    }

    /// Close the currently selected tab.
    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(id: tab.id)
    }

    // MARK: - Split Management

    /// Create a new split in the currently selected tab.
    func newSplit(direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        guard let tab = selectedTab,
              let focusedSurface = tab.focusedSurface,
              let app = ghosttyApp?.app else { return }

        let config = Ghostty.SurfaceConfiguration()
        let newSurface = Ghostty.SurfaceView(app, baseConfig: config)

        do {
            tab.surfaceTree = try tab.surfaceTree.inserting(
                view: newSurface,
                at: focusedSurface,
                direction: direction
            )
            tab.focusedSurface = newSurface
            setupTitleObserver(for: tab, surfaceView: newSurface)
        } catch {
            Self.logger.error("Failed to create split: \(error)")
        }
    }

    /// Close a surface within a tab's split tree.
    func closeSurface(_ surfaceView: Ghostty.SurfaceView) {
        guard let (session, tab) = findSessionAndTab(for: surfaceView) else { return }

        guard let node = tab.surfaceTree.root?.node(view: surfaceView) else { return }

        if let newRoot = tab.surfaceTree.root?.remove(node) {
            tab.surfaceTree = SplitTree(root: newRoot, zoomed: nil)
            // Focus the first leaf of the remaining tree
            if let firstView = firstLeafView(in: newRoot) {
                tab.focusedSurface = firstView
            }
        } else {
            // This was the last surface in the tab - close the tab
            let shouldCloseSession = session.closeTab(id: tab.id)
            if shouldCloseSession {
                closeSession(id: session.id)
            }
        }
    }

    // MARK: - Lookup Helpers

    /// Find a surface view by UUID.
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for session in sessions {
            for tab in session.tabs {
                if let node = tab.surfaceTree.root {
                    if let found = findSurface(in: node, uuid: uuid) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    /// Find the session containing a given surface view.
    func session(for surfaceView: Ghostty.SurfaceView) -> Session? {
        return sessions.first { $0.contains(surfaceView: surfaceView) }
    }

    /// Find the session and tab containing a given surface view.
    func findSessionAndTab(for surfaceView: Ghostty.SurfaceView) -> (Session, TerminalTab)? {
        for session in sessions {
            if let tab = session.tab(containing: surfaceView) {
                return (session, tab)
            }
        }
        return nil
    }

    // MARK: - Notification Routing

    /// Set up NotificationCenter observers for Ghostty actions.
    func setupNotificationObservers() {
        let center = NotificationCenter.default

        // New tab (creates a new top-tab in current session)
        center.addObserver(
            self,
            selector: #selector(handleNewTab(_:)),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil
        )

        // Close surface
        center.addObserver(
            self,
            selector: #selector(handleCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil
        )

        // New split
        center.addObserver(
            self,
            selector: #selector(handleNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil
        )

        // Goto tab
        center.addObserver(
            self,
            selector: #selector(handleGotoTab(_:)),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil
        )

        // Focus split
        center.addObserver(
            self,
            selector: #selector(handleFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: nil
        )

        // Equalize splits
        center.addObserver(
            self,
            selector: #selector(handleEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits,
            object: nil
        )

        // Resize split
        center.addObserver(
            self,
            selector: #selector(handleResizeSplit(_:)),
            name: Ghostty.Notification.didResizeSplit,
            object: nil
        )

        // Bell notification - set attention flag on session
        center.addObserver(
            self,
            selector: #selector(handleBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )

        // Command finished notification - set attention flag on session
        center.addObserver(
            self,
            selector: #selector(handleCommandFinished(_:)),
            name: .ghosttyCommandFinished,
            object: nil
        )

        // Key input notification - clear attention flag when user types
        center.addObserver(
            self,
            selector: #selector(handleKeyInput(_:)),
            name: .ghosttyDidReceiveKeyInput,
            object: nil
        )

        // Session note notification - handle notes from terminal escape sequences
        center.addObserver(
            self,
            selector: #selector(handleSessionNote(_:)),
            name: .fantasttySessionNote,
            object: nil
        )
        Self.debugLog("setupNotificationObservers: All observers registered")
    }

    @objc private func handleNewTab(_ notification: Foundation.Notification) {
        let config: Ghostty.SurfaceConfiguration?
        if let userInfo = notification.userInfo,
           let surfaceConfig = userInfo[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration {
            config = surfaceConfig
        } else {
            config = nil
        }
        // Create a new tab in the current session (not a new session)
        createTab(config: config)
    }

    @objc private func handleCloseSurface(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        closeSurface(surfaceView)
    }

    @objc private func handleNewSplit(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let (_, tab) = findSessionAndTab(for: surfaceView),
              let app = ghosttyApp?.app else { return }

        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
        if let ghosttyDir = notification.userInfo?["direction"] as? ghostty_action_split_direction_e {
            switch ghosttyDir {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT:
                direction = .right
            case GHOSTTY_SPLIT_DIRECTION_LEFT:
                direction = .left
            case GHOSTTY_SPLIT_DIRECTION_DOWN:
                direction = .down
            case GHOSTTY_SPLIT_DIRECTION_UP:
                direction = .up
            default:
                direction = .right
            }
        } else {
            direction = .right
        }

        let config: Ghostty.SurfaceConfiguration
        if let userInfo = notification.userInfo,
           let surfaceConfig = userInfo[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration {
            config = surfaceConfig
        } else {
            config = Ghostty.SurfaceConfiguration()
        }

        let newSurface = Ghostty.SurfaceView(app, baseConfig: config)

        do {
            tab.surfaceTree = try tab.surfaceTree.inserting(
                view: newSurface,
                at: surfaceView,
                direction: direction
            )
            tab.focusedSurface = newSurface
            setupTitleObserver(for: tab, surfaceView: newSurface)
        } catch {
            Self.logger.error("Failed to create split: \(error)")
        }
    }

    @objc private func handleGotoTab(_ notification: Foundation.Notification) {
        guard let tab = notification.userInfo?[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e else { return }

        // Ghostty's goto_tab operates on top-level tabs
        // In our model, that maps to tabs within the current session
        guard let session = selectedSession else { return }

        let rawValue = Int(tab.rawValue)
        if rawValue > 0 && rawValue <= session.tabs.count {
            // Direct tab index (1-based in Ghostty)
            session.selectedTabID = session.tabs[rawValue - 1].id
        } else {
            // Special values: previous/next/last
            switch tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS:
                session.selectPreviousTab()
            case GHOSTTY_GOTO_TAB_NEXT:
                session.selectNextTab()
            case GHOSTTY_GOTO_TAB_LAST:
                if let lastTab = session.tabs.last {
                    session.selectedTabID = lastTab.id
                }
            default:
                break
            }
        }
    }

    @objc private func handleFocusSplit(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let (_, tab) = findSessionAndTab(for: surfaceView),
              let direction = notification.userInfo?[Ghostty.Notification.SplitDirectionKey] as? Ghostty.SplitFocusDirection else { return }

        let focusDirection: SplitTree<Ghostty.SurfaceView>.FocusDirection = direction.toSplitTreeFocusDirection()

        guard let currentNode = tab.surfaceTree.root?.node(view: surfaceView),
              let targetView = tab.surfaceTree.focusTarget(for: focusDirection, from: currentNode) else { return }

        tab.focusedSurface = targetView
        Ghostty.moveFocus(to: targetView, from: surfaceView)
    }

    @objc private func handleEqualizeSplits(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let (_, tab) = findSessionAndTab(for: surfaceView) else { return }
        tab.surfaceTree = tab.surfaceTree.equalized()
    }

    @objc private func handleResizeSplit(_ notification: Foundation.Notification) {
        // Resize is handled by the SplitView divider drag
    }

    @objc private func handleBellDidRing(_ notification: Foundation.Notification) {
        Self.debugLog("NOTIFICATION: handleBellDidRing called!")

        // Play the system bell sound so we can verify OUR handler was called
        NSSound.beep()
        Self.debugLog("NOTIFICATION: NSSound.beep() called")

        guard let surfaceView = notification.object as? Ghostty.SurfaceView else {
            Self.debugLog("NOTIFICATION: ERROR - object is not SurfaceView (got: \(type(of: notification.object)))")
            return
        }

        Self.debugLog("NOTIFICATION: SurfaceView id=\(surfaceView.id)")

        guard let (session, tab) = findSessionAndTab(for: surfaceView) else {
            Self.debugLog("NOTIFICATION: ERROR - could not find session/tab for surface")
            return
        }

        Self.debugLog("NOTIFICATION: Found session=\(session.id), tab=\(tab.id)")

        // Only set attention for background sessions
        if session.id != selectedSessionID {
            session.needsAttention = true
            Self.debugLog("NOTIFICATION: ATTENTION FLAG SET for background session!")
        } else {
            Self.debugLog("NOTIFICATION: Skipping - session is currently selected (foreground)")
        }
    }

    @objc private func handleCommandFinished(_ notification: Foundation.Notification) {
        Self.debugLog("NOTIFICATION: handleCommandFinished called!")

        guard let surfaceView = notification.object as? Ghostty.SurfaceView else {
            Self.debugLog("COMMAND_FINISHED: ERROR - object is not SurfaceView")
            return
        }

        Self.debugLog("COMMAND_FINISHED: SurfaceView id=\(surfaceView.id)")

        guard let (session, tab) = findSessionAndTab(for: surfaceView) else {
            Self.debugLog("COMMAND_FINISHED: ERROR - could not find session/tab for surface")
            return
        }

        Self.debugLog("COMMAND_FINISHED: Found session=\(session.id), tab=\(tab.id)")

        // Only set attention for background sessions
        if session.id != selectedSessionID {
            session.needsAttention = true
            Self.debugLog("COMMAND_FINISHED: ATTENTION FLAG SET for background session!")
        } else {
            Self.debugLog("COMMAND_FINISHED: Skipping - session is currently selected (foreground)")
        }
    }

    @objc private func handleKeyInput(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }

        guard let (session, _) = findSessionAndTab(for: surfaceView) else { return }

        // Clear attention when user types in this session
        if session.needsAttention {
            session.needsAttention = false
            Self.debugLog("KEY_INPUT: Cleared attention for session \(session.id)")
        }
    }

    @objc private func handleSessionNote(_ notification: Foundation.Notification) {
        Self.debugLog("SESSION_NOTE: handleSessionNote called!")

        guard let surfaceView = notification.object as? Ghostty.SurfaceView else {
            Self.debugLog("SESSION_NOTE: ERROR - object is not SurfaceView")
            return
        }

        guard let content = notification.userInfo?["content"] as? String else {
            Self.debugLog("SESSION_NOTE: ERROR - no content in userInfo")
            return
        }

        Self.debugLog("SESSION_NOTE: content='\(content)' surfaceView=\(surfaceView.id)")

        guard let (session, _) = findSessionAndTab(for: surfaceView) else {
            Self.debugLog("SESSION_NOTE: ERROR - could not find session for surface")
            return
        }

        Self.debugLog("SESSION_NOTE: Found session=\(session.id)")

        // Add the note entry to the session
        session.addNote(content: content, source: .terminal)
        Self.debugLog("SESSION_NOTE: Note added to session")

        // Set attention flag if this is a background session
        if session.id != selectedSessionID {
            session.needsAttention = true
            Self.debugLog("SESSION_NOTE: ATTENTION FLAG SET for background session")
        }
    }

    // MARK: - Private Helpers

    private func setupTitleObserver(for tab: TerminalTab, surfaceView: Ghostty.SurfaceView) {
        Self.debugLog("setupTitleObserver: Setting up observers for surface \(surfaceView.id)")

        // Observe title changes
        // Observe title changes to update tab title (but NOT for attention detection)
        surfaceView.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak tab, weak surfaceView] newTitle in
                guard let tab = tab, let surfaceView = surfaceView else { return }
                guard !newTitle.isEmpty else { return }

                // Update tab title if this surface is focused (or only surface)
                if tab.focusedSurface === surfaceView || !tab.surfaceTree.isSplit {
                    tab.title = newTitle
                }
            }
            .store(in: &titleCancellables)

        // Observe bell state changes - only set attention for background sessions
        surfaceView.$bell
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak surfaceView] bellActive in
                Self.debugLog("BELL STATE: \(bellActive)")
                guard bellActive, let self = self, let surfaceView = surfaceView else { return }
                Self.debugLog("BELL: Active! Looking for session...")
                if let (session, _) = self.findSessionAndTab(for: surfaceView) {
                    if session.id != self.selectedSessionID {
                        session.needsAttention = true
                        Self.debugLog("BELL: Set attention for BACKGROUND session \(session.id)")
                    } else {
                        Self.debugLog("BELL: Skipping - session is currently selected (foreground)")
                    }
                } else {
                    Self.debugLog("BELL: ERROR - Could not find session for surface")
                }
            }
            .store(in: &titleCancellables)

        Self.debugLog("setupTitleObserver: Observers registered")
    }

    private func findSurface(in node: SplitTree<Ghostty.SurfaceView>.Node, uuid: UUID) -> Ghostty.SurfaceView? {
        switch node {
        case .leaf(let view):
            return view.id == uuid ? view : nil
        case .split(let split):
            return findSurface(in: split.left, uuid: uuid) ?? findSurface(in: split.right, uuid: uuid)
        }
    }

    private func firstLeafView(in node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        switch node {
        case .leaf(let view):
            return view
        case .split(let split):
            return firstLeafView(in: split.left)
        }
    }
}
