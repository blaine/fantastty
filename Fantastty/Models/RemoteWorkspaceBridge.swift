import Combine
import Foundation
import GhosttyKit

struct RemoteWorkspaceRenderDiagnostic: Equatable, CustomStringConvertible {
    let workspaceID: String
    let paneID: Int
    let result: RemoteGridSurfaceRenderResult?
    let hasSurface: Bool
    let hasSurfaceModel: Bool
    let surfaceSize: RemoteGridSize?
    let stateSize: RemoteGridSize?
    let requestedResizeKeyframe: Bool
    let tentativeRows: Int

    var description: String {
        [
            "workspace=\(workspaceID)",
            "pane=\(paneID)",
            "result=\(result.map(String.init(describing:)) ?? "none")",
            "hasSurface=\(hasSurface)",
            "hasSurfaceModel=\(hasSurfaceModel)",
            "surfaceSize=\(Self.describe(surfaceSize))",
            "stateSize=\(Self.describe(stateSize))",
            "requestedResizeKeyframe=\(requestedResizeKeyframe)",
            "tentativeRows=\(tentativeRows)"
        ].joined(separator: ",")
    }

    private static func describe(_ size: RemoteGridSize?) -> String {
        guard let size else { return "nil" }
        return "\(size.columns)x\(size.rows)"
    }
}

struct RemoteWorkspacePredictionDiagnostic: Equatable, CustomStringConvertible {
    let workspaceID: String
    let paneID: Int
    let state: RemoteEngineDiagnosticPredictiveEchoState

    var description: String {
        [
            "workspace=\(workspaceID)",
            "pane=\(paneID)",
            "predictiveEcho=\(state.description)"
        ].joined(separator: ",")
    }
}

enum RemotePredictiveEchoSettings {
    static let userDefaultsKey = "remotePredictiveEchoEnabled"
}

final class RemoteWorkspaceBridge {
    typealias SurfaceFactory = (Int) -> Ghostty.SurfaceView?
    typealias PaneGridRenderer = (RemotePaneGridState, Ghostty.SurfaceView) -> RemoteGridSurfaceRenderResult
    typealias PaneGridRenderOperation = (
        RemotePaneGridState,
        Ghostty.SurfaceView,
        Bool,
        Set<Int>?
    ) -> RemoteGridSurfaceRenderResult
    typealias PaneGridResizeOperation = (Ghostty.SurfaceView, RemoteGridSize) -> Bool
    typealias KeyframeRequestHandler = (String, Int, RemotePaneGridKeyframeRequestReason) -> Task<Void, Never>?
    typealias PaneInputHandler = (String, Int, Data) -> Void
    typealias PaneResizeHandler = (String, Int, RemoteGridSize) -> Void
    typealias UnsupportedPaneStateHandler = (String, RemoteUnsupportedPaneState) -> Void
    typealias AuthoritativePaneRenderHandler = (String, Int) -> Void
    typealias RenderDiagnosticHandler = (RemoteWorkspaceRenderDiagnostic) -> Void
    typealias PredictionDiagnosticHandler = (RemoteWorkspacePredictionDiagnostic) -> Void
    typealias TabSelectionSyncHandler = (String, () -> Void) -> Void
    typealias PredictionClock = () -> TimeInterval
    typealias PredictionScheduler = (TimeInterval, @escaping @MainActor () -> Void) -> RemotePredictionTimer

    static let remoteRenderRetryDelay: DispatchTimeInterval = .milliseconds(50)
    static let remoteRenderRetryLimit = 20
    static let remoteWorkspaceSilentCommand = "/bin/cat"

    var ghosttyApp: Ghostty.App?
    var surfaceFactory: SurfaceFactory?
    var paneGridRenderer: PaneGridRenderer {
        get {
            paneGridRendererOverride ?? { state, surfaceView in
                MainActor.assumeIsolated {
                    guard let surface = surfaceView.surfaceModel else { return .notReady }
                    return RemoteGridSurfaceRenderer().render(state, into: surface)
                }
            }
        }
        set {
            paneGridRendererOverride = newValue
        }
    }
    private var paneGridRendererOverride: PaneGridRenderer?
    var paneGridRenderOperation: PaneGridRenderOperation = { state, surfaceView, resetGrid, rowsToRender in
        MainActor.assumeIsolated {
            guard let surface = surfaceView.surfaceModel else { return .notReady }
            return RemoteGridSurfaceRenderer().render(
                state,
                into: surface,
                resetGrid: resetGrid,
                rowsToRender: rowsToRender
            )
        }
    }
    var paneGridResizeOperation: PaneGridResizeOperation = { surface, size in
        surface.resizeRemoteGrid(columns: size.columns, rows: size.rows)
    }
    var keyframeRequestHandler: KeyframeRequestHandler?
    var paneInputHandler: PaneInputHandler?
    var paneResizeHandler: PaneResizeHandler?
    var unsupportedPaneStateHandler: UnsupportedPaneStateHandler?
    var authoritativePaneRenderHandler: AuthoritativePaneRenderHandler?
    var renderDiagnosticHandler: RenderDiagnosticHandler?
    var predictionDiagnosticHandler: PredictionDiagnosticHandler?
    var tabSelectionSyncHandler: TabSelectionSyncHandler?
    var isPredictiveEchoEnabled = true {
        didSet {
            guard oldValue != isPredictiveEchoEnabled, !isPredictiveEchoEnabled else { return }
            clearAllPredictions(reason: .disabledByUser)
        }
    }
    var predictionClock: PredictionClock = {
        Date().timeIntervalSinceReferenceDate
    }
    var predictionScheduler: PredictionScheduler = { delay, callback in
        let timer = DispatchRemotePredictionTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            timer.fire(callback)
        }
        return timer
    }

    private var bindings: [String: RemoteWorkspaceBinding] = [:]
    private var predictiveEchoEnabledByWorkspaceID: [String: Bool] = [:]

    func setPredictiveEchoEnabled(_ isEnabled: Bool, workspaceID: String) {
        predictiveEchoEnabledByWorkspaceID[workspaceID] = isEnabled
        guard !isEnabled, var binding = bindings[workspaceID] else { return }
        clearPredictions(reason: .disabledByUser, binding: &binding)
        bindings[workspaceID] = binding
    }

    func registerRemoteWorkspaceSession(_ session: Session) {
        bindings[session.workspaceID] = RemoteWorkspaceBinding(
            session: session,
            runtime: RemoteWorkspaceRuntime(workspaceID: session.workspaceID)
        )
    }

    func unregisterRemoteWorkspaceSession(workspaceID: String) {
        if var binding = bindings.removeValue(forKey: workspaceID) {
            binding.cancelPredictionTimers()
        }
    }

    func unregisterSession(_ session: Session) {
        unregisterRemoteWorkspaceSession(workspaceID: session.workspaceID)
    }

    func hasBinding(for workspaceID: String) -> Bool {
        guard let binding = bindings[workspaceID] else { return false }
        return binding.session != nil
    }

    func handle(_ message: RemoteWorkspaceMessage, delivery: RemotePaneDeltaDelivery = .reliable) {
        let workspaceID = message.workspaceID
        guard var binding = bindings[workspaceID] else { return }
        guard binding.session != nil else {
            bindings.removeValue(forKey: workspaceID)
            return
        }

        let actions = binding.runtime.handle(message, delivery: delivery)
        for action in actions {
            apply(action, workspaceID: workspaceID, binding: &binding)
        }
        bindings[workspaceID] = binding
    }

    func handleReattach(workspaceID: String) async {
        guard var binding = bindings[workspaceID] else { return }
        guard binding.session != nil else {
            bindings.removeValue(forKey: workspaceID)
            return
        }

        binding.pendingKeyframeRequests.removeAll()
        binding.pendingRenderRetryPaneIDs.removeAll()
        binding.renderRetryCounts.removeAll()
        binding.renderedGridSizesByPaneID.removeAll()
        binding.renderedGridRowVersionsByPaneID.removeAll()
        binding.renderedGridIdentitiesByPaneID.removeAll()
        for paneID in binding.predictionPaneIDs {
            clearPrediction(paneID: paneID, reason: .reattach, binding: &binding)
        }
        let renderedPredictionPaneIDs = binding.renderedPredictionPaneIDs
        for paneID in renderedPredictionPaneIDs {
            renderAuthoritativePane(paneID: paneID, binding: &binding, notifyAuthoritativeRender: false)
        }
        let actions = binding.runtime.handleReattach()
        for action in actions {
            if case .requestKeyframe(let paneID, let reason) = action {
                if recordKeyframeRequest(
                    workspaceID: workspaceID,
                    paneID: paneID,
                    reason: reason,
                    binding: &binding
                ) {
                    await keyframeRequestHandler?(workspaceID, paneID, reason)?.value
                }
                continue
            }
            apply(action, workspaceID: workspaceID, binding: &binding)
        }
        bindings[workspaceID] = binding
    }

    func handleRemotePaneBecameVisible(workspaceID: String, paneID: Int) {
        guard var binding = bindings[workspaceID] else { return }
        guard binding.session != nil else {
            bindings.removeValue(forKey: workspaceID)
            return
        }

        binding.renderedGridSizesByPaneID.removeValue(forKey: paneID)
        binding.renderedGridRowVersionsByPaneID.removeValue(forKey: paneID)
        binding.renderedGridIdentitiesByPaneID.removeValue(forKey: paneID)
        renderAuthoritativePane(paneID: paneID, binding: &binding, notifyAuthoritativeRender: false)
        bindings[workspaceID] = binding
    }

    func handleRemotePaneInput(workspaceID: String, paneID: Int, input: RemotePaneInput) {
        guard var binding = bindings[workspaceID] else { return }
        guard binding.session != nil else {
            bindings.removeValue(forKey: workspaceID)
            return
        }

        paneInputHandler?(workspaceID, paneID, input.data)
        guard binding.focusedPaneIDs.contains(paneID) else {
            bindings[workspaceID] = binding
            return
        }

        let hadRenderedPrediction = binding.renderedPredictionPaneIDs.contains(paneID)
        guard isPredictiveEchoEnabled(for: workspaceID) else {
            clearPrediction(paneID: paneID, reason: .disabledByUser, binding: &binding)
            if hadRenderedPrediction {
                renderAuthoritativePane(paneID: paneID, binding: &binding)
            }
            bindings[workspaceID] = binding
            return
        }

        var engine = binding.predictiveEchoEngines[paneID] ?? RemotePredictiveEchoEngine()
        let now = predictionClock()
        let stateSuppressionReason = diagnosticSuppressionReason(
            for: input,
            state: binding.runtime.paneState(paneID: paneID)
        )
        let engineSuppressionReason = engine.diagnosticSuppressionReason(for: input, now: now)
        let diagnosticSuppressionReason = stateSuppressionReason ?? engineSuppressionReason
        let result = engine.observeLocalInput(input, now: now)
        binding.predictiveEchoEngines[paneID] = engine
        emitPredictionDiagnostic(
            workspaceID: workspaceID,
            paneID: paneID,
            state: diagnosticState(
                for: result,
                input: input,
                diagnosticSuppressionReason: diagnosticSuppressionReason
            )
        )
        if shouldRenderPredictionStateAfterLocalInput(
            hadRenderedPrediction: hadRenderedPrediction,
            input: input,
            result: result
        ), let state = binding.runtime.paneState(paneID: paneID) {
            renderPane(paneID: paneID, state: state, binding: &binding)
        } else if shouldRenderAuthoritativeStateAfterLocalInput(
            hadRenderedPrediction: hadRenderedPrediction,
            result: result
        ) {
            renderAuthoritativePane(paneID: paneID, binding: &binding)
        }
        if result == .accepted {
            schedulePredictionRender(workspaceID: workspaceID, paneID: paneID, now: now, binding: &binding)
        } else {
            cancelPredictionTimer(paneID: paneID, binding: &binding)
        }
        bindings[workspaceID] = binding
    }

    func handleRemotePaneFocus(workspaceID: String, paneID: Int, focused: Bool) {
        guard var binding = bindings[workspaceID] else { return }
        guard binding.session != nil else {
            bindings.removeValue(forKey: workspaceID)
            return
        }
        let hadRenderedPrediction = binding.renderedPredictionPaneIDs.contains(paneID)
        setRemotePaneFocus(paneID: paneID, focused: focused, binding: &binding)
        if !focused && hadRenderedPrediction {
            renderAuthoritativePane(paneID: paneID, binding: &binding)
        }
        bindings[workspaceID] = binding
    }
}

private extension RemoteWorkspaceBridge {
    static func remoteSurfaceConfiguration() -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.command = remoteWorkspaceSilentCommand
        return config
    }

    func makeSurface(for paneID: Int) -> Ghostty.SurfaceView? {
        if let surfaceFactory {
            return surfaceFactory(paneID)
        }
        guard let app = ghosttyApp?.app else { return nil }
        return Ghostty.SurfaceView(app, baseConfig: Self.remoteSurfaceConfiguration())
    }

    func apply(
        _ action: RemoteWorkspaceRuntimeAction,
        workspaceID: String,
        binding: inout RemoteWorkspaceBinding
    ) {
        switch action {
        case .applyWorkspaceSnapshot(let snapshot):
            apply(snapshot, binding: &binding)
        case .renderPaneGrid(let paneID, let state):
            renderPane(paneID: paneID, state: state, binding: &binding)
        case .requestKeyframe(let paneID, let reason):
            requestKeyframe(
                workspaceID: workspaceID,
                paneID: paneID,
                reason: reason,
                binding: &binding
            )
        case .showUnsupportedPaneState(let state):
            unsupportedPaneStateHandler?(workspaceID, state)
        }
    }

    @discardableResult
    func requestKeyframe(
        workspaceID: String,
        paneID: Int,
        reason: RemotePaneGridKeyframeRequestReason,
        binding: inout RemoteWorkspaceBinding
    ) -> Task<Void, Never>? {
        guard recordKeyframeRequest(
            workspaceID: workspaceID,
            paneID: paneID,
            reason: reason,
            binding: &binding
        ) else { return nil }

        return keyframeRequestHandler?(workspaceID, paneID, reason)
    }

    func recordKeyframeRequest(
        workspaceID: String,
        paneID: Int,
        reason: RemotePaneGridKeyframeRequestReason,
        binding: inout RemoteWorkspaceBinding
    ) -> Bool {
        let request = RemotePendingKeyframeRequest(
            reason: reason,
            paneSize: binding.runtime.paneSize(paneID: paneID)
        )
        if let pending = binding.pendingKeyframeRequests[paneID],
           shouldSuppressKeyframeRequest(
            pending: pending,
            next: request
           ) {
            return false
        }
        binding.pendingKeyframeRequests[paneID] = request
        return true
    }

    func shouldSuppressKeyframeRequest(
        pending: RemotePendingKeyframeRequest,
        next: RemotePendingKeyframeRequest
    ) -> Bool {
        if next.reason == .resizeMismatch {
            if pending.reason != .resizeMismatch {
                return false
            }
            if pending.paneSize != next.paneSize {
                return false
            }
        }
        return true
    }

    func apply(_ snapshot: RemoteWorkspaceSnapshot, binding: inout RemoteWorkspaceBinding) {
        guard let session = binding.session else { return }

        let panesByWindow = Dictionary(grouping: snapshot.panes, by: \.windowID)
        let currentPaneIDs = Set(snapshot.panes.map(\.paneID))
        for paneID in binding.surfacesByPaneID.keys where !currentPaneIDs.contains(paneID) {
            clearPrediction(paneID: paneID, reason: .focusLost, binding: &binding)
            binding.predictiveEchoEngines.removeValue(forKey: paneID)
            binding.predictionGenerations.removeValue(forKey: paneID)
            binding.focusedPaneIDs.remove(paneID)
            binding.renderedPredictionPaneIDs.remove(paneID)
            binding.surfacesByPaneID.removeValue(forKey: paneID)
            binding.renderedGridSizesByPaneID.removeValue(forKey: paneID)
            binding.renderedGridRowVersionsByPaneID.removeValue(forKey: paneID)
            binding.renderedGridIdentitiesByPaneID.removeValue(forKey: paneID)
            binding.surfaceSizeSubscriptions.removeValue(forKey: paneID)
            binding.pendingRenderRetryPaneIDs.remove(paneID)
            binding.renderRetryCounts.removeValue(forKey: paneID)
        }

        let ownedTabIDs = Set(binding.tabIDsByWindowID.values)
        let existingTabsByWindowID = Dictionary(
            uniqueKeysWithValues: binding.tabIDsByWindowID.compactMap { windowID, tabID -> (Int, TerminalTab)? in
                guard let tab = session.tabs.first(where: { $0.id == tabID }) else { return nil }
                return (windowID, tab)
            }
        )

        let windows = snapshot.windows.sorted(by: compareWindows)
        var nextTabs: [TerminalTab] = []
        for window in windows {
            let tab: TerminalTab
            if let existing = existingTabsByWindowID[window.windowID] {
                tab = existing
            } else {
                tab = TerminalTab(type: session.type, title: window.title)
                binding.tabIDsByWindowID[window.windowID] = tab.id
            }
            tab.title = window.title
            tab.tmuxWindowID = window.windowID
            tab.tmuxWindowIndex = window.index

            let panes = (panesByWindow[window.windowID] ?? []).sorted(by: comparePanes)
            tab.surfaceTree = SplitTree(root: splitNode(for: panes, layout: window.layout, binding: &binding), zoomed: nil)
            let leaves = tab.surfaceTree?.root?.leaves() ?? []
            if let activePane = panes.first(where: \.isActive),
               let surface = binding.surfacesByPaneID[activePane.paneID] {
                tab.focusedSurface = surface
            } else if let focused = tab.focusedSurface, leaves.contains(where: { $0 === focused }) {
                tab.focusedSurface = focused
            } else {
                tab.focusedSurface = leaves.first
            }
            nextTabs.append(tab)
        }

        let currentWindowIDs = Set(windows.map(\.windowID))
        binding.tabIDsByWindowID = binding.tabIDsByWindowID.filter { currentWindowIDs.contains($0.key) }
        let previousSelectedTabID = session.selectedTabID
        let previousSelectionWasRemote = previousSelectedTabID.map { ownedTabIDs.contains($0) } ?? false
        let previousSelectedRemoteWindowID = previousSelectedTabID.flatMap { selectedTabID in
            existingTabsByWindowID.first { $0.value.id == selectedTabID }?.key
        }
        let previousSelectionWasUserOverride = previousSelectionWasRemote &&
            previousSelectedTabID != nil &&
            previousSelectedTabID != binding.lastAppliedSelectedTabID
        let nextOwnedTabIDs = Set(nextTabs.map(\.id))
        let nonRemoteTabs = session.tabs.filter { !ownedTabIDs.contains($0.id) && !nextOwnedTabIDs.contains($0.id) }
        session.tabs = nextTabs + nonRemoteTabs
        let currentTabIDs = Set(session.tabs.map(\.id))
        let resolvedSelectedTabID: UUID?
        if let selectedID = previousSelectedTabID,
           currentTabIDs.contains(selectedID),
           !previousSelectionWasRemote {
            resolvedSelectedTabID = selectedID
        } else if let previousSelectedRemoteWindowID,
                  previousSelectionWasUserOverride,
                  let selectedTabID = binding.tabIDsByWindowID[previousSelectedRemoteWindowID],
                  currentTabIDs.contains(selectedTabID) {
            resolvedSelectedTabID = selectedTabID
        } else if let activeWindow = windows.first(where: \.isActive),
           let selectedTabID = binding.tabIDsByWindowID[activeWindow.windowID] {
            resolvedSelectedTabID = selectedTabID
        } else if let selectedID = session.selectedTabID,
                  nextTabs.contains(where: { $0.id == selectedID }) {
            resolvedSelectedTabID = selectedID
        } else {
            resolvedSelectedTabID = nextTabs.first?.id
        }
        if session.selectedTabID != resolvedSelectedTabID {
            let applySelection = {
                session.selectedTabID = resolvedSelectedTabID
            }
            if let tabSelectionSyncHandler {
                tabSelectionSyncHandler(binding.runtime.workspaceID, applySelection)
            } else {
                applySelection()
            }
        }
        binding.lastAppliedSelectedTabID = resolvedSelectedTabID
    }

    func renderPane(
        paneID: Int,
        state: RemotePaneGridState,
        binding: inout RemoteWorkspaceBinding,
        allowPredictionOverlay: Bool = true,
        notifyAuthoritativeRender: Bool = true
    ) {
        guard let surface = binding.surfacesByPaneID[paneID] else {
            renderDiagnosticHandler?(RemoteWorkspaceRenderDiagnostic(
                workspaceID: binding.runtime.workspaceID,
                paneID: paneID,
                result: nil,
                hasSurface: false,
                hasSurfaceModel: false,
                surfaceSize: nil,
                stateSize: state.gridSize,
                requestedResizeKeyframe: false,
                tentativeRows: state.tentativeRows.count
            ))
            return
        }
        if let surfaceSize = remoteGridSize(from: surface.surfaceSize),
           let stateSize = state.gridSize,
           surfaceSize != stateSize {
            if nativeRemoteGridSize(from: surface) != surfaceSize {
                _ = paneGridResizeOperation(surface, surfaceSize)
            }
            let shouldRequestKeyframe = recordKeyframeRequest(
                workspaceID: binding.runtime.workspaceID,
                paneID: paneID,
                reason: .resizeMismatch,
                binding: &binding
            )
            let keyframeRequestTask: Task<Void, Never>?
            if shouldRequestKeyframe {
                paneResizeHandler?(binding.runtime.workspaceID, paneID, surfaceSize)
                keyframeRequestTask = keyframeRequestHandler?(binding.runtime.workspaceID, paneID, .resizeMismatch)
            } else {
                keyframeRequestTask = nil
            }
            renderDiagnosticHandler?(RemoteWorkspaceRenderDiagnostic(
                workspaceID: binding.runtime.workspaceID,
                paneID: paneID,
                result: nil,
                hasSurface: true,
                hasSurfaceModel: surface.surfaceModel != nil,
                surfaceSize: surfaceSize,
                stateSize: stateSize,
                requestedResizeKeyframe: keyframeRequestTask != nil,
                tentativeRows: state.tentativeRows.count
            ))
            return
        }

        var renderState = state
        if allowPredictionOverlay {
            var predictionEngine = binding.predictiveEchoEngines[paneID] ?? RemotePredictiveEchoEngine()
            let now = predictionClock()
            let hadRenderedPrediction = binding.renderedPredictionPaneIDs.contains(paneID)
            predictionEngine.observeAuthoritativeState(state, now: now)
            if hadRenderedPrediction, predictionEngine.lastClearReason == .mismatch {
                emitPredictionDiagnostic(
                    workspaceID: binding.runtime.workspaceID,
                    paneID: paneID,
                    state: .rolledBack(reason: .authoritativeMismatch)
                )
            }
            let overlay = predictionEngine.visibleOverlay(now: now)
            if !overlay.cells.isEmpty || overlay.cursor != nil {
                if let displayState = state.displayCopy(applying: overlay) {
                    renderState = displayState
                } else {
                    predictionEngine.clear(reason: .mismatch)
                }
            }
            binding.predictiveEchoEngines[paneID] = predictionEngine
        }

        binding.pendingKeyframeRequests.removeValue(forKey: paneID)
        if let stateSize = renderState.gridSize,
           nativeRemoteGridSize(from: surface) != stateSize {
            _ = paneGridResizeOperation(surface, stateSize)
        }
        var result = renderGrid(renderState, paneID: paneID, surfaceView: surface, binding: binding)
        if result.status == .rejectedBySurface, !renderState.tentativeRows.isEmpty {
            clearPrediction(paneID: paneID, reason: .mismatch, binding: &binding)
            emitPredictionDiagnostic(
                workspaceID: binding.runtime.workspaceID,
                paneID: paneID,
                state: .rolledBack(reason: .authoritativeMismatch)
            )
            renderState = state
            result = renderGrid(renderState, paneID: paneID, surfaceView: surface, binding: binding)
        }
        if result.status == .rendered {
            binding.renderedGridSizesByPaneID[paneID] = renderState.gridSize
            binding.renderedGridRowVersionsByPaneID[paneID] = renderState.rowVersions
            binding.renderedGridIdentitiesByPaneID[paneID] = renderIdentity(for: renderState)
            if renderState.tentativeRows.isEmpty {
                binding.renderedPredictionPaneIDs.remove(paneID)
            } else {
                binding.renderedPredictionPaneIDs.insert(paneID)
            }
        }
        renderDiagnosticHandler?(RemoteWorkspaceRenderDiagnostic(
            workspaceID: binding.runtime.workspaceID,
            paneID: paneID,
            result: result,
            hasSurface: true,
            hasSurfaceModel: surface.surfaceModel != nil,
            surfaceSize: remoteGridSize(from: surface.surfaceSize),
            stateSize: renderState.gridSize,
            requestedResizeKeyframe: false,
            tentativeRows: renderState.tentativeRows.count
        ))
        switch result.status {
        case .rendered:
            binding.renderRetryCounts.removeValue(forKey: paneID)
            guard let session = binding.session else { return }
            session.tab(containing: surface)?.requestThumbnailRefresh()
            if notifyAuthoritativeRender, renderState.tentativeRows.isEmpty {
                authoritativePaneRenderHandler?(binding.runtime.workspaceID, paneID)
            }
        case .notReady:
            scheduleRenderRetry(workspaceID: binding.runtime.workspaceID, paneID: paneID, binding: &binding)
            return
        case .rejectedBySurface:
            guard result.rejectionStage != .resetGrid else {
                scheduleRenderRetry(workspaceID: binding.runtime.workspaceID, paneID: paneID, binding: &binding)
                return
            }
            binding.renderRetryCounts.removeValue(forKey: paneID)
            guard let workspaceID = state.workspaceID,
                  let paneID = state.paneID,
                  let paneGeneration = state.paneGeneration else {
                return
            }
            unsupportedPaneStateHandler?(
                workspaceID,
                RemoteUnsupportedPaneState(
                    workspaceID: workspaceID,
                    paneID: paneID,
                    paneGeneration: paneGeneration,
                    reason: .unsupportedCellAttribute,
                    fallback: .keepLastGoodKeyframe
                )
            )
        }
    }

    func scheduleRenderRetry(workspaceID: String, paneID: Int, binding: inout RemoteWorkspaceBinding) {
        let retryCount = binding.renderRetryCounts[paneID] ?? 0
        guard retryCount < Self.remoteRenderRetryLimit else { return }
        guard !binding.pendingRenderRetryPaneIDs.contains(paneID) else { return }

        binding.renderRetryCounts[paneID] = retryCount + 1
        binding.pendingRenderRetryPaneIDs.insert(paneID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.remoteRenderRetryDelay) { [weak self] in
            self?.retryRenderPane(workspaceID: workspaceID, paneID: paneID)
        }
    }

    func retryRenderPane(workspaceID: String, paneID: Int) {
        guard var binding = bindings[workspaceID] else { return }
        guard binding.pendingRenderRetryPaneIDs.contains(paneID) else { return }
        binding.pendingRenderRetryPaneIDs.remove(paneID)
        guard let state = binding.runtime.paneState(paneID: paneID) else {
            bindings[workspaceID] = binding
            return
        }
        renderPane(paneID: paneID, state: state, binding: &binding)
        bindings[workspaceID] = binding
    }

    func renderGrid(
        _ state: RemotePaneGridState,
        paneID: Int,
        surfaceView: Ghostty.SurfaceView,
        binding: RemoteWorkspaceBinding
    ) -> RemoteGridSurfaceRenderResult {
        if let paneGridRendererOverride {
            return paneGridRendererOverride(state, surfaceView)
        }
        let resetGrid = binding.renderedGridIdentitiesByPaneID[paneID] != renderIdentity(for: state)
        let rowsToRender = rowsToRender(
            paneID: paneID,
            state: state,
            resetGrid: resetGrid,
            binding: binding
        )
        return paneGridRenderOperation(state, surfaceView, resetGrid, rowsToRender)
    }

    func renderIdentity(for state: RemotePaneGridState) -> RemotePaneRenderIdentity {
        RemotePaneRenderIdentity(
            gridSize: state.gridSize,
            paneGeneration: state.paneGeneration,
            keyframeID: state.keyframeID,
            activeScreen: state.activeScreen
        )
    }

    func rowsToRender(
        paneID: Int,
        state: RemotePaneGridState,
        resetGrid: Bool,
        binding: RemoteWorkspaceBinding
    ) -> Set<Int>? {
        guard !resetGrid else { return nil }
        if binding.renderedPredictionPaneIDs.contains(paneID), state.tentativeRows.isEmpty {
            return nil
        }

        var rows = state.tentativeRows
        guard let previousVersions = binding.renderedGridRowVersionsByPaneID[paneID],
              previousVersions.count == state.rowVersions.count else {
            return nil
        }
        for index in state.rowVersions.indices where state.rowVersions[index] != previousVersions[index] {
            rows.insert(index)
        }
        return rows
    }

    func splitNode(
        for panes: [RemoteWorkspacePane],
        layout: String?,
        binding: inout RemoteWorkspaceBinding
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        var surfaces: [(RemoteWorkspacePane, Ghostty.SurfaceView)] = []
        for pane in panes {
            let surface: Ghostty.SurfaceView
            if let existing = binding.surfacesByPaneID[pane.paneID] {
                surface = existing
            } else if let created = makeSurface(for: pane.paneID) {
                binding.surfacesByPaneID[pane.paneID] = created
                surface = created
            } else {
                return nil
            }
            sizeRemoteSurface(surface, to: pane.frame)
            configureRemotePaneSurface(surface, paneID: pane.paneID, workspaceID: binding.runtime.workspaceID)
            subscribeSurfaceSize(surface, paneID: pane.paneID, workspaceID: binding.runtime.workspaceID, binding: &binding)
            setRemotePaneFocus(paneID: pane.paneID, focused: pane.isActive, binding: &binding)
            surfaces.append((pane, surface))
        }
        if let node = validatedLayoutNode(layout, paneIDs: Set(panes.map(\.paneID))) {
            let surfacesByPaneID = binding.surfacesByPaneID
            return TmuxLayoutMapper.mapToSplitTree(node) { paneID in
                surfacesByPaneID[paneID]!
            }
        }
        return splitNode(for: ArraySlice(surfaces))
    }

    func sizeRemoteSurface(_ surface: Ghostty.SurfaceView, to frame: RemotePaneFrame) {
        let size = RemoteGridSize(columns: frame.columns, rows: frame.rows)
        guard nativeRemoteGridSize(from: surface) != size else { return }
        _ = paneGridResizeOperation(surface, size)
    }

    func nativeRemoteGridSize(from surfaceView: Ghostty.SurfaceView) -> RemoteGridSize? {
        guard let surface = surfaceView.surface else { return nil }
        return remoteGridSize(from: ghostty_surface_size(surface))
    }

    func validatedLayoutNode(_ layout: String?, paneIDs expectedPaneIDs: Set<Int>) -> TmuxLayoutNode? {
        guard let layout, !layout.isEmpty else { return nil }
        let node = TmuxLayoutParser.parse(layout)
        let layoutPaneIDs = node.allPaneIDs()
        guard layoutPaneIDs.count == expectedPaneIDs.count,
              Set(layoutPaneIDs) == expectedPaneIDs,
              layoutNodeLooksValid(node) else {
            return nil
        }
        return node
    }

    func layoutNodeLooksValid(_ node: TmuxLayoutNode) -> Bool {
        switch node {
        case .leaf(_, let width, let height):
            return width > 0 && height > 0
        case .horizontalSplit(let children, let width, let height),
             .verticalSplit(let children, let width, let height):
            return width > 0 && height > 0 && children.count >= 2 && children.allSatisfy(layoutNodeLooksValid)
        }
    }

    func configureRemotePaneSurface(_ surface: Ghostty.SurfaceView, paneID: Int, workspaceID: String) {
        surface.tmuxPaneID = paneID
        surface.tmuxControlClient = nil
        surface.remotePaneInputHandler = { [weak self] paneID, input in
            self?.handleRemotePaneInput(
                workspaceID: workspaceID,
                paneID: paneID,
                input: input
            )
        }
        surface.remotePaneFocusHandler = { [weak self] paneID, focused in
            self?.handleRemotePaneFocus(workspaceID: workspaceID, paneID: paneID, focused: focused)
        }
    }

    func subscribeSurfaceSize(
        _ surface: Ghostty.SurfaceView,
        paneID: Int,
        workspaceID: String,
        binding: inout RemoteWorkspaceBinding
    ) {
        guard binding.surfaceSizeSubscriptions[paneID] == nil else { return }
        binding.surfaceSizeSubscriptions[paneID] = surface.$surfaceSize
            .compactMap { [weak self] size in
                self?.remoteGridSize(from: size)
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] size in
                self?.handleSurfaceSizeChange(workspaceID: workspaceID, paneID: paneID, size: size)
            }
    }

    func handleSurfaceSizeChange(workspaceID: String, paneID: Int, size: RemoteGridSize) {
        guard var binding = bindings[workspaceID] else { return }
        if binding.runtime.paneSize(paneID: paneID) == size {
            return
        }
        clearPrediction(paneID: paneID, reason: .resize, binding: &binding)
        bindings[workspaceID] = binding
        paneResizeHandler?(workspaceID, paneID, size)
    }

    func shouldRenderPredictionStateAfterLocalInput(
        hadRenderedPrediction: Bool,
        input: RemotePaneInput,
        result: RemotePredictionInputResult
    ) -> Bool {
        hadRenderedPrediction && input.source == .plainEraseByte && result == .accepted
    }

    func shouldRenderAuthoritativeStateAfterLocalInput(
        hadRenderedPrediction: Bool,
        result: RemotePredictionInputResult
    ) -> Bool {
        hadRenderedPrediction && result != .accepted
    }

    func isPredictiveEchoEnabled(for workspaceID: String) -> Bool {
        isPredictiveEchoEnabled && (predictiveEchoEnabledByWorkspaceID[workspaceID] ?? true)
    }

    func diagnosticState(
        for result: RemotePredictionInputResult,
        input: RemotePaneInput,
        diagnosticSuppressionReason: RemoteEngineDiagnosticPredictionSuppressionReason? = nil
    ) -> RemoteEngineDiagnosticPredictiveEchoState {
        switch result {
        case .accepted:
            return .enabled
        case .hiddenPendingEcho:
            return .suppressed(reason: .echoNotProven)
        case .forwardOnly:
            return .suppressed(reason: diagnosticSuppressionReason ?? suppressionReason(for: input.source))
        case .rejected:
            return .suppressed(reason: .unsupportedState)
        }
    }

    func suppressionReason(
        for source: RemotePaneInputSource
    ) -> RemoteEngineDiagnosticPredictionSuppressionReason {
        switch source {
        case .paste:
            return .paste
        case .imeCommit:
            return .ime
        case .escapeSequence:
            return .escapeSequence
        case .mouse:
            return .mouse
        case .directKey, .plainEraseByte:
            return .unsupportedState
        case .localBinding:
            return .unsupportedState
        }
    }

    func emitPredictionDiagnostic(
        workspaceID: String,
        paneID: Int,
        state: RemoteEngineDiagnosticPredictiveEchoState
    ) {
        predictionDiagnosticHandler?(RemoteWorkspacePredictionDiagnostic(
            workspaceID: workspaceID,
            paneID: paneID,
            state: state
        ))
    }

    func renderAuthoritativePane(
        paneID: Int,
        binding: inout RemoteWorkspaceBinding,
        notifyAuthoritativeRender: Bool = true
    ) {
        guard let state = binding.runtime.paneState(paneID: paneID) else { return }
        renderPane(
            paneID: paneID,
            state: state,
            binding: &binding,
            allowPredictionOverlay: false,
            notifyAuthoritativeRender: notifyAuthoritativeRender
        )
    }

    func setRemotePaneFocus(paneID: Int, focused: Bool, binding: inout RemoteWorkspaceBinding) {
        if focused {
            if binding.focusedPaneIDs.insert(paneID).inserted {
                binding.predictionGenerations[paneID, default: 0] += 1
            }
            return
        }

        guard binding.focusedPaneIDs.remove(paneID) != nil else { return }
        clearPrediction(paneID: paneID, reason: .focusLost, binding: &binding)
    }

    func clearPrediction(
        paneID: Int,
        reason: RemotePredictionClearReason,
        binding: inout RemoteWorkspaceBinding
    ) {
        cancelPredictionTimer(paneID: paneID, binding: &binding)
        if var engine = binding.predictiveEchoEngines[paneID] {
            engine.clear(reason: reason)
            binding.predictiveEchoEngines[paneID] = engine
        }
        if let diagnosticReason = diagnosticSuppressionReason(for: reason) {
            emitPredictionDiagnostic(
                workspaceID: binding.runtime.workspaceID,
                paneID: paneID,
                state: .suppressed(reason: diagnosticReason)
            )
        }
        binding.predictionGenerations[paneID, default: 0] += 1
    }

    func diagnosticSuppressionReason(
        for clearReason: RemotePredictionClearReason
    ) -> RemoteEngineDiagnosticPredictionSuppressionReason? {
        switch clearReason {
        case .disabledByUser:
            return .disabledByUser
        case .focusLost:
            return .focusLost
        case .reattach:
            return .reattach
        case .unsafeAuthoritativeState, .epochChanged, .resize, .mismatch:
            return nil
        }
    }

    func cancelPredictionTimer(paneID: Int, binding: inout RemoteWorkspaceBinding) {
        binding.predictionTimers.removeValue(forKey: paneID)?.cancel()
        binding.predictionTimerDeadlines.removeValue(forKey: paneID)
    }

    func schedulePredictionRender(
        workspaceID: String,
        paneID: Int,
        now: TimeInterval,
        binding: inout RemoteWorkspaceBinding
    ) {
        guard let deadline = binding.predictiveEchoEngines[paneID]?.nextOverlayDeadline(now: now) else {
            return
        }
        if let existingDeadline = binding.predictionTimerDeadlines[paneID],
           existingDeadline <= deadline {
            return
        }

        cancelPredictionTimer(paneID: paneID, binding: &binding)
        let generation = binding.predictionGenerations[paneID, default: 0]
        let delay = max(0, deadline - now)
        let timer = predictionScheduler(delay) { [weak self] in
            self?.renderScheduledPrediction(workspaceID: workspaceID, paneID: paneID, generation: generation)
        }
        binding.predictionTimers[paneID] = timer
        binding.predictionTimerDeadlines[paneID] = deadline
    }

    func renderScheduledPrediction(workspaceID: String, paneID: Int, generation: UInt64) {
        guard var binding = bindings[workspaceID] else { return }
        guard isPredictiveEchoEnabled(for: workspaceID) else {
            clearPrediction(paneID: paneID, reason: .disabledByUser, binding: &binding)
            bindings[workspaceID] = binding
            return
        }
        guard generation == binding.predictionGenerations[paneID, default: 0] else {
            bindings[workspaceID] = binding
            return
        }
        cancelPredictionTimer(paneID: paneID, binding: &binding)
        guard binding.focusedPaneIDs.contains(paneID),
              let state = binding.runtime.paneState(paneID: paneID) else {
            bindings[workspaceID] = binding
            return
        }
        renderPane(paneID: paneID, state: state, binding: &binding)
        schedulePredictionRender(
            workspaceID: workspaceID,
            paneID: paneID,
            now: predictionClock(),
            binding: &binding
        )
        bindings[workspaceID] = binding
    }

    func splitNode(
        for surfaces: ArraySlice<(RemoteWorkspacePane, Ghostty.SurfaceView)>
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard let first = surfaces.first else { return nil }
        guard surfaces.count > 1 else { return .leaf(view: first.1) }
        let rest = surfaces.dropFirst()
        guard let right = splitNode(for: rest) else { return .leaf(view: first.1) }
        let nextPane = rest.first?.0
        let direction = splitDirection(first.0, nextPane)
        return .split(.init(
            direction: direction,
            ratio: splitRatio(first.0, rest.map(\.0), direction: direction),
            left: .leaf(view: first.1),
            right: right
        ))
    }

    func splitDirection(
        _ pane: RemoteWorkspacePane,
        _ nextPane: RemoteWorkspacePane?
    ) -> SplitTree<Ghostty.SurfaceView>.Direction {
        guard let nextPane else { return .horizontal }
        if nextPane.frame.y != pane.frame.y {
            return .vertical
        }
        return .horizontal
    }

    func splitRatio(
        _ first: RemoteWorkspacePane,
        _ rest: [RemoteWorkspacePane],
        direction: SplitTree<Ghostty.SurfaceView>.Direction
    ) -> Double {
        guard !rest.isEmpty else { return 1.0 }
        let firstExtent = paneExtent([first], direction: direction)
        let restExtent = paneExtent(rest, direction: direction)
        return Double(firstExtent) / Double(firstExtent + restExtent)
    }

    func paneExtent(
        _ panes: [RemoteWorkspacePane],
        direction: SplitTree<Ghostty.SurfaceView>.Direction
    ) -> Int {
        guard let first = panes.first else { return 1 }
        switch direction {
        case .horizontal:
            let minX = panes.map(\.frame.x).min() ?? first.frame.x
            let maxX = panes.map { $0.frame.x + $0.frame.columns }.max() ?? first.frame.x + first.frame.columns
            return max(1, maxX - minX)
        case .vertical:
            let minY = panes.map(\.frame.y).min() ?? first.frame.y
            let maxY = panes.map { $0.frame.y + $0.frame.rows }.max() ?? first.frame.y + first.frame.rows
            return max(1, maxY - minY)
        }
    }

    func compareWindows(_ left: RemoteWorkspaceWindow, _ right: RemoteWorkspaceWindow) -> Bool {
        switch (left.index, right.index) {
        case let (leftIndex?, rightIndex?) where leftIndex != rightIndex:
            return leftIndex < rightIndex
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return left.windowID < right.windowID
        }
    }

    func comparePanes(_ left: RemoteWorkspacePane, _ right: RemoteWorkspacePane) -> Bool {
        if left.frame.y != right.frame.y {
            return left.frame.y < right.frame.y
        }
        if left.frame.x != right.frame.x {
            return left.frame.x < right.frame.x
        }
        return left.paneID < right.paneID
    }

    func remoteGridSize(from size: ghostty_surface_size_s?) -> RemoteGridSize? {
        guard let size else { return nil }
        let columns = Int(size.columns)
        let rows = Int(size.rows)
        guard columns > 0, rows > 0 else { return nil }
        return RemoteGridSize(columns: columns, rows: rows)
    }

    func clearAllPredictions(reason: RemotePredictionClearReason) {
        for workspaceID in Array(bindings.keys) {
            guard var binding = bindings[workspaceID] else { continue }
            clearPredictions(reason: reason, binding: &binding)
            bindings[workspaceID] = binding
        }
    }

    func clearPredictions(reason: RemotePredictionClearReason, binding: inout RemoteWorkspaceBinding) {
        let paneIDs = binding.predictionPaneIDs.union(binding.renderedPredictionPaneIDs)
        for paneID in paneIDs {
            let hadRenderedPrediction = binding.renderedPredictionPaneIDs.contains(paneID)
            clearPrediction(paneID: paneID, reason: reason, binding: &binding)
            if hadRenderedPrediction {
                renderAuthoritativePane(paneID: paneID, binding: &binding)
            }
        }
    }

    func diagnosticSuppressionReason(
        for input: RemotePaneInput,
        state: RemotePaneGridState?
    ) -> RemoteEngineDiagnosticPredictionSuppressionReason? {
        guard input.predictionEligible else {
            return suppressionReason(for: input.source)
        }
        guard let state else {
            return .unsupportedState
        }
        guard state.activeScreen == .primary else {
            return .alternateScreen
        }
        guard state.gridSize != nil, state.cursor?.visible == true else {
            return .echoOffOrNoOutput
        }
        return nil
    }
}

private struct RemoteWorkspaceBinding {
    weak var session: Session?
    var runtime: RemoteWorkspaceRuntime
    var surfacesByPaneID: [Int: Ghostty.SurfaceView] = [:]
    var tabIDsByWindowID: [Int: UUID] = [:]
    var surfaceSizeSubscriptions: [Int: AnyCancellable] = [:]
    var pendingKeyframeRequests: [Int: RemotePendingKeyframeRequest] = [:]
    var pendingRenderRetryPaneIDs: Set<Int> = []
    var renderRetryCounts: [Int: Int] = [:]
    var renderedGridSizesByPaneID: [Int: RemoteGridSize] = [:]
    var renderedGridRowVersionsByPaneID: [Int: [UInt64]] = [:]
    var renderedGridIdentitiesByPaneID: [Int: RemotePaneRenderIdentity] = [:]
    var predictiveEchoEngines: [Int: RemotePredictiveEchoEngine] = [:]
    var predictionTimers: [Int: RemotePredictionTimer] = [:]
    var predictionTimerDeadlines: [Int: TimeInterval] = [:]
    var predictionGenerations: [Int: UInt64] = [:]
    var focusedPaneIDs: Set<Int> = []
    var renderedPredictionPaneIDs: Set<Int> = []
    var lastAppliedSelectedTabID: UUID?
}

private struct RemotePaneRenderIdentity: Equatable {
    let gridSize: RemoteGridSize?
    let paneGeneration: UInt64?
    let keyframeID: UInt64?
    let activeScreen: RemoteActiveScreen?
}

private extension RemoteWorkspaceBinding {
    var predictionPaneIDs: Set<Int> {
        Set(predictiveEchoEngines.keys)
            .union(predictionTimers.keys)
            .union(predictionTimerDeadlines.keys)
            .union(predictionGenerations.keys)
    }

    mutating func cancelPredictionTimers() {
        predictionTimers.values.forEach { $0.cancel() }
        predictionTimers.removeAll()
        predictionTimerDeadlines.removeAll()
    }
}

private struct RemotePendingKeyframeRequest: Equatable {
    let reason: RemotePaneGridKeyframeRequestReason
    let paneSize: RemoteGridSize?
}

private extension RemoteWorkspaceMessage {
    var workspaceID: String {
        switch self {
        case .workspaceSnapshot(let snapshot):
            return snapshot.workspaceID
        case .paneKeyframe(let keyframe):
            return keyframe.workspaceID
        case .paneDelta(let delta):
            return delta.workspaceID
        case .unsupportedPaneState(let state):
            return state.workspaceID
        }
    }
}
