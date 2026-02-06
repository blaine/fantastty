import SwiftUI

struct SidebarRowView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editingName = ""

    /// The primary session type (from the first tab) for display purposes
    private var primarySessionType: SessionType {
        session.tabs.first?.sessionType ?? .local
    }

    var body: some View {
        HStack(spacing: 8) {
            // Attention indicator
            if session.needsAttention {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
            }

            // Session type icon
            Image(systemName: primarySessionType.iconName)
                .foregroundStyle(session.needsAttention ? .orange : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isEditing {
                        TextField("Workspace name", text: $editingName, onCommit: {
                            session.name = editingName
                            isEditing = false
                        })
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .onExitCommand {
                            isEditing = false
                        }
                    } else {
                        Text(session.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fontWeight(session.needsAttention ? .semibold : .regular)
                            .onTapGesture {
                                editingName = session.name
                                isEditing = true
                            }
                    }

                    // Show tab count if multiple tabs (hidden when tabs shown in sidebar)
                    if session.tabs.count > 1 && !tabsInSidebar {
                        Text("(\(session.tabs.count))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Show SSH host info as subtitle
                if case .ssh(let host, let user, _) = primarySessionType {
                    Text(user.map { "\($0)@\(host)" } ?? host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action buttons on hover
            if isHovering {
                HStack(spacing: 4) {
                    // Toggle attention
                    Button {
                        session.toggleAttention()
                    } label: {
                        Image(systemName: session.needsAttention ? "bell.fill" : "bell")
                            .font(.caption2)
                            .foregroundStyle(session.needsAttention ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(session.needsAttention ? "Clear attention" : "Flag for attention")

                    // Close button
                    Button {
                        sessionManager.closeSession(id: session.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close workspace")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Rename...") {
                editingName = session.name
                isEditing = true
            }

            Button("Edit Notes...") {
                // Will be handled by a sheet
            }

            Divider()

            Button(session.needsAttention ? "Clear Attention Flag" : "Flag for Attention") {
                session.toggleAttention()
            }

            Divider()

            Button("Close Workspace") {
                sessionManager.closeSession(id: session.id)
            }
        }
    }
}
