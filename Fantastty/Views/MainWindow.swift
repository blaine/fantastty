import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var ghosttyApp: Ghostty.App

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let selectedID = sessionManager.selectedSessionID,
               let session = sessionManager.sessions.first(where: { $0.id == selectedID }) {
                SessionDetailView(session: session)
                    .id(session.id) // Force recreation on tab switch
            } else {
                Text("No session selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(windowTitle)
        .sheet(isPresented: $sessionManager.showSSHSheet) {
            SSHConnectionSheet()
        }
    }

    private var windowTitle: String {
        if let selectedID = sessionManager.selectedSessionID,
           let session = sessionManager.sessions.first(where: { $0.id == selectedID }) {
            return session.title
        }
        return "Fantastty"
    }
}
