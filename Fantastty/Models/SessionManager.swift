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

    /// Whether persistent tmux sessions are enabled
    @AppStorage("persistentSessions") var persistentSessionsEnabled: Bool = false

    /// Reference to tmux manager
    private let tmuxManager = TmuxManager.shared

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

    /// Whether the notes panel is expanded
    @Published var notesExpanded: Bool = false

    /// Reference to the Ghostty app state
    var ghosttyApp: Ghostty.App?

    private var titleCancellables = Set<AnyCancellable>()

    /// Local event monitor for routing keystrokes to tmux in control mode
    private var keyEventMonitor: Any?

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

    // MARK: - Workspace Name Generation

    private static func generateWorkspaceName() -> String {
        let adjectives = ["swift", "bold", "calm", "keen", "warm", "bright", "quick",
                          "fresh", "sharp", "steady", "clear", "deep", "light", "golden",
                          "silver", "amber", "coral", "jade", "sage", "iron"]
        let nouns = ["falcon", "harbor", "maple", "spark", "wave", "cedar", "ridge",
                     "brook", "mesa", "dusk", "pine", "reef", "cove", "peak", "vale",
                     "moss", "flint", "glade", "drift", "helm"]
        return "\(adjectives.randomElement()!)-\(nouns.randomElement()!)"
    }

    // MARK: - Layout Persistence

    /// Path to the layout snapshot file.
    private static let layoutURL: URL = {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".fantastty/layout.json")
    }()

    /// Save the current layout (sidebar order, tab order, selections) to disk.
    func saveLayout() {
        guard persistentSessionsEnabled else { return }

        var workspaces: [WorkspaceLayout] = []

        for session in sessions {
            guard let baseSessionName = session.tmuxSessionName else { continue }

            let tabSessionNames = session.tabs.dropFirst().compactMap { $0.tmuxSessionName }

            let selectedTabIndex: Int?
            if let selectedID = session.selectedTabID,
               let idx = session.tabs.firstIndex(where: { $0.id == selectedID }) {
                selectedTabIndex = idx
            } else {
                selectedTabIndex = nil
            }

            workspaces.append(WorkspaceLayout(
                workspaceID: session.workspaceID,
                baseSessionName: baseSessionName,
                tabSessionNames: tabSessionNames,
                selectedTabIndex: selectedTabIndex,
                sessionType: session.type == .local ? nil : session.type
            ))
        }

        let snapshot = LayoutSnapshot(
            workspaces: workspaces,
            selectedWorkspaceID: selectedSession?.workspaceID,
            savedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: Self.layoutURL, options: .atomic)
            Self.logger.info("Saved layout snapshot with \(workspaces.count) workspaces")
        } catch {
            Self.logger.error("Failed to save layout: \(error)")
        }
    }

    /// Load a layout snapshot from disk. Returns nil if missing or corrupt.
    private func loadLayout() -> LayoutSnapshot? {
        guard FileManager.default.fileExists(atPath: Self.layoutURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: Self.layoutURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LayoutSnapshot.self, from: data)
        } catch {
            Self.logger.warning("Failed to load layout snapshot: \(error)")
            return nil
        }
    }

    /// Delete the layout snapshot file after consumption.
    private func deleteLayout() {
        try? FileManager.default.removeItem(at: Self.layoutURL)
    }

    // MARK: - Session Restoration

    /// Restore sessions from existing tmux sessions.
    /// Call this on app launch before creating new sessions.
    /// Uses a saved layout snapshot (if available) to preserve sidebar order
    /// and workspace selection. Control mode discovers all panes automatically.
    /// Returns true if any sessions were restored.
    @discardableResult
    func restoreTmuxSessions() -> Bool {
        let isPersistent = persistentSessionsEnabled
        let isTmuxAvailable = tmuxManager.isTmuxAvailable
        guard isPersistent, isTmuxAvailable else {
            Self.logger.info("Tmux restoration skipped: persistentSessions=\(isPersistent), tmuxAvailable=\(isTmuxAvailable)")
            return false
        }

        var liveWorkspaces = tmuxManager.groupSessionsByWorkspace()
        let layout = loadLayout()
        var restoredCount = 0
        var restoredIDs = Set<String>()

        // Phase 1: Restore workspaces in layout order (preserves sidebar ordering)
        if let layout = layout {
            Self.logger.info("Restoring with layout snapshot (\(layout.workspaces.count) workspaces)")

            for wsLayout in layout.workspaces {
                let workspaceID = wsLayout.workspaceID

                if SessionMetadataStore.shared.getOrCreate(forKey: workspaceID).isArchived {
                    Self.logger.info("Skipping archived workspace \(workspaceID)")
                    continue
                }

                let sessionType = wsLayout.sessionType ?? .local

                if sessionType == .local {
                    // Local: verify tmux session is still alive, then use control mode
                    guard liveWorkspaces[workspaceID]?.isValid == true else {
                        Self.logger.info("Skipping stale workspace \(workspaceID)")
                        continue
                    }
                    if createSession(type: .local, workspaceID: workspaceID) != nil {
                        restoredCount += 1
                    }
                } else if case .ssh = sessionType {
                    // SSH: recreate (remote tmux may still be alive even if local is gone)
                    createSession(type: sessionType, workspaceID: workspaceID)
                    restoredCount += 1
                }

                restoredIDs.insert(workspaceID)
            }

            // Restore selected workspace
            if let selectedWSID = layout.selectedWorkspaceID,
               let selectedSession = sessions.first(where: { $0.workspaceID == selectedWSID }) {
                selectedSessionID = selectedSession.id
            }
        }

        // Phase 2: Restore any live workspaces not already handled
        for (workspaceID, workspace) in liveWorkspaces {
            guard !restoredIDs.contains(workspaceID),
                  workspace.isValid,
                  !SessionMetadataStore.shared.getOrCreate(forKey: workspaceID).isArchived else { continue }

            Self.logger.info("Restoring discovered workspace \(workspaceID)")
            if createSession(type: .local, workspaceID: workspaceID) != nil {
                restoredCount += 1
            }
        }

        deleteLayout()
        Self.logger.info("Restored \(restoredCount) workspaces from tmux")
        return restoredCount > 0
    }

    // MARK: - Session Management (Sidebar)

    /// Create a new session (sidebar item) with an initial tab.
    @discardableResult
    func createSession(type: SessionType = .local, config: Ghostty.SurfaceConfiguration? = nil, tmuxSessionName: String? = nil, workspaceID: String? = nil) -> Session? {
        guard let app = ghosttyApp?.app else {
            Self.logger.error("Cannot create session: ghostty app not initialized")
            return nil
        }

        var surfaceConfig = config ?? Ghostty.SurfaceConfiguration()

        // Generate a workspace ID for this session (or use provided one for reconnection)
        let workspaceID = workspaceID ?? String(UUID().uuidString.prefix(8).lowercased())
        var actualTmuxSessionName: String? = nil

        // Use tmux if enabled and available
        let useControlMode = persistentSessionsEnabled && tmuxManager.isTmuxAvailable && tmuxSessionName == nil && type == .local
        Self.debugLog("createSession: persistent=\(persistentSessionsEnabled) tmuxAvailable=\(tmuxManager.isTmuxAvailable) tmuxSessionName=\(tmuxSessionName ?? "nil") type=\(type.displayName) useControlMode=\(useControlMode)")
        if persistentSessionsEnabled && tmuxManager.isTmuxAvailable && !useControlMode {
            if let existingSession = tmuxSessionName {
                // Reattaching to existing session
                actualTmuxSessionName = existingSession
                surfaceConfig.command = tmuxManager.commandForAttach(sessionName: existingSession)
            } else {
                // Creating new tmux session
                actualTmuxSessionName = tmuxManager.baseSessionName(workspaceID: workspaceID)
                var paneCommand: String? = nil
                if case .ssh = type, let sshCmd = type.sshCommand {
                    let remoteSessionName = "fantastty-\(workspaceID)"
                    paneCommand = "\(sshCmd) tmux new-session -A -s \"\(remoteSessionName)\""
                }
                surfaceConfig.command = tmuxManager.commandForFirstTab(
                    sessionName: actualTmuxSessionName!,
                    workingDirectory: type == .local ? surfaceConfig.workingDirectory : nil,
                    paneCommand: paneCommand
                )
            }
            Self.logger.info("Using tmux session: \(actualTmuxSessionName ?? "nil")")
        } else if !useControlMode, let command = type.command {
            surfaceConfig.command = command
        }

        if useControlMode {
            // Control mode: create session with no tabs — tabs are created
            // asynchronously when tmux reports panes via windowsChanged delegate.
            let sessionName = tmuxManager.baseSessionName(workspaceID: workspaceID)
            actualTmuxSessionName = sessionName

            let session = Session(type: type, workspaceID: workspaceID)
            session.tmuxSessionName = sessionName

            // Auto-generate workspace name
            let metadataStore = SessionMetadataStore.shared
            let meta = metadataStore.getOrCreate(forKey: workspaceID)
            if meta.name.isEmpty {
                metadataStore.update(forKey: workspaceID, name: Self.generateWorkspaceName())
            }

            sessions.append(session)
            selectedSessionID = session.id

            // Start control mode connection
            let control = TmuxControlConnection(
                tmuxPath: tmuxManager.tmuxPath,
                sessionName: sessionName,
                delegate: self
            )
            session.controlConnection = control

            control.start()
            Self.debugLog("CONTROL: Started control mode for workspace \(workspaceID) session=\(sessionName)")
            return session
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: surfaceConfig)
        let session = Session(type: type, surfaceView: surfaceView, workspaceID: workspaceID)

        // Store tmux session name if using persistent sessions
        if let tmuxName = actualTmuxSessionName {
            session.tmuxSessionName = tmuxName
            // Track tmux session name on the initial tab
            session.selectedTab?.tmuxSessionName = tmuxName
        }

        // Auto-generate workspace name for new sessions (not reattaches)
        if tmuxSessionName == nil {
            let metadataStore = SessionMetadataStore.shared
            let meta = metadataStore.getOrCreate(forKey: workspaceID)
            if meta.name.isEmpty {
                metadataStore.update(forKey: workspaceID, name: Self.generateWorkspaceName())
            }
        }

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
    /// When killTmux is true (default), also kills the tmux session.
    /// Set killTmux to false when quitting the app to leave sessions running.
    func closeSession(id: UUID, killTmux: Bool = true) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let session = sessions[index]

        // Stop control connection if active
        session.controlConnection?.stop()
        session.controlConnection = nil

        // Kill tmux session if requested and session has one
        if killTmux {
            let wsID = session.workspaceID
            tmuxManager.killWorkspaceSessions(workspaceID: wsID)
            Self.logger.info("Killed tmux sessions for workspace \(wsID)")
        }

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

    // MARK: - Workspace Archiving

    /// Archive a workspace: kill tmux, set metadata flag, remove from active sessions.
    func archiveSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]

        // Kill tmux sessions
        tmuxManager.killWorkspaceSessions(workspaceID: session.workspaceID)

        // Set archived flag in metadata
        let metadataStore = SessionMetadataStore.shared
        metadataStore.update(forKey: session.workspaceID, isArchived: true)

        // Remove from active sessions
        sessions.remove(at: index)

        // Update selection (same logic as closeSession)
        if selectedSessionID == id {
            if !sessions.isEmpty {
                let newIndex = min(index, sessions.count - 1)
                selectedSessionID = sessions[newIndex].id
            } else {
                selectedSessionID = nil
                createSession()
            }
        }

        Self.logger.info("Archived session \(id)")
    }

    /// Unarchive a workspace: clear archived flag, create a fresh session.
    func unarchiveSession(workspaceID: String) {
        let metadataStore = SessionMetadataStore.shared
        metadataStore.update(forKey: workspaceID, isArchived: false)

        createSession(workspaceID: workspaceID)
    }

    /// Permanently delete an archived workspace's metadata.
    func deleteArchivedWorkspace(workspaceID: String) {
        SessionMetadataStore.shared.remove(forKey: workspaceID)
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

        // In control mode, ask tmux to create a new window (tab appears via delegate)
        if let control = session.controlConnection {
            control.send("new-window")
            Self.logger.info("Requested new tmux window via control mode")
            return nil  // Tab created asynchronously via %window-add → windowsChanged
        }

        var surfaceConfig = config ?? Ghostty.SurfaceConfiguration()
        var actualTabSessionName: String? = nil

        // Use independent tmux session if persistent sessions are active
        if session.tmuxSessionName != nil,
           tmuxManager.isTmuxAvailable {
            session.tmuxTabCounter += 1
            let tabSessionName = tmuxManager.tabSessionName(
                workspaceID: session.workspaceID,
                tabIndex: session.tmuxTabCounter
            )
            surfaceConfig.command = tmuxManager.commandForTabSession(
                tabSessionName: tabSessionName
            )
            actualTabSessionName = tabSessionName
            Self.logger.info("Using independent tmux session: \(tabSessionName)")
        } else if let command = type.command {
            surfaceConfig.command = command
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: surfaceConfig)
        let tab = TerminalTab(type: type, surfaceView: surfaceView)
        tab.tmuxSessionName = actualTabSessionName

        session.addTab(tab)
        setupTitleObserver(for: tab, surfaceView: surfaceView)

        Self.logger.info("Created tab \(tab.id) in session \(session.id)")
        return tab
    }

    /// Create a new browser tab in the current session.
    @discardableResult
    func createBrowserTab(url: URL = URL(string: "https://www.google.com")!) -> TerminalTab? {
        guard let session = selectedSession else {
            Self.logger.error("Cannot create browser tab: no session")
            return nil
        }

        let tab = TerminalTab(url: url)
        session.addTab(tab)

        Self.logger.info("Created browser tab \(tab.id) in session \(session.id)")
        return tab
    }

    /// Close a tab within its session. If last tab, closes the session.
    func closeTab(id: UUID) {
        guard let session = sessions.first(where: { $0.tabs.contains { $0.id == id } }) else { return }

        // In control mode, ask tmux to kill the window instead of closing locally
        if let control = session.controlConnection,
           let tab = session.tabs.first(where: { $0.id == id }),
           let windowId = tab.tmuxWindowId {
            control.send("kill-window -t @\(windowId)")
            Self.logger.info("Requested kill-window @\(windowId) via control mode")
            // Tab removed via %window-close → windowClosed delegate callback
            return
        }

        // Kill the tab's linked tmux session (skip base session — other tabs need it)
        if let tab = session.tabs.first(where: { $0.id == id }),
           let tabTmuxName = tab.tmuxSessionName,
           tabTmuxName != session.tmuxSessionName {
            tmuxManager.killSession(name: tabTmuxName)
        }

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
            guard let tree = tab.surfaceTree else { return }
            tab.surfaceTree = try tree.inserting(
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
        guard let (_, tab) = findSessionAndTab(for: surfaceView) else { return }

        guard let node = tab.surfaceTree?.root?.node(view: surfaceView) else { return }

        if let newRoot = tab.surfaceTree?.root?.remove(node) {
            tab.surfaceTree = SplitTree(root: newRoot, zoomed: nil)
            // Focus the first leaf of the remaining tree
            if let firstView = firstLeafView(in: newRoot) {
                tab.focusedSurface = firstView
            }
        } else {
            // This was the last surface in the tab — close via SessionManager for tmux cleanup
            closeTab(id: tab.id)
        }
    }

    // MARK: - Lookup Helpers

    /// Find a surface view by UUID.
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for session in sessions {
            for tab in session.tabs {
                if let node = tab.surfaceTree?.root {
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

        // Ticket URL notification
        center.addObserver(
            self,
            selector: #selector(handleTicketURL(_:)),
            name: .fantasttyTicketURL,
            object: nil
        )

        // Pull request URL notification
        center.addObserver(
            self,
            selector: #selector(handlePullRequestURL(_:)),
            name: .fantasttyPullRequestURL,
            object: nil
        )

        // Key event monitor for routing keystrokes to tmux in control mode
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleControlModeKeyEvent(event)
        }

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
            guard let tree = tab.surfaceTree else { return }
            tab.surfaceTree = try tree.inserting(
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

        guard let currentNode = tab.surfaceTree?.root?.node(view: surfaceView),
              let targetView = tab.surfaceTree?.focusTarget(for: focusDirection, from: currentNode) else { return }

        tab.focusedSurface = targetView
        Ghostty.moveFocus(to: targetView, from: surfaceView)
    }

    @objc private func handleEqualizeSplits(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let (_, tab) = findSessionAndTab(for: surfaceView) else { return }
        if let tree = tab.surfaceTree {
            tab.surfaceTree = tree.equalized()
        }
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

    @objc private func handleTicketURL(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let url = notification.userInfo?["url"] as? String,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }
        session.ticketURL = url.isEmpty ? nil : url
        Self.debugLog("TICKET_URL: Set '\(url)' for session \(session.id)")
    }

    @objc private func handlePullRequestURL(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let url = notification.userInfo?["url"] as? String,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }
        session.pullRequestURL = url.isEmpty ? nil : url
        Self.debugLog("PR_URL: Set '\(url)' for session \(session.id)")
    }

    // MARK: - Control Mode Helpers

    /// Create a control mode tab with an inert surface for a tmux pane.
    @discardableResult
    private func createControlModeTab(
        session: Session,
        pane: TmuxPane,
        app: ghostty_app_t
    ) -> TerminalTab {
        var config = Ghostty.SurfaceConfiguration()
        // Inert subprocess: disable echo to prevent DSR responses from being echoed back
        // as visible garbage, then exec tail to hold the PTY open.
        config.command = "/bin/sh -c 'stty -echo 2>/dev/null; exec tail -f /dev/null'"

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        let tab = TerminalTab(type: session.type, surfaceView: surfaceView)
        tab.tmuxPaneId = pane.paneId
        tab.tmuxWindowId = pane.windowId

        session.addTab(tab)
        session.paneTabMap[pane.paneId] = tab.id
        setupTitleObserver(for: tab, surfaceView: surfaceView)
        setupResizeObserver(for: surfaceView, session: session)

        return tab
    }

    /// Observe a control mode surface's grid size and sync to tmux when it changes.
    private func setupResizeObserver(for surfaceView: Ghostty.SurfaceView, session: Session) {
        // Clear surface on first valid size — wipe stale content that arrived
        // before tmux knew the correct dimensions.
        surfaceView.$surfaceSize
            .compactMap { $0 }
            .filter { $0.columns > 0 && $0.rows > 0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak surfaceView] _ in
                guard let self = self, let surfaceView = surfaceView else { return }
                // ESC[2J = clear screen, ESC[H = cursor home
                self.injectOutput(into: surfaceView, data: Data([0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48]))
            }
            .store(in: &titleCancellables)

        // Ongoing: sync tmux client size whenever the grid dimensions change.
        surfaceView.$surfaceSize
            .compactMap { $0 }
            .removeDuplicates { $0.columns == $1.columns && $0.rows == $1.rows }
            .receive(on: DispatchQueue.main)
            .sink { [weak session] size in
                guard let session = session,
                      let control = session.controlConnection,
                      size.columns > 0, size.rows > 0 else { return }
                control.send("refresh-client -C \(size.columns)x\(size.rows)")
                Self.debugLog("CONTROL: surface resized → refresh-client \(size.columns)x\(size.rows)")
            }
            .store(in: &titleCancellables)
    }

    /// Inject raw output data into a surface via the Ghostty C API.
    private func injectOutput(into surfaceView: Ghostty.SurfaceView, data: Data) {
        guard let surface = surfaceView.surface else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_inject_output(surface, ptr, UInt(buffer.count))
        }
    }

    /// Find the surface view for a given tmux pane ID within a session.
    private func surfaceForPane(_ paneId: Int, in session: Session) -> Ghostty.SurfaceView? {
        guard let tabId = session.paneTabMap[paneId],
              let tab = session.tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.focusedSurface
    }

    /// Route a keystroke from a control mode tab to tmux via send-keys.
    func routeKeyToTmux(paneId: Int, text: String, session: Session) {
        guard let control = session.controlConnection else { return }
        let hex = text.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
        control.send("send-keys -t %\(paneId) -H \(hex)")
    }

    /// Handle a key event for control mode surfaces.
    /// Returns nil to consume the event (prevent Ghostty from writing to the inert PTY,
    /// which would cause double-echo). Returns the event for non-control-mode surfaces
    /// and Cmd+ shortcuts.
    private func handleControlModeKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Find the session/tab for the currently focused surface
        guard let session = selectedSession,
              let control = session.controlConnection,
              let tab = session.selectedTab,
              let paneId = tab.tmuxPaneId else {
            return event
        }

        // Skip Cmd+key combinations (app shortcuts like Cmd+C, Cmd+V, Cmd+T)
        if event.modifierFlags.contains(.command) {
            return event
        }

        // Map special keys to tmux key names
        if let tmuxKey = tmuxKeyName(for: event) {
            control.send("send-keys -t %\(paneId) \(tmuxKey)")
            return nil  // Consume event — tmux handles it
        }

        // For regular text input, hex-encode the characters
        if let chars = event.characters, !chars.isEmpty {
            let hex = chars.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
            control.send("send-keys -t %\(paneId) -H \(hex)")
            return nil  // Consume event — tmux handles it
        }

        return event
    }

    /// Map an NSEvent keyCode to a tmux key name for special keys.
    /// Returns nil for regular text keys (handled via hex encoding).
    private func tmuxKeyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 0x24: return "Enter"       // Return
        case 0x30: return "Tab"         // Tab
        case 0x33: return "BSpace"      // Backspace
        case 0x35: return "Escape"      // Escape
        case 0x75: return "DC"          // Forward Delete
        case 0x7E: return "Up"          // Up Arrow
        case 0x7D: return "Down"        // Down Arrow
        case 0x7B: return "Left"        // Left Arrow
        case 0x7C: return "Right"       // Right Arrow
        case 0x73: return "Home"        // Home
        case 0x77: return "End"         // End
        case 0x74: return "PageUp"      // Page Up (NPage in tmux)
        case 0x79: return "PageDown"    // Page Down
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default: return nil
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
                if tab.focusedSurface === surfaceView || !(tab.surfaceTree?.isSplit ?? false) {
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

    /// Find the session that owns a given control connection.
    private func session(for connection: TmuxControlConnection) -> Session? {
        return sessions.first { $0.controlConnection === connection }
    }
}

// MARK: - TmuxControlConnectionDelegate

extension SessionManager: TmuxControlConnectionDelegate {
    func controlConnection(_ connection: TmuxControlConnection, windowsChanged windows: [TmuxWindow]) {
        guard let session = session(for: connection),
              let app = ghosttyApp?.app else { return }

        Self.debugLog("CONTROL: windowsChanged with \(windows.count) windows, \(windows.flatMap(\.panes).count) panes")

        // Collect all pane IDs from the new window list
        var newPaneIds = Set<Int>()
        for window in windows {
            for pane in window.panes {
                newPaneIds.insert(pane.paneId)
            }
        }

        // Remove tabs for panes that no longer exist
        let existingPaneIds = Set(session.paneTabMap.keys)
        for paneId in existingPaneIds where !newPaneIds.contains(paneId) {
            if let tabId = session.paneTabMap.removeValue(forKey: paneId) {
                session.closeTab(id: tabId)
            }
        }

        // Add tabs for new panes
        var createdNewTabs = false
        for window in windows {
            for pane in window.panes {
                if session.paneTabMap[pane.paneId] == nil {
                    createControlModeTab(session: session, pane: pane, app: app)
                    Self.debugLog("CONTROL: Created tab for pane %\(pane.paneId) window @\(pane.windowId)")
                    createdNewTabs = true
                }
            }
        }

        Self.debugLog("CONTROL: Session now has \(session.tabs.count) tabs, paneTabMap=\(session.paneTabMap)")
    }

    func controlConnection(_ connection: TmuxControlConnection, paneOutput paneId: Int, data: Data) {
        guard let session = session(for: connection) else {
            Self.debugLog("CONTROL: paneOutput %\(paneId) - no session found")
            return
        }
        guard let surfaceView = surfaceForPane(paneId, in: session) else {
            Self.debugLog("CONTROL: paneOutput %\(paneId) - no surface (paneTabMap=\(session.paneTabMap))")
            return
        }
        injectOutput(into: surfaceView, data: data)
    }

    func controlConnection(_ connection: TmuxControlConnection, windowClosed windowId: Int) {
        guard let session = session(for: connection) else { return }

        // Find and close all tabs associated with this window
        let panesToRemove = session.paneTabMap.filter { paneId, _ in
            // Look up the pane's window from the connection's window list
            // Since the window was already removed from connection.windows by handleWindowClose,
            // find tabs that have this window ID
            if let tab = session.tabs.first(where: { $0.id == session.paneTabMap[paneId] }) {
                return tab.tmuxWindowId == windowId
            }
            return false
        }

        for (paneId, tabId) in panesToRemove {
            session.paneTabMap.removeValue(forKey: paneId)
            let isEmpty = session.closeTab(id: tabId)
            if isEmpty {
                closeSession(id: session.id)
                return
            }
        }
    }

    func controlConnectionDidExit(_ connection: TmuxControlConnection) {
        guard let session = session(for: connection) else { return }
        Self.logger.warning("Control connection exited for workspace \(session.workspaceID)")
        session.controlConnection = nil
        // Optionally attempt reconnection here in the future
    }
}
