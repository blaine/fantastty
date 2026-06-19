import SwiftUI
import GhosttyKit

/// The pages of the settings window, shown in the sidebar.
private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case sidebar
    case sessions
    case integrations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .sidebar: return "Sidebar"
        case .sessions: return "Sessions"
        case .integrations: return "Integrations"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .sidebar: return "sidebar.left"
        case .sessions: return "terminal"
        case .integrations: return "puzzlepiece.extension"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsPage? = .appearance

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.icon).tag(page)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle((selection ?? .appearance).title)
        }
        .frame(width: 760, height: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .appearance {
        case .appearance: AppearancePage()
        case .sidebar: SidebarPage()
        case .sessions: SessionsPage()
        case .integrations: IntegrationsPage()
        }
    }
}

// MARK: - Pages

private struct AppearancePage: View {
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearance: AppearanceMode = .system
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) {
                    AppearanceMode.applyCurrent()
                    let scheme: ghostty_color_scheme_e = AppearanceMode.current.isDark
                        ? GHOSTTY_COLOR_SCHEME_DARK
                        : GHOSTTY_COLOR_SCHEME_LIGHT
                    if let app = ghosttyApp.app {
                        ghostty_app_set_color_scheme(app, scheme)
                    }
                }
            }

            AppearanceFontSection()
            AppearanceThemeSection()
        }
        .formStyle(.grouped)
    }
}

private struct SidebarPage: View {
    @AppStorage("tabsInSidebar") private var tabsInSidebar = false

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show tab thumbnails in sidebar", isOn: $tabsInSidebar)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SessionsPage: View {
    @AppStorage("persistentSessions") private var persistentSessions = false

    private var tmuxAvailable: Bool {
        TmuxManager.shared.isTmuxAvailable
    }

    var body: some View {
        Form {
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
    }
}

private struct IntegrationsPage: View {
    var body: some View {
        Form {
            Section("Integrations") {
                LinearAPIKeyRow()
            }
        }
        .formStyle(.grouped)
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
