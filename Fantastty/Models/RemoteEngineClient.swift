import CryptoKit
import Darwin
import Foundation
import Network
import Security

struct RemoteEngineAttachMaterial: Equatable, Sendable {
    let workspaceID: String
    let host: String
    let port: UInt16
    let session: String
    let key: String
    let expires: Date
    let helperPID: Int
    let helperVersion: String
    let helperArch: String
    let certSHA256: String
    let alpn: String
}

struct RemoteEngineBootstrapLine {
    static func parse(_ line: String, workspaceID: String) throws -> RemoteEngineAttachMaterial {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("FANTASTTY_REMOTE ") else {
            throw RemoteEngineError.invalidBootstrapLine("missing FANTASTTY_REMOTE prefix")
        }

        var fields: [String: String] = [:]
        for field in trimmed.split(separator: " ").dropFirst() {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw RemoteEngineError.invalidBootstrapLine("invalid field \(field)")
            }
            let key = String(parts[0])
            guard fields[key] == nil else {
                throw RemoteEngineError.invalidBootstrapLine("duplicate field \(key)")
            }
            fields[key] = String(parts[1])
        }

        guard let endpoint = fields["quic_addr"] else {
            throw RemoteEngineError.invalidBootstrapLine("missing quic_addr")
        }
        let (host, port) = try parseEndpoint(endpoint)
        guard let session = fields["session"], isLowercaseHex(session, count: 64) else {
            throw RemoteEngineError.invalidBootstrapLine("invalid session")
        }
        guard let key = fields["key"], isLowercaseHex(key, count: 64) else {
            throw RemoteEngineError.invalidBootstrapLine("invalid key")
        }
        guard let expiresText = fields["expires"],
              let expires = ISO8601DateFormatter.fantasttyRemoteEngine.date(from: expiresText) else {
            throw RemoteEngineError.invalidBootstrapLine("invalid expires")
        }
        guard let pidText = fields["helper_pid"], let helperPID = Int(pidText), helperPID > 0 else {
            throw RemoteEngineError.invalidBootstrapLine("invalid helper_pid")
        }
        guard let version = fields["version"], !version.isEmpty else {
            throw RemoteEngineError.invalidBootstrapLine("missing version")
        }
        guard let arch = fields["arch"], !arch.isEmpty else {
            throw RemoteEngineError.invalidBootstrapLine("missing arch")
        }
        guard let certSHA256 = fields["quic_cert_sha256"], isLowercaseHex(certSHA256, count: 64) else {
            throw RemoteEngineError.invalidBootstrapLine("invalid quic_cert_sha256")
        }
        guard let alpn = fields["quic_alpn"], !alpn.isEmpty else {
            throw RemoteEngineError.invalidBootstrapLine("missing quic_alpn")
        }

        return RemoteEngineAttachMaterial(
            workspaceID: workspaceID,
            host: host,
            port: port,
            session: session,
            key: key,
            expires: expires,
            helperPID: helperPID,
            helperVersion: version,
            helperArch: arch,
            certSHA256: certSHA256,
            alpn: alpn
        )
    }

    private static func parseEndpoint(_ endpoint: String) throws -> (String, UInt16) {
        if endpoint.hasPrefix("[") {
            guard let closeBracket = endpoint.firstIndex(of: "]") else {
                throw RemoteEngineError.invalidBootstrapLine("invalid quic_addr")
            }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closeBracket])
            let portStart = endpoint.index(after: closeBracket)
            guard portStart < endpoint.endIndex, endpoint[portStart] == ":" else {
                throw RemoteEngineError.invalidBootstrapLine("invalid quic_addr")
            }
            let portText = String(endpoint[endpoint.index(after: portStart)...])
            guard let port = UInt16(portText) else {
                throw RemoteEngineError.invalidBootstrapLine("invalid quic_addr port")
            }
            return (host, port)
        }

        guard let colon = endpoint.lastIndex(of: ":") else {
            throw RemoteEngineError.invalidBootstrapLine("invalid quic_addr")
        }
        let host = String(endpoint[..<colon])
        let portText = String(endpoint[endpoint.index(after: colon)...])
        guard !host.isEmpty, let port = UInt16(portText) else {
            throw RemoteEngineError.invalidBootstrapLine("invalid quic_addr")
        }
        return (host, port)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        guard value.count == count else { return false }
        return value.allSatisfy { character in
            character >= "0" && character <= "9" || character >= "a" && character <= "f"
        }
    }
}

struct RemoteEngineLocalIPv4Network: Equatable {
    let address: UInt32
    let netmask: UInt32

    init?(address: String, netmask: String) {
        guard let address = Self.parseIPv4(address),
              let netmask = Self.parseIPv4(netmask) else {
            return nil
        }
        self.address = address
        self.netmask = netmask
    }

    init(address: UInt32, netmask: UInt32) {
        self.address = address
        self.netmask = netmask
    }

    func contains(_ candidate: String) -> Bool {
        guard netmask != 0,
              let candidate = Self.parseIPv4(candidate) else {
            return false
        }
        return (candidate & netmask) == (address & netmask)
    }

    private static func parseIPv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }

        var address: UInt32 = 0
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let octet = UInt32(part),
                  octet <= 255 else {
                return nil
            }
            address = (address << 8) | octet
        }
        return address
    }
}

protocol RemoteEngineBootstrapper {
    func attachMaterial(workspaceID: String, host: SSHHostInfo) async throws -> RemoteEngineAttachMaterial
    func attachMaterial(workspaceID: String, host: SSHHostInfo, tmuxSessionName: String?) async throws -> RemoteEngineAttachMaterial
    func shutdown(material: RemoteEngineAttachMaterial, host: SSHHostInfo) async throws
}

extension RemoteEngineBootstrapper {
    func attachMaterial(workspaceID: String, host: SSHHostInfo, tmuxSessionName: String?) async throws -> RemoteEngineAttachMaterial {
        guard tmuxSessionName == nil else {
            throw RemoteEngineError.bootstrapFailed("remote engine bootstrapper does not support external tmux sessions")
        }
        return try await attachMaterial(workspaceID: workspaceID, host: host)
    }
}

protocol RemoteEngineProcessRunning {
    func run(_ executableURL: URL, arguments: [String]) async throws -> String
}

struct RemoteEngineProcessRunner: RemoteEngineProcessRunning {
    func run(_ executableURL: URL, arguments: [String]) async throws -> String {
        var stdoutRead: Int32 = -1
        var stdoutWrite: Int32 = -1
        var stderrRead: Int32 = -1
        var stderrWrite: Int32 = -1
        defer {
            Self.closeIfOpen(&stdoutRead)
            Self.closeIfOpen(&stdoutWrite)
            Self.closeIfOpen(&stderrRead)
            Self.closeIfOpen(&stderrWrite)
        }

        (stdoutRead, stdoutWrite) = try Self.makePipe()
        (stderrRead, stderrWrite) = try Self.makePipe()

        var fileActions: posix_spawn_file_actions_t?
        var fileActionsInitialized = false
        let initResult = posix_spawn_file_actions_init(&fileActions)
        guard initResult == 0 else {
            throw RemoteEngineError.bootstrapFailed("failed to prepare process launch: \(Self.posixErrorDescription(initResult))")
        }
        fileActionsInitialized = true
        defer {
            if fileActionsInitialized {
                posix_spawn_file_actions_destroy(&fileActions)
            }
        }

        try Self.checkFileAction(posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO))
        try Self.checkFileAction(posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO))
        try Self.checkFileAction(posix_spawn_file_actions_addclose(&fileActions, stdoutRead))
        try Self.checkFileAction(posix_spawn_file_actions_addclose(&fileActions, stdoutWrite))
        try Self.checkFileAction(posix_spawn_file_actions_addclose(&fileActions, stderrRead))
        try Self.checkFileAction(posix_spawn_file_actions_addclose(&fileActions, stderrWrite))

        let spawnedProcess = try Self.spawn(
            executableURL: executableURL,
            arguments: arguments,
            fileActions: &fileActions
        )

        Self.closeIfOpen(&stdoutWrite)
        Self.closeIfOpen(&stderrWrite)

        let stdoutHandle = FileHandle(fileDescriptor: stdoutRead, closeOnDealloc: true)
        stdoutRead = -1
        let stderrHandle = FileHandle(fileDescriptor: stderrRead, closeOnDealloc: true)
        stderrRead = -1

        return try await withTaskCancellationHandler {
            let stdoutTask = Task.detached {
                stdoutHandle.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderrHandle.readDataToEndOfFile()
            }
            let statusTask = Task.detached {
                spawnedProcess.waitForExit()
            }
            let status = await statusTask.value
            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value
            guard status == 0 else {
                let errorText = String(data: stderr, encoding: .utf8) ?? ""
                let message = errorText.isEmpty
                    ? "\(executableURL.path) exited with status \(status)"
                    : errorText
                throw RemoteEngineError.bootstrapFailed(message)
            }
            return String(data: stdout, encoding: .utf8) ?? ""
        } onCancel: {
            spawnedProcess.terminate()
        }
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        fileActions: inout posix_spawn_file_actions_t?
    ) throws -> RemoteEngineSpawnedProcess {
        var cArguments: [UnsafeMutablePointer<CChar>?] = []
        for argument in [executableURL.path] + arguments {
            guard let duplicated = strdup(argument) else {
                throw RemoteEngineError.bootstrapFailed("failed to prepare process arguments")
            }
            cArguments.append(duplicated)
        }
        cArguments.append(nil)
        defer {
            for case let argument? in cArguments {
                free(argument)
            }
        }

        var cEnvironment: [UnsafeMutablePointer<CChar>?] = []
        for (key, value) in ProcessInfo.processInfo.environment {
            guard let duplicated = strdup("\(key)=\(value)") else {
                throw RemoteEngineError.bootstrapFailed("failed to prepare process environment")
            }
            cEnvironment.append(duplicated)
        }
        cEnvironment.append(nil)
        defer {
            for case let variable? in cEnvironment {
                free(variable)
            }
        }

        var pid = pid_t()
        let spawnResult = executableURL.path.withCString { path in
            cArguments.withUnsafeMutableBufferPointer { buffer in
                cEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        path,
                        &fileActions,
                        nil,
                        buffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard spawnResult == 0 else {
            throw RemoteEngineError.bootstrapFailed(
                "failed to launch \(executableURL.path): \(Self.posixErrorDescription(spawnResult))"
            )
        }
        return RemoteEngineSpawnedProcess(pid: pid)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            pipe(buffer.baseAddress)
        }
        guard result == 0 else {
            throw RemoteEngineError.bootstrapFailed("failed to create process pipe: \(posixErrorDescription(errno))")
        }
        return (read: fds[0], write: fds[1])
    }

    private static func checkFileAction(_ result: Int32) throws {
        guard result == 0 else {
            throw RemoteEngineError.bootstrapFailed("failed to prepare process launch: \(posixErrorDescription(result))")
        }
    }

    private static func closeIfOpen(_ fd: inout Int32) {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    private static func posixErrorDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

private final class RemoteEngineSpawnedProcess: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var didTerminate = false

    init(pid: pid_t) {
        self.pid = pid
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = !didTerminate
        lock.unlock()

        if shouldTerminate {
            kill(pid, SIGTERM)
        }
    }

    func waitForExit() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno == EINTR {
                continue
            }
            return -1
        }

        lock.lock()
        didTerminate = true
        lock.unlock()

        if status & 0x7f == 0 {
            return (status >> 8) & 0xff
        }
        if status & 0x7f != 0x7f {
            return 128 + (status & 0x7f)
        }
        return status
    }
}
protocol RemoteEngineHelperDeploying {
    func ensureDeployed(host: SSHHostInfo) async throws -> RemoteEngineHelperDeployment
}

struct RemoteEngineHelperDeployment {
    let helperPath: String
    let libraryPath: String
    let libraryEnvironmentVariable: String
}

struct RemoteEngineHelperArtifact {
    let label: String
    let version: String
    let os: String
    let arch: String
    let libraryName: String
    let libraryEnvironmentVariable: String
    let checksumCommand: String
    let helperURL: URL
    let helperSHA256: String
    let libraryURL: URL
    let librarySHA256: String
}

struct RemoteEngineBundledArtifactStore {
    var rootURL: URL

    init(rootURL: URL = Bundle.main.resourceURL?.appendingPathComponent("RemoteEngine", isDirectory: true) ?? URL(fileURLWithPath: "/dev/null")) {
        self.rootURL = rootURL
    }

    func artifact(forRemoteUname uname: String) throws -> RemoteEngineHelperArtifact {
        try artifact(remoteSystem: "Linux", remoteMachine: uname)
    }

    func artifact(remoteSystem: String, remoteMachine: String) throws -> RemoteEngineHelperArtifact {
        let label: String
        let os: String
        let arch: String
        let libraryName: String
        let libraryEnvironmentVariable: String
        let checksumCommand: String
        let normalizedSystem = remoteSystem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMachine = remoteMachine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch (normalizedSystem, normalizedMachine) {
        case ("linux", "x86_64"), ("linux", "amd64"):
            label = "linux-amd64"
            os = "linux"
            arch = "amd64"
            libraryName = "libghostty-vt.so.0.1.0"
            libraryEnvironmentVariable = "LD_LIBRARY_PATH"
            checksumCommand = "sha256sum -c -"
        case ("linux", "aarch64"), ("linux", "arm64"):
            label = "linux-arm64"
            os = "linux"
            arch = "arm64"
            libraryName = "libghostty-vt.so.0.1.0"
            libraryEnvironmentVariable = "LD_LIBRARY_PATH"
            checksumCommand = "sha256sum -c -"
        case ("darwin", "arm64"):
            label = "darwin-arm64"
            os = "darwin"
            arch = "arm64"
            libraryName = "libghostty-vt.dylib"
            libraryEnvironmentVariable = "DYLD_LIBRARY_PATH"
            checksumCommand = "shasum -a 256 -c -"
        default:
            let system = remoteSystem.trimmingCharacters(in: .whitespacesAndNewlines)
            let machine = remoteMachine.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteEngineError.bootstrapFailed("unsupported remote platform: \(system) \(machine)")
        }

        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let manifest: RemoteEngineHelperManifest
        do {
            manifest = try JSONDecoder().decode(RemoteEngineHelperManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw RemoteEngineError.bootstrapFailed("missing remote helper artifacts: \(manifestURL.path)")
        }

        guard let entry = manifest.artifacts[label] else {
            throw RemoteEngineError.bootstrapFailed("missing remote helper artifact for \(label)")
        }
        guard entry.os == os else {
            throw RemoteEngineError.bootstrapFailed("remote helper artifact \(label) declares os \(entry.os), expected \(os)")
        }
        guard entry.arch == arch else {
            throw RemoteEngineError.bootstrapFailed("remote helper artifact \(label) declares arch \(entry.arch), expected \(arch)")
        }

        let helperURL = rootURL.appendingPathComponent(entry.helper)
        let libraryURL = rootURL.appendingPathComponent(entry.library)
        guard try sha256Hex(of: helperURL) == entry.helperSHA256 else {
            throw RemoteEngineError.bootstrapFailed("remote helper artifact checksum mismatch for \(label)")
        }
        guard try sha256Hex(of: libraryURL) == entry.librarySHA256 else {
            throw RemoteEngineError.bootstrapFailed("remote helper library checksum mismatch for \(label)")
        }

        return RemoteEngineHelperArtifact(
            label: label,
            version: manifest.version,
            os: os,
            arch: arch,
            libraryName: libraryName,
            libraryEnvironmentVariable: libraryEnvironmentVariable,
            checksumCommand: checksumCommand,
            helperURL: helperURL,
            helperSHA256: entry.helperSHA256,
            libraryURL: libraryURL,
            librarySHA256: entry.librarySHA256
        )
    }
}

struct RemoteEngineHelperDeployer: RemoteEngineHelperDeploying {
    var artifactStore = RemoteEngineBundledArtifactStore()
    var processRunner: RemoteEngineProcessRunning = RemoteEngineProcessRunner()
    var remoteDirectory = ".cache/fantastty/remote-engine"

    func ensureDeployed(host: SSHHostInfo) async throws -> RemoteEngineHelperDeployment {
        let platform = try await remotePlatform(host: host)
        let artifact = try artifactStore.artifact(remoteSystem: platform.system, remoteMachine: platform.machine)
        let helperPath = "\(remoteDirectory)/fantastty-helper"
        let libraryDirectory = "\(remoteDirectory)/lib"
        let libraryPath = "\(libraryDirectory)/\(artifact.libraryName)"
        let helperTmpPath = "\(helperPath).tmp"
        let libraryTmpPath = "\(libraryPath).tmp"

        _ = try await runSSH(
            host: host,
            remoteCommand: [
                "mkdir -p \(shellQuote(remoteDirectory)) \(shellQuote(libraryDirectory))",
                "chmod 700 \(shellQuote(remoteDirectory)) \(shellQuote(libraryDirectory))"
            ].joined(separator: " && ")
        )
        if !(await remoteArtifactsMatch(
            host: host,
            artifact: artifact,
            helperPath: helperPath,
            libraryPath: libraryPath
        )) {
            _ = try await processRunner.run(
                URL(fileURLWithPath: "/usr/bin/scp"),
                arguments: scpArguments(host: host, localURL: artifact.libraryURL, remotePath: libraryTmpPath)
            )
            _ = try await runSSH(
                host: host,
                remoteCommand: installLibraryCommand(
                    artifact: artifact,
                    libraryTmpPath: libraryTmpPath,
                    libraryPath: libraryPath,
                    libraryDirectory: libraryDirectory
                )
            )
            _ = try await processRunner.run(
                URL(fileURLWithPath: "/usr/bin/scp"),
                arguments: scpArguments(host: host, localURL: artifact.helperURL, remotePath: helperTmpPath)
            )
            _ = try await runSSH(
                host: host,
                remoteCommand: [
                    "printf '%s  %s\\n' \(shellQuote(artifact.helperSHA256)) \(shellQuote(helperTmpPath)) | \(artifact.checksumCommand)",
                    "mv \(shellQuote(helperTmpPath)) \(shellQuote(helperPath))",
                    "chmod 700 \(shellQuote(helperPath))"
                ].joined(separator: " && ")
            )
        }

        let versionLine = try await runSSH(
            host: host,
            remoteCommand: [
                "env",
                "-u", "XDG_RUNTIME_DIR",
                "\(artifact.libraryEnvironmentVariable)=\(shellQuote(libraryDirectory))",
                shellQuote(helperPath),
                "--version"
            ].joined(separator: " ")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedVersionLine = "fantastty-helper version=\(artifact.version) arch=\(artifact.arch)"
        guard versionLine == expectedVersionLine else {
            throw RemoteEngineError.bootstrapFailed("unexpected helper version line: \(versionLine)")
        }

        return RemoteEngineHelperDeployment(
            helperPath: helperPath,
            libraryPath: libraryDirectory,
            libraryEnvironmentVariable: artifact.libraryEnvironmentVariable
        )
    }

    private func remotePlatform(host: SSHHostInfo) async throws -> (system: String, machine: String) {
        let output = try await runSSH(host: host, remoteCommand: "uname -s && uname -m")
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 2 else {
            throw RemoteEngineError.bootstrapFailed("remote platform probe did not report system and machine")
        }
        return (lines[0], lines[1])
    }

    private func installLibraryCommand(
        artifact: RemoteEngineHelperArtifact,
        libraryTmpPath: String,
        libraryPath: String,
        libraryDirectory: String
    ) -> String {
        var commands = [
            "printf '%s  %s\\n' \(shellQuote(artifact.librarySHA256)) \(shellQuote(libraryTmpPath)) | \(artifact.checksumCommand)",
            "mv \(shellQuote(libraryTmpPath)) \(shellQuote(libraryPath))",
            "chmod 600 \(shellQuote(libraryPath))"
        ]
        if artifact.os == "linux" {
            commands.append(contentsOf: [
                "ln -sf 'libghostty-vt.so.0.1.0' \(shellQuote("\(libraryDirectory)/libghostty-vt.so.0"))",
                "ln -sf 'libghostty-vt.so.0' \(shellQuote("\(libraryDirectory)/libghostty-vt.so"))"
            ])
        }
        return commands.joined(separator: " && ")
    }

    private func remoteArtifactsMatch(
        host: SSHHostInfo,
        artifact: RemoteEngineHelperArtifact,
        helperPath: String,
        libraryPath: String
    ) async -> Bool {
        let libraryDirectory = (libraryPath as NSString).deletingLastPathComponent
        let sonameLinkPath = "\(libraryDirectory)/libghostty-vt.so.0"
        let linkerNamePath = "\(libraryDirectory)/libghostty-vt.so"
        var commands = [
            "test -f \(shellQuote(helperPath))",
            "test -f \(shellQuote(libraryPath))"
        ]
        if artifact.os == "linux" {
            commands.append(contentsOf: [
                "test -L \(shellQuote(sonameLinkPath))",
                "test \"$(readlink \(shellQuote(sonameLinkPath)))\" = \(shellQuote("libghostty-vt.so.0.1.0"))",
                "test -L \(shellQuote(linkerNamePath))",
                "test \"$(readlink \(shellQuote(linkerNamePath)))\" = \(shellQuote("libghostty-vt.so.0"))"
            ])
        }
        commands.append(contentsOf: [
            "printf '%s  %s\\n' \(shellQuote(artifact.helperSHA256)) \(shellQuote(helperPath)) | \(artifact.checksumCommand)",
            "printf '%s  %s\\n' \(shellQuote(artifact.librarySHA256)) \(shellQuote(libraryPath)) | \(artifact.checksumCommand)"
        ])
        do {
            _ = try await runSSH(
                host: host,
                remoteCommand: commands.joined(separator: " && ")
            )
            return true
        } catch {
            return false
        }
    }

    private func runSSH(host: SSHHostInfo, remoteCommand: String) async throws -> String {
        try await processRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: sshArguments(host: host, remoteCommand: remoteCommand)
        )
    }
}

struct SSHRemoteEngineBootstrapper: RemoteEngineBootstrapper {
    var helperPath = ".cache/fantastty/remote-engine/fantastty-helper"
    var libraryPath = ".cache/fantastty/remote-engine/lib"
    var ttl = "8h"
    var keyTTL = "30s"
    var advertiseHostOverride: String?
    var helperDeployer: RemoteEngineHelperDeploying? = RemoteEngineHelperDeployer()
    var processRunner: RemoteEngineProcessRunning = RemoteEngineProcessRunner()
    var localIPv4Networks: () -> [RemoteEngineLocalIPv4Network] = Self.currentLocalIPv4Networks

    func attachMaterial(workspaceID: String, host: SSHHostInfo) async throws -> RemoteEngineAttachMaterial {
        try await attachMaterial(workspaceID: workspaceID, host: host, tmuxSessionName: nil)
    }

    func attachMaterial(workspaceID: String, host: SSHHostInfo, tmuxSessionName: String?) async throws -> RemoteEngineAttachMaterial {
        let advertiseHost = try await resolvedAdvertiseHost(for: host)
        let deployment = try await helperDeployer?.ensureDeployed(host: host)
        let output = try await runSSH(
            host: host,
            remoteCommand: launchCommand(
                workspaceID: workspaceID,
                host: host,
                deployment: deployment,
                advertiseHost: advertiseHost,
                tmuxSessionName: tmuxSessionName
            )
        )
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) else {
            throw RemoteEngineError.invalidBootstrapLine("empty bootstrap output")
        }
        return try attachMaterial(from: line, workspaceID: workspaceID, advertiseHost: advertiseHost)
    }

    func shutdown(material: RemoteEngineAttachMaterial, host: SSHHostInfo) async throws {
        _ = try await runSSH(
            host: host,
            remoteCommand: [
                "env",
                "-u", "XDG_RUNTIME_DIR",
                "LD_LIBRARY_PATH=\(shellQuote(libraryPath))",
                "DYLD_LIBRARY_PATH=\(shellQuote(libraryPath))",
                shellQuote(helperPath),
                "shutdown",
                "--session", shellQuote(material.session)
            ].joined(separator: " ")
        )
    }

    func launchCommand(
        workspaceID: String,
        host: SSHHostInfo,
        deployment: RemoteEngineHelperDeployment? = nil,
        advertiseHost: String? = nil,
        tmuxSessionName: String? = nil
    ) -> String {
        let helperPath = deployment?.helperPath ?? helperPath
        let libraryPath = deployment?.libraryPath ?? libraryPath
        let libraryEnvironmentVariable = deployment?.libraryEnvironmentVariable ?? "LD_LIBRARY_PATH"
        let advertiseHost = advertiseHost ?? host.hostname
        var command = [
            "env",
            "-u", "XDG_RUNTIME_DIR",
            "FANTASTTY_REMOTE_ADVERTISE_HOST=\(shellQuote(advertiseHost))",
            "\(libraryEnvironmentVariable)=\(shellQuote(libraryPath))",
            shellQuote(helperPath),
            "launch-or-resume",
            shellQuote(workspaceID),
            "--ttl", shellQuote(ttl),
            "--key-ttl", shellQuote(keyTTL)
        ]
        if let tmuxSessionName, !tmuxSessionName.isEmpty {
            command.append(contentsOf: ["--tmux-session", shellQuote(tmuxSessionName)])
        }
        return command.joined(separator: " ")
    }

    private func runSSH(host: SSHHostInfo, remoteCommand: String) async throws -> String {
        try await processRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: sshArguments(host: host, remoteCommand: remoteCommand)
        )
    }

    private func attachMaterial(from line: String, workspaceID: String, advertiseHost: String) throws -> RemoteEngineAttachMaterial {
        let material = try RemoteEngineBootstrapLine.parse(line, workspaceID: workspaceID)
        guard material.host != advertiseHost else {
            return material
        }
        return RemoteEngineAttachMaterial(
            workspaceID: material.workspaceID,
            host: advertiseHost,
            port: material.port,
            session: material.session,
            key: material.key,
            expires: material.expires,
            helperPID: material.helperPID,
            helperVersion: material.helperVersion,
            helperArch: material.helperArch,
            certSHA256: material.certSHA256,
            alpn: material.alpn
        )
    }

    private func resolvedAdvertiseHost(for host: SSHHostInfo) async throws -> String {
        if let override = advertiseHostOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }

        let output = try await processRunner.run(
            URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: sshConfigArguments(host: host)
        )
        guard let hostname = parseSSHConfigHostname(output) else {
            throw RemoteEngineError.bootstrapFailed("ssh -G did not report hostname for \(host.displayName)")
        }
        if shouldProbeRouteSource(for: hostname),
           let sshServerAddress = try await remoteSSHConnectionServerAddress(for: host) {
            let localNetworks = localIPv4Networks()
            if isOnLocalIPv4Network(sshServerAddress, networks: localNetworks) {
                return sshServerAddress
            }
            if let localSubnetAddress = try await remoteAddressOnLocalIPv4Network(for: host, networks: localNetworks) {
                return localSubnetAddress
            }
            return sshServerAddress
        }
        return hostname
    }

    private static func currentLocalIPv4Networks() -> [RemoteEngineLocalIPv4Network] {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0,
              let firstAddress = interfaceAddresses else {
            return []
        }
        defer { freeifaddrs(interfaceAddresses) }

        var networks: [RemoteEngineLocalIPv4Network] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let currentPointer = pointer {
            defer { pointer = currentPointer.pointee.ifa_next }

            let interface = currentPointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addressPointer = interface.ifa_addr,
                  let netmaskPointer = interface.ifa_netmask,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  netmaskPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            networks.append(RemoteEngineLocalIPv4Network(address: address, netmask: netmask))
        }
        return networks
    }

    private func shouldProbeRouteSource(for hostname: String) -> Bool {
        if isIPv4Address(hostname) || hostname.contains(":") {
            return false
        }
        return !hostname.contains(".")
    }

    private func remoteSSHConnectionServerAddress(for host: SSHHostInfo) async throws -> String? {
        let output = try await runSSH(
            host: host,
            remoteCommand: "printf '%s\\n' \"$SSH_CONNECTION\" | awk 'NF >= 4 { print $3; exit }'"
        )
        return parseIPv4Address(output)
    }

    private func remoteAddressOnLocalIPv4Network(for host: SSHHostInfo, networks: [RemoteEngineLocalIPv4Network]) async throws -> String? {
        guard !networks.isEmpty else { return nil }
        let output = try await runSSH(
            host: host,
            remoteCommand: "hostname -I 2>/dev/null || true"
        )
        for address in parseIPv4Addresses(output) {
            if isOnLocalIPv4Network(address, networks: networks) {
                return address
            }
        }
        return nil
    }

    private func isOnLocalIPv4Network(_ address: String, networks: [RemoteEngineLocalIPv4Network]) -> Bool {
        networks.contains { $0.contains(address) }
    }

    private func parseIPv4Address(_ output: String) -> String? {
        parseIPv4Addresses(output).first
    }

    private func parseIPv4Addresses(_ output: String) -> [String] {
        var addresses: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            for field in line.split(whereSeparator: \.isWhitespace) {
                let candidate = String(field)
                if isIPv4Address(candidate) {
                    addresses.append(candidate)
                }
            }
        }
        return addresses
    }

    private func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = Int(part) else {
                return false
            }
            return (0...255).contains(octet)
        }
    }

    private func parseSSHConfigHostname(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].lowercased() == "hostname" else {
                continue
            }
            let hostname = parts[1].trimmingCharacters(in: .whitespaces)
            if !hostname.isEmpty {
                return hostname
            }
        }
        return nil
    }
}

private struct RemoteEngineHelperManifest: Decodable {
    let version: String
    let artifacts: [String: Artifact]

    struct Artifact: Decodable {
        let os: String
        let arch: String
        let helper: String
        let helperSHA256: String
        let library: String
        let librarySHA256: String

        enum CodingKeys: String, CodingKey {
            case os
            case arch
            case helper
            case helperSHA256 = "helper_sha256"
            case library
            case librarySHA256 = "library_sha256"
        }
    }
}

protocol RemoteEngineTransport {
    func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection
}

struct RemoteEngineInboundMessage: Equatable, Sendable {
    let message: RemoteWorkspaceMessage
    let delivery: RemotePaneDeltaDelivery

    init(_ message: RemoteWorkspaceMessage, delivery: RemotePaneDeltaDelivery = .reliable) {
        self.message = message
        self.delivery = delivery
    }
}

protocol RemoteEngineConnection: AnyObject {
    var messages: AsyncThrowingStream<RemoteEngineInboundMessage, Error> { get }

    func requestKeyframe(workspaceID: String, paneID: Int, reason: RemotePaneGridKeyframeRequestReason) async throws
    func sendKeys(workspaceID: String, paneID: Int, data: Data) async throws
    func resizePane(workspaceID: String, paneID: Int, size: RemoteGridSize) async throws
    func newWindow(workspaceID: String) async throws
    func selectWindow(workspaceID: String, windowID: Int) async throws
    func close()
}

struct RemoteEngineReconnectPolicy: Equatable, Sendable {
    var maxAttempts: Int?
    var delayNanoseconds: UInt64
    var connectTimeoutNanoseconds: UInt64 = 10_000_000_000

    static let forever = RemoteEngineReconnectPolicy(maxAttempts: nil, delayNanoseconds: 1_000_000_000)
    static let once = RemoteEngineReconnectPolicy(maxAttempts: 1, delayNanoseconds: 0)
}

enum RemoteEngineClientState: Equatable, Sendable {
    case idle
    case connecting
    case reconnecting(reason: String?)
    case connected
    case disconnected(reason: String?)
}

struct RemoteEngineFailurePresentation: Equatable, Sendable {
    let code: String
    let userReason: String
    let mode: RemoteEngineFailureMode

    var connectionReason: String {
        "\(userReason) [\(code)]"
    }

    var allowsSSHFallbackBeforeRemotePanes: Bool {
        mode == .fellBackToSSHControlMode || code == "REMOTE_ENGINE_DISCONNECTED"
    }

    static func presenting(_ error: Error) -> RemoteEngineFailurePresentation {
        let reason = error.localizedDescription
        let normalized = reason.lowercased()

        if normalized.contains("udp") ||
            normalized.contains("socket is not connected") ||
            normalized.contains("operation timed out") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_UDP_UNREACHABLE",
                userReason: "Remote engine UDP connection is unreachable.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("checksum mismatch") || normalized.contains("artifact mismatch") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_HELPER_ARTIFACT_MISMATCH",
                userReason: "Remote helper artifact does not match the bundled app version.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("unexpected helper version") || normalized.contains("version mismatch") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_HELPER_VERSION_MISMATCH",
                userReason: "Remote helper version does not match this app.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("permission denied") || normalized.contains("operation not permitted") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_HELPER_PERMISSION",
                userReason: "Remote helper could not be installed with the current account permissions.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("unsupported remote architecture") ||
            normalized.contains("unsupported architecture") ||
            normalized.contains("unsupported host architecture") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_UNSUPPORTED_HOST_ARCH",
                userReason: "Remote engine does not support this host architecture.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("tmux not found") || normalized.contains("missing tmux") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_TMUX_MISSING",
                userReason: "Remote host does not have tmux installed.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("tmux version") && (normalized.contains("too old") || normalized.contains("older than required")) {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_TMUX_TOO_OLD",
                userReason: "Remote host tmux version is too old for the remote engine.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("unsafe registry path") || normalized.contains("unsafe runtime") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_UNSAFE_RUNTIME_DIR",
                userReason: "Remote helper runtime directory failed safety checks.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("missing shell environment") || normalized.contains("shell environment") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_SHELL_ENVIRONMENT",
                userReason: "Remote host shell environment is not usable for helper startup.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("remote engine bootstrap failed") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_HELPER_DEPLOY_FAILED",
                userReason: "Remote helper could not be installed or started.",
                mode: .fellBackToSSHControlMode
            )
        }
        if normalized.contains("certificate pin") || normalized.contains("pin mismatch") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_QUIC_PIN_MISMATCH",
                userReason: "Remote engine certificate pin validation failed.",
                mode: .disconnectedAfterRemotePanes
            )
        }
        if normalized.contains("one-time key") || normalized.contains("attach credentials") || normalized.contains("attach key") {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_ATTACH_REJECTED",
                userReason: "Remote engine rejected the one-time attach credentials.",
                mode: .disconnectedAfterRemotePanes
            )
        }
        if let remoteError = error as? RemoteEngineError,
           case .bootstrapFailed = remoteError {
            return RemoteEngineFailurePresentation(
                code: "REMOTE_ENGINE_HELPER_DEPLOY_FAILED",
                userReason: "Remote helper could not be installed or started.",
                mode: .fellBackToSSHControlMode
            )
        }
        return RemoteEngineFailurePresentation(
            code: "REMOTE_ENGINE_DISCONNECTED",
            userReason: "Remote engine disconnected.",
            mode: .disconnectedAfterRemotePanes
        )
    }
}

enum RemoteEngineFailureMode: Equatable, Sendable {
    case fellBackToSSHControlMode
    case disconnectedAfterRemotePanes
}

final class RemoteEngineClient {
    typealias AttachMaterialProvider = () async throws -> RemoteEngineAttachMaterial
    typealias MessageHandler = @MainActor (RemoteEngineInboundMessage) -> Void
    typealias ReattachHandler = @MainActor () async -> Void
    typealias StateHandler = @MainActor (RemoteEngineClientState) -> Void

    private let workspaceID: String
    private let materialProvider: AttachMaterialProvider
    private let transport: RemoteEngineTransport
    private let reconnectPolicy: RemoteEngineReconnectPolicy
    private let messageHandler: MessageHandler
    private let reattachHandler: ReattachHandler?
    private let stateHandler: StateHandler?

    private let clientStateLock = NSLock()
    private var task: Task<Void, Never>?
    private var connection: RemoteEngineConnection?
    private var outboundTail = Task<Void, Never> {}
    private var outboundDisconnectReason: String?
    private var currentState: RemoteEngineClientState = .idle
    private var currentAttachMaterial: RemoteEngineAttachMaterial?

    var state: RemoteEngineClientState {
        withClientStateLock {
            currentState
        }
    }

    var lastAttachMaterial: RemoteEngineAttachMaterial? {
        withClientStateLock {
            currentAttachMaterial
        }
    }

    init(
        workspaceID: String,
        materialProvider: @escaping AttachMaterialProvider,
        transport: RemoteEngineTransport,
        reconnectPolicy: RemoteEngineReconnectPolicy = .forever,
        messageHandler: @escaping MessageHandler,
        reattachHandler: ReattachHandler? = nil,
        stateHandler: StateHandler? = nil
    ) {
        self.workspaceID = workspaceID
        self.materialProvider = materialProvider
        self.transport = transport
        self.reconnectPolicy = reconnectPolicy
        self.messageHandler = messageHandler
        self.reattachHandler = reattachHandler
        self.stateHandler = stateHandler
    }

    func start() {
        withClientStateLock {
            guard task == nil else { return }
            task = Task { [weak self] in
                await self?.run()
            }
        }
    }

    func stop() {
        let connectionToClose = withClientStateLock {
            task?.cancel()
            task = nil
            resetOutboundQueueLocked()
            outboundDisconnectReason = nil
            let activeConnection = connection
            connection = nil
            currentState = .disconnected(reason: nil)
            return activeConnection
        }
        connectionToClose?.close()
        if let stateHandler {
            Task { @MainActor in
                stateHandler(.disconnected(reason: nil))
            }
        }
    }

    func run() async {
        var attempts = 0
        var hasAttached = false
        var lastDisconnectReason: String?
        while !Task.isCancelled {
            attempts += 1
            if hasAttached {
                await updateState(.reconnecting(reason: lastDisconnectReason))
            } else {
                await updateState(.connecting)
            }

            do {
                let material = try await materialProvider()
                try Task.checkCancellation()
                guard material.workspaceID == workspaceID else {
                    throw RemoteEngineError.wrongWorkspace(material.workspaceID)
                }
                setLastAttachMaterial(material)
                let nextConnection = try await connect(using: material)
                if Task.isCancelled {
                    nextConnection.close()
                    throw CancellationError()
                }
                installConnection(nextConnection)
                var connectionAttached = false
                if hasAttached, let reattachHandler {
                    await reattachHandler()
                    connectionAttached = true
                }
                await updateState(.connected)
                for try await inbound in nextConnection.messages {
                    if !connectionAttached {
                        hasAttached = true
                        connectionAttached = true
                    }
                    await MainActor.run {
                        messageHandler(inbound)
                    }
                }
                let disconnectReason = completeConnection(nextConnection)
                lastDisconnectReason = disconnectReason
                if hasAttached, shouldRetry(after: attempts) {
                    await updateState(.reconnecting(reason: disconnectReason))
                } else {
                    await updateState(.disconnected(reason: disconnectReason))
                }
            } catch is CancellationError {
                let connectionToClose = takeActiveConnection()
                connectionToClose?.close()
                await updateState(.disconnected(reason: nil))
                return
            } catch {
                let connectionToClose = takeActiveConnection()
                connectionToClose?.close()
                let disconnectReason = error.localizedDescription
                lastDisconnectReason = disconnectReason
                if hasAttached, shouldRetry(after: attempts) {
                    await updateState(.reconnecting(reason: disconnectReason))
                } else {
                    await updateState(.disconnected(reason: disconnectReason))
                }
            }

            if !shouldRetry(after: attempts) {
                return
            }
            if reconnectPolicy.delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: reconnectPolicy.delayNanoseconds)
                } catch {
                    await updateState(.disconnected(reason: nil))
                    return
                }
            }
        }
    }

    private func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection {
        let resume = RemoteEngineConnectBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resume.setContinuation(continuation)
                let connectTask = Task {
                    do {
                        let connection = try await transport.connect(using: material)
                        resume.succeed(connection)
                    } catch {
                        resume.fail(error)
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: reconnectPolicy.connectTimeoutNanoseconds)
                        resume.fail(RemoteEngineError.remote("remote engine UDP connection timed out"))
                    } catch is CancellationError {
                    } catch {
                        resume.fail(error)
                    }
                }
                resume.setTasks(connectTask: connectTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            resume.fail(CancellationError())
        }
    }

    @discardableResult
    func requestKeyframe(paneID: Int, reason: RemotePaneGridKeyframeRequestReason) -> Task<Void, Never>? {
        guard let connection = currentConnection() else { return nil }
        let workspaceID = workspaceID
        return enqueueOutbound(connection: connection) {
            try await connection.requestKeyframe(workspaceID: workspaceID, paneID: paneID, reason: reason)
        }
    }

    func sendKeys(paneID: Int, data: Data) {
        guard let connection = currentConnection(), !data.isEmpty else { return }
        let workspaceID = workspaceID
        _ = enqueueOutbound(connection: connection) {
            try await connection.sendKeys(workspaceID: workspaceID, paneID: paneID, data: data)
        }
    }

    func resizePane(paneID: Int, size: RemoteGridSize) {
        guard let connection = currentConnection(), size.columns > 0, size.rows > 0 else { return }
        let workspaceID = workspaceID
        _ = enqueueOutbound(connection: connection) {
            try await connection.resizePane(workspaceID: workspaceID, paneID: paneID, size: size)
        }
    }

    func newWindow() {
        guard let connection = currentConnection() else { return }
        let workspaceID = workspaceID
        _ = enqueueOutbound(connection: connection) {
            try await connection.newWindow(workspaceID: workspaceID)
        }
    }

    func selectWindow(windowID: Int) {
        guard let connection = currentConnection(), windowID >= 0 else { return }
        let workspaceID = workspaceID
        _ = enqueueOutbound(connection: connection) {
            try await connection.selectWindow(workspaceID: workspaceID, windowID: windowID)
        }
    }

    private func enqueueOutbound(
        connection outboundConnection: RemoteEngineConnection,
        _ operation: @escaping () async throws -> Void
    ) -> Task<Void, Never> {
        withClientStateLock {
            let previous = outboundTail
            let next = Task { [weak self] in
                await previous.value
                guard !Task.isCancelled else { return }
                guard let self, self.isCurrentConnection(outboundConnection) else { return }
                do {
                    try await operation()
                } catch {
                    await self.handleOutboundError(from: outboundConnection, error: error)
                }
            }
            outboundTail = next
            return next
        }
    }

    private func resetOutboundQueueLocked() {
        outboundTail.cancel()
        outboundTail = Task<Void, Never> {}
    }

    private func handleOutboundError(from failedConnection: RemoteEngineConnection, error: Error) async {
        let reason = error.localizedDescription
        let shouldClose = withClientStateLock {
            guard connection === failedConnection else { return false }
            outboundDisconnectReason = reason
            connection = nil
            resetOutboundQueueLocked()
            return true
        }
        if shouldClose {
            failedConnection.close()
        }
    }

    private func updateState(_ nextState: RemoteEngineClientState) async {
        let didChange = withClientStateLock {
            guard currentState != nextState else { return false }
            currentState = nextState
            return true
        }
        guard didChange else { return }
        guard let stateHandler else { return }
        await MainActor.run {
            stateHandler(nextState)
        }
    }

    private func setLastAttachMaterial(_ material: RemoteEngineAttachMaterial) {
        withClientStateLock {
            currentAttachMaterial = material
        }
    }

    private func currentConnection() -> RemoteEngineConnection? {
        withClientStateLock {
            connection
        }
    }

    private func isCurrentConnection(_ candidate: RemoteEngineConnection) -> Bool {
        withClientStateLock {
            connection === candidate
        }
    }

    private func installConnection(_ nextConnection: RemoteEngineConnection) {
        withClientStateLock {
            resetOutboundQueueLocked()
            connection = nextConnection
            outboundDisconnectReason = nil
        }
    }

    private func takeActiveConnection() -> RemoteEngineConnection? {
        withClientStateLock {
            let activeConnection = connection
            connection = nil
            resetOutboundQueueLocked()
            outboundDisconnectReason = nil
            return activeConnection
        }
    }

    private func completeConnection(_ expectedConnection: RemoteEngineConnection) -> String? {
        withClientStateLock {
            guard connection == nil || connection === expectedConnection else { return nil }
            if connection === expectedConnection {
                connection = nil
                resetOutboundQueueLocked()
            }
            let reason = outboundDisconnectReason
            outboundDisconnectReason = nil
            return reason
        }
    }

    private func withClientStateLock<T>(_ body: () -> T) -> T {
        clientStateLock.lock()
        defer { clientStateLock.unlock() }
        return body()
    }

    private func shouldRetry(after attempts: Int) -> Bool {
        guard let maxAttempts = reconnectPolicy.maxAttempts else { return true }
        return attempts < maxAttempts
    }
}

struct RemoteEngineMessageLineDecoder {
    private var buffer = Data()
    private let decoder = JSONDecoder()

    mutating func append(_ data: Data) throws -> [RemoteWorkspaceMessage] {
        buffer.append(data)
        return try drainCompleteLines()
    }

    mutating func finish() throws -> [RemoteWorkspaceMessage] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return [try decodeLine(buffer)]
    }

    private mutating func drainCompleteLines() throws -> [RemoteWorkspaceMessage] {
        var messages: [RemoteWorkspaceMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            messages.append(try decodeLine(Data(line)))
        }
        return messages
    }

    private func decodeLine(_ line: Data) throws -> RemoteWorkspaceMessage {
        if let attachError = try? decoder.decode(RemoteEngineAttachError.self, from: line),
           let message = attachError.error {
            throw RemoteEngineError.remote(message)
        }
        return try decoder.decode(RemoteWorkspaceMessage.self, from: line)
    }
}

struct RemoteEngineDatagramDecoder {
    private let decoder = JSONDecoder()

    func decode(_ data: Data) throws -> RemoteWorkspaceMessage {
        .paneDelta(try decoder.decode(RemotePaneDelta.self, from: data))
    }

    func decodeIfValid(_ data: Data) -> RemoteWorkspaceMessage? {
        try? decode(data)
    }
}

struct RemoteEngineReliableFrameDecoder {
    private var decoder = RemoteEngineMessageLineDecoder()
    private(set) var didReceiveEndOfStream = false

    mutating func receive(_ data: Data, endOfStream: Bool) throws -> [RemoteWorkspaceMessage] {
        var messages: [RemoteWorkspaceMessage] = []
        if !data.isEmpty {
            messages.append(contentsOf: try decoder.append(data))
        }
        if endOfStream {
            didReceiveEndOfStream = true
            messages.append(contentsOf: try decoder.finish())
        }
        return messages
    }
}

struct RemoteEngineInboundFrameDecoder {
    private var reliableDecoder = RemoteEngineReliableFrameDecoder()
    private let datagramDecoder = RemoteEngineDatagramDecoder()

    var didReceiveReliableEndOfStream: Bool {
        reliableDecoder.didReceiveEndOfStream
    }

    mutating func receiveReliable(_ data: Data, endOfStream: Bool) throws -> [RemoteEngineInboundMessage] {
        try reliableDecoder.receive(data, endOfStream: endOfStream).map {
            RemoteEngineInboundMessage($0, delivery: .reliable)
        }
    }

    func receiveDatagram(_ data: Data) -> RemoteEngineInboundMessage? {
        guard let message = datagramDecoder.decodeIfValid(data) else { return nil }
        return RemoteEngineInboundMessage(message, delivery: .datagram)
    }
}

enum RemoteEngineQUICStreamFrameContext: Equatable, Sendable {
    case openStream

    var networkContentContext: NWConnection.ContentContext {
        switch self {
        case .openStream:
            return .defaultStream
        }
    }
}

struct RemoteEngineQUICStreamFrame: Equatable, Sendable {
    let content: Data
    let context: RemoteEngineQUICStreamFrameContext
    let isComplete: Bool

    static func open(_ content: Data) -> RemoteEngineQUICStreamFrame {
        RemoteEngineQUICStreamFrame(content: content, context: .openStream, isComplete: false)
    }
}

enum RemoteEngineNWQUICDiagnosticEvent: Equatable, Sendable, CustomStringConvertible {
    case connectStarted(host: String, port: UInt16)
    case connectionState(String)
    case pinValidated(matches: Bool)
    case attachSendStarted
    case attachSendCompleted
    case attachSendFailed(String)
    case controlSendStarted(String)
    case controlSendCompleted(String)
    case controlSendFailed(String, String)
    case reliableReceive(byteCount: Int)
    case datagramReceive(byteCount: Int)
    case decodedMessage(String)

    var description: String {
        switch self {
        case .connectStarted(let host, let port):
            return "connect-started \(host):\(port)"
        case .connectionState(let state):
            return "state \(state)"
        case .pinValidated(let matches):
            return "pin-validated match=\(matches)"
        case .attachSendStarted:
            return "attach-send-started"
        case .attachSendCompleted:
            return "attach-send-completed"
        case .attachSendFailed(let reason):
            return "attach-send-failed \(reason)"
        case .controlSendStarted(let type):
            return "control-send-started \(type)"
        case .controlSendCompleted(let type):
            return "control-send-completed \(type)"
        case .controlSendFailed(let type, let reason):
            return "control-send-failed \(type) \(reason)"
        case .reliableReceive(let byteCount):
            return "reliable-receive bytes=\(byteCount)"
        case .datagramReceive(let byteCount):
            return "datagram-receive bytes=\(byteCount)"
        case .decodedMessage(let kind):
            return "decoded \(kind)"
        }
    }
}

struct RemoteEngineDiagnosticSnapshot: Equatable, Sendable {
    let appVersion: String
    let helperVersion: String
    let helperArch: String
    let hostAlias: String
    let resolvedRemoteAddress: String
    let bootstrapPhase: RemoteEngineDiagnosticBootstrapPhase
    let quicPhase: RemoteEngineDiagnosticQUICPhase
    let reconnectAttempts: Int
    let lastKeyframeGeneration: UInt64?
    let lastDatagramSequence: UInt64?
    let fallbackReason: String?
    let predictiveEchoState: RemoteEngineDiagnosticPredictiveEchoState

    init(
        appVersion: String,
        helperVersion: String,
        helperArch: String,
        hostAlias: String,
        resolvedRemoteAddress: String,
        bootstrapPhase: RemoteEngineDiagnosticBootstrapPhase,
        quicPhase: RemoteEngineDiagnosticQUICPhase,
        reconnectAttempts: Int,
        lastKeyframeGeneration: UInt64?,
        lastDatagramSequence: UInt64?,
        fallbackReason: String?,
        predictiveEchoState: RemoteEngineDiagnosticPredictiveEchoState
    ) {
        self.appVersion = appVersion
        self.helperVersion = helperVersion
        self.helperArch = helperArch
        self.hostAlias = hostAlias
        self.resolvedRemoteAddress = resolvedRemoteAddress
        self.bootstrapPhase = bootstrapPhase
        self.quicPhase = quicPhase
        self.reconnectAttempts = reconnectAttempts
        self.lastKeyframeGeneration = lastKeyframeGeneration
        self.lastDatagramSequence = lastDatagramSequence
        self.fallbackReason = fallbackReason.map(Self.redactedFallbackReason)
        self.predictiveEchoState = predictiveEchoState
    }

    init(
        appVersion: String,
        hostAlias: String,
        material: RemoteEngineAttachMaterial,
        bootstrapPhase: RemoteEngineDiagnosticBootstrapPhase,
        quicPhase: RemoteEngineDiagnosticQUICPhase,
        reconnectAttempts: Int,
        lastKeyframeGeneration: UInt64?,
        lastDatagramSequence: UInt64?,
        fallbackReason: String?,
        predictiveEchoState: RemoteEngineDiagnosticPredictiveEchoState
    ) {
        self.init(
            appVersion: appVersion,
            helperVersion: material.helperVersion,
            helperArch: material.helperArch,
            hostAlias: hostAlias,
            resolvedRemoteAddress: "\(material.host):\(material.port)",
            bootstrapPhase: bootstrapPhase,
            quicPhase: quicPhase,
            reconnectAttempts: reconnectAttempts,
            lastKeyframeGeneration: lastKeyframeGeneration,
            lastDatagramSequence: lastDatagramSequence,
            fallbackReason: fallbackReason,
            predictiveEchoState: predictiveEchoState
        )
    }

    func redactedSupportBundle() -> String {
        [
            "app_version=\(appVersion)",
            "helper_version=\(helperVersion)",
            "helper_arch=\(helperArch)",
            "host_alias=\(hostAlias)",
            "resolved_remote_address=\(resolvedRemoteAddress)",
            "bootstrap_phase=\(bootstrapPhase.rawValue)",
            "quic_phase=\(quicPhase.rawValue)",
            "reconnect_attempts=\(reconnectAttempts)",
            "last_keyframe_generation=\(lastKeyframeGeneration.map(String.init) ?? "none")",
            "last_datagram_sequence=\(lastDatagramSequence.map(String.init) ?? "none")",
            "fallback_reason=\(redactedFallbackReason)",
            "predictive_echo=\(predictiveEchoState.description)",
            "one_time_key=<redacted>",
            "certificate_pin=<redacted>",
            "raw_typed_input=<redacted>",
            "pane_contents=<redacted>",
            "shell_command=<redacted>",
            "local_path=<redacted>"
        ].joined(separator: "\n")
    }

    private var redactedFallbackReason: String {
        fallbackReason ?? "none"
    }

    private static func redactedFallbackReason(_ fallbackReason: String) -> String {
        return RemoteEngineFailurePresentation
            .presenting(RemoteEngineError.remote(fallbackReason))
            .connectionReason
    }
}

enum RemoteEngineDiagnosticBootstrapPhase: String, Equatable, Sendable {
    case notStarted
    case resolvingHost
    case helperDeploy
    case launchingHelper
    case attached
    case failed
}

enum RemoteEngineDiagnosticQUICPhase: String, Equatable, Sendable {
    case notStarted
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed
}

enum RemoteEngineDiagnosticPredictiveEchoState: Equatable, Sendable, CustomStringConvertible {
    case disabled
    case enabled
    case suppressed(reason: RemoteEngineDiagnosticPredictionSuppressionReason)
    case rolledBack(reason: RemoteEngineDiagnosticPredictionRollbackReason)

    var description: String {
        switch self {
        case .disabled:
            return "disabled"
        case .enabled:
            return "enabled"
        case .suppressed(let reason):
            return "suppressed:\(reason.rawValue)"
        case .rolledBack(let reason):
            return "rolledBack:\(reason.rawValue)"
        }
    }
}

enum RemoteEngineDiagnosticPredictionSuppressionReason: String, Equatable, Sendable {
    case echoNotProven
    case echoOffOrNoOutput
    case paste
    case ime
    case escapeSequence
    case mouse
    case alternateScreen
    case unsupportedState
    case focusLost
    case reattach
    case disabledByUser
}

enum RemoteEngineDiagnosticPredictionRollbackReason: String, Equatable, Sendable {
    case authoritativeMismatch
    case keyframeChanged
    case resize
    case cursorChanged
}

enum RemoteEngineQUICConnectionMode: Equatable, Sendable {
    case typedNetworkConnection
    case legacyNWConnection
}

final class RemoteEngineNWQUICTransport: RemoteEngineTransport {
    private let diagnostics: @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void

    init(diagnostics: @escaping @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void = { _ in }) {
        self.diagnostics = diagnostics
    }

    static func preferredConnectionMode() -> RemoteEngineQUICConnectionMode {
        if #available(macOS 26.0, *) {
            return .typedNetworkConnection
        }
        return .legacyNWConnection
    }

    func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection {
        switch Self.preferredConnectionMode() {
        case .typedNetworkConnection:
            if #available(macOS 26.0, *) {
                let connection = RemoteEngineTypedQUICConnection(material: material, diagnostics: diagnostics)
                try await connection.start()
                return connection
            }
            fallthrough
        case .legacyNWConnection:
            let connection = RemoteEngineNWQUICConnection(material: material, diagnostics: diagnostics)
            try await connection.start()
            return connection
        }
    }
}

struct RemoteEngineQUICSecurityConfiguration: Equatable, Sendable {
    let alpn: String
    let certificateSPKISHA256: String
    let maxDatagramFrameSize: Int

    init(material: RemoteEngineAttachMaterial) {
        alpn = material.alpn
        certificateSPKISHA256 = material.certSHA256
        maxDatagramFrameSize = 1200
    }

    func validate(trust: sec_trust_t) -> Bool {
        RemoteEnginePinState(expected: certificateSPKISHA256).validate(trust: trust)
    }
}

final class RemoteEnginePinValidationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var hasPinMismatch = false

    func record(matches: Bool) {
        guard !matches else { return }
        lock.lock()
        hasPinMismatch = true
        lock.unlock()
    }

    func errorAfterValidationFailure(_ error: Error) -> Error {
        lock.lock()
        let hasPinMismatch = hasPinMismatch
        lock.unlock()
        guard hasPinMismatch else { return error }
        return RemoteEngineError.remote("certificate pin mismatch")
    }
}

private final class RemoteEngineInboundMessageSink {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<RemoteEngineInboundMessage, Error>.Continuation?

    func setContinuation(_ continuation: AsyncThrowingStream<RemoteEngineInboundMessage, Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ message: RemoteWorkspaceMessage, delivery: RemotePaneDeltaDelivery) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(RemoteEngineInboundMessage(message, delivery: delivery))
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    func finish(throwing error: Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }
}

@available(macOS 26.0, *)
private final class RemoteEngineTypedQUICConnection: RemoteEngineConnection {
    let messages: AsyncThrowingStream<RemoteEngineInboundMessage, Error>

    private static let channelRetainer = RemoteEngineBoundedObjectRetainer(maximumCount: 256)

    private let material: RemoteEngineAttachMaterial
    private let diagnostics: @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void
    private let pinValidationTracker = RemoteEnginePinValidationTracker()
    private let sink = RemoteEngineInboundMessageSink()
    private let lock = NSLock()
    private var connection: NetworkConnection<QUIC>?
    private var stream: QUIC.Stream<QUICStream>?
    private var datagrams: QUIC.Datagrams<QUICDatagram>?
    private var receiveTasks: [Task<Void, Never>] = []

    init(material: RemoteEngineAttachMaterial, diagnostics: @escaping @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void) {
        self.material = material
        self.diagnostics = diagnostics
        let sink = sink
        messages = AsyncThrowingStream { continuation in
            sink.setContinuation(continuation)
        }
    }

    func start() async throws {
        try Task.checkCancellation()
        let connection = Self.makeConnection(
            material: material,
            pinValidationTracker: pinValidationTracker,
            diagnostics: diagnostics
        )
        setConnection(connection)
        try await waitUntilReady(connection)
        try Task.checkCancellation()
        let stream = try await connection.openStream()
        let datagrams = try await connection.datagrams
        setChannels(connection: connection, stream: stream, datagrams: datagrams)
        startReceiving(stream: stream, datagrams: datagrams)
        try await sendAttachRequest(on: stream)
    }

    func requestKeyframe(workspaceID: String, paneID: Int, reason: RemotePaneGridKeyframeRequestReason) async throws {
        let request = RemoteEngineKeyframeRequest(workspaceID: workspaceID, paneID: paneID, reason: reason)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func sendKeys(workspaceID: String, paneID: Int, data: Data) async throws {
        for chunk in data.remoteEngineChunks(maxBytes: 2048) {
            let request = RemoteEngineInputRequest(workspaceID: workspaceID, paneID: paneID, data: chunk)
            let encoded = try JSONEncoder().encode(request) + Data([0x0A])
            try await sendControlRequest(encoded, type: request.type)
        }
    }

    func resizePane(workspaceID: String, paneID: Int, size: RemoteGridSize) async throws {
        let request = RemoteEngineResizeRequest(workspaceID: workspaceID, paneID: paneID, size: size)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func newWindow(workspaceID: String) async throws {
        let request = RemoteEngineNewWindowRequest(workspaceID: workspaceID)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func selectWindow(workspaceID: String, windowID: Int) async throws {
        let request = RemoteEngineSelectWindowRequest(workspaceID: workspaceID, windowID: windowID)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func close() {
        let tasks = withLock {
            let tasks = receiveTasks
            receiveTasks = []
            stream = nil
            datagrams = nil
            connection = nil
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
        sink.finish()
    }

    private static func makeConnection(
        material: RemoteEngineAttachMaterial,
        pinValidationTracker: RemoteEnginePinValidationTracker,
        diagnostics: @escaping @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void
    ) -> NetworkConnection<QUIC> {
        let security = RemoteEngineQUICSecurityConfiguration(material: material)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(material.host),
            port: NWEndpoint.Port(rawValue: material.port)!
        )
        let builder = NWParametersBuilder.parameters {
            QUIC(alpn: [security.alpn])
                .maxDatagramFrameSize(security.maxDatagramFrameSize)
                .tls.certificateValidator { _, trust in
                    let matches = security.validate(trust: trust)
                    pinValidationTracker.record(matches: matches)
                    diagnostics(.pinValidated(matches: matches))
                    return matches
                }
                .tls.peerAuthentication(.required)
        }
        return NetworkConnection(to: endpoint, using: builder)
    }

    private func waitUntilReady(_ connection: NetworkConnection<QUIC>) async throws {
        let resume = RemoteEngineResumeBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resume.setContinuation(continuation)
                diagnostics(.connectStarted(host: material.host, port: material.port))
                connection.onStateUpdate { _, state in
                    self.diagnostics(.connectionState(String(describing: state)))
                    switch state {
                    case .ready:
                        resume.succeed()
                    case .waiting(let error):
                        resume.fail(RemoteEngineError.remote(
                            "remote engine UDP connection is unreachable: \(error.localizedDescription)"
                        ))
                    case .failed(let error):
                        resume.fail(self.pinValidationTracker.errorAfterValidationFailure(error))
                    case .cancelled:
                        resume.fail(CancellationError())
                    default:
                        break
                    }
                }
                _ = connection.start()
                if Task.isCancelled {
                    resume.fail(CancellationError())
                }
            }
        } onCancel: {
            resume.fail(CancellationError())
        }
    }

    private func sendAttachRequest(on stream: QUIC.Stream<QUICStream>) async throws {
        let request = RemoteEngineAttachRequest(session: material.session, key: material.key)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        diagnostics(.attachSendStarted)
        do {
            try await stream.send(encoded)
            diagnostics(.attachSendCompleted)
        } catch {
            diagnostics(.attachSendFailed(error.localizedDescription))
            throw error
        }
    }

    private func sendControlRequest(_ data: Data, type: String) async throws {
        guard let stream = currentStream() else {
            throw RemoteEngineError.remote("remote QUIC stream is not attached")
        }
        diagnostics(.controlSendStarted(type))
        do {
            try await stream.send(data)
            diagnostics(.controlSendCompleted(type))
        } catch {
            diagnostics(.controlSendFailed(type, error.localizedDescription))
            throw error
        }
    }

    private func startReceiving(stream: QUIC.Stream<QUICStream>, datagrams: QUIC.Datagrams<QUICDatagram>) {
        let reliableTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveReliable(from: stream)
        }
        let datagramTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveDatagrams(from: datagrams)
        }
        withLock {
            receiveTasks.append(reliableTask)
            receiveTasks.append(datagramTask)
        }
    }

    private func receiveReliable(from stream: QUIC.Stream<QUICStream>) async {
        var decoder = RemoteEngineInboundFrameDecoder()
        do {
            while !Task.isCancelled {
                let message = try await stream.receive(atLeast: 1, atMost: 64 * 1024)
                if !message.content.isEmpty {
                    diagnostics(.reliableReceive(byteCount: message.content.count))
                    let decoded = try decoder.receiveReliable(message.content, endOfStream: false)
                    for inbound in decoded {
                        yield(inbound)
                    }
                }
                if message.metadata.endOfStream {
                    let decoded = try decoder.receiveReliable(Data(), endOfStream: true)
                    for inbound in decoded {
                        yield(inbound)
                    }
                    sink.finish()
                    return
                }
            }
        } catch {
            sink.finish(throwing: error)
        }
    }

    private func receiveDatagrams(from datagrams: QUIC.Datagrams<QUICDatagram>) async {
        let decoder = RemoteEngineDatagramDecoder()
        do {
            while !Task.isCancelled {
                let message = try await datagrams.receive()
                guard !message.content.isEmpty,
                      let workspaceMessage = decoder.decodeIfValid(message.content) else {
                    continue
                }
                let inbound = RemoteEngineInboundMessage(workspaceMessage, delivery: .datagram)
                diagnostics(.datagramReceive(byteCount: message.content.count))
                yield(inbound)
            }
        } catch {
            if !Task.isCancelled {
                sink.finish(throwing: error)
            }
        }
    }

    private func yield(_ inbound: RemoteEngineInboundMessage) {
        diagnostics(.decodedMessage(RemoteEngineNWQUICConnection.diagnosticKind(of: inbound.message)))
        sink.yield(inbound.message, delivery: inbound.delivery)
    }

    private func setConnection(_ connection: NetworkConnection<QUIC>) {
        withLock {
            self.connection = connection
        }
    }

    private func setChannels(
        connection: NetworkConnection<QUIC>,
        stream: QUIC.Stream<QUICStream>,
        datagrams: QUIC.Datagrams<QUICDatagram>
    ) {
        withLock {
            self.stream = stream
            self.datagrams = datagrams
        }
        Self.channelRetainer.retain(
            RemoteEngineTypedQUICChannelSet(
                connection: connection,
                stream: stream,
                datagrams: datagrams
            )
        )
    }

    private func currentStream() -> QUIC.Stream<QUICStream>? {
        withLock { stream }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class RemoteEngineTypedQUICChannelSet {
    let connection: NetworkConnection<QUIC>
    let stream: QUIC.Stream<QUICStream>
    let datagrams: QUIC.Datagrams<QUICDatagram>

    init(
        connection: NetworkConnection<QUIC>,
        stream: QUIC.Stream<QUICStream>,
        datagrams: QUIC.Datagrams<QUICDatagram>
    ) {
        self.connection = connection
        self.stream = stream
        self.datagrams = datagrams
    }
}

final class RemoteEngineBoundedObjectRetainer {
    private let lock = NSLock()
    private let maximumCount: Int
    private var objects: [AnyObject] = []

    init(maximumCount: Int) {
        self.maximumCount = max(0, maximumCount)
    }

    var retainedObjectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return objects.count
    }

    func retain(_ object: AnyObject) {
        lock.lock()
        objects.append(object)
        if objects.count > maximumCount {
            objects.removeFirst(objects.count - maximumCount)
        }
        lock.unlock()
    }
}

private final class RemoteEngineNWQUICConnection: RemoteEngineConnection {
    let messages: AsyncThrowingStream<RemoteEngineInboundMessage, Error>

    private let material: RemoteEngineAttachMaterial
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let diagnostics: @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void
    private let pinValidationTracker: RemoteEnginePinValidationTracker

    init(material: RemoteEngineAttachMaterial, diagnostics: @escaping @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void) {
        self.material = material
        self.diagnostics = diagnostics
        let pinValidationTracker = RemoteEnginePinValidationTracker()
        self.pinValidationTracker = pinValidationTracker
        queue = DispatchQueue(label: "fantastty.remote-engine.quic.\(material.workspaceID)")
        connection = NWConnection(
            host: NWEndpoint.Host(material.host),
            port: NWEndpoint.Port(rawValue: material.port)!,
            using: Self.parameters(
                for: material,
                queue: queue,
                pinValidationTracker: pinValidationTracker,
                diagnostics: diagnostics
            )
        )

        let connection = connection
        messages = AsyncThrowingStream { continuation in
            var decoder = RemoteEngineInboundFrameDecoder()
            let decoderLock = NSLock()

            func yieldMessage(_ message: RemoteEngineInboundMessage) {
                diagnostics(.decodedMessage(Self.diagnosticKind(of: message.message)))
                continuation.yield(message)
            }

            func yieldReliableData(_ data: Data) throws {
                decoderLock.lock()
                let messages: [RemoteEngineInboundMessage]
                do {
                    messages = try decoder.receiveReliable(data, endOfStream: false)
                    decoderLock.unlock()
                } catch {
                    decoderLock.unlock()
                    throw error
                }
                for message in messages {
                    yieldMessage(message)
                }
            }

            func finishReliableData() throws {
                decoderLock.lock()
                let messages: [RemoteEngineInboundMessage]
                do {
                    messages = try decoder.receiveReliable(Data(), endOfStream: true)
                    decoderLock.unlock()
                } catch {
                    decoderLock.unlock()
                    throw error
                }
                for message in messages {
                    yieldMessage(message)
                }
            }

            func yieldDatagramData(_ data: Data) {
                decoderLock.lock()
                let message = decoder.receiveDatagram(data)
                decoderLock.unlock()
                guard let message else { return }
                diagnostics(.datagramReceive(byteCount: data.count))
                yieldMessage(message)
            }

            func receiveNextDatagram() {
                connection.receiveMessage { data, _, _, error in
                    guard error == nil else { return }
                    if let data, !data.isEmpty {
                        yieldDatagramData(data)
                    }
                    receiveNextDatagram()
                }
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        continuation.finish(throwing: error)
                        return
                    }
                    do {
                        if let data, !data.isEmpty {
                            diagnostics(.reliableReceive(byteCount: data.count))
                            try yieldReliableData(data)
                        }
                        if isComplete {
                            try finishReliableData()
                            if data == nil || data?.isEmpty == true {
                                continuation.finish()
                                return
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    receiveNext()
                }
            }

            continuation.onTermination = { _ in
                connection.cancel()
            }
            receiveNext()
            receiveNextDatagram()
        }
    }

    fileprivate static func diagnosticKind(of message: RemoteWorkspaceMessage) -> String {
        switch message {
        case .workspaceSnapshot:
            return "workspaceSnapshot"
        case .paneKeyframe:
            return "paneKeyframe"
        case .paneDelta:
            return "paneDelta"
        case .unsupportedPaneState:
            return "unsupportedPaneState"
        }
    }

    func start() async throws {
        try Task.checkCancellation()
        try await waitUntilReady()
        try Task.checkCancellation()
        try await sendAttachRequest()
    }

    func requestKeyframe(workspaceID: String, paneID: Int, reason: RemotePaneGridKeyframeRequestReason) async throws {
        let request = RemoteEngineKeyframeRequest(workspaceID: workspaceID, paneID: paneID, reason: reason)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func sendKeys(workspaceID: String, paneID: Int, data: Data) async throws {
        for chunk in data.remoteEngineChunks(maxBytes: 2048) {
            let request = RemoteEngineInputRequest(workspaceID: workspaceID, paneID: paneID, data: chunk)
            let encoded = try JSONEncoder().encode(request) + Data([0x0A])
            try await sendControlRequest(encoded, type: request.type)
        }
    }

    func resizePane(workspaceID: String, paneID: Int, size: RemoteGridSize) async throws {
        let request = RemoteEngineResizeRequest(workspaceID: workspaceID, paneID: paneID, size: size)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func newWindow(workspaceID: String) async throws {
        let request = RemoteEngineNewWindowRequest(workspaceID: workspaceID)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func selectWindow(workspaceID: String, windowID: Int) async throws {
        let request = RemoteEngineSelectWindowRequest(workspaceID: workspaceID, windowID: windowID)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        try await sendControlRequest(encoded, type: request.type)
    }

    func close() {
        connection.cancel()
    }

    private func waitUntilReady() async throws {
        let resume = RemoteEngineResumeBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resume.setContinuation(continuation)
                diagnostics(.connectStarted(host: material.host, port: material.port))
                connection.stateUpdateHandler = { state in
                    self.diagnostics(.connectionState(String(describing: state)))
                    switch state {
                    case .ready:
                        resume.succeed()
                    case .waiting(let error):
                        resume.fail(RemoteEngineError.remote(
                            "remote engine UDP connection is unreachable: \(error.localizedDescription)"
                        ))
                    case .failed(let error):
                        resume.fail(self.pinValidationTracker.errorAfterValidationFailure(error))
                    case .cancelled:
                        resume.fail(CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                if Task.isCancelled {
                    connection.cancel()
                    resume.fail(CancellationError())
                }
            }
        } onCancel: {
            connection.cancel()
            resume.fail(CancellationError())
        }
    }

    private func sendAttachRequest() async throws {
        let request = RemoteEngineAttachRequest(session: material.session, key: material.key)
        let encoded = try JSONEncoder().encode(request) + Data([0x0A])
        diagnostics(.attachSendStarted)
        do {
            try await send(RemoteEngineQUICStreamFrame.open(encoded))
            diagnostics(.attachSendCompleted)
        } catch {
            diagnostics(.attachSendFailed(error.localizedDescription))
            throw error
        }
    }

    private func sendControlRequest(_ data: Data, type: String) async throws {
        diagnostics(.controlSendStarted(type))
        do {
            try await send(RemoteEngineQUICStreamFrame.open(data))
            diagnostics(.controlSendCompleted(type))
        } catch {
            diagnostics(.controlSendFailed(type, error.localizedDescription))
            throw error
        }
    }

    private func send(_ frame: RemoteEngineQUICStreamFrame) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame.content, contentContext: frame.context.networkContentContext, isComplete: frame.isComplete, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func parameters(
        for material: RemoteEngineAttachMaterial,
        queue: DispatchQueue,
        pinValidationTracker: RemoteEnginePinValidationTracker,
        diagnostics: @escaping @Sendable (RemoteEngineNWQUICDiagnosticEvent) -> Void
    ) -> NWParameters {
        let security = RemoteEngineQUICSecurityConfiguration(material: material)
        let options = NWProtocolQUIC.Options(alpn: [security.alpn])
        options.direction = .bidirectional
        options.maxDatagramFrameSize = security.maxDatagramFrameSize
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let matches = security.validate(trust: trust)
            pinValidationTracker.record(matches: matches)
            diagnostics(.pinValidated(matches: matches))
            complete(matches)
        }, queue)
        return NWParameters(quic: options)
    }
}
private struct RemoteEngineAttachRequest: Codable {
    let session: String
    let key: String
}

private struct RemoteEngineAttachError: Decodable {
    let error: String?
}

private struct RemoteEngineKeyframeRequest: Encodable {
    let type = "requestKeyframe"
    let workspaceID: String
    let paneID: Int
    let reason: String

    init(workspaceID: String, paneID: Int, reason: RemotePaneGridKeyframeRequestReason) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.reason = String(describing: reason)
    }
}

private struct RemoteEngineInputRequest: Encodable {
    let type = "sendKeys"
    let workspaceID: String
    let paneID: Int
    let data: Data
}

private struct RemoteEngineResizeRequest: Encodable {
    let type = "resizePane"
    let workspaceID: String
    let paneID: Int
    let columns: Int
    let rows: Int

    init(workspaceID: String, paneID: Int, size: RemoteGridSize) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        columns = size.columns
        rows = size.rows
    }
}

private struct RemoteEngineNewWindowRequest: Encodable {
    let type = "newWindow"
    let workspaceID: String
}

private struct RemoteEngineSelectWindowRequest: Encodable {
    let type = "selectWindow"
    let workspaceID: String
    let windowID: Int
}

private final class RemoteEngineResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init() {}

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func succeed() {
        resume(.success(()))
    }

    func fail(_ error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        continuation.resume(with: result)
    }
}

private final class RemoteEngineConnectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteEngineConnection, Error>?
    private var connectTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    func setContinuation(_ continuation: CheckedContinuation<RemoteEngineConnection, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(connectTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            connectTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.connectTask = connectTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func succeed(_ connection: RemoteEngineConnection) {
        if !resume(.success(connection)) {
            connection.close()
        }
    }

    func fail(_ error: Error) {
        _ = resume(.failure(error))
    }

    private func resume(_ result: Result<RemoteEngineConnection, Error>) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        let connectTask = connectTask
        self.connectTask = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        connectTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
        return true
    }
}

private final class RemoteEnginePinState {
    private let expected: String

    init(expected: String) {
        self.expected = expected
    }

    func validate(trust: sec_trust_t) -> Bool {
        certificateSPKISHA256(trust: trust) == expected
    }
}

enum RemoteEngineError: Error, LocalizedError, Equatable {
    case invalidBootstrapLine(String)
    case bootstrapFailed(String)
    case remote(String)
    case wrongWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .invalidBootstrapLine(let reason):
            return "invalid remote engine bootstrap line: \(reason)"
        case .bootstrapFailed(let reason):
            return "remote engine bootstrap failed: \(reason)"
        case .remote(let reason):
            return "remote engine error: \(reason)"
        case .wrongWorkspace(let workspaceID):
            return "remote engine attached wrong workspace: \(workspaceID)"
        }
    }
}

private extension ISO8601DateFormatter {
    static let fantasttyRemoteEngine: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}

private func sshConfigArguments(host: SSHHostInfo) -> [String] {
    var arguments = ["-G"] + remoteEngineSSHArguments()
    if let port = host.port, port != 22 {
        arguments.append(contentsOf: ["-p", "\(port)"])
    }
    arguments.append("--")
    arguments.append(sshTarget(host))
    return arguments
}

private func sshArguments(host: SSHHostInfo, remoteCommand: String) -> [String] {
    var arguments = remoteEngineSSHArguments()
    if let port = host.port, port != 22 {
        arguments.append(contentsOf: ["-p", "\(port)"])
    }
    arguments.append("--")
    arguments.append(sshTarget(host))
    arguments.append(remoteCommand)
    return arguments
}

private func scpArguments(host: SSHHostInfo, localURL: URL, remotePath: String) -> [String] {
    var arguments = remoteEngineSSHArguments()
    if let port = host.port, port != 22 {
        arguments.append(contentsOf: ["-P", "\(port)"])
    }
    arguments.append("--")
    arguments.append(localURL.path)
    arguments.append("\(scpTarget(host)):\(remotePath)")
    return arguments
}

private func remoteEngineSSHArguments() -> [String] {
    [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1"
    ] + fantasttySSHConnectionArguments
}

private func sshTarget(_ host: SSHHostInfo) -> String {
    var target = ""
    if let user = host.user {
        target += "\(user)@"
    }
    target += host.hostname
    return target
}

private func scpTarget(_ host: SSHHostInfo) -> String {
    var target = ""
    if let user = host.user {
        target += "\(user)@"
    }
    if host.hostname.contains(":"),
       !(host.hostname.hasPrefix("[") && host.hostname.hasSuffix("]")) {
        target += "[\(host.hostname)]"
    } else {
        target += host.hostname
    }
    return target
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    func remoteEngineChunks(maxBytes: Int) -> [Data] {
        guard maxBytes > 0, count > maxBytes else { return [self] }
        var chunks: [Data] = []
        var offset = startIndex
        while offset < endIndex {
            let next = index(offset, offsetBy: maxBytes, limitedBy: endIndex) ?? endIndex
            chunks.append(Data(self[offset..<next]))
            offset = next
        }
        return chunks
    }
}

private func certificateSPKISHA256(trust: sec_trust_t) -> String? {
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
          let certificate = chain.first,
          let publicKey = SecCertificateCopyKey(certificate) else {
        return nil
    }

    var error: Unmanaged<CFError>?
    guard let rawPublicKey = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
          rawPublicKey.count == 65,
          rawPublicKey.first == 0x04 else {
        return nil
    }

    var spki = Data([
        0x30, 0x59,
        0x30, 0x13,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00,
    ])
    spki.append(rawPublicKey)
    return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
}
