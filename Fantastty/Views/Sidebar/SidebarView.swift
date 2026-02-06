import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @State private var expandedSessions: Set<UUID> = []

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
                    .contextMenu {
                        Button("Show Overview") {
                            sessionManager.selectedSessionID = session.id
                            session.selectedTabID = nil
                        }
                        Button("Close Workspace") {
                            sessionManager.closeSession(id: session.id)
                        }
                    }

                    // Tab thumbnails (observed subview so tabs changes trigger re-render)
                    if expandedSessions.contains(session.id) {
                        SidebarTabThumbnails(session: session)
                    }
                } else {
                    SidebarRowView(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Show Overview") {
                                sessionManager.selectedSessionID = session.id
                                session.selectedTabID = nil
                            }
                            Button("Close Workspace") {
                                sessionManager.closeSession(id: session.id)
                            }
                        }
                }
            }
            .onMove { source, destination in
                sessionManager.sessions.move(fromOffsets: source, toOffset: destination)
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
