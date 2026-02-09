import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject private var metadataStore = SessionMetadataStore.shared
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @State private var expandedSessions: Set<UUID> = []
    @State private var workspaceToDelete: String?

    var body: some View {
        List(selection: $sessionManager.selectedSessionID) {
            ForEach(sessionManager.sessions) { session in
                if tabsInSidebar {
                    // Session row with manual disclosure chevron
                    HStack(spacing: 4) {
                        Button {
                            withAnimation {
                                if expandedSessions.contains(session.id) {
                                    expandedSessions.remove(session.id)
                                } else {
                                    expandedSessions.insert(session.id)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(expandedSessions.contains(session.id) ? 90 : 0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)

                        SidebarRowView(session: session)
                    }
                    .tag(session.id)
                    .simultaneousGesture(TapGesture().onEnded {
                        session.selectedTabID = nil
                    })

                    // Tab thumbnails (observed subview so tabs changes trigger re-render)
                    if expandedSessions.contains(session.id) {
                        SidebarTabThumbnails(session: session)
                    }
                } else {
                    SidebarRowView(session: session)
                        .tag(session.id)
                }
            }
            .onMove { source, destination in
                sessionManager.sessions.move(fromOffsets: source, toOffset: destination)
            }

            // Archived workspaces section
            if !metadataStore.archivedWorkspaces.isEmpty {
                Section("Archived") {
                    ForEach(metadataStore.archivedWorkspaces, id: \.workspaceID) { meta in
                        HStack {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading) {
                                Text(meta.name.isEmpty ? meta.workspaceID : meta.name)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                if let archivedAt = meta.archivedAt {
                                    Text(archivedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .contextMenu {
                            Button("Unarchive") {
                                sessionManager.unarchiveSession(workspaceID: meta.workspaceID)
                            }
                            Button("Delete Permanently", role: .destructive) {
                                workspaceToDelete = meta.workspaceID
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        .safeAreaInset(edge: .bottom) {
            Button {
                sessionManager.createSession()
            } label: {
                Label("New Workspace", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NewSessionMenu()
            }
        }
        .alert("Delete Workspace?", isPresented: Binding(
            get: { workspaceToDelete != nil },
            set: { if !$0 { workspaceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                workspaceToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let id = workspaceToDelete {
                    sessionManager.deleteArchivedWorkspace(workspaceID: id)
                }
                workspaceToDelete = nil
            }
        } message: {
            Text("This will permanently delete all metadata, notes, and URLs for this workspace. This cannot be undone.")
        }
    }
}

/// Subview that observes a session so ForEach(session.tabs) re-evaluates when tabs change.
private struct SidebarTabThumbnails: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ForEach(session.tabs) { tab in
            SidebarThumbnailView(
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
            .padding(.leading, 20)
        }
    }
}
