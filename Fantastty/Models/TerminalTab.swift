import SwiftUI
import GhosttyKit

/// A single terminal tab within a Session. Can contain split panes.
class TerminalTab: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    let sessionType: SessionType

    /// The displayed title, updated by OSC title-set sequences.
    @Published var title: String

    /// The root of the split tree for this tab. Contains one or more SurfaceViews.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// The currently focused surface in this tab.
    @Published var focusedSurface: Ghostty.SurfaceView?

    /// Create a new tab with a single surface.
    init(type: SessionType, surfaceView: Ghostty.SurfaceView) {
        self.sessionType = type
        self.title = type.displayName
        self.surfaceTree = .init(root: .leaf(view: surfaceView), zoomed: nil)
        self.focusedSurface = surfaceView
    }

    // MARK: - Hashable

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Surface Lookup

    /// Check if this tab contains the given surface view.
    func contains(surfaceView: Ghostty.SurfaceView) -> Bool {
        return surfaceTree.root?.node(view: surfaceView) != nil
    }
}
