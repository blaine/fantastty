import SwiftUI

/// Tab bar displayed at the top of the detail view, showing tabs within a session.
struct TabBarView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        isSelected: tab.id == session.selectedTabID,
                        onSelect: {
                            session.selectedTabID = tab.id
                        },
                        onClose: {
                            sessionManager.closeTab(id: tab.id)
                        }
                    )
                }

                // New tab menu
                Menu {
                    Button("New Tab") {
                        sessionManager.createTab()
                    }
                    Button("New Browser Tab") {
                        sessionManager.createBrowserTab()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Tab")

                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Individual tab item in the tab bar.
struct TabItemView: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Tab icon
            Image(systemName: tab.iconName)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .primary : .secondary)

            // Tab title
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)

            // Close button (visible on hover or if selected)
            if isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
