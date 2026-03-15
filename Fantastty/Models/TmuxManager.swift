import Foundation
import os

/// Manages tmux sessions for persistent terminal sessions.
class TmuxManager {
    static let shared = TmuxManager()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "tmux-manager"
    )

    /// Prefix for Fantastty workspace tmux sessions.
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

    // MARK: - Session Discovery

    /// List tmux sessions owned by Fantastty workspace naming.
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

    /// List all tmux sessions on the local machine.
    func listAllSessions() -> [TmuxSessionInfo] {
        let startedAt = Date()
        Self.logger.info("Starting local tmux session discovery")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}:#{session_created}:#{session_windows}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            let runStartedAt = Date()
            try process.run()
            let runElapsedMs = Int(Date().timeIntervalSince(runStartedAt) * 1000)
            Self.logger.info("Local tmux session process launched pid=\(process.processIdentifier) runElapsedMs=\(runElapsedMs)")

            let waitStartedAt = Date()
            process.waitUntilExit()
            let waitElapsedMs = Int(Date().timeIntervalSince(waitStartedAt) * 1000)
            Self.logger.info("Local tmux session process exited status=\(process.terminationStatus) waitElapsedMs=\(waitElapsedMs)")

            guard process.terminationStatus == 0 else {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                Self.logger.error("Local tmux session discovery failed status=\(process.terminationStatus) elapsedMs=\(elapsedMs)")
                return []
            }

            let readStartedAt = Date()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let readElapsedMs = Int(Date().timeIntervalSince(readStartedAt) * 1000)
            Self.logger.info("Local tmux session output read bytes=\(data.count) readElapsedMs=\(readElapsedMs)")
            guard let output = String(data: data, encoding: .utf8) else {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                Self.logger.error("Local tmux session discovery failed to decode output elapsedMs=\(elapsedMs)")
                return []
            }

            let sessions = output
                .split(separator: "\n")
                .compactMap { line -> TmuxSessionInfo? in
                    let parts = line.split(separator: ":", maxSplits: 2)
                    guard parts.count >= 1 else { return nil }

                    let name = String(parts[0])
                    let created = parts.count > 1 ? TimeInterval(parts[1]) ?? 0 : 0
                    let windows = parts.count > 2 ? Int(parts[2]) ?? 1 : 1

                    return TmuxSessionInfo(
                        name: name,
                        createdAt: Date(timeIntervalSince1970: created),
                        windowCount: windows
                    )
                }
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Self.logger.info("Finished local tmux session discovery count=\(sessions.count) elapsedMs=\(elapsedMs)")
            return sessions
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Self.logger.error("Local tmux session discovery threw error=\(error.localizedDescription, privacy: .public) elapsedMs=\(elapsedMs)")
            return []
        }
    }

    /// List tmux sessions on a remote host via SSH.
    func listRemoteSessions(host: SSHHostInfo) -> [TmuxSessionInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes"]
        if let port = host.port, port != 22 {
            args += ["-p", "\(port)"]
        }
        var target = ""
        if let user = host.user { target += "\(user)@" }
        target += host.hostname
        args.append(target)
        args.append("tmux list-sessions -F '#{session_name}:#{session_created}:#{session_windows}'")
        process.arguments = args

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
                    let created = parts.count > 1 ? TimeInterval(parts[1]) ?? 0 : 0
                    let windows = parts.count > 2 ? Int(parts[2]) ?? 1 : 1
                    return TmuxSessionInfo(name: name, createdAt: Date(timeIntervalSince1970: created), windowCount: windows)
                }
        } catch {
            return []
        }
    }

    /// Group sessions by workspace.
    /// v2 only restores a single attached tmux session per workspace.
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
                    baseSession: nil
                )
            }

            if parts.count == 1 {
                // This is the base session
                workspaces[workspaceID]?.baseSession = session
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

    /// Kill all sessions for a workspace prefix (canonical plus any legacy suffix sessions).
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

/// Information about a workspace's canonical tmux session.
struct TmuxWorkspaceInfo {
    let workspaceID: String
    var baseSession: TmuxSessionInfo?

    var isValid: Bool {
        baseSession != nil
    }
}
