import Foundation

/// Manages tmux sessions for persistent terminal sessions.
class TmuxManager {
    static let shared = TmuxManager()

    /// Prefix for all Fantastty-managed tmux sessions
    static let sessionPrefix = "fantastty-"

    /// Common tmux installation paths
    private static let tmuxPaths = [
        "/opt/homebrew/bin/tmux",  // Homebrew on Apple Silicon
        "/usr/local/bin/tmux",      // Homebrew on Intel / manual install
        "/usr/bin/tmux",            // System install
        "/run/current-system/sw/bin/tmux"  // NixOS
    ]

    /// Cached tmux path (nil if not found)
    private lazy var _tmuxPath: String? = {
        for path in Self.tmuxPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }()

    /// Cached tmux version (major, minor)
    private lazy var _tmuxVersion: (Int, Int)? = {
        parseTmuxVersion()
    }()

    /// Whether tmux supports DCS passthrough (tmux 3.3+)
    var supportsPassthrough: Bool {
        guard let (major, minor) = _tmuxVersion else { return false }
        return major > 3 || (major == 3 && minor >= 3)
    }

    /// Parse the tmux version from `tmux -V` output.
    /// Handles formats like "tmux 3.4", "tmux next-3.5", "tmux 3.3a"
    private func parseTmuxVersion() -> (Int, Int)? {
        guard let path = _tmuxPath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-V"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Find first occurrence of major.minor digits
            let pattern = #"(\d+)\.(\d+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let majorRange = Range(match.range(at: 1), in: output),
                  let minorRange = Range(match.range(at: 2), in: output),
                  let major = Int(output[majorRange]),
                  let minor = Int(output[minorRange]) else { return nil }

            return (major, minor)
        } catch {
            return nil
        }
    }

    /// Check if tmux is available on the system
    var isTmuxAvailable: Bool {
        _tmuxPath != nil
    }

    /// Get the path to tmux
    var tmuxPath: String {
        _tmuxPath ?? "tmux"
    }

    // MARK: - Session Name Generation

    /// Generate a base session name for a workspace
    func baseSessionName(workspaceID: String) -> String {
        return "\(Self.sessionPrefix)ws-\(workspaceID)"
    }

    /// Generate a linked session name for a tab within a workspace
    func tabSessionName(workspaceID: String, tabIndex: Int) -> String {
        return "\(Self.sessionPrefix)ws-\(workspaceID)-tab-\(tabIndex)"
    }

    // MARK: - Command Generation

    /// Generate the command to create or attach to the base session (first tab)
    /// - Parameters:
    ///   - sessionName: The tmux session name
    ///   - workingDirectory: Optional working directory for the session
    ///   - paneCommand: Optional command to run in the pane (e.g. SSH + remote tmux)
    func commandForFirstTab(sessionName: String, workingDirectory: String? = nil, paneCommand: String? = nil) -> String {
        var cmd = "\(tmuxPath) new-session -A -s \"\(sessionName)\""
        if let dir = workingDirectory {
            cmd += " -c '\(dir)'"
        }
        if supportsPassthrough {
            // ZDOTDIR injection only for local sessions (no pane command)
            if paneCommand == nil, ShellIntegration.shared.isAvailable {
                let zdotdir = ShellIntegration.shared.zdotdirPath
                let origZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()
                cmd += " -e 'ZDOTDIR=\(zdotdir)' -e 'FANTASTTY_ORIGINAL_ZDOTDIR=\(origZdotdir)'"
            }
        }
        // Pane command must come before \; chains (tmux parses -- as end of new-session args)
        if let paneCommand = paneCommand {
            cmd += " -- \(paneCommand)"
        }
        if supportsPassthrough {
            cmd += " \\; set-option allow-passthrough on"
        }
        // Keep pane alive if SSH disconnects
        if paneCommand != nil {
            cmd += " \\; set-option remain-on-exit on"
        }
        return cmd
    }

    /// Generate the command to create an independent session for an additional tab
    func commandForTabSession(tabSessionName: String) -> String {
        var cmd = "\(tmuxPath) new-session -s '\(tabSessionName)'"
        if supportsPassthrough {
            if ShellIntegration.shared.isAvailable {
                let zdotdir = ShellIntegration.shared.zdotdirPath
                let origZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()
                cmd += " -e 'ZDOTDIR=\(zdotdir)' -e 'FANTASTTY_ORIGINAL_ZDOTDIR=\(origZdotdir)'"
            }
            cmd += " \\; set-option allow-passthrough on"
        }
        return cmd
    }

    /// Generate the command arguments for control mode connection.
    /// Returns the full path and arguments for `tmux -CC new-session -A -s <name>`.
    func commandForControlMode(sessionName: String) -> (path: String, arguments: [String]) {
        return (tmuxPath, ["-CC", "new-session", "-A", "-s", sessionName])
    }

    /// Generate the command to attach to an existing session
    func commandForAttach(sessionName: String) -> String {
        var cmd = "\(tmuxPath) attach-session -t '\(sessionName)'"
        if supportsPassthrough {
            cmd += " \\; set-option allow-passthrough on"
        }
        return cmd
    }

    // MARK: - Session Discovery

    /// List all Fantastty-managed tmux sessions
    func listFantasttySessions() -> [TmuxSessionInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}:#{session_created}:#{session_windows}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return [] }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return output
                .split(separator: "\n")
                .compactMap { line -> TmuxSessionInfo? in
                    let parts = line.split(separator: ":", maxSplits: 2)
                    guard parts.count >= 1 else { return nil }

                    let name = String(parts[0])
                    guard name.hasPrefix(Self.sessionPrefix) else { return nil }

                    let created = parts.count > 1 ? TimeInterval(parts[1]) ?? 0 : 0
                    let windows = parts.count > 2 ? Int(parts[2]) ?? 1 : 1

                    return TmuxSessionInfo(
                        name: name,
                        createdAt: Date(timeIntervalSince1970: created),
                        windowCount: windows
                    )
                }
        } catch {
            return []
        }
    }

    /// Group sessions by workspace (base session + linked tab sessions)
    func groupSessionsByWorkspace() -> [String: TmuxWorkspaceInfo] {
        let sessions = listFantasttySessions()
        var workspaces: [String: TmuxWorkspaceInfo] = [:]

        for session in sessions {
            // Parse workspace ID from session name
            // Format: fantastty-ws-<id> or fantastty-ws-<id>-tab-<n>
            let name = session.name
            guard name.hasPrefix("\(Self.sessionPrefix)ws-") else { continue }

            let suffix = String(name.dropFirst("\(Self.sessionPrefix)ws-".count))
            let parts = suffix.split(separator: "-", maxSplits: 1)
            let workspaceID = String(parts[0])

            if workspaces[workspaceID] == nil {
                workspaces[workspaceID] = TmuxWorkspaceInfo(
                    workspaceID: workspaceID,
                    baseSession: nil,
                    tabSessions: []
                )
            }

            if parts.count == 1 {
                // This is the base session
                workspaces[workspaceID]?.baseSession = session
            } else {
                // This is a tab session
                workspaces[workspaceID]?.tabSessions.append(session)
            }
        }

        return workspaces
    }

    // MARK: - Session Control

    /// Kill a specific tmux session
    func killSession(name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["kill-session", "-t", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore errors
        }
    }

    /// Kill all sessions for a workspace (base + all tab sessions)
    func killWorkspaceSessions(workspaceID: String) {
        let prefix = "\(Self.sessionPrefix)ws-\(workspaceID)"
        for session in listFantasttySessions() where session.name.hasPrefix(prefix) {
            killSession(name: session.name)
        }
    }

    /// Check if a session exists
    func sessionExists(name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["has-session", "-t", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Information about a tmux session
struct TmuxSessionInfo {
    let name: String
    let createdAt: Date
    let windowCount: Int
}

/// Information about a workspace's tmux sessions
struct TmuxWorkspaceInfo {
    let workspaceID: String
    var baseSession: TmuxSessionInfo?
    var tabSessions: [TmuxSessionInfo]

    var isValid: Bool {
        baseSession != nil
    }
}
