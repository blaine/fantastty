import SwiftUI
import GhosttyKit

/// Renders the selected session with its tab bar, notes panel, and terminal content.
struct SessionDetailView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject var sessionManager: SessionManager

    @State private var notesExpanded = false
    @State private var showNotesPopover = false
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @State private var showThumbnails = true

    var body: some View {
        VStack(spacing: 0) {
            // Notes panel (collapsible)
            SessionNotesPanel(session: session, isExpanded: $notesExpanded)
            Divider()

            // Main content area with optional thumbnail panel
            HStack(spacing: 0) {
                // Terminal content
                VStack(spacing: 0) {
                    // Show tab bar if there are multiple tabs
                    if session.tabs.count > 1 {
                        TabBarView(session: session)
                        Divider()
                    }

                    // Render the selected tab's content
                    if let tab = session.selectedTab {
                        TabContentView(tab: tab, session: session)
                            .id(tab.id) // Force recreation when tab changes
                    } else {
                        Text("No tab selected")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // Thumbnail panel (when multiple tabs, enabled, and not shown in sidebar)
                if session.tabs.count > 1 && showThumbnails && !tabsInSidebar {
                    Divider()
                    TabThumbnailPanel(session: session)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Thumbnail panel toggle (hidden when thumbnails shown in sidebar)
                if session.tabs.count > 1 && !tabsInSidebar {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showThumbnails.toggle()
                        }
                    } label: {
                        Image(systemName: showThumbnails ? "sidebar.right" : "sidebar.right")
                            .symbolVariant(showThumbnails ? .none : .slash)
                    }
                    .help(showThumbnails ? "Hide tab previews" : "Show tab previews")
                }

                // Notes button
                Button {
                    showNotesPopover = true
                } label: {
                    Image(systemName: "doc.text")
                }
                .help("Edit Notes")
                .popover(isPresented: $showNotesPopover) {
                    SessionNotesPopover(session: session)
                }

                // Attention toggle
                Button {
                    session.toggleAttention()
                } label: {
                    Image(systemName: session.needsAttention ? "bell.fill" : "bell")
                        .foregroundStyle(session.needsAttention ? .orange : .primary)
                }
                .help(session.needsAttention ? "Clear attention flag" : "Flag for attention")
            }
        }
        // Don't auto-clear attention - let user manually clear it via toggle button
        // This ensures the attention indicator is visible
    }
}

/// Renders a single tab's split tree content.
struct TabContentView: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        TerminalSplitTreeView(
            tree: tab.surfaceTree,
            action: handleSplitOperation
        )
        .onAppear {
            // Restore focus to the previously focused surface
            if let focused = tab.focusedSurface {
                Ghostty.moveFocus(to: focused)
            }
        }
    }

    private func handleSplitOperation(_ operation: TerminalSplitOperation) {
        switch operation {
        case .resize(let resize):
            // Update the split ratio on the target node
            guard let root = tab.surfaceTree.root else { return }
            let newRoot = replaceNode(in: root, target: resize.node, with: resize.node.resizing(to: resize.ratio))
            tab.surfaceTree = SplitTree(root: newRoot, zoomed: tab.surfaceTree.zoomed)

        case .drop(let drop):
            // Handle drag-and-drop reorder of split panes
            guard let sourceNode = tab.surfaceTree.root?.node(view: drop.payload) else { return }
            guard let newRoot = tab.surfaceTree.root?.remove(sourceNode) else { return }

            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
            case .top: .up
            case .bottom: .down
            case .left: .left
            case .right: .right
            }

            let tempTree = SplitTree<Ghostty.SurfaceView>(root: newRoot, zoomed: nil)
            if let result = try? tempTree.inserting(view: drop.payload, at: drop.destination, direction: direction) {
                tab.surfaceTree = result
            }
        }
    }

    /// Replace a specific node in the tree with a new node.
    private func replaceNode(
        in node: SplitTree<Ghostty.SurfaceView>.Node,
        target: SplitTree<Ghostty.SurfaceView>.Node,
        with replacement: SplitTree<Ghostty.SurfaceView>.Node
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        if node == target {
            return replacement
        }
        switch node {
        case .leaf:
            return node
        case .split(let split):
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: replaceNode(in: split.left, target: target, with: replacement),
                right: replaceNode(in: split.right, target: target, with: replacement)
            ))
        }
    }
}
