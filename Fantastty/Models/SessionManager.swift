import SwiftUI
import GhosttyKit
import os
import Combine
import AppKit
import WebKit

/// Central orchestrator for all terminal sessions.
/// Routes libghostty notifications to the correct session/tab.
class SessionManager: ObservableObject {
    typealias TmuxOutputInjector = (Ghostty.SurfaceView, Data) -> Bool
    typealias TmuxWindowInitialCaptureRequester = TmuxSessionBridge.TmuxWindowInitialCaptureRequester
    typealias AttachedTmuxSplitSender = (TmuxControlClient, Int, Bool) async throws -> Void
    typealias AttachedTmuxNewWindowSender = (TmuxControlClient) async throws -> String
    typealias LiveTmuxWorkspaceProvider = () -> [String: TmuxWorkspaceInfo]
    typealias AttachedSessionReconnectStarter = (Session) -> Void
    typealias WorkspaceMetadataProvider = () -> [SessionMetadata]

    final class ThumbnailRefreshController {
        private enum Reason: Hashable {
            case startup
            case scroll
        }

        private let startupResumeDelay: TimeInterval
        private let scrollResumeDelay: TimeInterval
        private var activeReasons: Set<Reason> = []
        private var resumeTasks: [Reason: Task<Void, Never>] = [:]

        var onStateChange: ((Bool) -> Void)?

        private(set) var isSuspended = false {
            didSet {
                guard oldValue != isSuspended else { return }
                onStateChange?(isSuspended)
            }
        }

        init(
            startupResumeDelay: TimeInterval = 1.5,
            scrollResumeDelay: TimeInterval = 0.35
        ) {
            self.startupResumeDelay = startupResumeDelay
            self.scrollResumeDelay = scrollResumeDelay
        }

        deinit {
            resumeTasks.values.forEach { $0.cancel() }
        }

        func beginStartup() {
            suspend(.startup)
        }

        func endStartup() {
            scheduleResume(for: .startup, after: startupResumeDelay)
        }

        func noteScrollActivity() {
            suspend(.scroll)
            scheduleResume(for: .scroll, after: scrollResumeDelay)
        }

        private func suspend(_ reason: Reason) {
            resumeTasks[reason]?.cancel()
            activeReasons.insert(reason)
            updateSuspensionState()
        }

        private func scheduleResume(for reason: Reason, after delay: TimeInterval) {
            resumeTasks[reason]?.cancel()

            let delayNanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            resumeTasks[reason] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }

                guard let self else { return }
                await MainActor.run {
                    self.activeReasons.remove(reason)
                    self.resumeTasks[reason] = nil
                    self.updateSuspensionState()
                }
            }
        }

        private func updateSuspensionState() {
            isSuspended = !activeReasons.isEmpty
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "session-manager"
    )
    static var layoutURLOverride: URL?
    private var testLayoutURL: URL?

    private static func defaultSessionMetadataStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionMetadataStore {
        guard environment["XCTestConfigurationFilePath"] != nil else {
            return .shared
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
        return SessionMetadataStore(fileURL: fileURL)
    }

    private static func defaultLayoutURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString)-layout.json")
    }

    /// Whether persistent tmux sessions are enabled
    @AppStorage("persistentSessions") var persistentSessionsEnabled: Bool = false

    /// Reference to tmux manager
    private let tmuxManager = TmuxManager.shared

    /// Fallback coalescing injectors keyed by pane ID.
    /// The TmuxSessionBridge's own injectors handle the primary path;
    /// this covers the SessionManager-level override if set.
    private var fallbackInjectors: [Int: CoalescingInjector] = [:]

    private func defaultTmuxOutputInjector(_ surface: Ghostty.SurfaceView, _ data: Data) -> Bool {
        guard surface.surface != nil else { return false }
        guard let paneID = surface.tmuxPaneID else { return false }
        let injector = fallbackInjectors[paneID] ?? {
            let new = CoalescingInjector(paneID: paneID, surface: surface)
            fallbackInjectors[paneID] = new
            return new
        }()
        injector.updateSurface(surface)
        injector.enqueue(data)
        return true
    }

    private static func defaultAttachedTmuxSplitSender(
        _ client: TmuxControlClient,
        _ paneID: Int,
        _ horizontal: Bool
    ) async throws {
        try await client.splitPane(paneID: paneID, horizontal: horizontal)
    }

    private static func defaultAttachedTmuxNewWindowSender(
        _ client: TmuxControlClient
    ) async throws -> String {
        try await client.newWindow()
    }

    private static func connectAttachedSessionWithTimeout(
        _ client: TmuxControlClient,
        timeoutSeconds: TimeInterval = 20
    ) async throws {
        let timeoutNanoseconds = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.connect()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                await client.disconnect()
                throw TmuxControlError.serverError("timed out waiting for tmux control handshake")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func defaultAttachedSessionReconnectStarter(_ session: Session) {
        guard let client = session.controlClient else { return }
        logger.info(
            "Attached tmux reconnect start workspace=\(session.workspaceID, privacy: .public) session=\(client.attachmentInfo.sessionName, privacy: .public) launchMode=\(client.attachmentInfo.launchMode.rawValue, privacy: .public)"
        )

        Task { @MainActor [weak session] in
            do {
                try await connectAttachedSessionWithTimeout(client)
            } catch {
                guard let session else { return }
                #if DEBUG
                let trace = await client.currentDebugTrace()
                let tailTrace = trace.suffix(30).joined(separator: " | ")
                logger.error(
                    "Attached tmux reconnect failed workspace=\(session.workspaceID, privacy: .public) error=\(error.localizedDescription, privacy: .public) trace=\(tailTrace, privacy: .public)"
                )
                #else
                logger.error(
                    "Attached tmux reconnect failed workspace=\(session.workspaceID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                #endif
                if case .attached(var info) = session.mode {
                    info.connectionState = .disconnected(reason: error.localizedDescription)
                    session.mode = .attached(info)
                }
                if !session.tabs.contains(where: { $0.kind == .terminal }) {
                    session.backingState = .missingAttachedBacking(reason: error.localizedDescription)
                }
            }
        }
    }

    /// All sessions (sidebar items)
    @Published var sessions: [Session] = []

    /// Currently selected session ID (sidebar selection)
    @Published var selectedSessionID: UUID?

    /// The pending request for the unified session launcher sheet.
    @Published var sessionLauncherRequest: SessionLauncherRequest?

    /// The set of tmux sessions currently attached in the app.
    var attachedTmuxSessionKeys: Set<AttachedSessionKey> {
        var keys = Set<AttachedSessionKey>()
        for session in sessions {
            if case .attached(let info) = session.mode {
                keys.insert(.init(sessionName: info.sessionName, host: info.host))
            }
        }
        return keys
    }

    func showSessionLauncher(_ request: SessionLauncherRequest = .local()) {
        sessionLauncherRequest = request
    }

    func performSessionLauncherAction(_ action: SessionLauncherAction) {
        switch action {
        case .createSession(let type):
            createSession(type: type)
        case .createRemoteEngine(let host):
            createRemoteEngineSession(host: host)
        case .attachTmux(let info):
            attachToTmuxSession(info: info)
        case .connectSprite(let name):
            createSession(type: .sprite(name: name))
        case .createSprite:
            assertionFailure("Sprite creation is asynchronous and belongs in SessionLauncherSheet")
        }
    }

    /// Whether the notes panel is expanded
    @Published var notesExpanded: Bool = false

    /// Whether thumbnail refresh work should currently be suppressed.
    @Published private(set) var areThumbnailRefreshesSuspended: Bool = false

    /// Reference to the Ghostty app state
    var ghosttyApp: Ghostty.App? {
        didSet {
            attachedTmuxSessionBridge.ghosttyApp = ghosttyApp
            remoteWorkspaceBridge.ghosttyApp = ghosttyApp
        }
    }

    /// O(1) lookup: surface object identity → (Session, TerminalTab).
    /// Populated in setupTitleObserver; pruned in closeTab/closeSurface/closeSession.
    private var surfaceIndex: [ObjectIdentifier: (Session, TerminalTab)] = [:]
    private let attachedTmuxSessionBridge = TmuxSessionBridge()
    private let remoteWorkspaceBridge = RemoteWorkspaceBridge()
    private var lifecycleRouterByWorkspaceID: [String: TerminalLifecycleRouter] = [:]
    private var remoteEngineClientsByWorkspaceID: [String: RemoteEngineClient] = [:]
    private var remoteEngineTabSelectionCancellables: [String: AnyCancellable] = [:]
    private var remoteEngineTabSelectionSyncSuppressionWorkspaceIDs: Set<String> = []
    private var remoteEngineWorkspacesWaitingForAuthoritativeRender: Set<String> = []
    var tmuxOutputInjector: TmuxOutputInjector! {
        didSet {
            attachedTmuxSessionBridge.tmuxOutputInjector = tmuxOutputInjector
        }
    }
    var tmuxWindowInitialCaptureRequester: TmuxWindowInitialCaptureRequester {
        get { attachedTmuxSessionBridge.tmuxWindowInitialCaptureRequester }
        set { attachedTmuxSessionBridge.tmuxWindowInitialCaptureRequester = newValue }
    }
    var attachedTmuxSplitSender: AttachedTmuxSplitSender = SessionManager.defaultAttachedTmuxSplitSender
    var attachedTmuxNewWindowSender: AttachedTmuxNewWindowSender = SessionManager.defaultAttachedTmuxNewWindowSender
    var tmuxAvailabilityProvider: () -> Bool
    var liveTmuxWorkspaceProvider: LiveTmuxWorkspaceProvider
    var attachedSessionReconnectStarter: AttachedSessionReconnectStarter
    var workspaceMetadataProvider: WorkspaceMetadataProvider
    var sessionMetadataStore: SessionMetadataStore = .shared {
        didSet {
            workspaceMetadataProvider = { [sessionMetadataStore] in
                Array(sessionMetadataStore.metadata.values)
            }
        }
    }
    var remoteEngineBootstrapper: RemoteEngineBootstrapper = SSHRemoteEngineBootstrapper()
    var remoteEngineTransport: RemoteEngineTransport = RemoteEngineNWQUICTransport()
    var remoteEngineReconnectPolicy: RemoteEngineReconnectPolicy = .forever
    var remoteWorkspaceSurfaceFactory: RemoteWorkspaceBridge.SurfaceFactory? {
        get { remoteWorkspaceBridge.surfaceFactory }
        set { remoteWorkspaceBridge.surfaceFactory = newValue }
    }
    var remoteWorkspacePaneGridRenderer: RemoteWorkspaceBridge.PaneGridRenderer {
        get { remoteWorkspaceBridge.paneGridRenderer }
        set { remoteWorkspaceBridge.paneGridRenderer = newValue }
    }
    var remoteWorkspaceRenderDiagnosticHandler: RemoteWorkspaceBridge.RenderDiagnosticHandler? {
        get { remoteWorkspaceBridge.renderDiagnosticHandler }
        set { remoteWorkspaceBridge.renderDiagnosticHandler = newValue }
    }
    private let thumbnailRefreshController = ThumbnailRefreshController()

    // MARK: - Activity Tracking

    /// Last key/mouse input timestamp per workspace ID
    private var lastKeyInputAt: [String: Date] = [:]

    /// Cancellables for SessionManager-owned timers/publishers
    private var smCancellables = Set<AnyCancellable>()

    /// Local event monitor for mouse activity (token returned by NSEvent.addLocalMonitorForEvents)
    private var mouseMonitor: Any?

    private static let idleThreshold: TimeInterval = 60
    private static let tickInterval: TimeInterval = 5

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

    var selectedBrowserTab: TerminalTab? {
        guard let tab = selectedTab, tab.kind == .browser else { return nil }
        return tab
    }

    var canReloadSelectedBrowserTab: Bool {
        selectedBrowserTab?.webView != nil
    }

    var canFocusLocationInSelectedBrowserTab: Bool {
        selectedBrowserTab != nil
    }

    var canGoBackInSelectedBrowserTab: Bool {
        selectedBrowserTab?.webView?.canGoBack ?? false
    }

    var canGoForwardInSelectedBrowserTab: Bool {
        selectedBrowserTab?.webView?.canGoForward ?? false
    }

    init() {
        sessionMetadataStore = Self.defaultSessionMetadataStore()
        testLayoutURL = Self.defaultLayoutURL()
        tmuxAvailabilityProvider = { TmuxManager.shared.isTmuxAvailable }
        liveTmuxWorkspaceProvider = { TmuxManager.shared.groupSessionsByWorkspace() }
        attachedSessionReconnectStarter = SessionManager.defaultAttachedSessionReconnectStarter
        workspaceMetadataProvider = { [sessionMetadataStore] in
            Array(sessionMetadataStore.metadata.values)
        }
        tmuxOutputInjector = { [weak self] surface, data in
            self?.defaultTmuxOutputInjector(surface, data) ?? false
        }
        attachedTmuxSessionBridge.tmuxOutputInjector = tmuxOutputInjector
        remoteWorkspaceBridge.keyframeRequestHandler = { [weak self] workspaceID, paneID, reason in
            self?.remoteEngineClientsByWorkspaceID[workspaceID]?.requestKeyframe(paneID: paneID, reason: reason)
        }
        remoteWorkspaceBridge.paneInputHandler = { [weak self] workspaceID, paneID, data in
            self?.remoteEngineClientsByWorkspaceID[workspaceID]?.sendKeys(paneID: paneID, data: data)
        }
        remoteWorkspaceBridge.paneResizeHandler = { [weak self] workspaceID, paneID, size in
            self?.remoteEngineClientsByWorkspaceID[workspaceID]?.resizePane(paneID: paneID, size: size)
        }
        remoteWorkspaceBridge.tabSelectionSyncHandler = { [weak self] workspaceID, applySelection in
            guard let self else {
                applySelection()
                return
            }
            self.remoteEngineTabSelectionSyncSuppressionWorkspaceIDs.insert(workspaceID)
            defer { self.remoteEngineTabSelectionSyncSuppressionWorkspaceIDs.remove(workspaceID) }
            applySelection()
        }
        remoteWorkspaceBridge.unsupportedPaneStateHandler = { [weak self] workspaceID, state in
            self?.applyUnsupportedRemotePaneState(state, workspaceID: workspaceID)
        }
        remoteWorkspaceBridge.authoritativePaneRenderHandler = { [weak self] workspaceID, _ in
            self?.completeRemoteEngineRenderResume(workspaceID: workspaceID)
        }
        remoteWorkspaceBridge.isPredictiveEchoEnabled = Self.isRemotePredictiveEchoEnabled
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.remoteWorkspaceBridge.isPredictiveEchoEnabled = Self.isRemotePredictiveEchoEnabled
            }
            .store(in: &smCancellables)

        thumbnailRefreshController.onStateChange = { [weak self] isSuspended in
            DispatchQueue.main.async {
                self?.areThumbnailRefreshesSuspended = isSuspended
            }
        }
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private static var isRemotePredictiveEchoEnabled: Bool {
        guard UserDefaults.standard.object(forKey: RemotePredictiveEchoSettings.userDefaultsKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: RemotePredictiveEchoSettings.userDefaultsKey)
    }

    // MARK: - Activity Tracking Methods

    private func activityTick() {
        guard let session = selectedSession else { return }
        let lastInput = lastKeyInputAt[session.workspaceID] ?? .distantPast
        guard Date().timeIntervalSince(lastInput) < Self.idleThreshold else { return }
        session.totalActiveSeconds += Self.tickInterval
    }

    /// Flush all in-memory active times to disk. Call on deselect and app quit.
    func flushActiveTimes() {
        for session in sessions {
            updateActiveTimeMetadata(for: session)
        }
    }

    func beginStartupThumbnailRefreshSuppression() {
        thumbnailRefreshController.beginStartup()
    }

    func endStartupThumbnailRefreshSuppression() {
        thumbnailRefreshController.endStartup()
    }

    func noteThumbnailScrollActivity() {
        thumbnailRefreshController.noteScrollActivity()
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

    private var layoutPersistence: LayoutPersistence {
        LayoutPersistence(layoutURL: Self.layoutURLOverride ?? testLayoutURL)
    }

    private func tmuxHost(for sessionType: SessionType) -> TmuxHost {
        switch sessionType {
        case .ssh(let host, let user, let port):
            return .ssh(SSHHostInfo(user: user, hostname: host, port: port))
        case .local, .sprite:
            return .local
        }
    }

    /// Save the current layout (sidebar order, tab order, selections) to disk.
    func saveLayout() {
        guard persistentSessionsEnabled else { return }
        let snapshot = layoutPersistence.buildSnapshot(
            sessions: sessions,
            selectedWorkspaceID: selectedSession?.workspaceID
        )
        layoutPersistence.save(snapshot)
    }

    /// Load a layout snapshot from disk. Returns nil if missing or corrupt.
    private func loadLayout() -> LayoutSnapshot? {
        layoutPersistence.load()
    }

    // MARK: - Session Restoration

    /// Restore sessions from existing tmux sessions.
    /// Call this on app launch before creating new sessions.
    /// Uses a saved layout snapshot (if available) to preserve sidebar order,
    /// tab order, and selections from the previous session.
    /// Returns true if any sessions were restored.
    @discardableResult
    func restoreTmuxSessions() -> Bool {
        let isPersistent = persistentSessionsEnabled
        let isTmuxAvailable = tmuxAvailabilityProvider()
        guard isPersistent else {
            Self.logger.info("Tmux restoration skipped: persistentSessions=\(isPersistent)")
            return false
        }

        var liveWorkspaces = isTmuxAvailable ? liveTmuxWorkspaceProvider() : [:]
        let layout = loadLayout()
        var restoredCount = 0
        let metadataByWorkspaceID = Dictionary(
            uniqueKeysWithValues: workspaceMetadataProvider()
                .filter { !$0.workspaceID.isEmpty }
                .map { ($0.workspaceID, $0) }
        )

        if let layout = layout {
            Self.logger.info("Restoring with layout snapshot (\(layout.workspaces.count) workspaces)")

            // Restore workspaces in layout order
            for wsLayout in layout.workspaces {
                // Skip archived workspaces (tmux should already be dead, but be defensive)
                let metadata = metadataByWorkspaceID[wsLayout.workspaceID]
                if metadata?.isArchived == true || metadata?.isTrashed == true {
                    Self.logger.info("Skipping inactive workspace \(wsLayout.workspaceID)")
                    liveWorkspaces.removeValue(forKey: wsLayout.workspaceID)
                    continue
                }

                let attachment = wsLayout.attachment
                    ?? metadata?.attachment
                    ?? TmuxAttachmentInfo(
                        sessionName: tmuxManager.baseSessionName(workspaceID: wsLayout.workspaceID),
                        host: tmuxHost(for: wsLayout.sessionType ?? .local),
                        connectionState: .disconnected(reason: nil),
                        launchMode: .attach
                    )
                Self.logger.info("Restoring attached tmux workspace \(wsLayout.workspaceID)")
                restorePersistedAttachmentSession(
                    attachment: attachment,
                    workspaceID: wsLayout.workspaceID,
                    tabLayouts: wsLayout.tabs,
                    selectedTabIndex: wsLayout.selectedTabIndex,
                    autoReconnect: shouldAutoReconnect(
                        attachment: attachment,
                        tmuxAvailable: isTmuxAvailable
                    )
                )
                restoredCount += 1

                // Remove from live workspaces so we know what's left
                liveWorkspaces.removeValue(forKey: wsLayout.workspaceID)
            }

            // Append any live workspaces not in the layout
            for (workspaceID, workspace) in liveWorkspaces {
                guard workspace.isValid, let baseSession = workspace.baseSession else { continue }
                let metadata = metadataByWorkspaceID[workspaceID]
                if metadata?.isArchived == true || metadata?.isTrashed == true {
                    Self.logger.info("Skipping inactive workspace \(workspaceID)")
                    continue
                }

                Self.logger.info("Restoring unlayouted workspace \(workspaceID)")
                restorePersistedAttachmentSession(
                    attachment: TmuxAttachmentInfo(
                        sessionName: baseSession.name,
                        host: .local,
                        connectionState: .disconnected(reason: nil),
                        launchMode: .attach
                    ),
                    workspaceID: workspaceID
                )
                restoredCount += 1
            }

            restoredCount += restoreMetadataOnlyPlaceholders(
                excluding: Set(sessions.map(\.workspaceID)),
                preferredOrder: layout.workspaces.map(\.workspaceID),
                tmuxAvailable: isTmuxAvailable
            )

            // Restore selected workspace
            if let selectedWSID = layout.selectedWorkspaceID,
               let selectedSession = sessions.first(where: { $0.workspaceID == selectedWSID }) {
                selectedSessionID = selectedSession.id
            }
        } else {
            // No layout snapshot - fall back to unordered restoration
            Self.logger.info("No layout snapshot, restoring in discovery order")

            for (workspaceID, workspace) in liveWorkspaces {
                guard workspace.isValid, let baseSession = workspace.baseSession else { continue }
                let metadata = metadataByWorkspaceID[workspaceID]
                if metadata?.isArchived == true || metadata?.isTrashed == true {
                    Self.logger.info("Skipping inactive workspace \(workspaceID)")
                    continue
                }

                Self.logger.info("Restoring workspace \(workspaceID)")

                restorePersistedAttachmentSession(
                    attachment: TmuxAttachmentInfo(
                        sessionName: baseSession.name,
                        host: .local,
                        connectionState: .disconnected(reason: nil),
                        launchMode: .attach
                    ),
                    workspaceID: workspaceID
                )
                restoredCount += 1
            }

            restoredCount += restoreMetadataOnlyPlaceholders(
                excluding: Set(sessions.map(\.workspaceID)),
                tmuxAvailable: isTmuxAvailable
            )
        }

        // The layout file is left on disk after consumption. The periodic save
        // (every 60s) and shutdown save keep it up-to-date. Previous versions
        // deleted the file here, which caused layout loss on crash/force-quit.

        if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }

        Self.logger.info("Restored \(restoredCount) workspaces from tmux")
        return restoredCount > 0
    }

    private func persistedAttachmentInfo(from info: TmuxAttachmentInfo) -> TmuxAttachmentInfo {
        var persisted = info
        persisted.connectionState = .disconnected(reason: nil)
        persisted.launchMode = .attach
        return persisted
    }

    private func restorePersistedAttachmentSession(
        attachment: TmuxAttachmentInfo,
        workspaceID: String,
        tabLayouts: [WorkspaceTabLayout] = [],
        selectedTabIndex: Int? = nil,
        autoReconnect: Bool = true
    ) {
        if attachment.transport == .remoteEngine,
           case .ssh(let host) = attachment.host {
            restoreRemoteEngineSession(
                attachment: attachment,
                host: host,
                workspaceID: workspaceID,
                tabLayouts: tabLayouts,
                selectedTabIndex: selectedTabIndex,
                autoReconnect: autoReconnect
            )
            return
        }

        var attachedAttachment = attachment
        attachedAttachment.transport = .tmuxControl
        restoreAttachedSession(
            attachment: attachedAttachment,
            workspaceID: workspaceID,
            tabLayouts: tabLayouts,
            selectedTabIndex: selectedTabIndex,
            autoReconnect: autoReconnect
        )
    }

    private func restoreAttachedSession(
        attachment: TmuxAttachmentInfo,
        workspaceID: String,
        tabLayouts: [WorkspaceTabLayout] = [],
        selectedTabIndex: Int? = nil,
        autoReconnect: Bool = true
    ) {
        let session = makeAttachedSession(
            info: persistedAttachmentInfo(from: attachment),
            workspaceID: workspaceID
        )
        restorePersistedAttachedTabs(
            tabLayouts,
            in: session,
            selectedTabIndex: selectedTabIndex
        )
        sessions.append(session)
        if autoReconnect {
            startAttachedSessionReconnect(session)
        } else {
            session.backingState = placeholderBackingState(for: attachment)
        }
    }

    private func restoreRemoteEngineSession(
        attachment: TmuxAttachmentInfo,
        host: SSHHostInfo,
        workspaceID: String,
        tabLayouts: [WorkspaceTabLayout] = [],
        selectedTabIndex: Int? = nil,
        autoReconnect: Bool = true
    ) {
        var info = persistedAttachmentInfo(from: attachment)
        info.transport = .remoteEngine
        let session = Session(
            title: info.sessionName,
            type: .ssh(host: host.hostname, user: host.user, port: host.port),
            workspaceID: workspaceID,
            metadataStore: sessionMetadataStore
        )
        session.mode = .attached(info)
        restorePersistedAttachedTabs(
            tabLayouts,
            in: session,
            selectedTabIndex: selectedTabIndex
        )
        sessions.append(session)

        if autoReconnect {
            session.backingState = .available
            startRemoteEngineClient(
                session,
                host: host,
                tmuxSessionName: remoteEngineExternalTmuxSessionName(for: attachment, workspaceID: workspaceID)
            )
        } else {
            session.backingState = placeholderBackingState(for: info)
        }
    }

    private func restorePersistedAttachedTabs(
        _ tabLayouts: [WorkspaceTabLayout],
        in session: Session,
        selectedTabIndex: Int?
    ) {
        // Count terminal tabs preceding each browser tab so terminalInsertIndex
        // can interleave tmux-created terminal tabs at the right positions.
        var terminalCount = 0
        var browserTabs: [TerminalTab] = []
        for (i, layout) in tabLayouts.enumerated() {
            switch layout.kind {
            case .terminal:
                terminalCount += 1
            case .browser:
                let tab = TerminalTab(url: layout.url ?? URL(string: "https://www.google.com")!)
                tab.terminalTabsBefore = terminalCount
                browserTabs.append(tab)
            }
        }
        guard !browserTabs.isEmpty else { return }

        session.tabs = browserTabs

        if let selectedTabIndex,
           tabLayouts.indices.contains(selectedTabIndex),
           tabLayouts[selectedTabIndex].kind == .browser {
            let browserIndex = tabLayouts[..<selectedTabIndex].filter { $0.kind == .browser }.count
            if session.tabs.indices.contains(browserIndex) {
                session.selectedTabID = session.tabs[browserIndex].id
            }
        }
    }

    @discardableResult
    private func restoreMetadataOnlyPlaceholders(
        excluding restoredWorkspaceIDs: Set<String>,
        preferredOrder: [String] = [],
        tmuxAvailable: Bool
    ) -> Int {
        let preferredOrderIndex = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($0.element, $0.offset) }
        )

        let placeholders = workspaceMetadataProvider()
            .filter { !$0.isArchived && !$0.isTrashed && !restoredWorkspaceIDs.contains($0.workspaceID) && !$0.workspaceID.isEmpty }
            .sorted { lhs, rhs in
                let lhsIndex = preferredOrderIndex[lhs.workspaceID] ?? Int.max
                let rhsIndex = preferredOrderIndex[rhs.workspaceID] ?? Int.max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.workspaceID < rhs.workspaceID
            }

        for meta in placeholders {
            let attachment = meta.attachment ?? TmuxAttachmentInfo(
                sessionName: tmuxManager.baseSessionName(workspaceID: meta.workspaceID),
                host: .local,
                connectionState: .disconnected(reason: nil),
                launchMode: .attach
            )
            restorePersistedAttachmentSession(
                attachment: attachment,
                workspaceID: meta.workspaceID,
                autoReconnect: shouldAutoReconnect(
                    attachment: attachment,
                    tmuxAvailable: tmuxAvailable
                )
            )
        }

        return placeholders.count
    }

    private func placeholderBackingState(for attachment: TmuxAttachmentInfo) -> SessionBackingState {
        if case .disconnected(let reason) = attachment.connectionState {
            return .missingAttachedBacking(reason: reason)
        }
        return .missingAttachedBacking(reason: nil)
    }

    private func shouldAutoReconnect(
        attachment: TmuxAttachmentInfo,
        tmuxAvailable: Bool
    ) -> Bool {
        switch attachment.host {
        case .local:
            return tmuxAvailable
        case .ssh:
            return true
        }
    }

    func createShell(for session: Session) {
        clearStaleTerminalTabsForRecovery(in: session)

        guard !session.tabs.contains(where: { $0.kind == .terminal }) else {
            return
        }

        guard session.type == .local, tmuxManager.isTmuxAvailable else {
            return
        }

        let canonicalSessionName = tmuxManager.baseSessionName(workspaceID: session.workspaceID)
        let info = TmuxAttachmentInfo(
            sessionName: canonicalSessionName,
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .create
        )
        Self.logger.info(
            "Create shell requested workspace=\(session.workspaceID, privacy: .public) session=\(canonicalSessionName, privacy: .public) launchMode=create"
        )
        configureAttachedSession(session, with: info)
        session.backingState = .available
        selectedSessionID = session.id
        startAttachedSessionReconnect(session)
    }

    func reattachPlaceholderSession(_ session: Session) {
        clearStaleTerminalTabsForRecovery(in: session)

        guard case .attached(let existingInfo) = session.mode else { return }
        var info = persistedAttachmentInfo(from: existingInfo)
        info.connectionState = .disconnected(reason: nil)
        info.launchMode = .attach
        if info.transport == .remoteEngine,
           case .ssh(let host) = info.host {
            session.controlClient = nil
            attachedTmuxSessionBridge.unregisterSession(session)
            lifecycleRouterByWorkspaceID.removeValue(forKey: session.workspaceID)
            session.mode = .attached(info)
            session.backingState = .available
            selectedSessionID = session.id
            startRemoteEngineClient(session, host: host)
            return
        }
        configureAttachedSession(session, with: info)
        selectedSessionID = session.id
        startAttachedSessionReconnect(session)
    }

    private func configureAttachedSession(_ session: Session, with info: TmuxAttachmentInfo) {
        attachedTmuxSessionBridge.unregisterSession(session)
        let client = TmuxControlClient(attachmentInfo: info)
        session.controlClient = client
        session.mode = .attached(info)
        attachedTmuxSessionBridge.registerAttachedSession(session)
        lifecycleRouterByWorkspaceID[session.workspaceID] = TerminalLifecycleRouter(commandSender: client)
    }

    private func clearStaleTerminalTabsForRecovery(in session: Session) {
        guard shouldClearStaleTerminalTabsForRecovery(in: session) else { return }
        guard session.tabs.contains(where: { $0.kind == .terminal }) else { return }

        for terminalTab in session.tabs where terminalTab.kind == .terminal {
            deregisterSurfaces(in: terminalTab)
        }

        session.tabs.removeAll { $0.kind == .terminal }
        if let selectedTabID = session.selectedTabID,
           !session.tabs.contains(where: { $0.id == selectedTabID }) {
            session.selectedTabID = session.tabs.first?.id
        }
    }

    private func shouldClearStaleTerminalTabsForRecovery(in session: Session) -> Bool {
        if session.backingState != .available {
            return true
        }
        if case .attached(let info) = session.mode,
           case .disconnected = info.connectionState {
            return true
        }
        return false
    }

    private func startAttachedSessionReconnect(_ session: Session) {
        guard case .attached(var info) = session.mode else { return }
        if case .connecting = info.connectionState {
            return
        }
        info.connectionState = .connecting
        session.mode = .attached(info)
        session.backingState = .available
        attachedSessionReconnectStarter(session)

        if case .attached(let updatedInfo) = session.mode,
           case .disconnected(let reason) = updatedInfo.connectionState,
           !session.tabs.contains(where: { $0.kind == .terminal }) {
            session.backingState = .missingAttachedBacking(reason: reason)
        }
    }

    // MARK: - Session Management (Sidebar)

    /// Create a new session (sidebar item) in attached tmux control mode.
    @discardableResult
    func createSession(type: SessionType = .local, workspaceID: String? = nil) -> Session? {
        let workspaceID = workspaceID ?? String(UUID().uuidString.prefix(8).lowercased())

        let host: TmuxHost = {
            switch type {
            case .local, .sprite:
                return .local
            case .ssh(let hostname, let user, let port):
                return .ssh(SSHHostInfo(user: user, hostname: hostname, port: port))
            }
        }()

        let info = TmuxAttachmentInfo(
            sessionName: tmuxManager.baseSessionName(workspaceID: workspaceID),
            host: host,
            connectionState: .disconnected(reason: nil),
            launchMode: .create
        )

        let session = makeAttachedSession(info: info, workspaceID: workspaceID)
        sessions.append(session)
        selectedSessionID = session.id

        let shouldReconnect: Bool = {
            switch host {
            case .local:
                return tmuxManager.isTmuxAvailable
            case .ssh:
                return true
            }
        }()

        if shouldReconnect {
            startAttachedSessionReconnect(session)
        } else {
            session.backingState = .missingAttachedBacking(reason: "tmux unavailable")
        }

        let metadataStore = sessionMetadataStore
        var meta = metadataStore.getOrCreate(forKey: workspaceID)
        if meta.name.isEmpty {
            metadataStore.update(forKey: workspaceID, name: Self.generateWorkspaceName())
            meta = metadataStore.getOrCreate(forKey: workspaceID)
        }
        meta.attachment = persistedAttachmentInfo(from: info)
        metadataStore.update(meta)

        Self.logger.info("Created attached session \(session.id) type=\(type.displayName)")
        return session
    }

    /// Close a session by ID.
    /// When killTmux is true (default), also kills the tmux session.
    /// Set killTmux to false when quitting the app to leave sessions running.
    func closeSession(id: UUID, killTmux: Bool = true) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let session = sessions[index]
        let wasRemoteEngineSession = remoteEngineClientsByWorkspaceID[session.workspaceID] != nil
        attachedTmuxSessionBridge.unregisterSession(session)
        unregisterRemoteEngineSession(session, shutdownRemote: killTmux)
        updateLifecycleMetadata(
            for: session,
            isArchived: false,
            isTrashed: true
        )

        // Remove all surfaces in this session from the lookup index
        for tab in session.tabs {
            deregisterSurfaces(in: tab)
        }

        // Clean up lifecycle router for this workspace
        lifecycleRouterByWorkspaceID.removeValue(forKey: session.workspaceID)

        // Kill tmux session if requested and session has one
        if killTmux && !wasRemoteEngineSession {
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

    /// Select a tab from the sidebar, activating its session first so the chosen tab is displayed.
    func selectTab(_ tab: TerminalTab, in session: Session) {
        selectedSessionID = session.id
        session.selectedTabID = tab.id
    }

    func selectTabFromKeyBinding(_ tab: TerminalTab, in session: Session) {
        DispatchQueue.main.async { [weak session] in
            session?.selectedTabID = tab.id
        }
    }

    func selectNextTabFromKeyBinding(in session: Session) {
        DispatchQueue.main.async { [weak session] in
            session?.selectNextTab()
        }
    }

    func selectPreviousTabFromKeyBinding(in session: Session) {
        DispatchQueue.main.async { [weak session] in
            session?.selectPreviousTab()
        }
    }

    func selectLastTabFromKeyBinding(in session: Session) {
        DispatchQueue.main.async { [weak session] in
            guard let lastTab = session?.tabs.last else { return }
            session?.selectedTabID = lastTab.id
        }
    }

    // MARK: - Workspace Archiving

    /// Archive a workspace: kill tmux, set metadata flag, remove from active sessions.
    func archiveSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let wasRemoteEngineSession = remoteEngineClientsByWorkspaceID[session.workspaceID] != nil
        attachedTmuxSessionBridge.unregisterSession(session)
        unregisterRemoteEngineSession(session, shutdownRemote: true)

        // Kill tmux sessions
        if !wasRemoteEngineSession {
            tmuxManager.killWorkspaceSessions(workspaceID: session.workspaceID)
        }

        updateLifecycleMetadata(
            for: session,
            isArchived: true
        )

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
        let metadataStore = sessionMetadataStore
        metadataStore.update(forKey: workspaceID, isArchived: false)

        guard !sessions.contains(where: { $0.workspaceID == workspaceID }) else {
            selectedSessionID = sessions.first(where: { $0.workspaceID == workspaceID })?.id
            return
        }

        let metadata = metadataStore.getOrCreate(forKey: workspaceID)
        let attachment = metadata.attachment ?? TmuxAttachmentInfo(
            sessionName: tmuxManager.baseSessionName(workspaceID: metadata.workspaceID),
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach
        )
        restorePersistedAttachmentSession(
            attachment: attachment,
            workspaceID: metadata.workspaceID
        )
        selectedSessionID = sessions.last?.id
    }

    /// Restore a trashed workspace as an active placeholder.
    func restoreTrashedWorkspace(workspaceID: String) {
        let metadataStore = sessionMetadataStore
        metadataStore.update(forKey: workspaceID, isArchived: false, isTrashed: false)

        guard !sessions.contains(where: { $0.workspaceID == workspaceID }) else {
            selectedSessionID = sessions.first(where: { $0.workspaceID == workspaceID })?.id
            return
        }

        let metadata = metadataStore.getOrCreate(forKey: workspaceID)
        let attachment = metadata.attachment ?? TmuxAttachmentInfo(
            sessionName: tmuxManager.baseSessionName(workspaceID: metadata.workspaceID),
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach
        )
        restorePersistedAttachmentSession(
            attachment: attachment,
            workspaceID: metadata.workspaceID
        )
        selectedSessionID = sessions.last?.id
    }

    /// Permanently delete an archived workspace's metadata.
    func deleteArchivedWorkspace(workspaceID: String) {
        sessionMetadataStore.remove(forKey: workspaceID)
    }

    /// Permanently delete a trashed workspace's metadata.
    func deleteTrashedWorkspace(workspaceID: String) {
        sessionMetadataStore.remove(forKey: workspaceID)
    }

    /// Permanently delete all trashed workspaces.
    func emptyTrash() {
        for meta in sessionMetadataStore.trashedWorkspaces {
            sessionMetadataStore.remove(forKey: meta.workspaceID)
        }
    }

    // MARK: - Tab Management (Top tabs within session)

    /// Create a new tab in the current session.
    @discardableResult
    func createTab() -> TerminalTab? {
        guard let session = selectedSession else {
            Self.logger.error("Cannot create tab: no session")
            return nil
        }

        if let client = session.controlClient {
            Task {
                do {
                    _ = try await attachedTmuxNewWindowSender(client)
                } catch {
                    Self.logger.error("Failed to create attached tmux window: \(error.localizedDescription, privacy: .public)")
                }
            }
            return nil
        }

        if let remoteEngineClient = remoteEngineClientsByWorkspaceID[session.workspaceID] {
            remoteEngineClient.newWindow()
            return nil
        }

        Self.logger.error(
            "Cannot create tab: attached session missing control client for workspace \(session.workspaceID, privacy: .public)"
        )
        return nil
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
    /// For terminal tabs in attached tmux sessions, sends kill-window through the
    /// lifecycle router. The actual tab removal happens when tmux confirms via
    /// %window-close. Browser tabs are still closed locally.
    func closeTab(id: UUID) {
        guard let session = sessions.first(where: { $0.tabs.contains { $0.id == id } }) else { return }

        if let tab = session.tabs.first(where: { $0.id == id }),
           tab.kind == .terminal,
           let router = lifecycleRouterByWorkspaceID[session.workspaceID] {
            Task {
                await router.closeTerminalTab(tab, in: session)
            }
            // Tab removal happens when tmux sends %window-close back
            return
        }

        if let tab = session.tabs.first(where: { $0.id == id }),
           tab.kind == .terminal,
           isRemoteEngineSession(session) {
            Self.logger.info(
                "Ignoring local terminal tab close for remote engine workspace \(session.workspaceID, privacy: .public)"
            )
            return
        }

        if let tab = session.tabs.first(where: { $0.id == id }) {
            // Remove tab's surfaces from the lookup index before the tab is removed
            deregisterSurfaces(in: tab)
        }

        let shouldCloseSession = session.closeTab(id: id)
        if shouldCloseSession {
            closeSession(id: session.id)
        }

        Self.logger.info("Closed tab \(id)")
    }

    /// Close the currently selected tab.
    func closeSelectedTab() {
        guard let session = selectedSession, let tab = session.selectedTab else { return }
        // Cmd-W closes a tab, but must never tear down the whole workspace:
        // closing the final tab cascades to closeSession, which is far too
        // destructive for Cmd-W. Closing the workspace is reserved for the
        // explicit "Close Workspace" command (Cmd-Shift-W).
        guard session.tabs.count > 1 else { return }
        closeTab(id: tab.id)
    }

    /// Clear the terminal screen for the focused surface.
    /// In attached tmux mode, sends Ctrl-L to the active pane.
    /// In regular mode, triggers Ghostty's clear_screen binding.
    func clearScreen() {
        guard let session = selectedSession,
              let surface = selectedTab?.focusedSurface else { return }

        if case .attached = session.mode,
           let paneID = surface.tmuxPaneID,
           let remotePaneInputHandler = surface.remotePaneInputHandler {
            remotePaneInputHandler(paneID, RemotePaneInput(data: Data([0x0c]), source: .directKey))
        } else if case .attached = session.mode,
                  let paneID = surface.tmuxPaneID,
                  let client = surface.tmuxControlClient {
            Task {
                // Send Ctrl-L (form feed / clear) to the pane
                // Ctrl-L = 0x0c (form feed / clear)
                await client.sendKeys(paneID: paneID, data: Data([0x0c]))
            }
        } else if let s = surface.surface {
            let action = "clear_screen"
            ghostty_surface_binding_action(s, action, UInt(action.lengthOfBytes(using: .utf8)))
        }
    }

    /// Open a URL in the session's embedded browser, or in the system default browser.
    func openURL(_ url: URL, inEmbeddedBrowser: Bool = true) {
        if inEmbeddedBrowser {
            createBrowserTab(url: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func reloadSelectedBrowserTab() -> Bool {
        guard let webView = selectedBrowserTab?.webView else { return false }
        webView.reload()
        return true
    }

    @discardableResult
    func goBackInSelectedBrowserTab() -> Bool {
        guard let webView = selectedBrowserTab?.webView else { return false }
        webView.goBack()
        return true
    }

    @discardableResult
    func goForwardInSelectedBrowserTab() -> Bool {
        guard let webView = selectedBrowserTab?.webView else { return false }
        webView.goForward()
        return true
    }

    @discardableResult
    func focusLocationInSelectedBrowserTab() -> Bool {
        guard let tab = selectedBrowserTab else { return false }
        tab.requestBrowserLocationFocus()
        return true
    }

    // MARK: - Split Management

    /// Create a new split in the currently selected tab.
    func newSplit(direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        guard let focusedSurface = focusedSurfaceView else { return }
        Task { @MainActor [weak self] in
            await self?.performSplit(from: focusedSurface, direction: direction)
        }
    }

    /// Close a surface within a tab's split tree.
    /// For tmux panes in attached sessions, sends kill-pane through the lifecycle
    /// router. The actual pane removal happens when tmux confirms via %layout-change.
    func closeSurface(_ surfaceView: Ghostty.SurfaceView) {
        guard let (session, tab) = findSessionAndTab(for: surfaceView) else { return }

        // Route tmux pane closures through the lifecycle router
        if let paneID = surfaceView.tmuxPaneID,
           let router = lifecycleRouterByWorkspaceID[session.workspaceID] {
            Task {
                await router.closePane(paneID: paneID, in: session)
            }
            return
        }

        if surfaceView.tmuxPaneID != nil, isRemoteEngineSession(session) {
            Self.logger.info(
                "Ignoring local pane close for remote engine workspace \(session.workspaceID, privacy: .public)"
            )
            return
        }

        surfaceIndex.removeValue(forKey: ObjectIdentifier(surfaceView))

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
    /// Checks the O(1) surfaceIndex first; falls back to linear search for safety.
    func findSessionAndTab(for surfaceView: Ghostty.SurfaceView) -> (Session, TerminalTab)? {
        if let result = surfaceIndex[ObjectIdentifier(surfaceView)] {
            return result
        }
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

        // Open URL notification (terminal link clicks)
        center.addObserver(
            self,
            selector: #selector(handleOpenURL(_:)),
            name: .ghosttyOpenURL,
            object: nil
        )

        // Activity accumulation tick
        Timer.publish(every: Self.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.activityTick() }
            .store(in: &smCancellables)

        // Periodic disk flush (activity times + layout)
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.flushActiveTimes()
                self?.saveLayout()
            }
            .store(in: &smCancellables)

        // Flush active time for the old session whenever selection changes
        $selectedSessionID
            .scan((UUID?.none, UUID?.none)) { ($0.1, $1) }
            .dropFirst()
            .sink { [weak self] (oldID, _) in
                guard let self = self, let oldID = oldID,
                      let session = self.sessions.first(where: { $0.id == oldID }) else { return }
                self.updateActiveTimeMetadata(for: session)
            }
            .store(in: &smCancellables)

        // Mouse activity monitor — keeps the idle clock from expiring while mousing
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            if let session = self?.selectedSession {
                self?.lastKeyInputAt[session.workspaceID] = Date()
            }
            return event
        }

    }

    @objc private func handleNewTab(_ notification: Foundation.Notification) {
        // Create a new tab in the current session (not a new session)
        createTab()
    }

    @objc private func handleCloseSurface(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        // Ghostty's close_surface (Cmd-W) must never tear down the whole
        // workspace. If this is the only pane of the only tab, closing it would
        // cascade closeSurface -> closeTab -> closeSession. Closing the
        // workspace is reserved for the explicit Close Workspace command.
        if let (session, tab) = findSessionAndTab(for: surfaceView),
           session.tabs.count <= 1,
           (tab.surfaceTree?.root?.leaves().count ?? 1) <= 1 {
            return
        }
        closeSurface(surfaceView)
    }

    @objc private func handleNewSplit(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let _ = findSessionAndTab(for: surfaceView) else { return }

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

        let config: Ghostty.SurfaceConfiguration?
        if let userInfo = notification.userInfo,
           let surfaceConfig = userInfo[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration {
            config = surfaceConfig
        } else {
            config = nil
        }

        Task { @MainActor [weak self] in
            await self?.performSplit(from: surfaceView, direction: direction, config: config)
        }
    }

    @MainActor
    func performSplit(
        from surfaceView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        config: Ghostty.SurfaceConfiguration? = nil
    ) async {
        _ = config
        guard let (session, tab) = findSessionAndTab(for: surfaceView),
              let client = session.controlClient,
              let paneID = splitPaneIDIfAllowed(for: tab, direction: direction) else {
            return
        }
        let horizontal = direction == .right

        do {
            try await attachedTmuxSplitSender(client, paneID, horizontal)
        } catch {
            Self.logger.error("Failed to split attached tmux pane: \(error)")
        }
    }

    @MainActor
    func canPerformSplit(
        from surfaceView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection
    ) -> Bool {
        guard let (session, tab) = findSessionAndTab(for: surfaceView) else { return false }
        guard !isRemoteEngineSession(session),
              session.controlClient != nil else { return false }
        return splitPaneIDIfAllowed(for: tab, direction: direction) != nil
    }

    @MainActor
    func canPerformSplitOnFocusedSurface(
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection
    ) -> Bool {
        guard let surfaceView = focusedSurfaceView else { return false }
        return canPerformSplit(from: surfaceView, direction: direction)
    }

    @MainActor
    private func splitPaneIDIfAllowed(
        for tab: TerminalTab,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection
    ) -> Int? {
        switch direction {
        case .right, .down:
            return tab.focusedSurface?.tmuxPaneID
        case .left, .up:
            return nil
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
            selectTabFromKeyBinding(session.tabs[rawValue - 1], in: session)
        } else {
            // Special values: previous/next/last
            switch tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS:
                selectPreviousTabFromKeyBinding(in: session)
            case GHOSTTY_GOTO_TAB_NEXT:
                selectNextTabFromKeyBinding(in: session)
            case GHOSTTY_GOTO_TAB_LAST:
                selectLastTabFromKeyBinding(in: session)
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
        NSSound.beep()

        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }

        if session.id != selectedSessionID {
            session.needsAttention = true
        }
    }

    @objc private func handleCommandFinished(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }

        if session.id != selectedSessionID {
            session.needsAttention = true
        }
    }

    @objc private func handleKeyInput(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }

        guard let (session, _) = findSessionAndTab(for: surfaceView) else { return }

        // Clear attention when user types in this session
        if session.needsAttention {
            session.needsAttention = false
        }

        // Record key input for idle detection
        lastKeyInputAt[session.workspaceID] = Date()
    }

    @objc private func handleSessionNote(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let content = notification.userInfo?["content"] as? String,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }

        session.addNote(content: content, source: .terminal)

        if session.id != selectedSessionID {
            session.needsAttention = true
        }
    }

    @objc private func handleTicketURL(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let url = notification.userInfo?["url"] as? String,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }
        session.ticketURL = url.isEmpty ? nil : url
    }

    @objc private func handlePullRequestURL(_ notification: Foundation.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView,
              let url = notification.userInfo?["url"] as? String,
              let (session, _) = findSessionAndTab(for: surfaceView) else { return }
        session.pullRequestURL = url.isEmpty ? nil : url
    }

    @objc private func handleOpenURL(_ notification: Foundation.Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        openURL(url)
    }

    // MARK: - Private Helpers

    /// Remove all surfaces in a tab's split tree from the surface index.
    private func deregisterSurfaces(in tab: TerminalTab) {
        guard let root = tab.surfaceTree?.root else { return }
        deregisterSurfaces(in: root)
    }

    private func deregisterSurfaces(in node: SplitTree<Ghostty.SurfaceView>.Node) {
        switch node {
        case .leaf(let view):
            surfaceIndex.removeValue(forKey: ObjectIdentifier(view))
        case .split(let split):
            deregisterSurfaces(in: split.left)
            deregisterSurfaces(in: split.right)
        }
    }

    private func setupTitleObserver(for tab: TerminalTab, surfaceView: Ghostty.SurfaceView, session: Session) {
        // Register in the O(1) lookup index
        surfaceIndex[ObjectIdentifier(surfaceView)] = (session, tab)

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
            .store(in: &tab.cancellables)

        // Observe bell state changes - only set attention for background sessions
        surfaceView.$bell
            .filter { $0 }  // only act when bell rings; keyDown sets bell=false on every keypress
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak surfaceView] bellActive in
                guard bellActive, let self = self, let surfaceView = surfaceView else { return }
                if let (session, _) = self.findSessionAndTab(for: surfaceView),
                   session.id != self.selectedSessionID {
                    session.needsAttention = true
                }
            }
            .store(in: &tab.cancellables)
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

    // MARK: - Tmux Attach

    @discardableResult
    func createRemoteEngineSession(host: SSHHostInfo, workspaceID: String? = nil) -> Session {
        let workspaceID = workspaceID ?? String(UUID().uuidString.prefix(8).lowercased())
        let info = TmuxAttachmentInfo(
            sessionName: "fantastty-remote-\(workspaceID)",
            host: .ssh(host),
            connectionState: .connecting,
            launchMode: .attach,
            transport: .remoteEngine
        )
        let session = Session(
            title: info.sessionName,
            type: .ssh(host: host.hostname, user: host.user, port: host.port),
            workspaceID: workspaceID,
            metadataStore: sessionMetadataStore
        )
        session.mode = .attached(info)
        session.backingState = .available

        sessions.append(session)
        selectedSessionID = session.id
        startRemoteEngineClient(session, host: host)

        let metadataStore = sessionMetadataStore
        var meta = metadataStore.getOrCreate(forKey: workspaceID)
        if meta.name.isEmpty {
            metadataStore.update(forKey: workspaceID, name: Self.generateWorkspaceName())
            meta = metadataStore.getOrCreate(forKey: workspaceID)
        }
        meta.attachment = persistedAttachmentInfo(from: info)
        metadataStore.update(meta)

        Self.logger.info("Created remote engine session \(session.id) host=\(host.displayName)")
        return session
    }

    private func startRemoteEngineClient(_ session: Session, host: SSHHostInfo, tmuxSessionName: String? = nil) {
        let workspaceID = session.workspaceID
        remoteWorkspaceBridge.registerRemoteWorkspaceSession(session)

        let client = RemoteEngineClient(
            workspaceID: workspaceID,
            materialProvider: { [remoteEngineBootstrapper] in
                try await remoteEngineBootstrapper.attachMaterial(
                    workspaceID: workspaceID,
                    host: host,
                    tmuxSessionName: tmuxSessionName
                )
            },
            transport: remoteEngineTransport,
            reconnectPolicy: remoteEngineReconnectPolicy,
            messageHandler: { [weak self] inbound in
                self?.remoteWorkspaceBridge.handle(inbound.message, delivery: inbound.delivery)
            },
            reattachHandler: { [weak self] in
                await self?.remoteWorkspaceBridge.handleReattach(workspaceID: workspaceID)
            },
            stateHandler: { [weak self, weak session] state in
                guard let self, let session else { return }
                self.applyRemoteEngineState(state, to: session)
            }
        )
        remoteEngineClientsByWorkspaceID[workspaceID] = client
        observeRemoteEngineTabSelection(for: session)
        client.start()
    }

    private func observeRemoteEngineTabSelection(for session: Session) {
        remoteEngineTabSelectionCancellables[session.workspaceID]?.cancel()
        remoteEngineTabSelectionCancellables[session.workspaceID] = session.$selectedTabID
            .dropFirst()
            .sink { [weak self, weak session] selectedTabID in
                guard let self, let session, let selectedTabID else { return }
                guard let tab = session.tabs.first(where: { $0.id == selectedTabID }),
                      let windowID = tab.tmuxWindowID else {
                    return
                }
                guard !self.remoteEngineTabSelectionSyncSuppressionWorkspaceIDs.contains(session.workspaceID) else {
                    return
                }
                self.remoteEngineClientsByWorkspaceID[session.workspaceID]?.selectWindow(windowID: windowID)
            }
    }

    private func remoteEngineExternalTmuxSessionName(for info: TmuxAttachmentInfo, workspaceID: String) -> String? {
        let privateWorkspaceSessionName = "fantastty-remote-\(workspaceID)"
        return info.sessionName == privateWorkspaceSessionName ? nil : info.sessionName
    }

    private func unregisterRemoteEngineSession(_ session: Session, shutdownRemote: Bool = false) {
        let client = remoteEngineClientsByWorkspaceID.removeValue(forKey: session.workspaceID)
        remoteEngineTabSelectionCancellables.removeValue(forKey: session.workspaceID)?.cancel()
        remoteEngineTabSelectionSyncSuppressionWorkspaceIDs.remove(session.workspaceID)
        remoteEngineWorkspacesWaitingForAuthoritativeRender.remove(session.workspaceID)
        let material = client?.lastAttachMaterial
        client?.stop()
        remoteWorkspaceBridge.unregisterSession(session)

        guard shutdownRemote,
              let material,
              case .attached(let info) = session.mode,
              case .ssh(let host) = info.host else {
            return
        }

        let bootstrapper = remoteEngineBootstrapper
        Task {
            do {
                try await bootstrapper.shutdown(material: material, host: host)
            } catch {
                Self.logger.error("Failed to shut down remote engine helper: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func isRemoteEngineSession(_ session: Session) -> Bool {
        if remoteEngineClientsByWorkspaceID[session.workspaceID] != nil {
            return true
        }
        guard case .attached(let info) = session.mode else { return false }
        return info.transport == .remoteEngine
    }

    func handleRemoteTerminalTabBecameVisible(session: Session, tab: TerminalTab) {
        attachedTmuxSessionBridge.handleTabBecameVisible(session: session, tab: tab)

        guard isRemoteEngineSession(session) else { return }
        for surface in tab.surfaceTree?.root?.leaves() ?? [] {
            guard let paneID = surface.tmuxPaneID else { continue }
            remoteWorkspaceBridge.handleRemotePaneBecameVisible(
                workspaceID: session.workspaceID,
                paneID: paneID
            )
        }
    }

    func handleRemoteSelectedTerminalBecameVisible(session: Session) {
        guard let tab = session.selectedTab else { return }
        handleRemoteTerminalTabBecameVisible(session: session, tab: tab)
    }

    private func updateLifecycleMetadata(
        for session: Session,
        isArchived: Bool? = nil,
        isTrashed: Bool? = nil
    ) {
        var meta = sessionMetadataStore.getOrCreate(forKey: session.workspaceID)
        if let isArchived {
            meta.isArchived = isArchived
            meta.archivedAt = isArchived ? Date() : nil
        }
        if let isTrashed {
            meta.isTrashed = isTrashed
            meta.trashedAt = isTrashed ? Date() : nil
        }
        sessionMetadataStore.update(meta)
    }

    private func updateActiveTimeMetadata(for session: Session) {
        var meta = sessionMetadataStore.getOrCreate(forKey: session.workspaceID)
        meta.totalActiveSeconds = session.totalActiveSeconds
        sessionMetadataStore.update(meta)
    }

    private func applyRemoteEngineState(_ state: RemoteEngineClientState, to session: Session) {
        guard remoteEngineClientsByWorkspaceID[session.workspaceID] != nil else { return }
        guard case .attached(var info) = session.mode else { return }
        switch state {
        case .idle:
            info.connectionState = .disconnected(reason: nil)
        case .connecting:
            info.connectionState = .connecting
            session.backingState = .available
        case .reconnecting(let reason):
            info.connectionState = .reconnecting(reason: reason)
            session.backingState = .available
        case .connected:
            session.backingState = .available
            if case .reconnecting = info.connectionState {
                remoteEngineWorkspacesWaitingForAuthoritativeRender.insert(session.workspaceID)
            } else {
                info.connectionState = .connected
                remoteEngineWorkspacesWaitingForAuthoritativeRender.remove(session.workspaceID)
            }
        case .disconnected(let reason):
            remoteEngineWorkspacesWaitingForAuthoritativeRender.remove(session.workspaceID)
            let presentation = reason.map(remoteEngineFailurePresentation)
            let presentedReason = presentation?.connectionReason
            if presentation?.allowsSSHFallbackBeforeRemotePanes == true &&
                shouldFallbackRemoteEngineSessionToSSHControlMode(session) {
                fallbackRemoteEngineSessionToSSHControlMode(session, info: info, reason: presentedReason)
                return
            }
            info.connectionState = .disconnected(reason: presentedReason)
            if !session.tabs.contains(where: { $0.kind == .terminal }) {
                session.backingState = .missingAttachedBacking(reason: presentedReason)
            }
        }
        session.mode = .attached(info)
    }

    private func completeRemoteEngineRenderResume(workspaceID: String) {
        guard remoteEngineWorkspacesWaitingForAuthoritativeRender.remove(workspaceID) != nil else { return }
        guard remoteEngineClientsByWorkspaceID[workspaceID] != nil else { return }
        guard let session = sessions.first(where: { $0.workspaceID == workspaceID }) else { return }
        guard case .attached(var info) = session.mode else { return }
        guard info.transport == .remoteEngine else { return }
        guard case .reconnecting = info.connectionState else { return }

        info.connectionState = .connected
        session.backingState = .available
        session.mode = .attached(info)
    }

    private func remoteEngineFailurePresentation(_ reason: String) -> RemoteEngineFailurePresentation {
        RemoteEngineFailurePresentation
            .presenting(RemoteEngineError.remote(reason))
    }

    private func applyUnsupportedRemotePaneState(_ state: RemoteUnsupportedPaneState, workspaceID: String) {
        guard remoteEngineClientsByWorkspaceID[workspaceID] != nil else { return }
        guard let session = sessions.first(where: { $0.workspaceID == workspaceID }) else { return }
        guard case .attached(var info) = session.mode else { return }

        info.connectionState = .disconnected(
            reason: "remote pane \(state.paneID) unsupported: \(state.reason.rawValue)"
        )
        session.mode = .attached(info)
    }

    private func shouldFallbackRemoteEngineSessionToSSHControlMode(_ session: Session) -> Bool {
        guard !hasRemoteEnginePane(in: session) else { return false }
        guard case .attached(let info) = session.mode,
              case .ssh = info.host else {
            return false
        }
        return true
    }

    private func hasRemoteEnginePane(in session: Session) -> Bool {
        session.tabs.contains { tab in
            tab.surfaceTree?.root?.leaves().contains { surface in
                surface.remotePaneInputHandler != nil
            } == true
        }
    }

    private func fallbackRemoteEngineSessionToSSHControlMode(
        _ session: Session,
        info: TmuxAttachmentInfo,
        reason: String?
    ) {
        remoteEngineClientsByWorkspaceID.removeValue(forKey: session.workspaceID)?.stop()
        remoteEngineTabSelectionCancellables.removeValue(forKey: session.workspaceID)?.cancel()
        remoteEngineTabSelectionSyncSuppressionWorkspaceIDs.remove(session.workspaceID)
        remoteWorkspaceBridge.unregisterSession(session)

        var fallbackInfo = info
        fallbackInfo.connectionState = .disconnected(reason: reason)
        fallbackInfo.launchMode = .create
        fallbackInfo.transport = .tmuxControl

        configureAttachedSession(session, with: fallbackInfo)
        session.backingState = .available
        startAttachedSessionReconnect(session)

        var meta = sessionMetadataStore.getOrCreate(forKey: session.workspaceID)
        meta.attachment = persistedAttachmentInfo(from: fallbackInfo)
        sessionMetadataStore.update(meta)
    }

    func makeAttachedSession(info: TmuxAttachmentInfo, workspaceID: String? = nil) -> Session {
        let wsID = workspaceID ?? String(UUID().uuidString.prefix(8)).lowercased()
        let sessionType: SessionType = {
            switch info.host {
            case .local:
                return .local
            case .ssh(let sshInfo):
                return .ssh(host: sshInfo.hostname, user: sshInfo.user, port: sshInfo.port)
            }
        }()
        let session = Session(title: info.sessionName, type: sessionType, workspaceID: wsID, metadataStore: sessionMetadataStore)
        session.mode = .attached(info)

        if info.transport == .tmuxControl {
            let client = TmuxControlClient(attachmentInfo: info)
            session.controlClient = client
            attachedTmuxSessionBridge.registerAttachedSession(session)
        }

        return session
    }

    /// Attach to an existing tmux session and display it as a new Session.
    func attachToTmuxSession(info: TmuxAttachmentInfo) {
        let session = makeAttachedSession(info: info)

        sessions.append(session)
        selectedSessionID = session.id

        if info.transport == .remoteEngine, case .ssh(let host) = info.host {
            startRemoteEngineClient(session, host: host, tmuxSessionName: info.sessionName)
        } else {
            startAttachedSessionReconnect(session)
        }

        // Persist metadata so the session survives across restarts even if
        // layout.json is lost or corrupt.
        let metadataStore = sessionMetadataStore
        var meta = metadataStore.getOrCreate(forKey: session.workspaceID)
        if meta.name.isEmpty {
            metadataStore.update(forKey: session.workspaceID, name: Self.generateWorkspaceName())
            meta = metadataStore.getOrCreate(forKey: session.workspaceID)
        }
        meta.attachment = persistedAttachmentInfo(from: info)
        metadataStore.update(meta)
    }

}
