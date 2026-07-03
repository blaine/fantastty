import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject private var metadataStore = SessionMetadataStore.shared
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @AppStorage("showArchivedSessions") private var showArchived = false
    @AppStorage("showTrashedSessions") private var showTrashed = false
    @State private var expandedSessions: Set<UUID> = []
    @State private var workspaceToDelete: String?
    @State private var deletingTrashedWorkspace = false
    @State private var confirmingEmptyTrash = false

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

            // Archived workspaces section (hidden by default)
            if showArchived && !metadataStore.archivedWorkspaces.isEmpty {
                Section("Archived") {
                    ForEach(metadataStore.archivedWorkspaces, id: \.workspaceID) { meta in
                        HStack {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(meta.name.isEmpty ? meta.workspaceID : meta.name)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contextMenu {
                            Button("Unarchive") {
                                sessionManager.unarchiveSession(workspaceID: meta.workspaceID)
                            }
                            Button("Delete Permanently", role: .destructive) {
                                deletingTrashedWorkspace = false
                                workspaceToDelete = meta.workspaceID
                            }
                        }
                    }
                }
            }

            if showTrashed && !metadataStore.trashedWorkspaces.isEmpty {
                Section("Trashed") {
                    ForEach(metadataStore.trashedWorkspaces, id: \.workspaceID) { meta in
                        HStack {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(meta.name.isEmpty ? meta.workspaceID : meta.name)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contextMenu {
                            Button("Restore") {
                                sessionManager.restoreTrashedWorkspace(workspaceID: meta.workspaceID)
                            }
                            Button("Delete Permanently", role: .destructive) {
                                deletingTrashedWorkspace = true
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
            VStack(spacing: 0) {
                if !metadataStore.archivedWorkspaces.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showArchived.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "archivebox")
                            Text("Archived (\(metadataStore.archivedWorkspaces.count))")
                            Spacer()
                            Image(systemName: showArchived ? "eye" : "eye.slash")
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                if !metadataStore.trashedWorkspaces.isEmpty {
                    HStack(spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showTrashed.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("Trashed (\(metadataStore.trashedWorkspaces.count))")
                                Spacer()
                                Image(systemName: showTrashed ? "eye" : "eye.slash")
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            confirmingEmptyTrash = true
                        } label: {
                            Image(systemName: "trash.slash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Empty Trash")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                Menu {
                    Button("New Workspace...") {
                        sessionManager.showSessionLauncher(.local())
                    }
                } label: {
                    Label("New Workspace", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(.regularMaterial)
        }
        .alert("Delete Workspace?", isPresented: Binding(
            get: { workspaceToDelete != nil },
            set: {
                if !$0 {
                    workspaceToDelete = nil
                    deletingTrashedWorkspace = false
                }
            }
        )) {
            Button("Cancel", role: .cancel) {
                workspaceToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let id = workspaceToDelete {
                    if deletingTrashedWorkspace {
                        sessionManager.deleteTrashedWorkspace(workspaceID: id)
                    } else {
                        sessionManager.deleteArchivedWorkspace(workspaceID: id)
                    }
                }
                workspaceToDelete = nil
                deletingTrashedWorkspace = false
            }
        } message: {
            Text("This will permanently delete all metadata, notes, and URLs for this workspace. This cannot be undone.")
        }
        .alert("Empty Trash?", isPresented: $confirmingEmptyTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) {
                sessionManager.emptyTrash()
            }
        } message: {
            Text("This will permanently delete all \(metadataStore.trashedWorkspaces.count) trashed workspace(s). This cannot be undone.")
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
                isSessionActive: session.id == sessionManager.selectedSessionID,
                onSelect: {
                    sessionManager.selectTab(tab, in: session)
                },
                onClose: {
                    let shouldClose = session.closeTab(id: tab.id)
                    if shouldClose {
                        sessionManager.closeSession(id: session.id)
                    }
                }
            )
            .onDrag {
                SessionTabDropDelegate.itemProvider(for: tab)
            }
            .onDrop(
                of: SessionTabDropDelegate.supportedTypes,
                delegate: SessionTabDropDelegate(
                    session: session,
                    targetTabID: tab.id,
                    sessionManager: sessionManager
                )
            )
            .padding(.leading, 20)
        }

        Color.clear
            .frame(height: 20)
            .contentShape(Rectangle())
            .onDrop(
                of: SessionTabDropDelegate.supportedTypes,
                delegate: SessionTabDropDelegate(
                    session: session,
                    targetTabID: nil,
                    sessionManager: sessionManager
                )
            )
    }
}
