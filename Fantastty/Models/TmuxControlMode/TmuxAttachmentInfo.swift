import Foundation

let fantasttySSHConnectionArguments = [
    "-o", "ControlMaster=no",
    "-o", "ControlPath=none"
]

// MARK: - ConnectionState

/// The state of a tmux control mode connection.
enum ConnectionState: Codable, Equatable {
    case connecting
    case reconnecting(reason: String?)
    case connected
    case disconnected(reason: String?)
}

// MARK: - SSHHostInfo

/// SSH connection details for a remote tmux session.
struct SSHHostInfo: Codable, Hashable {
    let user: String?
    let hostname: String
    let port: Int?

    /// Human-readable display name.
    /// Omits port when nil or 22.
    var displayName: String {
        var result = ""
        if let user {
            result += "\(user)@"
        }
        result += hostname
        if let port, port != 22 {
            result += ":\(port)"
        }
        return result
    }

    /// The ssh command prefix for connecting to this host.
    /// e.g. "ssh -t hostname" or "ssh -t -p 2222 user@hostname"
    var sshCommandPrefix: String {
        var parts = ["ssh", "-t"]
        parts.append(contentsOf: fantasttySSHConnectionArguments)
        if let port, port != 22 {
            parts.append("-p")
            parts.append("\(port)")
        }
        var target = ""
        if let user {
            target += "\(user)@"
        }
        target += hostname
        parts.append(target)
        return parts.joined(separator: " ")
    }
}

// MARK: - TmuxHost

/// Whether the tmux session is local or on a remote host.
enum TmuxHost: Codable, Hashable {
    case local
    case ssh(SSHHostInfo)

    /// Display name for the host.
    var displayName: String {
        switch self {
        case .local:
            return "localhost"
        case .ssh(let info):
            return info.displayName
        }
    }
}

enum TmuxAttachmentLaunchMode: String, Codable, Equatable {
    case attach
    case create
}

enum TmuxAttachmentTransport: String, Codable, Equatable {
    case tmuxControl
    case remoteEngine
}

// MARK: - TmuxAttachmentInfo

/// Information about a tmux session attachment, including the session name,
/// host, and current connection state.
struct TmuxAttachmentInfo: Codable, Equatable {
    let sessionName: String
    let host: TmuxHost
    var connectionState: ConnectionState
    var launchMode: TmuxAttachmentLaunchMode
    var transport: TmuxAttachmentTransport

    init(
        sessionName: String,
        host: TmuxHost,
        connectionState: ConnectionState,
        launchMode: TmuxAttachmentLaunchMode = .attach,
        transport: TmuxAttachmentTransport = .tmuxControl
    ) {
        self.sessionName = sessionName
        self.host = host
        self.connectionState = connectionState
        self.launchMode = launchMode
        self.transport = transport
    }

    /// Generate the command to attach to this tmux session in control mode.
    /// - Parameter tmuxPath: Path to the tmux binary (default: "tmux").
    /// - Returns: The full command string.
    func controlCommand(tmuxPath: String = "tmux") -> String {
        let tmuxArgs = "\(tmuxPath) -CC attach-session -t '\(sessionName)'"
        switch host {
        case .local:
            return tmuxArgs
        case .ssh(let info):
            return "\(info.sshCommandPrefix) \(tmuxArgs)"
        }
    }

    /// Generate the command to create a new tmux session before attaching.
    /// This keeps the control-mode transport on the simpler attach path.
    func createSessionCommand(tmuxPath: String = "tmux") -> String {
        let tmuxArgs = "\(tmuxPath) has-session -t '\(sessionName)' 2>/dev/null || \(tmuxPath) new-session -d -s '\(sessionName)' -c ~"
        switch host {
        case .local:
            return tmuxArgs
        case .ssh(let info):
            // Wrap in quotes so the entire expression runs on the remote host
            return "\(info.sshCommandPrefix) \"\(tmuxArgs)\""
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionName
        case host
        case connectionState
        case launchMode
        case transport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        host = try container.decode(TmuxHost.self, forKey: .host)
        connectionState = try container.decode(ConnectionState.self, forKey: .connectionState)
        launchMode = try container.decodeIfPresent(TmuxAttachmentLaunchMode.self, forKey: .launchMode) ?? .attach
        transport = try container.decodeIfPresent(TmuxAttachmentTransport.self, forKey: .transport) ?? .tmuxControl
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionName, forKey: .sessionName)
        try container.encode(host, forKey: .host)
        try container.encode(connectionState, forKey: .connectionState)
        try container.encode(launchMode, forKey: .launchMode)
        try container.encode(transport, forKey: .transport)
    }
}

// MARK: - SessionMode

/// Session attachment mode for a workspace.
enum SessionMode: Codable, Equatable {
    case attached(TmuxAttachmentInfo)
}
