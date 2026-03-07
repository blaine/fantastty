import Foundation

// MARK: - ConnectionState

/// The state of a tmux control mode connection.
enum ConnectionState: Codable, Equatable {
    case connecting
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

// MARK: - TmuxAttachmentInfo

/// Information about a tmux session attachment, including the session name,
/// host, and current connection state.
struct TmuxAttachmentInfo: Codable, Equatable {
    let sessionName: String
    let host: TmuxHost
    var connectionState: ConnectionState

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
}

// MARK: - SessionMode

/// Whether a session is managed by Fantastty or attached to an external tmux session.
enum SessionMode: Codable, Equatable {
    case managed
    case attached(TmuxAttachmentInfo)
}
