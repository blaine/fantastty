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

            Button("New Sprite Workspace...") {
                sessionManager.showSpriteSheet = true
            }

            Divider()

            Button("Attach to tmux Session...") {
                sessionManager.showTmuxAttachSheet = true
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
