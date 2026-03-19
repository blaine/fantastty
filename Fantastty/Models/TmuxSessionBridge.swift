import SwiftUI
import GhosttyKit
import Combine

final class TmuxSessionBridge: ObservableObject {
    typealias TmuxOutputInjector = (Ghostty.SurfaceView, Data) -> Bool
    typealias TmuxWindowSelector = (TmuxControlClient, Int) -> Void
    typealias TmuxWindowInitialCaptureRequester = (TmuxControlClient, Int, [Int]) -> Void

    var ghosttyApp: Ghostty.App?
    var tmuxOutputInjector: TmuxOutputInjector!
    var tmuxWindowSelector: TmuxWindowSelector = TmuxSessionBridge.defaultTmuxWindowSelector
    var tmuxWindowInitialCaptureRequester: TmuxWindowInitialCaptureRequester!
    var onWindowClosed: ((TmuxControlClient, Int) -> Void)?
    var onClientExit: ((TmuxControlClient) -> Void)?

    private let bindingStore = WorkspaceBindingStore()
    private var runtimeByWorkspaceID: [String: AttachedWorkspaceRuntimeV2] = [:]
    private var windowControllersByWorkspace: [String: [Int: TmuxWindowController]] = [:]
    private var tabSelectionCancellables: [String: AnyCancellable] = [:]
    private var activeWindowIDByWorkspaceID: [String: Int] = [:]
    private var tabSelectionSyncSuppressionWorkspaceIDs: Set<String> = []
    static let attachedTmuxSilentCommand = "/bin/sh -lc 'stty raw -echo; exec /bin/cat >/dev/null'"

    init() {
        tmuxOutputInjector = { [weak self] surface, data in
            self?.defaultTmuxOutputInjector(surface, data) ?? false
        }
        tmuxWindowInitialCaptureRequester = { [weak self] client, windowID, paneIDs in
            guard let self else { return }
            Task { @MainActor in
                await self.requestInitialAttachedTmuxCapture(
                    client: client,
                    windowID: windowID,
                    paneIDs: paneIDs
                )
            }
        }
    }

    func registerAttachedSession(_ session: Session) {
        guard case .attached = session.mode,
              let client = session.controlClient else {
            return
        }

        client.delegate = self
        bindingStore.bind(session: session, client: client)
        runtimeByWorkspaceID[session.workspaceID] = AttachedWorkspaceRuntimeV2()
        observeTabSelection(for: session, client: client)
    }

    func unregisterSession(_ session: Session) {
        if let controllers = windowControllersByWorkspace.removeValue(forKey: session.workspaceID) {
            for (_, controller) in controllers {
                controller.teardown()
            }
        }
        session.controlClient?.delegate = nil
        bindingStore.unbind(session: session)
        runtimeByWorkspaceID.removeValue(forKey: session.workspaceID)
        tabSelectionCancellables.removeValue(forKey: session.workspaceID)?.cancel()
        activeWindowIDByWorkspaceID.removeValue(forKey: session.workspaceID)
        tabSelectionSyncSuppressionWorkspaceIDs.remove(session.workspaceID)
    }

    func hasBinding(for workspaceID: String) -> Bool {
        bindingStore.hasBinding(workspaceID: workspaceID)
    }

    /// Fallback coalescing injectors for surfaces not managed by a
    /// TmuxWindowController (e.g. during initial window setup).
    /// Keyed by pane ID; each limits to one in-flight inject.
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

    private static func defaultTmuxWindowSelector(_ client: TmuxControlClient, _ windowID: Int) {
        Task {
            await client.selectWindow(windowID: windowID)
        }
    }

    private static func attachedTmuxSurfaceConfiguration() -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        // Attached tmux panes render injected control-mode output, so the local
        // Ghostty child process must stay silent to avoid mixed streams.
        config.command = attachedTmuxSilentCommand
        return config
    }
}

private extension TmuxSessionBridge {
    func requestInitialAttachedTmuxCapture(
        client: TmuxControlClient,
        windowID: Int,
        paneIDs: [Int]
    ) async {
        do {
            let captured = try await client.capturePaneContents(paneIDs: paneIDs)
            guard let session = session(for: client),
                  session.tabs.contains(where: { $0.tmuxWindowID == windowID }) else {
                return
            }
            for pane in captured {
                route(.paneOutput(paneID: pane.paneID, data: pane.data), from: client)
            }
        } catch {}
    }

    func observeTabSelection(for session: Session, client: TmuxControlClient) {
        tabSelectionCancellables[session.workspaceID]?.cancel()
        tabSelectionCancellables[session.workspaceID] = session.$selectedTabID
            .dropFirst()
            .sink { [weak self, weak session] selectedTabID in
                guard let self, let session, let selectedTabID else { return }
                guard let tab = session.tabs.first(where: { $0.id == selectedTabID }),
                      let windowID = tab.tmuxWindowID else {
                    return
                }
                guard !self.tabSelectionSyncSuppressionWorkspaceIDs.contains(session.workspaceID) else {
                    return
                }
                guard self.activeWindowIDByWorkspaceID[session.workspaceID] != windowID else {
                    return
                }
                self.tmuxWindowSelector(client, windowID)
            }
    }

    func session(for client: TmuxControlClient) -> Session? {
        bindingStore.session(for: client)
    }

    func route(_ event: AttachedRuntimeEventV2, from client: TmuxControlClient) {
        guard let session = session(for: client),
              var runtime = runtimeByWorkspaceID[session.workspaceID] else {
            return
        }

        let actions = runtime.handle(event)
        runtimeByWorkspaceID[session.workspaceID] = runtime
        apply(actions: actions, session: session, client: client)
    }

    func apply(actions: [AttachedRuntimeActionV2], session: Session, client: TmuxControlClient) {
        for action in actions {
            switch action {
            case .upsertWindow(let snapshot):
                upsertWindow(snapshot, in: session, client: client)

            case .removeWindow(let windowID):
                if let controller = windowControllersByWorkspace[session.workspaceID]?.removeValue(forKey: windowID) {
                    controller.teardown()
                }
                if let index = session.tabs.firstIndex(where: { $0.tmuxWindowID == windowID }) {
                    let removed = session.tabs.remove(at: index)
                    if session.selectedTabID == removed.id {
                        withSuppressedTabSelectionSync(for: session.workspaceID) {
                            session.selectedTabID = session.tabs.first?.id
                        }
                    }
                }
                if activeWindowIDByWorkspaceID[session.workspaceID] == windowID {
                    activeWindowIDByWorkspaceID.removeValue(forKey: session.workspaceID)
                }

            case .renameWindow(let windowID, let title):
                guard let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }) else { continue }
                tab.title = title

            case .selectWindow(let windowID):
                guard let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }) else { continue }
                activeWindowIDByWorkspaceID[session.workspaceID] = windowID
                withSuppressedTabSelectionSync(for: session.workspaceID) {
                    session.selectedTabID = tab.id
                }

            case .applyLayout(let windowID, let layout, _):
                if let controller = windowControllersByWorkspace[session.workspaceID]?[windowID] {
                    controller.applyLayout(layout)
                    // Rebind surfaces to current client for key routing after reconnects
                    let leaves = controller.tab.surfaceTree?.root?.leaves() ?? []
                    for surface in leaves {
                        surface.tmuxControlClient = client
                    }
                    controller.tab.requestThumbnailRefresh()
                } else {
                    applyLayout(layout, windowID: windowID, session: session, client: client)
                }

            case .setActivePane(let windowID, let paneID):
                if let controller = windowControllersByWorkspace[session.workspaceID]?[windowID] {
                    controller.setActivePane(paneID)
                } else {
                    guard let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }),
                          let surface = tab.surfaceTree?.root?.leaves().first(where: { $0.tmuxPaneID == paneID }) else {
                        continue
                    }
                    tab.focusedSurface = surface
                }

            case .deliverPaneOutput(let windowID, let paneID, let data):
                if let controller = windowControllersByWorkspace[session.workspaceID]?[windowID] {
                    controller.deliverOutput(paneID: paneID, data: data)
                } else {
                    guard let surface = AttachedTmuxWindowRuntime.surface(forPaneID: paneID, tabs: session.tabs),
                          tmuxOutputInjector(surface, data) else {
                        continue
                    }
                    tabContainingPane(paneID, in: session)?.requestThumbnailRefresh()
                }
            }
        }
    }

    func upsertWindow(_ snapshot: AttachedWindowSnapshotV2, in session: Session, client: TmuxControlClient) {
        if let existing = session.tabs.first(where: { $0.tmuxWindowID == snapshot.windowID }) {
            existing.title = snapshot.title
            existing.tmuxWindowIndex = snapshot.windowIndex
            if snapshot.isActive {
                activeWindowIDByWorkspaceID[session.workspaceID] = snapshot.windowID
                withSuppressedTabSelectionSync(for: session.workspaceID) {
                    session.selectedTabID = existing.id
                }
            }
            return
        }

        let controller = TmuxWindowController(
            windowID: snapshot.windowID,
            title: snapshot.title,
            windowIndex: snapshot.windowIndex ?? 0,
            surfaceFactory: { [weak self] paneID in
                guard let app = self?.ghosttyApp?.app else {
                    fatalError("Ghostty app not available")
                }
                let surface = Ghostty.SurfaceView(app, baseConfig: Self.attachedTmuxSurfaceConfiguration())
                surface.tmuxPaneID = paneID
                surface.tmuxControlClient = client
                return surface
            },
            paneInjectorFactory: { [weak self] paneID in
                return { [weak self, weak session] data -> Bool in
                    guard let self, let session else { return false }
                    guard let surface = AttachedTmuxWindowRuntime.surface(forPaneID: paneID, tabs: session.tabs) else {
                        return false
                    }
                    let result = self.tmuxOutputInjector(surface, data)
                    if result {
                        self.tabContainingPane(paneID, in: session)?.requestThumbnailRefresh()
                    }
                    return result
                }
            }
        )
        controller.onBootstrapReady = { [weak controller, weak client] in
            guard let controller, let client else { return }
            let paneIDs = Array(controller.paneControllers.keys).sorted()
            guard !paneIDs.isEmpty else { return }
            Task {
                await client.continueDeferredBootstrap(paneIDs: paneIDs)
            }
        }
        windowControllersByWorkspace[session.workspaceID, default: [:]][snapshot.windowID] = controller
        let tab = controller.tab

        let window = TmuxWindow(
            windowID: snapshot.windowID,
            name: snapshot.title,
            paneIDs: [],
            windowIndex: snapshot.windowIndex,
            isActive: snapshot.isActive
        )
        let insertIndex = AttachedTmuxWindowRuntime.terminalInsertIndex(for: window, tabs: session.tabs)
        session.tabs.insert(tab, at: insertIndex)

        if snapshot.isActive || session.selectedTabID == nil {
            if snapshot.isActive {
                activeWindowIDByWorkspaceID[session.workspaceID] = snapshot.windowID
            } else if activeWindowIDByWorkspaceID[session.workspaceID] == nil {
                activeWindowIDByWorkspaceID[session.workspaceID] = snapshot.windowID
            }
            withSuppressedTabSelectionSync(for: session.workspaceID) {
                session.selectedTabID = tab.id
            }
        }
    }

    func applyLayout(
        _ layout: String,
        windowID: Int,
        session: Session,
        client: TmuxControlClient
    ) {
        guard let app = ghosttyApp?.app,
              let tab = session.tabs.first(where: { $0.tmuxWindowID == windowID }) else {
            return
        }

        let buildResult = AttachedTmuxWindowRuntime.buildLayoutTree(
            layout: layout,
            existingTree: tab.surfaceTree
        ) { paneID in
            let surface = Ghostty.SurfaceView(
                app,
                baseConfig: Self.attachedTmuxSurfaceConfiguration()
            )
            surface.tmuxPaneID = paneID
            surface.tmuxControlClient = client
            return surface
        }

        tab.surfaceTree = .init(root: buildResult.root, zoomed: nil)
        // Existing layout leaves may be reused; always rebind them to the
        // current control client so key routing remains valid after reconnects.
        let leaves = tab.surfaceTree?.root?.leaves() ?? []
        for surface in leaves {
            surface.tmuxControlClient = client
        }
        if let focused = tab.focusedSurface,
           !leaves.contains(where: { $0 === focused }) {
            tab.focusedSurface = leaves.first
        } else if tab.focusedSurface == nil {
            tab.focusedSurface = leaves.first
        }
        tab.requestThumbnailRefresh()
    }

    func tabContainingPane(_ paneID: Int, in session: Session) -> TerminalTab? {
        for tab in session.tabs where tab.kind == .terminal {
            guard let leaves = tab.surfaceTree?.root?.leaves() else { continue }
            if leaves.contains(where: { $0.tmuxPaneID == paneID }) {
                return tab
            }
        }
        return nil
    }

    func withSuppressedTabSelectionSync(
        for workspaceID: String,
        _ body: () -> Void
    ) {
        tabSelectionSyncSuppressionWorkspaceIDs.insert(workspaceID)
        defer { tabSelectionSyncSuppressionWorkspaceIDs.remove(workspaceID) }
        body()
    }
}

extension TmuxSessionBridge: TmuxControlClientDelegate {
    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow) {
        route(.windowAdded(window), from: client)
    }

    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int) {
        route(.windowClosed(windowID: windowID), from: client)
        onWindowClosed?(client, windowID)
    }

    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String) {
        route(.windowRenamed(windowID: windowID, title: name), from: client)
    }

    func controlClient(_ client: TmuxControlClient, didChangeActiveWindowID windowID: Int) {
        route(.activeWindowChanged(windowID: windowID), from: client)
    }

    func controlClient(_ client: TmuxControlClient, didChangeActivePaneID paneID: Int, inWindowID windowID: Int) {
        route(.activePaneChanged(windowID: windowID, paneID: paneID), from: client)
    }

    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String) {
        route(.layoutChanged(windowID: windowID, layout: layout), from: client)
    }

    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int) {
        route(.paneOutput(paneID: paneID, data: data), from: client)
    }

    func controlClient(_ client: TmuxControlClient, didReceivePaneTitle title: String, forPaneID paneID: Int) {
        // Pane title handling is intentionally deferred.
    }

    func controlClient(_ client: TmuxControlClient, didChangeState state: ConnectionState) {
        guard let session = session(for: client),
              case .attached(var info) = session.mode else {
            return
        }

        info.connectionState = state
        session.mode = .attached(info)

        switch state {
        case .connected:
            session.backingState = .available
        case .connecting:
            break
        case .disconnected(let reason):
            if !session.tabs.contains(where: { $0.kind == .terminal }) {
                session.backingState = .missingAttachedBacking(reason: reason)
            }
        }
    }

    func controlClientDidExit(_ client: TmuxControlClient, reason: String?) {
        route(.clientExited, from: client)
        if let session = session(for: client),
           let controllers = windowControllersByWorkspace.removeValue(forKey: session.workspaceID) {
            for (_, controller) in controllers {
                controller.teardown()
            }
        }
        onClientExit?(client)
        guard let session = session(for: client),
              case .attached(var info) = session.mode else {
            return
        }

        info.connectionState = .disconnected(reason: reason)
        session.mode = .attached(info)
        activeWindowIDByWorkspaceID.removeValue(forKey: session.workspaceID)
        if !session.tabs.contains(where: { $0.kind == .terminal }) {
            session.backingState = .missingAttachedBacking(reason: reason)
        }
    }
}
