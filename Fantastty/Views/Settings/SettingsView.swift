import SwiftUI

struct SettingsView: View {
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false
    @AppStorage("persistentSessions") private var persistentSessions = false

    private var tmuxAvailable: Bool {
        TmuxManager.shared.isTmuxAvailable
    }

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show tab thumbnails in sidebar", isOn: $tabsInSidebar)
            }

            Section {
                Toggle("Persistent terminal sessions", isOn: $persistentSessions)
                    .disabled(!tmuxAvailable)

                if persistentSessions && tmuxAvailable {
                    Text("Terminals run inside tmux. Sessions survive app restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !tmuxAvailable {
                    Text("tmux not found. Install via Homebrew: brew install tmux")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Sessions")
            } footer: {
                if tmuxAvailable {
                    Text("When enabled, each workspace runs in a tmux session. Quitting the app leaves sessions running; relaunching reattaches to them.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize()
    }
}
