import SwiftUI

struct NewSessionMenu: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Menu {
            Button("New Workspace") {
                sessionManager.createSession()
            }

            Button("New SSH Workspace...") {
                sessionManager.showSSHSheet = true
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
