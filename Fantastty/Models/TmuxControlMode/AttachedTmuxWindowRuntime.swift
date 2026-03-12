import Foundation
import GhosttyKit

struct AttachedTmuxLayoutBuildResult {
    let root: SplitTree<Ghostty.SurfaceView>.Node
    let paneIDs: Set<Int>
}

enum AttachedTmuxWindowRuntime {
    static func terminalInsertIndex(for window: TmuxWindow, tabs: [TerminalTab]) -> Int {
        guard let incomingIndex = window.windowIndex else {
            return tabs.endIndex
        }

        for (index, tab) in tabs.enumerated() where tab.kind == .terminal {
            let existingIndex = tab.tmuxWindowIndex ?? Int.max
            if existingIndex > incomingIndex {
                return index
            }
        }

        return tabs.endIndex
    }

    static func surface(forPaneID paneID: Int, tabs: [TerminalTab]) -> Ghostty.SurfaceView? {
        for tab in tabs {
            guard let leaves = tab.surfaceTree?.root?.leaves() else { continue }
            for surface in leaves where surface.tmuxPaneID == paneID {
                return surface
            }
        }
        return nil
    }

    static func buildLayoutTree(
        layout: String,
        existingTree: SplitTree<Ghostty.SurfaceView>?,
        makeSurface: (Int) -> Ghostty.SurfaceView
    ) -> AttachedTmuxLayoutBuildResult {
        let layoutNode = TmuxLayoutParser.parse(layout)

        var existingSurfaces: [Int: Ghostty.SurfaceView] = [:]
        if let leaves = existingTree?.root?.leaves() {
            for surface in leaves {
                if let pid = surface.tmuxPaneID {
                    existingSurfaces[pid] = surface
                }
            }
        }

        let rootNode = TmuxLayoutMapper.mapToSplitTree(layoutNode) { paneID -> Ghostty.SurfaceView in
            if let existing = existingSurfaces[paneID] {
                return existing
            }
            return makeSurface(paneID)
        }

        return AttachedTmuxLayoutBuildResult(
            root: rootNode,
            paneIDs: Set(layoutNode.allPaneIDs())
        )
    }
}
