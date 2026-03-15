import Foundation

struct AttachedWorkspaceRuntimeV2 {
    private var windows: [Int: AttachedWindowRuntimeV2] = [:]
    private var paneToWindowID: [Int: Int] = [:]
    private var pendingLayouts: [Int: String] = [:]
    private var pendingPaneOutput: [Int: AttachedPaneRuntimeV2] = [:]

    mutating func handle(_ event: AttachedRuntimeEventV2) -> [AttachedRuntimeActionV2] {
        switch event {
        case .windowAdded(let window):
            return handleWindowAdded(window)

        case .windowClosed(let windowID):
            return handleWindowClosed(windowID: windowID)

        case .windowRenamed(let windowID, let title):
            guard var window = windows[windowID] else { return [] }
            window.rename(to: title)
            windows[windowID] = window
            return [.renameWindow(windowID: windowID, title: title)]

        case .activeWindowChanged(let windowID):
            guard windows[windowID] != nil else { return [] }
            return [.selectWindow(windowID: windowID)]

        case .layoutChanged(let windowID, let layout):
            return handleLayoutChanged(windowID: windowID, layout: layout)

        case .activePaneChanged(let windowID, let paneID):
            guard var window = windows[windowID] else { return [] }
            window.setActivePane(paneID)
            windows[windowID] = window
            guard window.activePaneID == paneID else { return [] }
            return [.setActivePane(windowID: windowID, paneID: paneID)]

        case .paneOutput(let paneID, let data):
            return handlePaneOutput(paneID: paneID, data: data)

        case .clientExited:
            windows.removeAll(keepingCapacity: false)
            paneToWindowID.removeAll(keepingCapacity: false)
            pendingLayouts.removeAll(keepingCapacity: false)
            pendingPaneOutput.removeAll(keepingCapacity: false)
            return []
        }
    }
}

private extension AttachedWorkspaceRuntimeV2 {
    mutating func handleWindowAdded(_ window: TmuxWindow) -> [AttachedRuntimeActionV2] {
        windows[window.windowID] = AttachedWindowRuntimeV2(window: window)
        var actions: [AttachedRuntimeActionV2] = [
            .upsertWindow(
                .init(
                    windowID: window.windowID,
                    title: window.name,
                    windowIndex: window.windowIndex,
                    isActive: window.isActive
                )
            )
        ]

        if let pendingLayout = pendingLayouts.removeValue(forKey: window.windowID) {
            actions.append(contentsOf: handleLayoutChanged(windowID: window.windowID, layout: pendingLayout))
        }

        return actions
    }

    mutating func handleWindowClosed(windowID: Int) -> [AttachedRuntimeActionV2] {
        guard let removedWindow = windows.removeValue(forKey: windowID) else { return [] }
        for paneID in removedWindow.paneIDs {
            paneToWindowID.removeValue(forKey: paneID)
        }
        pendingLayouts.removeValue(forKey: windowID)

        if windows.isEmpty {
            pendingPaneOutput.removeAll(keepingCapacity: false)
        }

        return [.removeWindow(windowID: windowID)]
    }

    mutating func handleLayoutChanged(windowID: Int, layout: String) -> [AttachedRuntimeActionV2] {
        guard var window = windows[windowID] else {
            pendingLayouts[windowID] = layout
            return []
        }

        for paneID in window.paneIDs {
            paneToWindowID.removeValue(forKey: paneID)
        }

        let paneIDs = window.applyLayout(layout)
        windows[windowID] = window
        for paneID in paneIDs {
            paneToWindowID[paneID] = windowID
        }

        var actions: [AttachedRuntimeActionV2] = [
            .applyLayout(windowID: windowID, layout: layout, paneIDs: paneIDs)
        ]

        for paneID in paneIDs {
            guard var paneRuntime = pendingPaneOutput.removeValue(forKey: paneID) else { continue }
            for data in paneRuntime.drainOutput() {
                actions.append(.deliverPaneOutput(windowID: windowID, paneID: paneID, data: data))
            }
        }

        return actions
    }

    mutating func handlePaneOutput(paneID: Int, data: Data) -> [AttachedRuntimeActionV2] {
        guard let windowID = paneToWindowID[paneID], windows[windowID] != nil else {
            var paneRuntime = pendingPaneOutput[paneID] ?? AttachedPaneRuntimeV2()
            paneRuntime.appendOutput(data)
            pendingPaneOutput[paneID] = paneRuntime
            return []
        }

        return [.deliverPaneOutput(windowID: windowID, paneID: paneID, data: data)]
    }
}
