import SwiftUI

struct SessionLauncherSheet: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var spriteManager = SpriteManager.shared

    let request: SessionLauncherRequest

    @State private var location: SessionLauncherLocation
    @State private var sshDraft = SessionLauncherConnectionDraft()
    @State private var spriteName = ""
    @State private var filter = ""
    @State private var discoveredSessions: [SessionLauncherDiscoveredSession] = []
    @State private var selectedRowID: String? = "new-session"
    @State private var isDiscovering = false
    @State private var isCreatingSprite = false
    @State private var discoveryError: String?
    @State private var discoveryTask: Task<Void, Never>?

    init(request: SessionLauncherRequest) {
        self.request = request
        _location = State(initialValue: request.location)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                locationRail
                Divider()
                detailPane
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, idealWidth: 760, maxWidth: .infinity, minHeight: 440, idealHeight: 480, maxHeight: .infinity)
        .onAppear {
            selectedRowID = request.focus == .existingSessions ? firstExistingRowID ?? "new-session" : "new-session"
            refreshDiscovery()
        }
        .onDisappear {
            discoveryTask?.cancel()
        }
        .onChange(of: location) {
            filter = ""
            selectedRowID = "new-session"
            discoveryError = nil
            refreshDiscovery()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Workspace")
                    .font(.headline)
                Text("Choose where the session lives, then choose what to open there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var locationRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            ForEach(SessionLauncherLocation.allCases) { item in
                Button {
                    location = item
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                        Text(item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(location == item ? .white.opacity(0.8) : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(location == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(location == item ? .white : .primary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(14)
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionSection
                sessionSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch location {
        case .local:
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac")
                    .font(.title3.weight(.semibold))
                Text("No connection details are required.")
                    .foregroundStyle(.secondary)
            }
        case .ssh:
            VStack(alignment: .leading, spacing: 10) {
                Text("SSH host")
                    .font(.title3.weight(.semibold))
                HStack {
                    TextField("Host or SSH config alias", text: $sshDraft.host)
                    TextField("Port", text: $sshDraft.port)
                        .frame(width: 80)
                }
                TextField("User", text: $sshDraft.user)
                Toggle("Use remote engine", isOn: $sshDraft.useRemoteEngine)
                Text("Authentication is handled by SSH config, keys, agent, or system prompts. Fantastty does not store credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
        case .sprite:
            VStack(alignment: .leading, spacing: 10) {
                Text("Sprite")
                    .font(.title3.weight(.semibold))
                TextField("Sprite name", text: $spriteName)
                    .textFieldStyle(.roundedBorder)
                if !spriteManager.isSpriteCliAvailable {
                    Text("The sprite CLI was not found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button("Refresh") {
                    refreshDiscovery()
                }
                .disabled(!canDiscover)
            }

            TextField("Filter existing sessions", text: $filter)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                ProgressView("Discovering sessions...")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            if let discoveryError {
                Text(discoveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            List(rows, selection: $selectedRowID) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(row.id)
            }
            .frame(minHeight: 100, idealHeight: 220)

            if !isLoading && discoveryError == nil && rows.count == 1 {
                Text("No existing sessions found at this location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(primaryButtonTitle) {
                guard let action = selectedAction else { return }
                perform(action)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedAction == nil || isCreatingSprite || (location == .sprite && !spriteManager.isSpriteCliAvailable))
        }
        .padding(16)
    }

    private var rows: [SessionLauncherRow] {
        SessionLauncherSessionList.rows(
            for: currentDiscoveredSessions,
            attachedKeys: sessionManager.attachedTmuxSessionKeys,
            filter: filter
        )
    }

    private var currentDiscoveredSessions: [SessionLauncherDiscoveredSession] {
        switch location {
        case .sprite:
            return SessionLauncherDiscovery.discoveredSessions(
                location: .sprite,
                sshHost: nil,
                listLocalTmux: { [] },
                listRemoteTmux: { _ in [] },
                listSprites: { spriteManager.sprites }
            )
        case .local, .ssh:
            return discoveredSessions
        }
    }

    private var firstExistingRowID: String? {
        rows.dropFirst().first?.id
    }

    private var selectedRow: SessionLauncherRow {
        rows.first(where: { $0.id == selectedRowID }) ?? rows[0]
    }

    private var primaryButtonTitle: String {
        if case .newSession = selectedRow.selection {
            return "Create Workspace"
        }
        return "Adopt Session"
    }

    private var canDiscover: Bool {
        switch location {
        case .local:
            return true
        case .ssh:
            return sshDraft.canDiscover
        case .sprite:
            return spriteManager.isSpriteCliAvailable
        }
    }

    private var isLoading: Bool {
        isDiscovering || (location == .sprite && spriteManager.isLoading)
    }

    private var selectedAction: SessionLauncherAction? {
        switch selectedRow.selection {
        case .newSession:
            return SessionLauncherAction.newSessionAction(
                location: location,
                sshHost: sshDraft.sshHostInfo,
                spriteName: spriteName,
                useRemoteEngine: sshDraft.useRemoteEngine
            )
        case .existing(let session):
            switch session {
            case .tmux(let name, let host, _):
                return SessionLauncherAction.existingTmuxAction(
                    name: name,
                    host: host,
                    useRemoteEngine: sshDraft.useRemoteEngine
                )
            case .sprite(let name):
                return .connectSprite(name)
            }
        }
    }

    private func perform(_ action: SessionLauncherAction) {
        switch action {
        case .createSprite(let name):
            isCreatingSprite = true
            discoveryError = nil
            spriteManager.create(name: name) { result in
                isCreatingSprite = false
                switch result {
                case .success(let createdName):
                    sessionManager.performSessionLauncherAction(.connectSprite(createdName))
                    dismiss()
                case .failure(let error):
                    discoveryError = error.localizedDescription
                }
            }
        default:
            sessionManager.performSessionLauncherAction(action)
            dismiss()
        }
    }

    private func refreshDiscovery() {
        discoveryTask?.cancel()
        guard canDiscover else {
            discoveredSessions = []
            isDiscovering = false
            return
        }

        if location == .sprite {
            spriteManager.refreshList()
            return
        }

        isDiscovering = true
        discoveryError = nil
        let location = self.location
        let sshHost = sshDraft.sshHostInfo

        discoveryTask = Task.detached(priority: .userInitiated) {
            let sessions = SessionLauncherDiscovery.discoveredSessions(
                location: location,
                sshHost: sshHost,
                listLocalTmux: { TmuxManager.shared.listAllSessions() },
                listRemoteTmux: { TmuxManager.shared.listRemoteSessions(host: $0) },
                listSprites: { [] }
            )

            guard !Task.isCancelled else { return }
            await MainActor.run {
                discoveredSessions = sessions
                isDiscovering = false
                if request.focus == .existingSessions, selectedRowID == "new-session", let firstExistingRowID {
                    selectedRowID = firstExistingRowID
                } else if !rows.contains(where: { $0.id == selectedRowID }) {
                    selectedRowID = "new-session"
                }
            }
        }
    }
}
