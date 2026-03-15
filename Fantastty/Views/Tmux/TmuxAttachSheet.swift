import SwiftUI
import os

struct TmuxAttachSheet: View {
    @Environment(\.dismiss) private var dismiss

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "tmux-attach-sheet"
    )

    @State private var hostString: String = ""
    @State private var sessionFilter: String = ""
    @State private var discoveredSessions: [DiscoveredSession] = []
    @State private var isLocal: Bool = true
    @State private var isDiscovering: Bool = false
    @State private var discoveryTask: Task<Void, Never>?

    /// Set of (sessionName, host) pairs already attached in the app.
    var attachedSessionKeys: Set<AttachedSessionKey> = []

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
        .onAppear {
            Self.logger.info("Attach sheet appeared; starting discovery")
            discoverSessions()
        }
        .onChange(of: isLocal) { discoverSessions() }
    }

    private func discoverSessions() {
        discoveryTask?.cancel()
        isDiscovering = true
        let isLocal = self.isLocal
        let hostString = self.hostString
        let startedAt = Date()
        Self.logger.info("Discover sessions requested isLocal=\(isLocal) host=\(hostString, privacy: .public)")

        discoveryTask = Task.detached(priority: .userInitiated) {
            let detachedStartedAt = Date()
            Self.logger.info("Detached discovery started isLocal=\(isLocal)")
            let sessions = Self.discoverSessions(
                isLocal: isLocal,
                hostString: hostString,
                listLocal: { TmuxManager.shared.listAllSessions() },
                listRemote: { TmuxManager.shared.listRemoteSessions(host: $0) }
            )
            let detachedElapsedMs = Int(Date().timeIntervalSince(detachedStartedAt) * 1000)
            Self.logger.info("Detached discovery finished sessions=\(sessions.count) elapsedMs=\(detachedElapsedMs)")

            guard !Task.isCancelled else { return }

            await MainActor.run {
                discoveredSessions = sessions
                isDiscovering = false
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                Self.logger.info("Discovery applied on main actor sessions=\(sessions.count) elapsedMs=\(elapsedMs)")
            }
        }
    }

    nonisolated static func discoverSessions(
        isLocal: Bool,
        hostString: String,
        listLocal: () -> [TmuxSessionInfo],
        listRemote: (SSHHostInfo) -> [TmuxSessionInfo]
    ) -> [DiscoveredSession] {
        logger.info("discoverSessions: isLocal=\(isLocal) hostString='\(hostString, privacy: .public)'")
        if isLocal {
            return listLocal().map {
                DiscoveredSession(name: $0.name, host: .local, windowCount: $0.windowCount)
            }
        }

        guard let hostInfo = parseHostString(hostString) else {
            logger.info("discoverSessions: parseHostString returned nil for hostString='\(hostString, privacy: .public)'")
            return []
        }
        logger.info("discoverSessions: parsed host=\(hostInfo.hostname, privacy: .public) user=\(hostInfo.user ?? "nil", privacy: .public)")

        return listRemote(hostInfo).map {
            DiscoveredSession(name: $0.name, host: .ssh(hostInfo), windowCount: $0.windowCount)
        }
    }

    private var filteredSessions: [DiscoveredSession] {
        let filtered = Self.filterSessions(discoveredSessions, by: sessionFilter)
        return filtered.filter { !attachedSessionKeys.contains($0.sessionKey) }
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

        var sessionKey: AttachedSessionKey {
            AttachedSessionKey(sessionName: name, host: host)
        }
    }

    struct AttachedSessionKey: Hashable {
        let sessionName: String
        let host: TmuxHost
    }

    nonisolated static func parseHostString(_ s: String) -> SSHHostInfo? {
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

    nonisolated static func filterSessions(_ sessions: [DiscoveredSession], by filter: String) -> [DiscoveredSession] {
        guard !filter.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.host.displayName.localizedCaseInsensitiveContains(filter)
        }
    }
}
