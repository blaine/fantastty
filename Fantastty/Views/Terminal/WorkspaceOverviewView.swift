import SwiftUI
import WebKit
import GhosttyKit

/// Exposé-style grid overview of all tabs in a workspace.
struct WorkspaceOverviewView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    private var columnCount: Int {
        let count = session.tabs.count
        if count <= 2 { return count }
        if count <= 4 { return 2 }
        if count <= 9 { return 3 }
        return 4
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)

        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(session.tabs) { tab in
                    OverviewTileView(tab: tab) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            session.selectedTabID = tab.id
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }
}

/// A single tile in the workspace overview grid.
struct OverviewTileView: View {
    @ObservedObject var tab: TerminalTab
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var snapshot: NSImage?

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let snapshot = snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4)
                        .overlay {
                            Image(systemName: tab.iconName)
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipped()
            .cornerRadius(8)
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)

            // Label
            HStack(spacing: 6) {
                Image(systemName: tab.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .onAppear { captureSnapshot() }
        .onReceive(timer) { _ in captureSnapshot() }
    }

    private func captureSnapshot() {
        switch tab.kind {
        case .terminal:
            guard let surface = firstSurface(in: tab.surfaceTree?.root),
                  let image = surface.asImage else { return }
            snapshot = image
        case .browser:
            guard let webView = tab.webView else { return }
            webView.takeSnapshot(with: nil) { image, _ in
                if let image = image { snapshot = image }
            }
        }
    }

    private func firstSurface(in node: SplitTree<Ghostty.SurfaceView>.Node?) -> Ghostty.SurfaceView? {
        guard let node = node else { return nil }
        switch node {
        case .leaf(let view): return view
        case .split(let split): return firstSurface(in: split.left)
        }
    }
}
