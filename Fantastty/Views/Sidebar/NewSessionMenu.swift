import SwiftUI

struct NewSessionMenu: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Menu {
            Button("New Workspace...") {
                sessionManager.showSessionLauncher(.local())
            }

            Button("New Local Workspace") {
                sessionManager.createSession()
            }

            Button("New SSH Workspace...") {
                sessionManager.showSessionLauncher(.ssh())
            }

            Button("New Sprite Workspace...") {
                sessionManager.showSessionLauncher(.sprite())
            }

            Divider()

            Button("Attach to tmux Session...") {
                sessionManager.showSessionLauncher(.local(focus: .existingSessions))
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
