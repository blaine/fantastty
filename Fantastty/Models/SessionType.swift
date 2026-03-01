import Foundation

/// The type of terminal session.
enum SessionType: Equatable, Hashable {
    case local
    case ssh(host: String, user: String?, port: Int?)
    case sprite(name: String)

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
        case .sprite(let name):
            return name
        }
    }

    /// The system image name for the sidebar icon.
    var iconName: String {
        switch self {
        case .local:
            return "terminal"
        case .ssh:
            return "network"
        case .sprite:
            return "cloud"
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
        case .sprite(let name):
            return "\(SpriteManager.shared.spritePath) console -s \"\(name)\""
        }
    }

    /// The SSH command with -t (force TTY) for use inside tmux, or nil for local sessions.
    var sshCommand: String? {
        guard case .ssh(let host, let user, let port) = self else { return nil }
        var cmd = "ssh -t"
        if let port = port, port != 22 { cmd += " -p \(port)" }
        if let user = user { cmd += " \(user)@\(host)" } else { cmd += " \(host)" }
        return cmd
    }

    /// The sprite console command for use inside local tmux, or nil for non-sprite sessions.
    var spriteConsoleCommand: String? {
        guard case .sprite(let name) = self else { return nil }
        return "\(SpriteManager.shared.spritePath) console -s \"\(name)\""
    }
}

// MARK: - Codable

extension SessionType: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, host, user, port, spriteName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode("local", forKey: .kind)
        case .ssh(let host, let user, let port):
            try container.encode("ssh", forKey: .kind)
            try container.encode(host, forKey: .host)
            try container.encodeIfPresent(user, forKey: .user)
            try container.encodeIfPresent(port, forKey: .port)
        case .sprite(let name):
            try container.encode("sprite", forKey: .kind)
            try container.encode(name, forKey: .spriteName)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "ssh":
            let host = try container.decode(String.self, forKey: .host)
            let user = try container.decodeIfPresent(String.self, forKey: .user)
            let port = try container.decodeIfPresent(Int.self, forKey: .port)
            self = .ssh(host: host, user: user, port: port)
        case "sprite":
            let name = try container.decode(String.self, forKey: .spriteName)
            self = .sprite(name: name)
        default:
            self = .local
        }
    }
}
