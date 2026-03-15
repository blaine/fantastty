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

        // Count how many terminal tabs already exist with a lower windowIndex
        // to determine this window's ordinal position among terminals.
        let terminalOrdinal = tabs.filter {
            $0.kind == .terminal && ($0.tmuxWindowIndex ?? Int.max) < incomingIndex
        }.count

        for (index, tab) in tabs.enumerated() {
            if tab.kind == .terminal {
                let existingIndex = tab.tmuxWindowIndex ?? Int.max
                if existingIndex > incomingIndex {
                    return index
                }
            } else if let before = tab.terminalTabsBefore, before > terminalOrdinal {
                // This browser tab expects more terminal tabs before it than
                // we've placed so far — insert the terminal tab here.
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
