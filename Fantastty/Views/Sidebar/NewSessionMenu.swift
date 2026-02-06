import SwiftUI

struct NewSessionMenu: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Menu {
            Button("New Local Tab") {
                sessionManager.createSession()
            }

            Button("New Browser Tab") {
                sessionManager.createBrowserTab()
            }

            Button("New SSH Session...") {
                sessionManager.showSSHSheet = true
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
