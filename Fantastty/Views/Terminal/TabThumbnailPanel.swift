import SwiftUI
import GhosttyKit

/// A panel showing live thumbnails of non-focused tabs in the current session.
struct TabThumbnailPanel: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    /// Width of the thumbnail panel
    static let panelWidth: CGFloat = 160

    /// Refresh interval for thumbnails
    static let refreshInterval: TimeInterval = 0.5

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tabs")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(session.tabs.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Thumbnail list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(session.tabs) { tab in
                        TabThumbnailView(
                            tab: tab,
                            isSelected: tab.id == session.selectedTabID,
                            onSelect: {
                                session.selectedTabID = tab.id
                            },
                            onClose: {
                                let shouldClose = session.closeTab(id: tab.id)
                                if shouldClose {
                                    sessionManager.closeSession(id: session.id)
                                }
                            }
                        )
                    }
                }
                .padding(8)
            }
        }
        .frame(width: Self.panelWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// A single tab thumbnail with live preview.
struct TabThumbnailView: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    /// Timer for refreshing the thumbnail
    private let timer = Timer.publish(
        every: TabThumbnailPanel.refreshInterval,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Thumbnail image
            ZStack {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .cornerRadius(4)
                } else {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .aspectRatio(16/10, contentMode: .fit)
                        .cornerRadius(4)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                }

                // Hover overlay with close button
                if isHovered && !isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
                        Spacer()
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onTapGesture {
                onSelect()
            }

            // Tab title
            Text(tab.title)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color.clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            updateThumbnail()
        }
        .onReceive(timer) { _ in
            // Only update if not selected (selected tab is visible anyway)
            if !isSelected {
                updateThumbnail()
            }
        }
    }

    private func updateThumbnail() {
        // Get the first surface from the tab's split tree
        guard let surface = firstSurface(in: tab.surfaceTree.root) else { return }

        // Capture snapshot on main thread
        DispatchQueue.main.async {
            if let image = surface.asImage {
                self.thumbnail = image
            }
        }
    }

    /// Get the first leaf surface from a split tree node.
    private func firstSurface(in node: SplitTree<Ghostty.SurfaceView>.Node?) -> Ghostty.SurfaceView? {
        guard let node = node else { return nil }
        switch node {
        case .leaf(let view):
            return view
        case .split(let split):
            return firstSurface(in: split.left)
        }
    }
}
