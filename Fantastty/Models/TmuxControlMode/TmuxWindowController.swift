import Combine
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
    private var currentPaneIDs: Set<Int> = []
    private var surfaceSizeSubscriptions: [Int: AnyCancellable] = [:]  // keyed by paneID
    private var panesWithReportedSize: Set<Int> = []
    private var bootstrapCompleted: Bool = false
    var onBootstrapReady: (() -> Void)?

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
        // Only rebuild for structural changes (panes added/removed).
        // Non-structural layout changes (tmux responding to our resize-pane
        // or refresh-client) are ignored since per-surface subscribers
        // handle sizing.
        let newPaneIDs = Set(TmuxLayoutParser.parse(layout).allPaneIDs())
        if newPaneIDs == currentPaneIDs, !currentPaneIDs.isEmpty {
            return
        }
        currentPaneIDs = newPaneIDs

        let buildResult = AttachedTmuxWindowRuntime.buildLayoutTree(
            layout: layout,
            existingTree: tab.surfaceTree
        ) { [surfaceFactory] paneID in
            surfaceFactory(paneID)
        }

        // Remove controllers for panes no longer in layout
        for (paneID, controller) in paneControllers where !newPaneIDs.contains(paneID) {
            controller.teardown()
            paneControllers.removeValue(forKey: paneID)
            surfaceSizeSubscriptions.removeValue(forKey: paneID)
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

        // Subscribe to size changes for newly added panes
        for paneID in newPaneIDs where surfaceSizeSubscriptions[paneID] == nil {
            if let surface = tab.surfaceTree?.root?.leaves().first(where: { $0.tmuxPaneID == paneID }) {
                subscribeSurfaceSize(paneID: paneID, surface: surface)
            }
        }

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

    /// Subscribes to a surface's grid size changes and sends resize-pane to tmux.
    private func subscribeSurfaceSize(paneID: Int, surface: Ghostty.SurfaceView) {
        surfaceSizeSubscriptions[paneID] = surface.$surfaceSize
            .compactMap { $0 }  // skip nil (surface hasn't rendered yet)
            .removeDuplicates { $0.columns == $1.columns && $0.rows == $1.rows }
            .handleEvents(receiveOutput: { [weak self] _ in
                // Track immediately (before debounce) for bootstrap readiness
                if self?.panesWithReportedSize.insert(paneID).inserted == true {
                    self?.checkBootstrapReadiness()
                }
            })
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak surface] size in
                guard let client = surface?.tmuxControlClient else { return }
                let cols = Int(size.columns)
                let rows = Int(size.rows)
                guard cols > 0, rows > 0 else { return }
                TmuxSizingLog.write("resize-pane %\(paneID): \(cols)x\(rows) (cell=\(size.cell_width_px)x\(size.cell_height_px) screen=\(size.width_px)x\(size.height_px))")
                Task { await client.resizePane(paneID: paneID, columns: cols, rows: rows) }
            }
    }

    private func checkBootstrapReadiness() {
        guard !bootstrapCompleted else { return }
        let allPaneIDs = Set(paneControllers.keys)
        guard !allPaneIDs.isEmpty, panesWithReportedSize.isSuperset(of: allPaneIDs) else { return }
        bootstrapCompleted = true
        onBootstrapReady?()
    }

    func teardown() {
        surfaceSizeSubscriptions.removeAll()
        for (_, controller) in paneControllers {
            controller.teardown()
        }
        paneControllers.removeAll()
        pendingOutput.removeAll()
    }
}
