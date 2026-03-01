import Foundation
import os

/// Manages Fly.io Sprite CLI interactions for sprite-based workspaces.
class SpriteManager: ObservableObject {
    static let shared = SpriteManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "sprite-manager"
    )

    @Published var sprites: [SpriteInfo] = []
    @Published var isLoading: Bool = false

    /// Common sprite CLI installation paths
    private static let spritePaths = [
        "\(NSHomeDirectory())/.local/bin/sprite",
        "/usr/local/bin/sprite",
        "/opt/homebrew/bin/sprite",
        "\(NSHomeDirectory())/.fly/bin/sprite",
    ]

    /// Cached sprite CLI path (nil if not found)
    private lazy var _spritePath: String? = {
        for path in Self.spritePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }()

    /// Whether the sprite CLI is available on the system
    var isSpriteCliAvailable: Bool {
        _spritePath != nil
    }

    /// Get the path to the sprite CLI
    var spritePath: String {
        _spritePath ?? "sprite"
    }

    // MARK: - List

    /// Refresh the list of available sprites.
    func refreshList() {
        guard isSpriteCliAvailable else { return }
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.runSpriteList()
            DispatchQueue.main.async {
                self.sprites = result
                self.isLoading = false
            }
        }
    }

    private func runSpriteList() -> [SpriteInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spritePath)
        process.arguments = ["list"]

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
                .compactMap { line -> SpriteInfo? in
                    let name = line.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return nil }
                    return SpriteInfo(name: name)
                }
        } catch {
            Self.logger.error("Failed to list sprites: \(error)")
            return []
        }
    }

    // MARK: - Create

    /// Create a new sprite. Calls completion on main thread.
    func create(name: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard isSpriteCliAvailable else {
            completion(.failure(SpriteError.cliNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.spritePath)
            var args = ["create"]
            if let name = name, !name.isEmpty {
                args.append(name)
            }
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let spriteName = output.isEmpty ? (name ?? "unknown") : output
                    DispatchQueue.main.async { completion(.success(spriteName)) }
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    DispatchQueue.main.async { completion(.failure(SpriteError.createFailed(errMsg))) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Destroy

    /// Destroy a sprite. Calls completion on main thread.
    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isSpriteCliAvailable else {
            completion(.failure(SpriteError.cliNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.spritePath)
            process.arguments = ["destroy", "-s", name, "-f"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    DispatchQueue.main.async { completion(.failure(SpriteError.destroyFailed(name))) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Remote Tmux Setup

    /// Fire-and-forget: ensure tmux is installed on the sprite and configure auto-attach.
    func setupRemoteTmux(spriteName: String, workspaceID: String) {
        guard isSpriteCliAvailable else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let script = """
            command -v tmux >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq tmux >/dev/null 2>&1; }; \
            printf '[ -z "$TMUX" ] && exec tmux new-session -A -s "fantastty-\(workspaceID)"\\n' \
              > /etc/profile.d/fantastty.sh
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.spritePath)
            process.arguments = ["exec", "-s", spriteName, "--", "sh", "-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                Self.logger.info("Remote tmux setup completed for sprite \(spriteName) (exit: \(process.terminationStatus))")
            } catch {
                Self.logger.error("Failed to setup remote tmux on sprite \(spriteName): \(error)")
            }
        }
    }
}

// MARK: - Supporting Types

struct SpriteInfo: Identifiable {
    let name: String
    var id: String { name }
}

enum SpriteError: LocalizedError {
    case cliNotFound
    case createFailed(String)
    case destroyFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The sprite CLI was not found. Install it from https://fly.io/docs/sprites/"
        case .createFailed(let msg):
            return "Failed to create sprite: \(msg)"
        case .destroyFailed(let name):
            return "Failed to destroy sprite '\(name)'"
        }
    }
}
