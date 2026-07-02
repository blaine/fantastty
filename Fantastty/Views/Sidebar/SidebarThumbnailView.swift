import SwiftUI
import WebKit
import GhosttyKit

/// A tab thumbnail for the sidebar that uses TimelineView for live updates.
/// (TabThumbnailView uses Timer.publish which doesn't fire reliably in List rows.)
struct SidebarThumbnailView: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject var sessionManager: SessionManager
    let isSelected: Bool
    let isSessionActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @StateObject private var snapshotStore = ThumbnailSnapshotStore()

    /// A tab reads as selected in the sidebar only while its session is the active one.
    /// Each session remembers its own selected tab, so without this an inactive session
    /// would keep highlighting the tab you last left it on.
    private var isActiveSelection: Bool { isSelected && isSessionActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                thumbnailImage

                // Hover overlay with close button
                if isHovered && !isActiveSelection {
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
                    .stroke(isActiveSelection ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onTapGesture {
                onSelect()
            }

            // Tab title
            Text(tab.title)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActiveSelection ? .primary : .secondary)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveSelection ? Color.accentColor.opacity(0.15) : (isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color.clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            guard !sessionManager.areThumbnailRefreshesSuspended else { return }
            updateThumbnail()
        }
        .onChange(of: sessionManager.areThumbnailRefreshesSuspended) { _, isSuspended in
            guard !isSuspended else { return }
            updateThumbnail()
        }
        .onReceive(tab.thumbnailRefreshes.debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in
            guard isSessionActive && !sessionManager.areThumbnailRefreshesSuspended else { return }
            updateThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        switch tab.kind {
        case .terminal:
            if let image = snapshotStore.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .cornerRadius(4)
            } else {
                placeholder
            }
        case .browser:
            if let snapshot = snapshotStore.image {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(4)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ThumbnailPlaceholderView(
            style: ThumbnailPlaceholderStyle.forTab(tab),
            cornerRadius: 4,
            symbolFont: .title2
        )
    }

    private func updateThumbnail() {
        snapshotStore.refresh(tab: tab, targetSize: TabThumbnailPanel.thumbnailRenderSize)
    }

}
