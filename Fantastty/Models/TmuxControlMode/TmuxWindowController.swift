import Foundation
import GhosttyKit

final class TmuxWindowController {
    typealias SurfaceFactory = (Int) -> Ghostty.SurfaceView
    typealias PaneInjectorFactory = (Int) -> TmuxPaneController.Injector

    let windowID: Int
    let tab: TerminalTab

    private let surfaceFactory: SurfaceFactory
    private let paneInjectorFactory: PaneInjectorFactory?
    private(set) var paneControllers: [Int: TmuxPaneController] = [:]
    private var pendingOutput: [Int: [Data]] = [:]

    init(
        windowID: Int,
        title: String,
        windowIndex: Int,
        surfaceFactory: @escaping SurfaceFactory,
        paneInjectorFactory: PaneInjectorFactory? = nil
    ) {
        self.windowID = windowID
        self.surfaceFactory = surfaceFactory
        self.paneInjectorFactory = paneInjectorFactory

        self.tab = TerminalTab(type: .local, title: title)
        self.tab.tmuxWindowID = windowID
        self.tab.tmuxWindowIndex = windowIndex
    }

    func applyLayout(_ layout: String) {
        let buildResult = AttachedTmuxWindowRuntime.buildLayoutTree(
            layout: layout,
            existingTree: tab.surfaceTree
        ) { [surfaceFactory] paneID in
            surfaceFactory(paneID)
        }

        let newPaneIDs = buildResult.paneIDs

        // Remove controllers for panes no longer in layout
        for (paneID, controller) in paneControllers where !newPaneIDs.contains(paneID) {
            controller.teardown()
            paneControllers.removeValue(forKey: paneID)
        }

        // Add controllers for new panes
        for paneID in newPaneIDs where paneControllers[paneID] == nil {
            let injector = paneInjectorFactory?(paneID)
            let controller = TmuxPaneController(paneID: paneID, injector: injector)
            paneControllers[paneID] = controller

            // Flush any pending output for this pane
            if let pending = pendingOutput.removeValue(forKey: paneID) {
                for data in pending {
                    controller.deliver(data)
                }
            }
        }

        tab.surfaceTree = SplitTree(root: buildResult.root, zoomed: nil)

        // Set initial focus
        let leaves = tab.surfaceTree?.root?.leaves() ?? []
        if let focused = tab.focusedSurface, !leaves.contains(where: { $0 === focused }) {
            tab.focusedSurface = leaves.first
        } else if tab.focusedSurface == nil {
            tab.focusedSurface = leaves.first
        }
    }

    func deliverOutput(paneID: Int, data: Data) {
        if let controller = paneControllers[paneID] {
            controller.deliver(data)
        } else {
            pendingOutput[paneID, default: []].append(data)
        }
    }

    func setActivePane(_ paneID: Int) {
        guard let surface = tab.surfaceTree?.root?.leaves().first(where: { $0.tmuxPaneID == paneID }) else {
            return
        }
        tab.focusedSurface = surface
    }

    func teardown() {
        for (_, controller) in paneControllers {
            controller.teardown()
        }
        paneControllers.removeAll()
        pendingOutput.removeAll()
    }
}
