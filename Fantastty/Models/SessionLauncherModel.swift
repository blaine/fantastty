import Foundation

enum SessionLauncherLocation: String, CaseIterable, Identifiable {
    case local
    case ssh
    case sprite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "This Mac"
        case .ssh: return "SSH host"
        case .sprite: return "Sprite"
        }
    }

    var subtitle: String {
        switch self {
        case .local: return "Local shell or local tmux"
        case .ssh: return "Remote shell or remote tmux"
        case .sprite: return "Sprite sessions"
        }
    }
}

struct SessionLauncherRequest: Identifiable, Equatable {
    enum Focus: Equatable {
        case newSession
        case existingSessions
    }

    let id = UUID()
    var location: SessionLauncherLocation
    var focus: Focus

    static func local(focus: Focus = .newSession) -> SessionLauncherRequest {
        SessionLauncherRequest(location: .local, focus: focus)
    }

    static func ssh(focus: Focus = .newSession) -> SessionLauncherRequest {
        SessionLauncherRequest(location: .ssh, focus: focus)
    }

    static func sprite(focus: Focus = .newSession) -> SessionLauncherRequest {
        SessionLauncherRequest(location: .sprite, focus: focus)
    }
}

struct SessionLauncherConnectionDraft: Equatable {
    var host: String = ""
    var user: String = ""
    var port: String = "22"
    var useRemoteEngine: Bool = false

    var sshHostInfo: SSHHostInfo? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }

        let normalizedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort: Int?
        if normalizedPort.isEmpty || normalizedPort == "22" {
            parsedPort = nil
        } else if let value = Int(normalizedPort), value > 0 {
            parsedPort = value
        } else {
            return nil
        }

        return SSHHostInfo(
            user: normalizedUser.isEmpty ? nil : normalizedUser,
            hostname: normalizedHost,
            port: parsedPort
        )
    }

    var canDiscover: Bool {
        sshHostInfo != nil
    }
}

enum SessionLauncherDiscoveredSession: Equatable {
    case tmux(name: String, host: TmuxHost, windowCount: Int)
    case sprite(name: String)

    var title: String {
        switch self {
        case .tmux(let name, _, _), .sprite(let name):
            return name
        }
    }

    var hostDisplayName: String {
        switch self {
        case .tmux(_, let host, _):
            return host.displayName
        case .sprite:
            return "Sprite"
        }
    }

    var attachedKey: AttachedSessionKey? {
        switch self {
        case .tmux(let name, let host, _):
            return AttachedSessionKey(sessionName: name, host: host)
        case .sprite:
            return nil
        }
    }
}

enum SessionLauncherSelection: Equatable {
    case newSession
    case existing(SessionLauncherDiscoveredSession)
}

struct SessionLauncherRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let selection: SessionLauncherSelection
}

enum SessionLauncherSessionList {
    static func rows(
        for sessions: [SessionLauncherDiscoveredSession],
        attachedKeys: Set<AttachedSessionKey>,
        filter: String = ""
    ) -> [SessionLauncherRow] {
        let normalizedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingRows = sessions
            .filter { session in
                guard let key = session.attachedKey else { return true }
                return !attachedKeys.contains(key)
            }
            .filter { session in
                guard !normalizedFilter.isEmpty else { return true }
                return session.title.localizedCaseInsensitiveContains(normalizedFilter)
                    || session.hostDisplayName.localizedCaseInsensitiveContains(normalizedFilter)
            }
            .map(row(for:))

        return [newSessionRow] + existingRows
    }

    private static var newSessionRow: SessionLauncherRow {
        SessionLauncherRow(
            id: "new-session",
            title: "New session",
            subtitle: "Start a fresh session at this location.",
            selection: .newSession
        )
    }

    private static func row(for session: SessionLauncherDiscoveredSession) -> SessionLauncherRow {
        switch session {
        case .tmux(let name, let host, let windowCount):
            return SessionLauncherRow(
                id: "tmux-\(host.displayName)-\(name)",
                title: name,
                subtitle: "\(windowCount) window\(windowCount == 1 ? "" : "s") · \(host.displayName)",
                selection: .existing(session)
            )
        case .sprite(let name):
            return SessionLauncherRow(
                id: "sprite-\(name)",
                title: name,
                subtitle: "Sprite session",
                selection: .existing(session)
            )
        }
    }
}

enum SessionLauncherDiscovery {
    static func discoveredSessions(
        location: SessionLauncherLocation,
        sshHost: SSHHostInfo?,
        listLocalTmux: () -> [TmuxSessionInfo],
        listRemoteTmux: (SSHHostInfo) -> [TmuxSessionInfo],
        listSprites: () -> [SpriteInfo]
    ) -> [SessionLauncherDiscoveredSession] {
        switch location {
        case .local:
            return listLocalTmux().map {
                .tmux(name: $0.name, host: .local, windowCount: $0.windowCount)
            }
        case .ssh:
            guard let sshHost else { return [] }
            return listRemoteTmux(sshHost).map {
                .tmux(name: $0.name, host: .ssh(sshHost), windowCount: $0.windowCount)
            }
        case .sprite:
            return listSprites().map {
                .sprite(name: $0.name)
            }
        }
    }
}

enum SessionLauncherAction: Equatable {
    case createSession(SessionType)
    case createRemoteEngine(SSHHostInfo)
    case createSprite(name: String?)
    case attachTmux(TmuxAttachmentInfo)
    case connectSprite(String)

    static func newSessionAction(
        location: SessionLauncherLocation,
        sshHost: SSHHostInfo?,
        spriteName: String,
        useRemoteEngine: Bool
    ) -> SessionLauncherAction? {
        switch location {
        case .local:
            return .createSession(.local)
        case .ssh:
            guard let sshHost else { return nil }
            if useRemoteEngine {
                return .createRemoteEngine(sshHost)
            }
            return .createSession(.ssh(host: sshHost.hostname, user: sshHost.user, port: sshHost.port))
        case .sprite:
            let normalizedName = spriteName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .createSprite(name: normalizedName.isEmpty ? nil : normalizedName)
        }
    }

    static func existingTmuxAction(
        name: String,
        host: TmuxHost,
        useRemoteEngine: Bool
    ) -> SessionLauncherAction {
        let transport: TmuxAttachmentTransport
        if useRemoteEngine, case .ssh = host {
            transport = .remoteEngine
        } else {
            transport = .tmuxControl
        }

        return .attachTmux(TmuxAttachmentInfo(
            sessionName: name,
            host: host,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach,
            transport: transport
        ))
    }
}
