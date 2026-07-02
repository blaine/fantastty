import SwiftUI
import WebKit
import GhosttyKit
import Combine

/// The kind of content a tab holds.
enum TabKind {
    case terminal
    case browser
}

/// A single tab within a Session. Can hold terminal splits or a browser view.
class TerminalTab: ObservableObject, Identifiable, Hashable {
    let id = UUID()
    let kind: TabKind
    let sessionType: SessionType

    /// The displayed title, updated by OSC title-set sequences or page title.
    @Published var title: String

    /// The root of the split tree for this tab. Nil for browser tabs.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView>?

    /// The currently focused surface in this tab. Nil for browser tabs.
    @Published var focusedSurface: Ghostty.SurfaceView?

    /// The current URL for browser tabs. Nil for terminal tabs.
    @Published var url: URL?

    @Published var browserLocationFocusRequestID = 0

    /// The WKWebView instance for browser tabs. Nil for terminal tabs.
    var webView: WKWebView?

    /// Tmux window ID this tab represents (for attached sessions).
    var tmuxWindowID: Int?

    /// Tmux window index this tab represents (for attached-session ordering).
    var tmuxWindowIndex: Int?

    /// For restored browser tabs: how many terminal tabs should precede this tab.
    /// Used by `terminalInsertIndex` to interleave terminal tabs around browser tabs.
    /// Reset to nil after restore is complete.
    var terminalTabsBefore: Int?

    /// Combine subscriptions for this tab. Cancelled automatically when the tab deallocates.
    var cancellables = Set<AnyCancellable>()

    /// Debounced thumbnail refreshes should subscribe to this instead of polling.
    let thumbnailRefreshes = PassthroughSubject<Void, Never>()

    /// Icon name for the tab bar.
    var iconName: String {
        switch kind {
        case .terminal: return sessionType.iconName
        case .browser: return "globe"
        }
    }

    /// Create a new terminal tab with a single surface.
    init(type: SessionType, surfaceView: Ghostty.SurfaceView) {
        self.kind = .terminal
        self.sessionType = type
        self.title = type.displayName
        self.surfaceTree = .init(root: .leaf(view: surfaceView), zoomed: nil)
        self.focusedSurface = surfaceView
    }

    /// Create a new terminal tab whose surfaces will be populated later.
    init(type: SessionType, title: String) {
        self.kind = .terminal
        self.sessionType = type
        self.title = title
        self.surfaceTree = nil
        self.focusedSurface = nil
    }

    /// Create a new browser tab.
    init(url: URL) {
        self.kind = .browser
        self.sessionType = .local
        self.title = url.host ?? url.absoluteString
        self.url = url
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
        return surfaceTree?.root?.node(view: surfaceView) != nil
    }

    func requestThumbnailRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.thumbnailRefreshes.send(())
        }
    }

    func requestBrowserLocationFocus() {
        guard kind == .browser else { return }
        browserLocationFocusRequestID += 1
    }
}
