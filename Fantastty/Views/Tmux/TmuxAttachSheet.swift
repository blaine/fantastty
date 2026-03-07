import SwiftUI

struct TmuxAttachSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var hostString: String = ""
    @State private var sessionFilter: String = ""
    @State private var discoveredSessions: [DiscoveredSession] = []
    @State private var isLocal: Bool = true
    @State private var isDiscovering: Bool = false

    private let tmuxManager = TmuxManager.shared

    var onAttach: ((TmuxAttachmentInfo) -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text("Attach to tmux session")
                .font(.headline)

            Picker("Host", selection: $isLocal) {
                Text("Local").tag(true)
                Text("SSH").tag(false)
            }
            .pickerStyle(.segmented)

            if !isLocal {
                TextField("user@hostname:port", text: $hostString)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("Filter sessions...", text: $sessionFilter)
                .textFieldStyle(.roundedBorder)

            if isDiscovering {
                ProgressView("Discovering sessions...")
            } else {
                List(filteredSessions, id: \.id) { session in
                    Button {
                        attach(to: session)
                    } label: {
                        HStack {
                            Text(session.name)
                            Spacer()
                            Text("\(session.windowCount) windows")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Refresh") { discoverSessions() }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
        .onAppear { discoverSessions() }
        .onChange(of: isLocal) { discoverSessions() }
    }

    private func discoverSessions() {
        isDiscovering = true
        Task.detached {
            let sessions: [DiscoveredSession]
            if isLocal {
                let tmuxSessions = TmuxManager.shared.listAllSessions()
                sessions = tmuxSessions.map { DiscoveredSession(name: $0.name, host: .local, windowCount: $0.windowCount) }
            } else {
                guard let hostInfo = Self.parseHostString(hostString) else {
                    await MainActor.run { isDiscovering = false }
                    return
                }
                let tmuxSessions = TmuxManager.shared.listRemoteSessions(host: hostInfo)
                sessions = tmuxSessions.map { DiscoveredSession(name: $0.name, host: .ssh(hostInfo), windowCount: $0.windowCount) }
            }
            await MainActor.run {
                discoveredSessions = sessions
                isDiscovering = false
            }
        }
    }

    private var filteredSessions: [DiscoveredSession] {
        Self.filterSessions(discoveredSessions, by: sessionFilter)
    }

    private func attach(to session: DiscoveredSession) {
        let info = TmuxAttachmentInfo(
            sessionName: session.name,
            host: session.host,
            connectionState: .disconnected(reason: nil)
        )
        onAttach?(info)
        dismiss()
    }

    // MARK: - Extracted testable logic

    struct DiscoveredSession: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let host: TmuxHost
        let windowCount: Int
    }

    static func parseHostString(_ s: String) -> SSHHostInfo? {
        guard !s.isEmpty else { return nil }
        var user: String?
        var hostname = s
        var port: Int?

        if let atIndex = hostname.firstIndex(of: "@") {
            let u = String(hostname[..<atIndex])
            guard !u.isEmpty else { return nil }
            user = u
            hostname = String(hostname[hostname.index(after: atIndex)...])
        }
        guard !hostname.isEmpty else { return nil }

        if let colonIndex = hostname.lastIndex(of: ":") {
            if let p = Int(hostname[hostname.index(after: colonIndex)...]) {
                port = p
                hostname = String(hostname[..<colonIndex])
            }
        }
        guard !hostname.isEmpty else { return nil }
        return SSHHostInfo(user: user, hostname: hostname, port: port)
    }

    static func filterSessions(_ sessions: [DiscoveredSession], by filter: String) -> [DiscoveredSession] {
        guard !filter.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.host.displayName.localizedCaseInsensitiveContains(filter)
        }
    }
}
