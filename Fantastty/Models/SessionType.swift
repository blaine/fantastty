import Foundation

/// The type of terminal session.
enum SessionType: Equatable, Hashable {
    case local
    case ssh(host: String, user: String?, port: Int?)

    /// The display name for the sidebar.
    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .ssh(let host, let user, _):
            if let user = user {
                return "\(user)@\(host)"
            }
            return host
        }
    }

    /// The system image name for the sidebar icon.
    var iconName: String {
        switch self {
        case .local:
            return "terminal"
        case .ssh:
            return "network"
        }
    }

    /// The command string to pass to the terminal surface, or nil for default shell.
    var command: String? {
        switch self {
        case .local:
            return nil
        case .ssh(let host, let user, let port):
            var cmd = "ssh"
            if let port = port, port != 22 {
                cmd += " -p \(port)"
            }
            if let user = user {
                cmd += " \(user)@\(host)"
            } else {
                cmd += " \(host)"
            }
            return cmd
        }
    }
}
