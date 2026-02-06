import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        List(selection: $sessionManager.selectedSessionID) {
            ForEach(sessionManager.sessions) { session in
                SidebarRowView(session: session)
                    .tag(session.id)
                    .contextMenu {
                        Button("Close Tab") {
                            sessionManager.closeSession(id: session.id)
                        }
                    }
            }
            .onMove { source, destination in
                sessionManager.sessions.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NewSessionMenu()
            }
        }
    }
}
