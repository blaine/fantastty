import SwiftUI

struct NewSessionMenu: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Menu {
            Button("New Workspace...") {
                sessionManager.showSessionLauncher(.local())
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
