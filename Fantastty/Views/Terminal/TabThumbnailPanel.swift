import SwiftUI
import WebKit
import GhosttyKit
import AppKit

enum TerminalThumbnailRenderer {
    static func contentRect(for node: SplitTree<Ghostty.SurfaceView>.Node?) -> CGRect? {
        let frames = leafSurfaces(in: node).map(visibleFrame(of:))
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { partial, frame in
            partial.union(frame)
        }
    }

    static func thumbnailImage(
        for node: SplitTree<Ghostty.SurfaceView>.Node?,
        targetSize: NSSize? = nil
    ) -> NSImage? {
        let leaves = leafSurfaces(in: node)
        guard !leaves.isEmpty,
              let contentRect = contentRect(for: node),
              contentRect.width > 0,
              contentRect.height > 0 else {
            return nil
        }

        let image = NSImage(size: contentRect.size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: contentRect.size)).fill()

        for surface in leaves {
            guard let surfaceImage = surface.asImage else { continue }
            let frame = visibleFrame(of: surface)
            let drawRect = CGRect(
                x: frame.minX - contentRect.minX,
                y: frame.minY - contentRect.minY,
                width: frame.width,
                height: frame.height
            )
            surfaceImage.draw(in: drawRect)
        }

        image.unlockFocus()

        if let targetSize {
            return image.resized(toFit: targetSize)
        }
        return image
    }

    private static func leafSurfaces(
        in node: SplitTree<Ghostty.SurfaceView>.Node?
    ) -> [Ghostty.SurfaceView] {
        guard let node else { return [] }

        switch node {
        case .leaf(let view):
            return [view]
        case .split(let split):
            return leafSurfaces(in: split.left) + leafSurfaces(in: split.right)
        }
    }

    private static func visibleFrame(of surface: Ghostty.SurfaceView) -> CGRect {
        let bounds = surface.bounds.isEmpty
            ? CGRect(origin: .zero, size: surface.frame.size)
            : surface.bounds

        if surface.window != nil {
            return surface.convert(bounds, to: nil)
        }

        if let superview = surface.superview {
            return surface.convert(bounds, to: superview)
        }

        return surface.frame.isEmpty ? bounds : surface.frame
    }
}

private struct ThumbnailPanelScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A panel showing live thumbnails of non-focused tabs in the current session.
struct TabThumbnailPanel: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    /// Width of the thumbnail panel
    static let panelWidth: CGFloat = 160
    static let thumbnailRenderSize = NSSize(width: 144, height: 90)

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
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ThumbnailPanelScrollOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("thumbnailPanelScroll")).minY
                        )
                    }
                }
            }
            .coordinateSpace(name: "thumbnailPanelScroll")
            .onPreferenceChange(ThumbnailPanelScrollOffsetPreferenceKey.self) { _ in
                sessionManager.noteThumbnailScrollActivity()
            }
        }
        .frame(width: Self.panelWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// A single tab thumbnail with live preview.
struct TabThumbnailView: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject var sessionManager: SessionManager
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

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
            guard !sessionManager.areThumbnailRefreshesSuspended else { return }
            updateThumbnail()
        }
        .onChange(of: sessionManager.areThumbnailRefreshesSuspended) { _, isSuspended in
            guard !isSuspended else { return }
            updateThumbnail()
        }
        .onReceive(tab.thumbnailRefreshes.debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in
            guard !sessionManager.areThumbnailRefreshesSuspended else { return }
            updateThumbnail()
        }
    }

    private func updateThumbnail() {
        switch tab.kind {
        case .terminal:
            guard let image = TerminalThumbnailRenderer.thumbnailImage(
                for: tab.surfaceTree?.root,
                targetSize: TabThumbnailPanel.thumbnailRenderSize
            ) else {
                return
            }
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        case .browser:
            guard let webView = tab.webView else { return }
            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { image, _ in
                if let image = image {
                    self.thumbnail = image
                }
            }
        }
    }

}
