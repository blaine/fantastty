import Foundation

struct RemoteWorkspaceRuntime {
    let workspaceID: String

    private var layoutGeneration: UInt64?
    private var paneIDs: Set<Int> = []
    private var paneSizes: [Int: RemoteGridSize] = [:]
    private var paneStates: [Int: RemotePaneGridState] = [:]
    private var unsupportedPaneGenerations: [Int: UInt64] = [:]

    init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    mutating func handle(
        _ message: RemoteWorkspaceMessage,
        delivery: RemotePaneDeltaDelivery = .reliable
    ) -> [RemoteWorkspaceRuntimeAction] {
        switch message {
        case .workspaceSnapshot(let snapshot):
            return handle(snapshot)
        case .paneKeyframe(let keyframe):
            return handle(keyframe)
        case .paneDelta(let delta):
            return handle(delta, delivery: delivery)
        case .unsupportedPaneState(let state):
            return handle(state)
        }
    }

    mutating func handleReattach() -> [RemoteWorkspaceRuntimeAction] {
        guard !paneIDs.isEmpty else { return [] }

        paneStates.removeAll()
        unsupportedPaneGenerations.removeAll()
        return paneIDs.sorted().map { paneID in
            .requestKeyframe(paneID: paneID, reason: .noKeyframe)
        }
    }

    func paneSize(paneID: Int) -> RemoteGridSize? {
        paneSizes[paneID]
    }

    func paneState(paneID: Int) -> RemotePaneGridState? {
        paneStates[paneID]
    }
}

enum RemoteWorkspaceRuntimeAction: Equatable {
    case applyWorkspaceSnapshot(RemoteWorkspaceSnapshot)
    case renderPaneGrid(paneID: Int, state: RemotePaneGridState)
    case requestKeyframe(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)
    case showUnsupportedPaneState(RemoteUnsupportedPaneState)
}

private extension RemoteWorkspaceRuntime {
    mutating func handle(_ snapshot: RemoteWorkspaceSnapshot) -> [RemoteWorkspaceRuntimeAction] {
        guard snapshot.workspaceID == workspaceID else { return [] }
        if let layoutGeneration, snapshot.layoutGeneration <= layoutGeneration {
            return []
        }

        let nextPanes = snapshot.panes.sorted { $0.paneID < $1.paneID }
        guard let windowIDs = validateSnapshotWindows(snapshot.windows),
              validateSnapshotPanes(nextPanes, windowIDs: windowIDs) else {
            return []
        }

        layoutGeneration = snapshot.layoutGeneration
        let nextPaneIDs = Set(nextPanes.map(\.paneID))
        for paneID in Set(paneStates.keys).subtracting(nextPaneIDs) {
            paneStates.removeValue(forKey: paneID)
        }
        for paneID in Set(unsupportedPaneGenerations.keys).subtracting(nextPaneIDs) {
            unsupportedPaneGenerations.removeValue(forKey: paneID)
        }
        paneIDs = nextPaneIDs
        paneSizes = Dictionary(uniqueKeysWithValues: nextPanes.map { pane in
            (pane.paneID, RemoteGridSize(columns: pane.frame.columns, rows: pane.frame.rows))
        })

        var actions: [RemoteWorkspaceRuntimeAction] = [.applyWorkspaceSnapshot(snapshot)]
        for pane in nextPanes {
            let paneID = pane.paneID
            let expectedSize = RemoteGridSize(columns: pane.frame.columns, rows: pane.frame.rows)
            if unsupportedPaneGenerations[paneID] != nil {
                actions.append(.requestKeyframe(paneID: paneID, reason: .noKeyframe))
                continue
            }
            if let state = paneStates[paneID], state.keyframeID != nil {
                if state.gridSize == expectedSize {
                    actions.append(.renderPaneGrid(paneID: paneID, state: state))
                } else {
                    paneStates.removeValue(forKey: paneID)
                    actions.append(.requestKeyframe(paneID: paneID, reason: .resizeMismatch))
                }
            } else {
                actions.append(.requestKeyframe(paneID: paneID, reason: .noKeyframe))
            }
        }
        return actions
    }

    func validateSnapshotWindows(_ windows: [RemoteWorkspaceWindow]) -> Set<Int>? {
        var seenWindowIDs = Set<Int>()
        for window in windows {
            guard seenWindowIDs.insert(window.windowID).inserted else {
                return nil
            }
        }
        return seenWindowIDs
    }

    func validateSnapshotPanes(_ panes: [RemoteWorkspacePane], windowIDs: Set<Int>) -> Bool {
        var seenPaneIDs = Set<Int>()
        for pane in panes {
            guard seenPaneIDs.insert(pane.paneID).inserted else {
                return false
            }
            guard windowIDs.contains(pane.windowID) else {
                return false
            }
            guard pane.frame.columns > 0, pane.frame.rows > 0 else {
                return false
            }
        }
        return true
    }

    mutating func handle(_ keyframe: RemotePaneKeyframe) -> [RemoteWorkspaceRuntimeAction] {
        guard keyframe.workspaceID == workspaceID else { return [] }
        if let fencedGeneration = unsupportedPaneGenerations[keyframe.paneID],
           keyframe.paneGeneration < fencedGeneration {
            return []
        }
        if let expectedSize = paneSizes[keyframe.paneID],
           keyframe.gridSize != expectedSize {
            paneStates.removeValue(forKey: keyframe.paneID)
            return [.requestKeyframe(paneID: keyframe.paneID, reason: .resizeMismatch)]
        }

        var state = paneStates[keyframe.paneID] ?? .empty
        switch state.apply(keyframe) {
        case .applied:
            paneStates[keyframe.paneID] = state
            if let fencedGeneration = unsupportedPaneGenerations[keyframe.paneID],
               keyframe.paneGeneration >= fencedGeneration {
                unsupportedPaneGenerations.removeValue(forKey: keyframe.paneID)
            }
            guard paneIDs.contains(keyframe.paneID) else { return [] }
            return [.renderPaneGrid(paneID: keyframe.paneID, state: state)]
        case .dropped:
            return []
        case .needsKeyframe(let reason):
            return [.requestKeyframe(paneID: keyframe.paneID, reason: reason)]
        }
    }

    mutating func handle(
        _ delta: RemotePaneDelta,
        delivery: RemotePaneDeltaDelivery
    ) -> [RemoteWorkspaceRuntimeAction] {
        guard delta.workspaceID == workspaceID else { return [] }
        guard paneIDs.contains(delta.paneID) else { return [] }
        if let fencedGeneration = unsupportedPaneGenerations[delta.paneID],
           delta.paneGeneration <= fencedGeneration {
            return []
        }

        var state = paneStates[delta.paneID] ?? .empty
        switch state.apply(delta, delivery: delivery) {
        case .applied:
            if let expectedSize = paneSizes[delta.paneID],
               state.gridSize != expectedSize {
                paneStates.removeValue(forKey: delta.paneID)
                return [.requestKeyframe(paneID: delta.paneID, reason: .resizeMismatch)]
            }
            paneStates[delta.paneID] = state
            return [.renderPaneGrid(paneID: delta.paneID, state: state)]
        case .dropped:
            return []
        case .needsKeyframe(let reason):
            return [.requestKeyframe(paneID: delta.paneID, reason: reason)]
        }
    }

    mutating func handle(_ state: RemoteUnsupportedPaneState) -> [RemoteWorkspaceRuntimeAction] {
        guard state.workspaceID == workspaceID else { return [] }
        guard paneIDs.contains(state.paneID) else { return [] }
        if let currentGeneration = paneStates[state.paneID]?.paneGeneration,
           state.paneGeneration < currentGeneration {
            return []
        }
        if let fencedGeneration = unsupportedPaneGenerations[state.paneID],
           state.paneGeneration < fencedGeneration {
            return []
        }

        unsupportedPaneGenerations[state.paneID] = max(
            unsupportedPaneGenerations[state.paneID] ?? 0,
            state.paneGeneration
        )
        return [.showUnsupportedPaneState(state)]
    }
}
