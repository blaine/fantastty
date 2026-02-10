import SwiftUI
import GhosttyKit

/// Renders the selected session with its tab bar, notes panel, and terminal content.
struct SessionDetailView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject var sessionManager: SessionManager

    private var notesExpanded: Binding<Bool> {
        Binding(
            get: { sessionManager.notesExpanded },
            set: { sessionManager.notesExpanded = $0 }
        )
    }
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @State private var showThumbnails = true

    /// Binding for the editable toolbar title — reads session.title, writes session.name
    private var nameBinding: Binding<String> {
        Binding(
            get: { session.title },
            set: { session.name = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content area with optional thumbnail panel
            HStack(spacing: 0) {
                // Terminal content
                VStack(spacing: 0) {
                    // Show tab bar if there are multiple tabs
                    if session.tabs.count > 1 {
                        TabBarView(session: session)
                        Divider()
                    }

                    // Render the selected tab's content, or overview if none selected
                    if let tab = session.selectedTab {
                        TabContentView(tab: tab, session: session)
                            .id(tab.id) // Force recreation when tab changes
                    } else if !session.tabs.isEmpty {
                        WorkspaceOverviewView(session: session)
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
            .overlay(alignment: .top) {
                // Expanded notes content overlays the terminal
                if notesExpanded.wrappedValue {
                    SessionNotesPanel(session: session, isExpanded: notesExpanded)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EditableToolbarTitle(text: nameBinding)
                    .frame(minWidth: 100, maxWidth: 300)
                    .padding(.leading, 8)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Overview toggle
                if session.tabs.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if session.selectedTabID == nil {
                                // Exit overview — select first tab
                                session.selectedTabID = session.tabs.first?.id
                            } else {
                                session.selectedTabID = nil
                            }
                        }
                    } label: {
                        Image(systemName: session.selectedTabID == nil ? "square.grid.2x2.fill" : "square.grid.2x2")
                    }
                    .help(session.selectedTabID == nil ? "Exit overview" : "Show workspace overview")
                }

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

            }
        }
    }
}

/// Renders a single tab's split tree content.
struct TabContentView: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        switch tab.kind {
        case .terminal:
            if let tree = tab.surfaceTree {
                TerminalSplitTreeView(
                    tree: tree,
                    action: handleSplitOperation
                )
                .onAppear {
                    if let focused = tab.focusedSurface {
                        Ghostty.moveFocus(to: focused)
                    }
                }
            }

        case .browser:
            BrowserTabView(tab: tab)
        }
    }

    private func handleSplitOperation(_ operation: TerminalSplitOperation) {
        guard var tree = tab.surfaceTree else { return }

        switch operation {
        case .resize(let resize):
            guard let root = tree.root else { return }
            let newRoot = replaceNode(in: root, target: resize.node, with: resize.node.resizing(to: resize.ratio))
            tab.surfaceTree = SplitTree(root: newRoot, zoomed: tree.zoomed)

        case .drop(let drop):
            guard let sourceNode = tree.root?.node(view: drop.payload) else { return }
            guard let newRoot = tree.root?.remove(sourceNode) else { return }

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
