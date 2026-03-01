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
            Section("Integrations") {
                LinearAPIKeyRow()
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize()
    }
}

// MARK: - LinearAPIKeyRow

private struct LinearAPIKeyRow: View {
    @ObservedObject private var service = LinearService.shared
    @State private var draft = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Personal API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button(saved ? "Saved ✓" : "Save") { save() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if service.apiKey != nil {
                    Button("Clear") {
                        service.setAPIKey("")
                        draft = ""
                    }
                    .foregroundStyle(.red)
                }
            }
            Text("Get your key: Linear → Settings → Account → API. Stored in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            draft = service.loadAPIKey() ?? ""
        }
    }

    private func save() {
        service.setAPIKey(draft)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
