import SwiftUI
import WebKit
import GhosttyKit

/// A tab thumbnail for the sidebar that uses TimelineView for live updates.
/// (TabThumbnailView uses Timer.publish which doesn't fire reliably in List rows.)
struct SidebarThumbnailView: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var browserSnapshot: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                // TimelineView drives periodic re-capture of the thumbnail
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    thumbnailImage
                        .onAppear { captureBrowserSnapshot() }
                        .onChange(of: context.date) { captureBrowserSnapshot() }
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
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        switch tab.kind {
        case .terminal:
            if let surface = firstSurface(in: tab.surfaceTree?.root),
               let image = surface.asImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .cornerRadius(4)
            } else {
                terminalPlaceholder
            }
        case .browser:
            if let snapshot = browserSnapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(4)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .aspectRatio(16/10, contentMode: .fit)
                    .cornerRadius(4)
                    .overlay {
                        Image(systemName: "globe")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var terminalPlaceholder: some View {
        Rectangle()
            .fill(Color.black.opacity(0.3))
            .aspectRatio(16/10, contentMode: .fit)
            .cornerRadius(4)
            .overlay {
                ProgressView()
                    .scaleEffect(0.5)
            }
    }

    private func captureBrowserSnapshot() {
        guard tab.kind == .browser, let webView = tab.webView else { return }
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, _ in
            if let image = image {
                self.browserSnapshot = image
            }
        }
    }

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
