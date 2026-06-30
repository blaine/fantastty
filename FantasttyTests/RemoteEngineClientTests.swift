import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
private enum RemoteEngineClientTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

private enum RemoteEngineClientFixtureValues {
    static let sessionID = String(repeating: "7", count: 64)
    static let duplicateSessionID = String(repeating: "8", count: 64)
    static let attachKey = String(repeating: "a", count: 64)
    static let certificatePin = String(repeating: "c", count: 64)
}

final class RemoteEngineClientTests: XCTestCase {
    func testRemoteEngineObjectRetainerEvictsOldestObjectsWhenBounded() {
        let retainer = RemoteEngineBoundedObjectRetainer(maximumCount: 2)
        weak var oldestObject: NSObject?
        let retainedObject = NSObject()
        let newestObject = NSObject()

        autoreleasepool {
            let oldest = NSObject()
            oldestObject = oldest
            retainer.retain(oldest)
            retainer.retain(retainedObject)
            retainer.retain(newestObject)
        }

        XCTAssertNil(oldestObject)
        XCTAssertEqual(retainer.retainedObjectCount, 2)
    }

    func testBootstrapLineParsesQUICAttachMaterial() throws {
        let material = try RemoteEngineBootstrapLine.parse(
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=84dfd78 arch=amd64 quic_addr=remote.example.invalid:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """,
            workspaceID: "workspace-1"
        )

        XCTAssertEqual(material.workspaceID, "workspace-1")
        XCTAssertEqual(material.host, "remote.example.invalid")
        XCTAssertEqual(material.port, 33324)
        XCTAssertEqual(material.session, "\(RemoteEngineClientFixtureValues.sessionID)")
        XCTAssertEqual(material.key, "\(RemoteEngineClientFixtureValues.attachKey)")
        XCTAssertEqual(material.helperPID, 3_108_381)
        XCTAssertEqual(material.helperVersion, "84dfd78")
        XCTAssertEqual(material.helperArch, "amd64")
        XCTAssertEqual(material.certSHA256, "\(RemoteEngineClientFixtureValues.certificatePin)")
        XCTAssertEqual(material.alpn, "fantastty-remote-engine-v1")
    }

    func testBootstrapLineRejectsMissingQUICCertificatePin() {
        XCTAssertThrowsError(try RemoteEngineBootstrapLine.parse(
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=84dfd78 arch=amd64 quic_addr=remote.example.invalid:33324 quic_alpn=fantastty-remote-engine-v1
            """,
            workspaceID: "workspace-1"
        ))
    }

    func testBootstrapLineRejectsDuplicateFieldsWithoutTrapping() {
        XCTAssertThrowsError(try RemoteEngineBootstrapLine.parse(
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) session=\(RemoteEngineClientFixtureValues.duplicateSessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=84dfd78 arch=amd64 quic_addr=remote.example.invalid:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """,
            workspaceID: "workspace-1"
        )) { error in
            XCTAssertEqual(error as? RemoteEngineError, .invalidBootstrapLine("duplicate field session"))
        }
    }

    func testSSHBootstrapperLaunchCommandSetsRemoteHelperLibraryPath() {
        let bootstrapper = SSHRemoteEngineBootstrapper()

        let command = bootstrapper.launchCommand(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        XCTAssertTrue(command.contains("LD_LIBRARY_PATH='.cache/fantastty/remote-engine/lib'"))
        XCTAssertTrue(command.contains("launch-or-resume"))
    }

    func testSSHBootstrapperShutdownSetsLinuxAndDarwinHelperLibraryPaths() async throws {
        var bootstrapper = SSHRemoteEngineBootstrapper()
        let runner = RecordingRemoteEngineProcessRunner(outputs: [""])
        bootstrapper.processRunner = runner

        try await bootstrapper.shutdown(
            material: RemoteEngineAttachMaterial.fixture(workspaceID: "workspace-1"),
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        let command = try XCTUnwrap(runner.calls.first?.arguments.last)
        XCTAssertTrue(command.contains("LD_LIBRARY_PATH='.cache/fantastty/remote-engine/lib'"))
        XCTAssertTrue(command.contains("DYLD_LIBRARY_PATH='.cache/fantastty/remote-engine/lib'"))
        XCTAssertTrue(command.contains("shutdown --session '\(RemoteEngineClientFixtureValues.sessionID)'"))
    }

    func testSSHBootstrapperLaunchCommandRunsDeployedHelperDirectlyAsSSHUser() {
        var bootstrapper = SSHRemoteEngineBootstrapper()
        bootstrapper.ttl = "4h"
        bootstrapper.keyTTL = "15s"

        let command = bootstrapper.launchCommand(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil),
            deployment: RemoteEngineHelperDeployment(
                helperPath: ".cache/fantastty/remote-engine/fantastty-helper",
                libraryPath: ".cache/fantastty/remote-engine/lib",
                libraryEnvironmentVariable: "LD_LIBRARY_PATH"
            ),
            advertiseHost: "192.0.2.10"
        )

        assertRemoteEngineLaunchCommand(
            command,
            workspaceID: "workspace-1",
            ttl: "4h",
            keyTTL: "15s",
            advertiseHost: "192.0.2.10"
        )
    }

    func testBundledArtifactStoreRejectsHelperChecksumMismatch() throws {
        let fixture = try makeRemoteEngineArtifactFixture(helperSHAOverride: String(repeating: "0", count: 64))
        let store = RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL)

        XCTAssertThrowsError(try store.artifact(forRemoteUname: "x86_64")) { error in
            XCTAssertEqual(
                error as? RemoteEngineError,
                .bootstrapFailed("remote helper artifact checksum mismatch for linux-amd64")
            )
        }
    }

    func testBundledArtifactStoreRejectsLibraryChecksumMismatch() throws {
        let fixture = try makeRemoteEngineArtifactFixture(librarySHAOverride: String(repeating: "0", count: 64))
        let store = RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL)

        XCTAssertThrowsError(try store.artifact(forRemoteUname: "x86_64")) { error in
            XCTAssertEqual(
                error as? RemoteEngineError,
                .bootstrapFailed("remote helper library checksum mismatch for linux-amd64")
            )
        }
    }

    func testBundledArtifactStoreRejectsManifestArchitectureMismatch() throws {
        let fixture = try makeRemoteEngineArtifactFixture(manifestArch: "arm64")
        let store = RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL)

        XCTAssertThrowsError(try store.artifact(forRemoteUname: "x86_64")) { error in
            XCTAssertEqual(
                error as? RemoteEngineError,
                .bootstrapFailed("remote helper artifact linux-amd64 declares arch arm64, expected amd64")
            )
        }
    }

    func testBundledArtifactStoreSelectsDarwinARM64Artifact() throws {
        let fixture = try makeRemoteEngineArtifactFixture(
            label: "darwin-arm64",
            osName: "darwin",
            libraryName: "libghostty-vt.dylib",
            manifestArch: "arm64"
        )
        let store = RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL)

        let artifact = try store.artifact(remoteSystem: "Darwin\n", remoteMachine: "arm64\n")

        XCTAssertEqual(artifact.label, "darwin-arm64")
        XCTAssertEqual(artifact.os, "darwin")
        XCTAssertEqual(artifact.arch, "arm64")
        XCTAssertEqual(artifact.libraryName, "libghostty-vt.dylib")
    }

    func testHelperDeployerRejectsRemoteHelperVersionMismatch() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            "Linux\nx86_64\n",
            "",
            "",
            "fantastty-helper version=def456 arch=amd64\n"
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )

        do {
            _ = try await deployer.ensureDeployed(
                host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
            )
            XCTFail("Expected helper version mismatch to reject deployment")
        } catch {
            XCTAssertEqual(
                error as? RemoteEngineError,
                .bootstrapFailed("unexpected helper version line: fantastty-helper version=def456 arch=amd64")
            )
        }
    }

    func testHelperDeployerUploadsWhenRemoteArtifactsMismatch() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("Linux\nx86_64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact checksum mismatch")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=amd64\n")
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )

        _ = try await deployer.ensureDeployed(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        let scpCalls = runner.calls.filter { $0.executable == "/usr/bin/scp" }
        XCTAssertEqual(scpCalls.count, 2)
        XCTAssertTrue(scpCalls[0].arguments.contains(fixture.libraryURL.path))
        XCTAssertTrue(scpCalls[1].arguments.contains(fixture.helperURL.path))
    }

    func testHelperDeployerUsesBoundedIndependentSSHConnections() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("Linux\nx86_64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact checksum mismatch")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=amd64\n")
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )

        _ = try await deployer.ensureDeployed(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        for call in runner.calls where call.executable == "/usr/bin/ssh" || call.executable == "/usr/bin/scp" {
            assertRemoteEngineSSHOptions(call.arguments)
        }
    }

    func testHelperDeployerUploadsWhenRemoteLibraryLinksAreMissing() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = MissingRemoteLibraryLinksProcessRunner(helperVersion: "abc123")
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )

        _ = try await deployer.ensureDeployed(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        let scpCalls = runner.calls.filter { $0.executable == "/usr/bin/scp" }
        XCTAssertEqual(scpCalls.count, 2)
        XCTAssertTrue(scpCalls[0].arguments.contains(fixture.libraryURL.path))
        XCTAssertTrue(scpCalls[1].arguments.contains(fixture.helperURL.path))
    }

    func testSSHBootstrapperTerminatesTargetOptionParsing() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("hostname -oProxyCommand=touch /tmp/fantastty-pwn\n"),
            .success("10.205.1.96\n"),
            .success("Linux\nx86_64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact checksum mismatch")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=amd64\n"),
            .success("""
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=remote.example:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """)
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: deployer,
            processRunner: runner,
            localIPv4Networks: {
                [RemoteEngineLocalIPv4Network(address: "10.205.1.12", netmask: "255.255.255.0")!]
            }
        )
        let host = Fantastty.SSHHostInfo(user: nil, hostname: "-oProxyCommand=touch /tmp/fantastty-pwn", port: 2222)

        _ = try await bootstrapper.attachMaterial(workspaceID: "workspace-1", host: host)

        for call in runner.calls where call.executable == "/usr/bin/ssh" {
            let targetIndex = try XCTUnwrap(call.arguments.firstIndex(of: host.hostname))
            XCTAssertGreaterThan(targetIndex, 0)
            XCTAssertEqual(call.arguments[targetIndex - 1], "--")
            assertRemoteEngineSSHOptions(call.arguments)
        }
        for call in runner.calls where call.executable == "/usr/bin/scp" {
            let target = "\(host.hostname):"
            let targetIndex = try XCTUnwrap(call.arguments.firstIndex { $0.hasPrefix(target) })
            let terminatorIndex = try XCTUnwrap(call.arguments.firstIndex(of: "--"))
            XCTAssertLessThan(terminatorIndex, targetIndex)
            assertRemoteEngineSSHOptions(call.arguments)
        }
    }

    func testSSHBootstrapperDisablesControlMultiplexingForBootstrapCommands() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("hostname remote-test-host\n"),
            .success("10.205.1.96\n"),
            .success("Linux\nx86_64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact checksum mismatch")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=amd64\n"),
            .success("""
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=remote.example:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """)
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: deployer,
            processRunner: runner,
            localIPv4Networks: {
                [RemoteEngineLocalIPv4Network(address: "10.205.1.12", netmask: "255.255.255.0")!]
            }
        )

        _ = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        for call in runner.calls where call.executable == "/usr/bin/ssh" || call.executable == "/usr/bin/scp" {
            assertRemoteEngineSSHOptions(call.arguments)
        }
    }

    func testHelperDeployerBracketsIPv6SCPRemoteTargets() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(version: "abc123")
        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("Linux\nx86_64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact checksum mismatch")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=amd64\n")
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )
        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "2001:db8::1", port: nil)

        _ = try await deployer.ensureDeployed(host: host)

        let scpTargets = runner.calls
            .filter { $0.executable == "/usr/bin/scp" }
            .compactMap { $0.arguments.last }
        XCTAssertEqual(scpTargets.count, 2)
        XCTAssertTrue(scpTargets.allSatisfy { $0.hasPrefix("jesse@[2001:db8::1]:") })
    }

    func testSSHBootstrapperDeploysBundledHelperBeforeLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-remote-engine-artifacts-\(UUID().uuidString)")
        let artifactDir = root.appendingPathComponent("linux-amd64/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let helperURL = root.appendingPathComponent("linux-amd64/fantastty-helper")
        let libraryURL = root.appendingPathComponent("linux-amd64/lib/libghostty-vt.so.0.1.0")
        try Data("helper-binary".utf8).write(to: helperURL)
        try Data("ghostty-vt".utf8).write(to: libraryURL)
        let helperSHA = try sha256Hex(of: helperURL)
        let librarySHA = try sha256Hex(of: libraryURL)
        try """
        {
          "version": "abc123",
          "artifacts": {
            "linux-amd64": {
              "os": "linux",
              "arch": "amd64",
              "helper": "linux-amd64/fantastty-helper",
              "helper_sha256": "\(helperSHA)",
              "library": "linux-amd64/lib/libghostty-vt.so.0.1.0",
              "library_sha256": "\(librarySHA)"
            }
          }
        }
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("hostname remote-test-host\n"),
            .success("10.205.1.96\n"),
            .success("Linux\nx86_64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact missing")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=amd64\n"),
            .success("""
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=remote.example.invalid:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """)
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: root),
            processRunner: runner
        )
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: deployer,
            processRunner: runner,
            localIPv4Networks: {
                [RemoteEngineLocalIPv4Network(address: "10.205.1.12", netmask: "255.255.255.0")!]
            }
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        XCTAssertEqual(material.helperVersion, "abc123")
        XCTAssertEqual(runner.calls.map(\.executable), [
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/scp",
            "/usr/bin/ssh",
            "/usr/bin/scp",
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/ssh"
        ])
        assertRemoteEngineSSHCommand(runner.calls[0].arguments, target: "jesse@remote.example.invalid", usesConfigDump: true)
        assertRemoteEngineSSHCommand(runner.calls[1].arguments, target: "jesse@remote.example.invalid")
        XCTAssertTrue(runner.calls[5].arguments.contains(libraryURL.path))
        XCTAssertTrue(runner.calls[7].arguments.contains(helperURL.path))
        XCTAssertTrue(runner.calls[10].arguments.last?.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='10.205.1.96'") == true)
        XCTAssertTrue(runner.calls[10].arguments.last?.contains("LD_LIBRARY_PATH='.cache/fantastty/remote-engine/lib'") == true)
        XCTAssertTrue(runner.calls[10].arguments.last?.contains("'.cache/fantastty/remote-engine/fantastty-helper' launch-or-resume") == true)
    }

    func testHelperDeployerSkipsUploadWhenRemoteArtifactsMatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-remote-engine-artifacts-\(UUID().uuidString)")
        let artifactDir = root.appendingPathComponent("linux-amd64/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let helperURL = root.appendingPathComponent("linux-amd64/fantastty-helper")
        let libraryURL = root.appendingPathComponent("linux-amd64/lib/libghostty-vt.so.0.1.0")
        try Data("helper-binary".utf8).write(to: helperURL)
        try Data("ghostty-vt".utf8).write(to: libraryURL)
        let helperSHA = try sha256Hex(of: helperURL)
        let librarySHA = try sha256Hex(of: libraryURL)
        try """
        {
          "version": "abc123",
          "artifacts": {
            "linux-amd64": {
              "os": "linux",
              "arch": "amd64",
              "helper": "linux-amd64/fantastty-helper",
              "helper_sha256": "\(helperSHA)",
              "library": "linux-amd64/lib/libghostty-vt.so.0.1.0",
              "library_sha256": "\(librarySHA)"
            }
          }
        }
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            "Linux\nx86_64\n",
            "",
            "",
            "fantastty-helper version=abc123 arch=amd64\n"
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: root),
            processRunner: runner
        )

        let deployment = try await deployer.ensureDeployed(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        XCTAssertEqual(deployment.helperPath, ".cache/fantastty/remote-engine/fantastty-helper")
        XCTAssertEqual(deployment.libraryPath, ".cache/fantastty/remote-engine/lib")
        XCTAssertEqual(runner.calls.map(\.executable), [
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/ssh",
            "/usr/bin/ssh"
        ])
        XCTAssertFalse(
            runner.calls.contains { $0.executable == "/usr/bin/scp" },
            "matching remote artifacts should not be re-uploaded"
        )
    }

    func testHelperDeployerDeploysDarwinARM64HelperWithMacDynamicLibraryPath() async throws {
        let fixture = try makeRemoteEngineArtifactFixture(
            label: "darwin-arm64",
            osName: "darwin",
            libraryName: "libghostty-vt.dylib",
            manifestArch: "arm64"
        )
        let runner = RecordingRemoteEngineProcessRunner(results: [
            .success("Darwin\narm64\n"),
            .success(""),
            .failure(RemoteEngineError.bootstrapFailed("remote artifact missing")),
            .success(""),
            .success(""),
            .success(""),
            .success(""),
            .success("fantastty-helper version=abc123 arch=arm64\n")
        ])
        let deployer = RemoteEngineHelperDeployer(
            artifactStore: RemoteEngineBundledArtifactStore(rootURL: fixture.rootURL),
            processRunner: runner
        )

        let deployment = try await deployer.ensureDeployed(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote-mac.example.invalid", port: nil)
        )

        XCTAssertEqual(deployment.helperPath, ".cache/fantastty/remote-engine/fantastty-helper")
        XCTAssertEqual(deployment.libraryPath, ".cache/fantastty/remote-engine/lib")
        XCTAssertEqual(deployment.libraryEnvironmentVariable, "DYLD_LIBRARY_PATH")
        let remoteCommands = runner.calls.compactMap(\.arguments.last)
        XCTAssertTrue(remoteCommands.contains { $0.contains("libghostty-vt.dylib") })
        XCTAssertTrue(remoteCommands.contains { $0.contains("shasum -a 256 -c -") })
        let versionCommand = try XCTUnwrap(remoteCommands.first { $0.contains("fantastty-helper") && $0.contains("--version") })
        XCTAssertTrue(versionCommand.contains("DYLD_LIBRARY_PATH='.cache/fantastty/remote-engine/lib'"))
        XCTAssertFalse(versionCommand.contains(" LD_LIBRARY_PATH="))
    }

    func testSSHBootstrapperAdvertisesSSHConnectionServerAddressForShortSSHConfigAlias() async throws {
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            """
            user jesse
            hostname remote-test-host
            port 22
            """,
            "10.205.1.96\n",
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=10.205.1.96:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """
        ])
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: nil,
            processRunner: runner,
            localIPv4Networks: {
                [RemoteEngineLocalIPv4Network(address: "10.205.1.12", netmask: "255.255.255.0")!]
            }
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "mk-alias", port: nil)
        )

        XCTAssertEqual(material.host, "10.205.1.96")
        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh"])
        assertRemoteEngineSSHCommand(runner.calls[0].arguments, target: "jesse@mk-alias", usesConfigDump: true)
        assertRemoteEngineSSHCommand(runner.calls[1].arguments, target: "jesse@mk-alias")
        XCTAssertTrue(runner.calls[2].arguments.last?.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='10.205.1.96'") == true)
    }

    func testSSHBootstrapperPrefersRemoteAddressOnLocalSubnetWhenSSHUsesUnreachableRouteAddress() async throws {
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            """
            user jesse
            hostname remote-test-host
            port 22
            """,
            "203.0.113.18\n",
            "10.0.205.1 10.205.1.96 203.0.113.18\n",
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=203.0.113.18:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """
        ])
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: nil,
            processRunner: runner,
            localIPv4Networks: {
                [RemoteEngineLocalIPv4Network(address: "10.205.1.4", netmask: "255.255.255.0")!]
            }
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "mk-alias", port: nil)
        )

        XCTAssertEqual(material.host, "10.205.1.96")
        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh"])
        assertRemoteEngineSSHCommand(runner.calls[0].arguments, target: "jesse@mk-alias", usesConfigDump: true)
        assertRemoteEngineSSHCommand(runner.calls[1].arguments, target: "jesse@mk-alias")
        assertRemoteEngineSSHCommand(runner.calls[2].arguments, target: "jesse@mk-alias")
        XCTAssertTrue(runner.calls[3].arguments.last?.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='10.205.1.96'") == true)
    }

    func testSSHBootstrapperAdvertisesSSHConnectionServerAddressOutsideLocalSubnets() async throws {
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            """
            user jesse
            hostname remote-test-host
            port 22
            """,
            "203.0.113.18\n",
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=203.0.113.18:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """
        ])
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: nil,
            processRunner: runner,
            localIPv4Networks: { [] }
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "mk-alias", port: nil)
        )

        XCTAssertEqual(material.host, "203.0.113.18")
        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh"])
        XCTAssertTrue(runner.calls[2].arguments.last?.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='203.0.113.18'") == true)
    }

    func testSSHBootstrapperKeepsSSHConfigFQDN() async throws {
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            """
            user jesse
            hostname public.example.com
            port 22
            """,
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=public.example.com:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """
        ])
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: nil,
            processRunner: runner
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "prod", port: nil)
        )

        XCTAssertEqual(material.host, "public.example.com")
        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/bin/ssh", "/usr/bin/ssh"])
        assertRemoteEngineSSHCommand(runner.calls[0].arguments, target: "jesse@prod", usesConfigDump: true)
        XCTAssertTrue(runner.calls[1].arguments.last?.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='public.example.com'") == true)
    }

    func testSSHBootstrapperFallsBackToSSHConfigHostnameWhenSSHConnectionServerAddressIsUnavailable() async throws {
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            """
            user jesse
            hostname remote-test-host
            port 22
            """,
            "\n",
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=remote.example.invalid:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """
        ])
        let bootstrapper = SSHRemoteEngineBootstrapper(
            helperDeployer: nil,
            processRunner: runner
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "mk-alias", port: nil)
        )

        XCTAssertEqual(material.host, "remote-test-host")
        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh"])
        assertRemoteEngineSSHCommand(runner.calls[0].arguments, target: "jesse@mk-alias", usesConfigDump: true)
        XCTAssertTrue(runner.calls[2].arguments.last?.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='remote-test-host'") == true)
    }

    func testSSHBootstrapperAdvertisesExplicitOverrideHostWithoutSSHConfigLookup() async throws {
        let runner = RecordingRemoteEngineProcessRunner(outputs: [
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=10.205.1.96:33324 quic_cert_sha256=\(RemoteEngineClientFixtureValues.certificatePin) quic_alpn=fantastty-remote-engine-v1
            """
        ])
        let bootstrapper = SSHRemoteEngineBootstrapper(
            advertiseHostOverride: "10.205.1.96",
            helperDeployer: nil,
            processRunner: runner
        )

        let material = try await bootstrapper.attachMaterial(
            workspaceID: "workspace-1",
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        )

        XCTAssertEqual(material.host, "10.205.1.96")
        XCTAssertEqual(runner.calls.count, 1)
        assertRemoteEngineSSHCommand(runner.calls[0].arguments, target: "jesse@remote.example.invalid")
        let command = try XCTUnwrap(runner.calls[0].arguments.last)
        assertRemoteEngineLaunchCommand(
            command,
            workspaceID: "workspace-1",
            ttl: "8h",
            keyTTL: "30s",
            advertiseHost: "10.205.1.96"
        )
    }

    func testProcessRunnerDrainsLargeErrorOutputWithoutDeadlocking() async {
        let runner = RemoteEngineProcessRunner()
        let result = await withRemoteEngineTimeout(seconds: 2) {
            try await runner.run(
                URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import sys; sys.stderr.write('x' * 1000000); sys.stderr.flush(); sys.exit(7)"]
            )
        }

        switch result {
        case .failure(let error as RemoteEngineError):
            guard case .bootstrapFailed(let message) = error else {
                return XCTFail("error = \(error), want bootstrapFailed")
            }
            XCTAssertFalse(message.isEmpty)
        case .failure(let error):
            XCTFail("error = \(error), want RemoteEngineError.bootstrapFailed")
        case .success:
            XCTFail("process unexpectedly succeeded")
        case .timedOut:
            XCTFail("process runner deadlocked on large stderr output")
        }
    }

    func testProcessRunnerReportsLaunchFailureAsBootstrapFailure() async {
        let runner = RemoteEngineProcessRunner()
        let result = await withRemoteEngineTimeout(seconds: 2) {
            try await runner.run(URL(fileURLWithPath: "/definitely/not/a/fantastty-command"), arguments: [])
        }

        switch result {
        case .failure(let error as RemoteEngineError):
            guard case .bootstrapFailed(let message) = error else {
                return XCTFail("error = \(error), want bootstrapFailed")
            }
            XCTAssertTrue(message.contains("failed to launch"), message)
            XCTAssertTrue(message.contains("/definitely/not/a/fantastty-command"), message)
        case .failure(let error):
            XCTFail("error = \(error), want RemoteEngineError.bootstrapFailed")
        case .success:
            XCTFail("process unexpectedly succeeded")
        case .timedOut:
            XCTFail("process runner timed out")
        }
    }

    func testNWQUICTransportDiagnosticEventsDescribeConnectionMilestones() {
        XCTAssertEqual(
            RemoteEngineNWQUICDiagnosticEvent.connectStarted(host: "example.com", port: 443).description,
            "connect-started example.com:443"
        )
        XCTAssertEqual(
            RemoteEngineNWQUICDiagnosticEvent.connectionState("preparing").description,
            "state preparing"
        )
        XCTAssertEqual(
            RemoteEngineNWQUICDiagnosticEvent.controlSendCompleted("sendKeys").description,
            "control-send-completed sendKeys"
        )
        XCTAssertEqual(
            RemoteEngineNWQUICDiagnosticEvent.attachSendCompleted.description,
            "attach-send-completed"
        )
    }

    func testRemoteEngineSupportBundleRedactsSecretsAndPaneContent() {
        let oneTimeKey = "\(RemoteEngineClientFixtureValues.attachKey)"
        let certificatePin = "\(RemoteEngineClientFixtureValues.certificatePin)"

        let snapshot = RemoteEngineDiagnosticSnapshot(
            appVersion: "1.2.3",
            helperVersion: "abc123",
            helperArch: "amd64",
            hostAlias: "prod-box",
            resolvedRemoteAddress: "203.0.113.7:44321",
            bootstrapPhase: .helperDeploy,
            quicPhase: .reconnecting,
            reconnectAttempts: 4,
            lastKeyframeGeneration: 99,
            lastDatagramSequence: 1201,
            fallbackReason: "UDP unreachable before remote panes existed at /Users/jesse/.ssh/id_ed25519",
            predictiveEchoState: .suppressed(reason: .echoNotProven)
        )

        let export = snapshot.redactedSupportBundle()

        XCTAssertTrue(export.contains("app_version=1.2.3"))
        XCTAssertTrue(export.contains("helper_version=abc123"))
        XCTAssertTrue(export.contains("helper_arch=amd64"))
        XCTAssertTrue(export.contains("host_alias=prod-box"))
        XCTAssertTrue(export.contains("resolved_remote_address=203.0.113.7:44321"))
        XCTAssertTrue(export.contains("bootstrap_phase=helperDeploy"))
        XCTAssertTrue(export.contains("quic_phase=reconnecting"))
        XCTAssertTrue(export.contains("reconnect_attempts=4"))
        XCTAssertTrue(export.contains("last_keyframe_generation=99"))
        XCTAssertTrue(export.contains("last_datagram_sequence=1201"))
        XCTAssertTrue(export.contains("fallback_reason=Remote engine UDP connection is unreachable. [REMOTE_ENGINE_UDP_UNREACHABLE]"))
        XCTAssertTrue(export.contains("predictive_echo=suppressed:echoNotProven"))
        XCTAssertTrue(export.contains("one_time_key=<redacted>"))
        XCTAssertTrue(export.contains("certificate_pin=<redacted>"))
        XCTAssertTrue(export.contains("raw_typed_input=<redacted>"))
        XCTAssertTrue(export.contains("pane_contents=<redacted>"))
        XCTAssertTrue(export.contains("shell_command=<redacted>"))
        XCTAssertTrue(export.contains("local_path=<redacted>"))
        XCTAssertFalse(export.contains(oneTimeKey))
        XCTAssertFalse(export.contains(certificatePin))
        XCTAssertFalse(export.contains("hunter2"))
        XCTAssertFalse(export.contains("prod-db-password"))
        XCTAssertFalse(export.contains("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(export.contains("/Users/jesse"))
        XCTAssertFalse(export.contains("id_ed25519"))
    }

    func testRemoteEngineSupportBundleUsesAttachMaterialWithoutLeakingAttachSecrets() {
        let material = RemoteEngineAttachMaterial.fixture()

        let snapshot = RemoteEngineDiagnosticSnapshot(
            appVersion: "1.2.3",
            hostAlias: "prod-box",
            material: material,
            bootstrapPhase: .attached,
            quicPhase: .connected,
            reconnectAttempts: 1,
            lastKeyframeGeneration: nil,
            lastDatagramSequence: nil,
            fallbackReason: nil,
            predictiveEchoState: .enabled
        )

        let export = snapshot.redactedSupportBundle()

        XCTAssertTrue(export.contains("app_version=1.2.3"))
        XCTAssertTrue(export.contains("helper_version=84dfd78"))
        XCTAssertTrue(export.contains("helper_arch=amd64"))
        XCTAssertTrue(export.contains("host_alias=prod-box"))
        XCTAssertTrue(export.contains("resolved_remote_address=remote.example.invalid:33324"))
        XCTAssertTrue(export.contains("bootstrap_phase=attached"))
        XCTAssertTrue(export.contains("quic_phase=connected"))
        XCTAssertTrue(export.contains("reconnect_attempts=1"))
        XCTAssertTrue(export.contains("predictive_echo=enabled"))
        XCTAssertFalse(export.contains(material.key))
        XCTAssertFalse(export.contains(material.certSHA256))
        XCTAssertFalse(export.contains(material.session))
    }

    func testRemoteEngineDiagnosticSnapshotDoesNotRetainAttachSecrets() {
        let material = RemoteEngineAttachMaterial.fixture()

        let snapshot = RemoteEngineDiagnosticSnapshot(
            appVersion: "1.2.3",
            hostAlias: "prod-box",
            material: material,
            bootstrapPhase: .attached,
            quicPhase: .connected,
            reconnectAttempts: 1,
            lastKeyframeGeneration: nil,
            lastDatagramSequence: nil,
            fallbackReason: nil,
            predictiveEchoState: .enabled
        )

        let retainedStrings = recursiveStringValues(in: snapshot)

        XCTAssertFalse(retainedStrings.contains(material.key))
        XCTAssertFalse(retainedStrings.contains(material.certSHA256))
    }

    func testRemoteEngineDiagnosticSnapshotDoesNotRetainRawFallbackReason() {
        let snapshot = RemoteEngineDiagnosticSnapshot(
            appVersion: "1.2.3",
            helperVersion: "abc123",
            helperArch: "amd64",
            hostAlias: "prod-box",
            resolvedRemoteAddress: "203.0.113.7:44321",
            bootstrapPhase: .helperDeploy,
            quicPhase: .failed,
            reconnectAttempts: 1,
            lastKeyframeGeneration: nil,
            lastDatagramSequence: nil,
            fallbackReason: "UDP unreachable at /Users/jesse/.ssh/id_ed25519 with command export AWS_SECRET_ACCESS_KEY=abc123",
            predictiveEchoState: .enabled
        )

        let retainedStrings = recursiveStringValues(in: snapshot)

        XCTAssertTrue(retainedStrings.contains("Remote engine UDP connection is unreachable. [REMOTE_ENGINE_UDP_UNREACHABLE]"))
        XCTAssertFalse(retainedStrings.contains { $0.contains("/Users/jesse") })
        XCTAssertFalse(retainedStrings.contains { $0.contains("AWS_SECRET_ACCESS_KEY") })
        XCTAssertFalse(retainedStrings.contains { $0.contains("id_ed25519") })
    }

    func testRemoteEngineFailurePresentationClassifiesUserVisibleFailureModes() {
        let cases: [(Error, RemoteEngineFailurePresentation)] = [
            (
                RemoteEngineError.remote("UDP unreachable before remote panes existed"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_UDP_UNREACHABLE",
                    userReason: "Remote engine UDP connection is unreachable.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.remote("Operation timed out"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_UDP_UNREACHABLE",
                    userReason: "Remote engine UDP connection is unreachable.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("remote helper artifact checksum mismatch for linux-amd64"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_HELPER_ARTIFACT_MISMATCH",
                    userReason: "Remote helper artifact does not match the bundled app version.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("unexpected helper version line: fantastty-helper version=def456 arch=amd64"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_HELPER_VERSION_MISMATCH",
                    userReason: "Remote helper version does not match this app.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("scp failed: Permission denied"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_HELPER_PERMISSION",
                    userReason: "Remote helper could not be installed with the current account permissions.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.remote("remote engine bootstrap failed: missing helper"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_HELPER_DEPLOY_FAILED",
                    userReason: "Remote helper could not be installed or started.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.remote("invalid one-time key"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_ATTACH_REJECTED",
                    userReason: "Remote engine rejected the one-time attach credentials.",
                    mode: .disconnectedAfterRemotePanes
                )
            ),
            (
                RemoteEngineError.remote("attach key belongs to another remote session"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_ATTACH_REJECTED",
                    userReason: "Remote engine rejected the one-time attach credentials.",
                    mode: .disconnectedAfterRemotePanes
                )
            ),
            (
                RemoteEngineError.remote("certificate pin mismatch"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_QUIC_PIN_MISMATCH",
                    userReason: "Remote engine certificate pin validation failed.",
                    mode: .disconnectedAfterRemotePanes
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("unsupported remote architecture: riscv64"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_UNSUPPORTED_HOST_ARCH",
                    userReason: "Remote engine does not support this host architecture.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("tmux not found in PATH"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_TMUX_MISSING",
                    userReason: "Remote host does not have tmux installed.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("tmux version 2.9 is older than required 3.2"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_TMUX_TOO_OLD",
                    userReason: "Remote host tmux version is too old for the remote engine.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("unsafe registry path"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_UNSAFE_RUNTIME_DIR",
                    userReason: "Remote helper runtime directory failed safety checks.",
                    mode: .fellBackToSSHControlMode
                )
            ),
            (
                RemoteEngineError.bootstrapFailed("missing shell environment"),
                RemoteEngineFailurePresentation(
                    code: "REMOTE_ENGINE_SHELL_ENVIRONMENT",
                    userReason: "Remote host shell environment is not usable for helper startup.",
                    mode: .fellBackToSSHControlMode
                )
            )
        ]

        for (error, expectedPresentation) in cases {
            XCTAssertEqual(RemoteEngineFailurePresentation.presenting(error), expectedPresentation)
        }
    }

    func testRemoteEnginePinValidationTrackerMapsGenericFailureAfterPinMismatch() {
        let tracker = RemoteEnginePinValidationTracker()
        tracker.record(matches: false)

        let mapped = tracker.errorAfterValidationFailure(RemoteEngineError.remote("generic TLS failed"))

        XCTAssertEqual(mapped as? RemoteEngineError, .remote("certificate pin mismatch"))
    }

    func testAppEntitlementsAllowRemoteEngineNetworkClientConnections() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let entitlementsURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fantastty/Fantastty.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true)
    }

    func testMessageLineDecoderHandlesFragmentedReliableMessages() throws {
        let snapshot = RemoteWorkspaceMessage.workspaceSnapshot(.singlePaneFixture())
        let keyframe = RemoteWorkspaceMessage.paneKeyframe(.singleRowFixture())
        let encoded = try JSONEncoder().encode(snapshot) + Data([0x0A]) + JSONEncoder().encode(keyframe) + Data([0x0A])
        let split = encoded.index(encoded.startIndex, offsetBy: encoded.count / 2)
        var decoder = RemoteEngineMessageLineDecoder()

        let first = try decoder.append(Data(encoded[..<split]))
        let second = try decoder.append(Data(encoded[split...]))

        XCTAssertEqual(first + second, [snapshot, keyframe])
    }

    func testMessageLineDecoderReportsRemoteAttachError() {
        var decoder = RemoteEngineMessageLineDecoder()

        XCTAssertThrowsError(try decoder.append(Data("{\"error\":\"invalid one-time key\"}\n".utf8))) { error in
            XCTAssertEqual(error as? RemoteEngineError, .remote("invalid one-time key"))
        }
    }

    func testMessageLineDecoderAcceptsCompactReliablePaneDeltaEnvelope() throws {
        var decoder = RemoteEngineMessageLineDecoder()
        let encoded = Data(
            """
            {"paneDelta":{"_0":{"workspaceID":"workspace-1","paneID":7,"paneGeneration":3,"baseKeyframeID":11,"deltaSequence":1,"rowUpdates":[{"rowIndex":0,"rowVersion":12,"update":{"fullRowText":{"_0":"hi"}}}]}}}

            """.utf8
        )

        let messages = try decoder.append(encoded)

        XCTAssertEqual(messages, [.paneDelta(RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 12, update: .fullRow([
                    .text("h"),
                    .text("i")
                ]))
            ],
            cursor: nil
        ))])
    }

    func testMessageLineDecoderHandlesManyCompactReliableDeltasInLargeChunks() throws {
        var encoded = Data()
        var expected: [RemoteWorkspaceMessage] = []
        for sequence in 1...200 {
            let delta = RemotePaneDelta(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                baseKeyframeID: 11,
                deltaSequence: UInt64(sequence),
                rowUpdates: [
                    RemoteRowUpdate(
                        rowIndex: 0,
                        rowVersion: UInt64(sequence),
                        update: .fullRow("row-\(sequence)".map { .text(String($0)) })
                    )
                ],
                cursor: nil
            )
            let line = """
            {"paneDelta":{"_0":{"workspaceID":"workspace-1","paneID":7,"paneGeneration":3,"baseKeyframeID":11,"deltaSequence":\(sequence),"rowUpdates":[{"rowIndex":0,"rowVersion":\(sequence),"update":{"fullRowText":{"_0":"row-\(sequence)"}}}]}}}

            """
            encoded.append(Data(line.utf8))
            expected.append(.paneDelta(delta))
        }

        var decoder = RemoteEngineMessageLineDecoder()
        let firstSplit = encoded.index(encoded.startIndex, offsetBy: encoded.count / 3)
        let secondSplit = encoded.index(encoded.startIndex, offsetBy: encoded.count * 2 / 3)

        let messages =
            (try decoder.append(Data(encoded[..<firstSplit]))) +
            (try decoder.append(Data(encoded[firstSplit..<secondSplit]))) +
            (try decoder.append(Data(encoded[secondSplit...])))

        XCTAssertEqual(messages, expected)
    }

    func testReliableFrameDecoderFlushesUnterminatedMessageOnEndOfStream() throws {
        let keyframe = RemoteWorkspaceMessage.paneKeyframe(.singleRowFixture())
        let encoded = try JSONEncoder().encode(keyframe)
        var decoder = RemoteEngineReliableFrameDecoder()

        XCTAssertEqual(try decoder.receive(encoded, endOfStream: true), [keyframe])
        XCTAssertTrue(decoder.didReceiveEndOfStream)
    }

    func testReliableFrameDecoderFinishesAfterEmptyEndOfStream() throws {
        var decoder = RemoteEngineReliableFrameDecoder()

        XCTAssertEqual(try decoder.receive(Data(), endOfStream: true), [])
        XCTAssertTrue(decoder.didReceiveEndOfStream)
    }

    func testDatagramDecoderWrapsRawPaneDeltaPayload() throws {
        let delta = RemotePaneDelta.singleRowUpdateFixture()
        let encoded = try JSONEncoder().encode(delta)
        let decoder = RemoteEngineDatagramDecoder()

        XCTAssertEqual(try decoder.decode(encoded), .paneDelta(delta))
    }

    func testDatagramDecoderIgnoresWorkspaceMessageEnvelopePayload() throws {
        let delta = RemoteWorkspaceMessage.paneDelta(.singleRowUpdateFixture())
        let encoded = try JSONEncoder().encode(delta)
        let decoder = RemoteEngineDatagramDecoder()

        XCTAssertNil(decoder.decodeIfValid(encoded))
    }

    func testDatagramDecoderIgnoresMalformedPayload() {
        let decoder = RemoteEngineDatagramDecoder()

        XCTAssertNil(decoder.decodeIfValid(Data("{\"not\":\"a pane delta\"}".utf8)))
    }

    func testInboundFrameDecoderPreservesReliableAndDatagramDelivery() throws {
        let keyframe = RemoteWorkspaceMessage.paneKeyframe(.singleRowFixture())
        let delta = RemotePaneDelta.singleRowUpdateFixture()
        var decoder = RemoteEngineInboundFrameDecoder()

        let reliableMessages = try decoder.receiveReliable(
            try JSONEncoder().encode(keyframe) + Data([0x0A]),
            endOfStream: false
        )
        let datagramMessage = try XCTUnwrap(decoder.receiveDatagram(try JSONEncoder().encode(delta)))

        XCTAssertEqual(reliableMessages, [RemoteEngineInboundMessage(keyframe, delivery: .reliable)])
        XCTAssertEqual(datagramMessage, RemoteEngineInboundMessage(.paneDelta(delta), delivery: .datagram))
        XCTAssertNil(decoder.receiveDatagram(Data("{\"not\":\"a pane delta\"}".utf8)))
    }

    func testQUICControlFramesStayOnOpenAttachStream() {
        let attach = RemoteEngineQUICStreamFrame.open(Data("attach\n".utf8))
        let input = RemoteEngineQUICStreamFrame.open(Data("input\n".utf8))

        XCTAssertEqual(attach.context, .openStream)
        XCTAssertEqual(input.context, .openStream)
        XCTAssertFalse(attach.isComplete)
        XCTAssertFalse(input.isComplete)
    }

    @MainActor
    func testClientConnectsWithSSHDeliveredQUICPinAndALPN() async throws {
        let certPin = String(repeating: "a", count: 64)
        let material = try RemoteEngineBootstrapLine.parse(
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=remote.example:33324 quic_cert_sha256=\(certPin) quic_alpn=fantastty-test-alpn
            """,
            workspaceID: "workspace-pin"
        )
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in }
        )

        connection.finish()
        await client.run()

        XCTAssertEqual(transport.materials.map(\.certSHA256), [certPin])
        XCTAssertEqual(transport.materials.map(\.alpn), ["fantastty-test-alpn"])
    }

    func testProductionQUICSecurityConfigurationUsesSSHDeliveredPinAndALPN() throws {
        let certPin = String(repeating: "b", count: 64)
        let material = try RemoteEngineBootstrapLine.parse(
            """
            FANTASTTY_REMOTE port=53196 session=\(RemoteEngineClientFixtureValues.sessionID) key=\(RemoteEngineClientFixtureValues.attachKey) expires=2026-06-20T17:28:38Z helper_pid=3108381 version=abc123 arch=amd64 quic_addr=remote.example:33324 quic_cert_sha256=\(certPin) quic_alpn=fantastty-production-alpn
            """,
            workspaceID: "workspace-pin"
        )

        let configuration = RemoteEngineQUICSecurityConfiguration(material: material)

        XCTAssertEqual(configuration.alpn, "fantastty-production-alpn")
        XCTAssertEqual(configuration.certificateSPKISHA256, certPin)
        XCTAssertEqual(configuration.maxDatagramFrameSize, 1200)
    }

    func testProductionQUICTransportUsesTypedConnectionOnSupportedRuntime() {
        let mode = RemoteEngineNWQUICTransport.preferredConnectionMode()

        if #available(macOS 26.0, *) {
            XCTAssertEqual(mode, .typedNetworkConnection)
        } else {
            XCTAssertEqual(mode, .legacyNWConnection)
        }
    }

    @MainActor
    func testClientConnectsAndDeliversReliableMessages() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        var handled: [RemoteWorkspaceMessage] = []
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { handled.append($0.message) },
            stateHandler: { states.append($0) }
        )

        connection.yield(.workspaceSnapshot(.singlePaneFixture()))
        connection.yield(.paneKeyframe(.singleRowFixture()))
        connection.finish()
        await client.run()

        XCTAssertEqual(transport.materials, [material])
        XCTAssertEqual(handled, [.workspaceSnapshot(.singlePaneFixture()), .paneKeyframe(.singleRowFixture())])
        XCTAssertEqual(states, [.connecting, .connected, .disconnected(reason: nil)])
    }

    @MainActor
    func testClientStopDuringMaterialProviderDoesNotConnect() async {
        let material = RemoteEngineAttachMaterial.fixture()
        let provider = ControlledAttachMaterialProvider()
        let transport = ControlledRemoteEngineTransport()
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { try await provider.nextMaterial() },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in },
            stateHandler: { states.append($0) }
        )

        client.start()
        await waitUntilAsync { await provider.hasPendingRequest() }
        client.stop()
        await provider.resume(returning: material)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let materials = await transport.recordedMaterials()
        XCTAssertEqual(materials, [])
        XCTAssertFalse(states.contains(.connected))
    }

    @MainActor
    func testClientStopDuringTransportConnectClosesLateConnectionWithoutConnectedState() async {
        let material = RemoteEngineAttachMaterial.fixture()
        let connection = FakeRemoteEngineConnection()
        let transport = ControlledRemoteEngineTransport()
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in },
            stateHandler: { states.append($0) }
        )

        client.start()
        await waitUntilAsync { await transport.hasPendingConnect() }
        client.stop()
        await transport.resume(with: connection)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let materials = await transport.recordedMaterials()
        XCTAssertEqual(materials, [material])
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertFalse(states.contains(.connected))
    }

    @MainActor
    func testClientCallsReattachHandlerOnlyAfterSuccessfulReconnect() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture()
        var reattachCount = 0
        var handled: [RemoteWorkspaceMessage] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0),
            messageHandler: { handled.append($0.message) },
            reattachHandler: { reattachCount += 1 }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }
        XCTAssertEqual(reattachCount, 0)

        firstConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        firstConnection.finish()
        await waitUntil { transport.materials.count == 2 }

        secondConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        await waitUntil { reattachCount == 1 }

        secondConnection.finish()
        await task.value

        XCTAssertEqual(reattachCount, 1)
        XCTAssertEqual(handled.count, 2)
    }

    @MainActor
    func testClientReportsReconnectingDuringAppLayerResume() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture()
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0),
            messageHandler: { _ in },
            stateHandler: { states.append($0) }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }
        firstConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        firstConnection.finish(throwing: RemoteEngineError.remote("Socket is not connected"))
        await waitUntil { states.contains(.reconnecting(reason: "remote engine error: Socket is not connected")) }
        secondConnection.finish()
        await task.value

        XCTAssertEqual(states, [
            .connecting,
            .connected,
            .reconnecting(reason: "remote engine error: Socket is not connected"),
            .connected,
            .disconnected(reason: nil)
        ])
    }

    @MainActor
    func testClientFailsHungInitialConnectBeforeAttachKeyExpires() async {
        let transport = ControlledRemoteEngineTransport()
        let material = RemoteEngineAttachMaterial.fixture()
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(
                maxAttempts: 1,
                delayNanoseconds: 0,
                connectTimeoutNanoseconds: 50_000_000
            ),
            messageHandler: { _ in },
            stateHandler: { states.append($0) }
        )

        let task = Task { await client.run() }
        await waitUntilAsync { await transport.hasPendingConnect() }
        await task.value

        XCTAssertEqual(states, [
            .connecting,
            .disconnected(reason: "remote engine error: remote engine UDP connection timed out")
        ])
    }

    @MainActor
    func testClientDoesNotCallReattachHandlerAfterAttachErrorBeforeFirstMessage() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture()
        var reattachCount = 0
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0),
            messageHandler: { _ in },
            reattachHandler: { reattachCount += 1 }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        firstConnection.finish(throwing: RemoteEngineError.remote("invalid one-time key"))
        await waitUntil { transport.materials.count == 2 }
        secondConnection.finish()
        await task.value

        XCTAssertEqual(reattachCount, 0)
    }

    @MainActor
    func testClientWaitsForReattachKeyframeRequestBeforeProcessingReconnectMessages() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture()
        var handledReconnectMessages: [RemoteEngineInboundMessage] = []
        var states: [RemoteEngineClientState] = []
        var client: RemoteEngineClient!
        client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0),
            messageHandler: { inbound in
                if transport.materials.count == 2 {
                    handledReconnectMessages.append(inbound)
                }
            },
            reattachHandler: {
                await client.requestKeyframe(paneID: 7, reason: .noKeyframe)?.value
            },
            stateHandler: { states.append($0) }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }
        firstConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        await waitUntil { transport.materials.count == 1 }

        secondConnection.blockNextKeyframeRequestBeforeRecording()
        secondConnection.yield(
            .paneDelta(.singleRowUpdateFixture(workspaceID: material.workspaceID)),
            delivery: .datagram
        )
        firstConnection.finish()
        await waitUntil { transport.materials.count == 2 }
        await waitUntil { secondConnection.blockedKeyframeRequestCount == 1 }
        XCTAssertEqual(states.last, .reconnecting(reason: nil))
        await waitUntil(timeout: 0.1) { !handledReconnectMessages.isEmpty }

        XCTAssertTrue(
            handledReconnectMessages.isEmpty,
            "Reconnect inbound messages should wait until the immediate reattach keyframe request completes"
        )

        secondConnection.unblockNextKeyframeRequest()
        await waitUntil { secondConnection.keyframeRequests.count == 1 }
        await waitUntil { handledReconnectMessages.count == 1 }

        secondConnection.finish()
        await task.value

        XCTAssertEqual(secondConnection.keyframeRequests, [
            FakeRemoteEngineConnection.KeyframeRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                reason: .noKeyframe
            )
        ])
        XCTAssertEqual(handledReconnectMessages.map(\.delivery), [.datagram])
    }

    @MainActor
    func testClientPreservesInboundDeliverySource() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        var handled: [RemoteEngineInboundMessage] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { handled.append($0) }
        )

        connection.yield(.paneDelta(.singleRowUpdateFixture()), delivery: .datagram)
        connection.finish()
        await client.run()

        XCTAssertEqual(handled, [
            RemoteEngineInboundMessage(.paneDelta(.singleRowUpdateFixture()), delivery: .datagram)
        ])
    }

    @MainActor
    func testClientRequestsKeyframeOnOpenConnection() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        client.requestKeyframe(paneID: 7, reason: .malformedDelta)
        await waitUntil { connection.keyframeRequests.count == 1 }

        connection.finish()
        await task.value

        XCTAssertEqual(connection.keyframeRequests, [
            FakeRemoteEngineConnection.KeyframeRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                reason: .malformedDelta
            )
        ])
    }

    @MainActor
    func testClientSendsPaneInputOnOpenConnection() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        client.sendKeys(paneID: 7, data: Data("hi\n".utf8))
        await waitUntil { connection.inputRequests.count == 1 }

        connection.finish()
        await task.value

        XCTAssertEqual(connection.inputRequests, [
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                data: Data("hi\n".utf8)
            )
        ])
    }

    @MainActor
    func testClientSendsPaneResizeOnOpenConnection() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        client.resizePane(paneID: 7, size: RemoteGridSize(columns: 100, rows: 30))
        await waitUntil { connection.resizeRequests.count == 1 }

        connection.finish()
        await task.value

        XCTAssertEqual(connection.resizeRequests, [
            FakeRemoteEngineConnection.ResizeRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                size: RemoteGridSize(columns: 100, rows: 30)
            )
        ])
    }

    @MainActor
    func testCreateTabOnRemoteEngineSessionSendsNewWindowRequest() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(
            workspaceID: "remote-new-window-\(UUID().uuidString.prefix(8).lowercased())"
        )
        defer {
            remote.connection.finish()
        }

        remote.manager.selectedSessionID = remote.session.id

        let created = remote.manager.createTab()
        await waitUntil { remote.connection.newWindowRequests.count == 1 }

        XCTAssertNil(created)
        XCTAssertEqual(remote.connection.newWindowRequests, [remote.material.workspaceID])
        XCTAssertTrue(remote.connection.inputRequests.isEmpty)
        XCTAssertEqual(remote.session.tabs.count, 1)
    }

    @MainActor
    func testSelectingRemoteEngineTabSendsSelectWindowRequest() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(
            workspaceID: "remote-select-window-\(UUID().uuidString.prefix(8).lowercased())"
        )
        defer {
            remote.connection.finish()
        }
        remote.manager.selectedSessionID = remote.session.id

        remote.connection.yield(.workspaceSnapshot(RemoteWorkspaceSnapshot(
            workspaceID: remote.material.workspaceID,
            layoutGeneration: 2,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "first", index: 0, isActive: false),
                RemoteWorkspaceWindow(windowID: 2, title: "second", index: 1, isActive: true),
                RemoteWorkspaceWindow(windowID: 3, title: "last", index: 2, isActive: false)
            ],
            panes: [
                RemoteWorkspacePane(paneID: 7, windowID: 1, isActive: false, frame: RemotePaneFrame(x: 0, y: 0, columns: 80, rows: 24)),
                RemoteWorkspacePane(paneID: 8, windowID: 2, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 80, rows: 24)),
                RemoteWorkspacePane(paneID: 9, windowID: 3, isActive: false, frame: RemotePaneFrame(x: 0, y: 0, columns: 80, rows: 24))
            ]
        )))
        await waitUntil { remote.session.tabs.count == 3 }

        let lastTab = try XCTUnwrap(remote.session.tabs.first { $0.tmuxWindowID == 3 })
        remote.session.selectedTabID = lastTab.id
        await waitUntil(timeout: 0.1) { !remote.connection.selectWindowRequests.isEmpty }

        XCTAssertEqual(remote.connection.selectWindowRequests, [
            FakeRemoteEngineConnection.SelectWindowRequest(
                workspaceID: remote.material.workspaceID,
                windowID: 3
            )
        ])
    }

    @MainActor
    func testSelectedRemoteSessionVisibilityRepaintsCurrentAuthoritativeGrid() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(
            workspaceID: "remote-visible-\(UUID().uuidString.prefix(8).lowercased())"
        )
        defer {
            remote.connection.finish()
        }
        var renderedRows: [[[RemoteGridCell]]] = []
        remote.manager.remoteWorkspacePaneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }
        remote.session.selectedTabID = remote.tab.id

        remote.connection.yield(.paneKeyframe(.singleRowFixture(
            workspaceID: remote.material.workspaceID,
            keyframeID: 1,
            rowText: "ok"
        )))
        await waitUntil { renderedRows.count == 1 }
        remote.connection.yield(.paneDelta(.singleRowUpdateFixture(
            workspaceID: remote.material.workspaceID,
            baseKeyframeID: 1,
            rowText: "hi"
        )))
        await waitUntil { renderedRows.count == 2 }

        remote.manager.handleRemoteSelectedTerminalBecameVisible(session: remote.session)

        await waitUntil { renderedRows.count == 3 }
        XCTAssertEqual(renderedRows.last?.first?.map(\.text).joined(), "hi  ")
    }

    @MainActor
    func testClientSerializesPaneInputWrites() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        connection.blockNextInputBeforeRecording()
        client.sendKeys(paneID: 7, data: Data("first".utf8))
        await waitUntil { connection.blockedInputSendCount == 1 }

        client.sendKeys(paneID: 7, data: Data("second".utf8))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(connection.inputRequests.isEmpty)

        connection.unblockNextInput()
        await waitUntil { connection.inputRequests.count == 2 }

        connection.finish()
        await task.value

        XCTAssertEqual(connection.inputRequests, [
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                data: Data("first".utf8)
            ),
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                data: Data("second".utf8)
            )
        ])
    }

    @MainActor
    func testClientDoesNotBlockReattachedConnectionBehindStuckPreviousSend() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture()
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0),
            messageHandler: { _ in }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        firstConnection.blockNextInputBeforeRecording()
        client.sendKeys(paneID: 7, data: Data("first".utf8))
        await waitUntil { firstConnection.blockedInputSendCount == 1 }

        firstConnection.finish()
        await waitUntil { transport.materials.count == 2 }

        client.sendKeys(paneID: 7, data: Data("second".utf8))
        await waitUntil { secondConnection.inputRequests.count == 1 }

        firstConnection.unblockNextInput()
        secondConnection.finish()
        await task.value

        XCTAssertEqual(secondConnection.inputRequests, [
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                data: Data("second".utf8)
            )
        ])
    }

    @MainActor
    func testClientStopCancelsQueuedOutboundWork() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in }
        )

        let task = Task { await client.run() }
        await waitUntil { transport.materials.count == 1 }

        connection.blockNextInputBeforeRecording()
        client.sendKeys(paneID: 7, data: Data("first".utf8))
        await waitUntil { connection.blockedInputSendCount == 1 }

        client.sendKeys(paneID: 7, data: Data("second".utf8))
        client.stop()
        connection.unblockNextInput()
        await task.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(connection.inputRequests, [
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                data: Data("first".utf8)
            )
        ])
        XCTAssertEqual(client.state, .disconnected(reason: nil))
    }

    @MainActor
    func testClientReportsPaneInputSendFailure() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in },
            stateHandler: { states.append($0) }
        )

        let task = Task { await client.run() }
        await waitUntil { states.contains(.connected) }

        connection.failNextInput(with: RemoteEngineError.remote("send failed"))
        client.sendKeys(paneID: 7, data: Data("hi".utf8))
        await waitUntil { states.contains(.disconnected(reason: "remote engine error: send failed")) }

        XCTAssertEqual(client.state, .disconnected(reason: "remote engine error: send failed"))
        connection.finish()
        await task.value
    }

    @MainActor
    func testClientReportsReconnectingDuringOutboundSendRetry() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture()
        var states: [RemoteEngineClientState] = []
        var handledMessages = 0
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0),
            messageHandler: { _ in handledMessages += 1 },
            stateHandler: { states.append($0) }
        )

        let task = Task { await client.run() }
        await waitUntil { states.contains(.connected) }
        firstConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        await waitUntil { handledMessages == 1 }

        firstConnection.failNextInput(with: RemoteEngineError.remote("send failed"))
        client.sendKeys(paneID: 7, data: Data("hi".utf8))
        await waitUntil { transport.materials.count == 2 }

        let reconnectState = RemoteEngineClientState.reconnecting(reason: "remote engine error: send failed")
        guard let reconnectIndex = states.firstIndex(of: reconnectState) else {
            return XCTFail("Expected reconnecting state after outbound send failure, got \(states)")
        }
        XCTAssertFalse(
            states[..<reconnectIndex].contains { state in
                if case .disconnected = state { return true }
                return false
            },
            "Expected outbound send retry to avoid transient disconnected state, got \(states)"
        )

        secondConnection.finish()
        await task.value
    }

    @MainActor
    func testClientReportsKeyframeRequestFailure() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture()
        var states: [RemoteEngineClientState] = []
        let client = RemoteEngineClient(
            workspaceID: material.workspaceID,
            materialProvider: { material },
            transport: transport,
            reconnectPolicy: .once,
            messageHandler: { _ in },
            stateHandler: { states.append($0) }
        )

        let task = Task { await client.run() }
        await waitUntil { states.contains(.connected) }

        connection.failNextKeyframeRequest(with: RemoteEngineError.remote("keyframe failed"))
        client.requestKeyframe(paneID: 7, reason: .baseKeyframeMismatch)
        await waitUntil { states.contains(.disconnected(reason: "remote engine error: keyframe failed")) }

        XCTAssertEqual(client.state, .disconnected(reason: "remote engine error: keyframe failed"))
        connection.finish()
        await task.value
    }

    @MainActor
    func testSessionManagerCreatesRemoteEngineSessionAndReflectsClientState() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "manager-remote")
        let manager = SessionManager()
        manager.sessionMetadataStore = makeIsolatedSessionMetadataStore()
        manager.remoteEngineBootstrapper = FakeRemoteEngineBootstrapper(material: material)
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once

        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(host: host, workspaceID: material.workspaceID)

        await waitUntil { transport.materials == [material] }

        XCTAssertEqual(manager.sessions.map(\.id), [session.id])
        XCTAssertTrue(session.tabs.isEmpty)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached remote engine mode")
        }
        XCTAssertEqual(attachedInfo.sessionName, "fantastty-remote-\(material.workspaceID)")
        XCTAssertEqual(attachedInfo.host, Fantastty.TmuxHost.ssh(host))
        XCTAssertEqual(attachedInfo.connectionState, Fantastty.ConnectionState.connected)

        connection.finish()
        await waitUntil { attachedConnectionState(of: session) == .disconnected(reason: nil) }

        XCTAssertEqual(attachedConnectionState(of: session), .disconnected(reason: nil))
    }

    @MainActor
    func testSessionManagerAttachesExistingRemoteTmuxSessionThroughRemoteEngine() async throws {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let bootstrapper = FakeRemoteEngineBootstrapper { workspaceID in
            RemoteEngineAttachMaterial.fixture(workspaceID: workspaceID)
        }
        defer { connection.finish() }
        let manager = SessionManager()
        manager.sessionMetadataStore = makeIsolatedSessionMetadataStore()
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once

        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "0",
            host: Fantastty.TmuxHost.ssh(host),
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil),
            launchMode: Fantastty.TmuxAttachmentLaunchMode.attach,
            transport: Fantastty.TmuxAttachmentTransport.remoteEngine
        )

        manager.attachToTmuxSession(info: info)
        let session = try XCTUnwrap(manager.sessions.first)
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: session.workspaceID)

        await waitUntil { transport.materials == [material] }

        XCTAssertEqual(bootstrapper.materialRequests, [
            FakeRemoteEngineBootstrapper.MaterialRequest(
                workspaceID: session.workspaceID,
                host: host,
                tmuxSessionName: "0"
            )
        ])
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached remote engine mode")
        }
        XCTAssertEqual(attachedInfo.sessionName, "0")
        XCTAssertEqual(attachedInfo.transport, .remoteEngine)
        XCTAssertEqual(attachedInfo.connectionState, .connected)
        XCTAssertNil(session.controlClient)

    }

    @MainActor
    func testRemoteEngineSessionTitleAndActiveTimeUseInjectedMetadataStore() async throws {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture(
            workspaceID: "remote-metadata-\(UUID().uuidString.prefix(8).lowercased())"
        )
        let metadataStore = makeIsolatedSessionMetadataStore()
        let manager = SessionManager()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = FakeRemoteEngineBootstrapper(material: material)
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        defer {
            connection.finish()
        }

        let session = manager.createRemoteEngineSession(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil),
            workspaceID: material.workspaceID
        )
        await waitUntil { transport.materials == [material] }

        let injectedTitle = try XCTUnwrap(metadataStore.metadata[material.workspaceID]?.name)
        XCTAssertFalse(injectedTitle.isEmpty)
        XCTAssertEqual(session.title, injectedTitle)

        session.totalActiveSeconds = 12
        manager.flushActiveTimes()

        XCTAssertNil(SessionMetadataStore.shared.metadata[material.workspaceID])
        XCTAssertEqual(metadataStore.metadata[material.workspaceID]?.totalActiveSeconds, 12)
    }

    @MainActor
    func testSessionManagerFallsBackToSSHControlModeWhenInitialRemoteEngineBootstrapFails() async {
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = FailingRemoteEngineBootstrapper()
        manager.remoteEngineReconnectPolicy = .once
        var fallbackReconnects: [Session] = []
        manager.attachedSessionReconnectStarter = { fallbackReconnects.append($0) }

        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(host: host, workspaceID: "fallback-remote")

        await waitUntil { fallbackReconnects.count == 1 }

        XCTAssertEqual(fallbackReconnects.map(\.id), [session.id])
        XCTAssertNotNil(session.controlClient)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached fallback mode")
        }
        XCTAssertEqual(attachedInfo.sessionName, "fantastty-remote-fallback-remote")
        XCTAssertEqual(attachedInfo.host, .ssh(host))
        XCTAssertEqual(attachedInfo.launchMode, .create)
        XCTAssertEqual(attachedInfo.transport, .tmuxControl)
        XCTAssertEqual(attachedInfo.connectionState, .connecting)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.attachment?.transport, .tmuxControl)
    }

    @MainActor
    func testSessionManagerFallsBackToSSHControlModeWhenInitialRemoteEngineConnectFails() async {
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "fallback-connect")
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let transport = FakeRemoteEngineTransport(connections: [])
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        var fallbackReconnects: [Session] = []
        manager.attachedSessionReconnectStarter = { fallbackReconnects.append($0) }

        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(host: host, workspaceID: material.workspaceID)

        await waitUntil { fallbackReconnects.count == 1 }

        XCTAssertEqual(bootstrapper.materialRequests, [
            .init(workspaceID: material.workspaceID, host: host, tmuxSessionName: nil)
        ])
        XCTAssertEqual(transport.materials, [material])
        XCTAssertEqual(fallbackReconnects.map(\.id), [session.id])
        XCTAssertNotNil(session.controlClient)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached fallback mode")
        }
        XCTAssertEqual(attachedInfo.sessionName, "fantastty-remote-\(material.workspaceID)")
        XCTAssertEqual(attachedInfo.host, .ssh(host))
        XCTAssertEqual(attachedInfo.launchMode, .create)
        XCTAssertEqual(attachedInfo.transport, .tmuxControl)
        XCTAssertEqual(attachedInfo.connectionState, .connecting)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.attachment?.transport, .tmuxControl)
    }

    @MainActor
    func testSessionManagerFallsBackToSSHControlModeWhenConnectFailsBeforeRemotePanesExistWithBrowserTab() async {
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "fallback-browser")
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let transport = ControlledFailingRemoteEngineTransport()
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        var fallbackReconnects: [Session] = []
        manager.attachedSessionReconnectStarter = { fallbackReconnects.append($0) }

        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(host: host, workspaceID: material.workspaceID)
        await waitUntil { transport.materials == [material] && transport.hasPendingConnect }
        session.addTab(TerminalTab(url: URL(string: "https://example.com")!))

        transport.failPendingConnect(with: RemoteEngineError.remote("connect failed"))
        await waitUntil { fallbackReconnects.count == 1 }

        XCTAssertEqual(fallbackReconnects.map(\.id), [session.id])
        XCTAssertEqual(session.tabs.map(\.kind), [.browser])
        XCTAssertNotNil(session.controlClient)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached fallback mode")
        }
        XCTAssertEqual(attachedInfo.sessionName, "fantastty-remote-\(material.workspaceID)")
        XCTAssertEqual(attachedInfo.host, .ssh(host))
        XCTAssertEqual(attachedInfo.launchMode, .create)
        XCTAssertEqual(attachedInfo.transport, .tmuxControl)
        XCTAssertEqual(attachedInfo.connectionState, .connecting)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.attachment?.transport, .tmuxControl)
        XCTAssertEqual(bootstrapper.materialRequests, [
            .init(workspaceID: material.workspaceID, host: host, tmuxSessionName: nil)
        ])
    }

    @MainActor
    func testSessionManagerDoesNotFallbackToSSHControlModeAfterRemotePanesExist() async {
        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "remote-with-panes")
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let manager = SessionManager()
        manager.ghosttyApp = RemoteEngineClientTestSupport.ghosttyApp
        manager.sessionMetadataStore = makeIsolatedSessionMetadataStore()
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        var fallbackReconnects: [Session] = []
        manager.attachedSessionReconnectStarter = { fallbackReconnects.append($0) }

        let session = manager.createRemoteEngineSession(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil),
            workspaceID: material.workspaceID
        )
        await waitUntil { transport.materials == [material] }
        connection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        await waitUntil { session.tabs.count == 1 }
        guard let originalTab = session.tabs.first else {
            return XCTFail("Expected remote engine tab")
        }
        guard let originalSurface = originalTab.surfaceTree?.root?.leaves().first else {
            return XCTFail("Expected remote engine surface")
        }

        connection.finish(throwing: RemoteEngineError.remote("network down"))
        let disconnectedReason = "Remote engine disconnected. [REMOTE_ENGINE_DISCONNECTED]"
        await waitUntil { attachedConnectionState(of: session) == .disconnected(reason: disconnectedReason) }

        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached remote engine mode")
        }
        XCTAssertEqual(attachedConnectionState(of: session), .disconnected(reason: disconnectedReason))
        XCTAssertEqual(attachedInfo.transport, .remoteEngine)
        XCTAssertTrue(fallbackReconnects.isEmpty)
        XCTAssertNil(session.controlClient)
        XCTAssertTrue(manager.sessions.contains(where: { $0.id == session.id }))
        XCTAssertEqual(session.tabs.map(\.id), [originalTab.id])
        XCTAssertTrue(session.tabs.first?.surfaceTree?.root?.leaves().first === originalSurface)
        XCTAssertTrue(bootstrapper.shutdowns.isEmpty)
    }

    @MainActor
    func testSessionManagerDoesNotFallbackToSSHControlModeForAttachAuthFailureBeforeRemotePanesExist() async {
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "auth-failure")
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let transport = ControlledFailingRemoteEngineTransport()
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        var fallbackReconnects: [Session] = []
        manager.attachedSessionReconnectStarter = { fallbackReconnects.append($0) }

        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(host: host, workspaceID: material.workspaceID)
        await waitUntil { transport.materials == [material] && transport.hasPendingConnect }

        transport.failPendingConnect(with: RemoteEngineError.remote("attach key belongs to another remote session"))
        let expectedReason = "Remote engine rejected the one-time attach credentials. [REMOTE_ENGINE_ATTACH_REJECTED]"
        await waitUntil { attachedConnectionState(of: session) == .disconnected(reason: expectedReason) }

        XCTAssertTrue(fallbackReconnects.isEmpty)
        XCTAssertNil(session.controlClient)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached remote engine mode")
        }
        XCTAssertEqual(attachedInfo.transport, .remoteEngine)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.attachment?.transport, .remoteEngine)
    }

    @MainActor
    func testSessionManagerRequestsKnownPaneKeyframesAfterRemoteEngineReconnect() async {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "remote-reattach")
        let manager = SessionManager()
        manager.ghosttyApp = RemoteEngineClientTestSupport.ghosttyApp
        manager.sessionMetadataStore = makeIsolatedSessionMetadataStore()
        manager.remoteEngineBootstrapper = FakeRemoteEngineBootstrapper(material: material)
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0)

        let session = manager.createRemoteEngineSession(
            host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil),
            workspaceID: material.workspaceID
        )
        await waitUntil { transport.materials.count == 1 }
        firstConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
        firstConnection.yield(.paneKeyframe(.singleRowFixture(workspaceID: material.workspaceID)))
        await waitUntil { session.tabs.count == 1 && firstConnection.keyframeRequests.count == 1 }
        XCTAssertEqual(firstConnection.keyframeRequests, [
            FakeRemoteEngineConnection.KeyframeRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                reason: .noKeyframe
            )
        ])

        firstConnection.finish()
        await waitUntil { transport.materials.count == 2 }
        await waitUntil { secondConnection.keyframeRequests.count == 1 }

        secondConnection.finish()

        XCTAssertEqual(secondConnection.keyframeRequests, [
            FakeRemoteEngineConnection.KeyframeRequest(
                workspaceID: material.workspaceID,
                paneID: 7,
                reason: .noKeyframe
            )
        ])
    }

    @MainActor
    func testScenario0003FakeAppJourneyReconnectsWithFreshMaterialAndPreservesSurfaceIdentity() async throws {
        let workspaceID = "scenario-0003-\(UUID().uuidString.prefix(8).lowercased())"
        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let firstMaterial = RemoteEngineAttachMaterial.fixture(
            workspaceID: workspaceID,
            session: String(repeating: "1", count: 64),
            key: String(repeating: "2", count: 64)
        )
        let secondMaterial = RemoteEngineAttachMaterial.fixture(
            workspaceID: workspaceID,
            session: String(repeating: "3", count: 64),
            key: String(repeating: "4", count: 64)
        )
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let bootstrapper = FakeRemoteEngineBootstrapper(materials: [firstMaterial, secondMaterial])
        let manager = SessionManager()
        manager.ghosttyApp = RemoteEngineClientTestSupport.ghosttyApp
        manager.remoteWorkspaceSurfaceFactory = { _ in
            Fantastty.Ghostty.SurfaceView(RemoteEngineClientTestSupport.ghosttyApp.app!, baseConfig: nil)
        }
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0)
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore

        let initialMarker = "COLD"
        let staleMarker = "STAL"
        let freshMarker = "FRES"
        let validMarker = "VALD"
        var observedSurface: Ghostty.SurfaceView?
        var renderedTexts: [String] = []
        var renderEvents: [(diagnostic: RemoteWorkspaceRenderDiagnostic, visibleText: String)] = []
        let renderedText: ([[RemoteGridCell]]) -> String = { rows in
            rows
                .map { row in row.map(\.text).joined() }
                .joined(separator: "\n")
        }
        let describeRenderEvents: ([(diagnostic: RemoteWorkspaceRenderDiagnostic, visibleText: String)]) -> String = { events in
            events
                .map { "\($0.diagnostic.description) visible=\($0.visibleText)" }
                .joined(separator: " | ")
        }
        manager.remoteWorkspacePaneGridRenderer = { state, _ in
            renderedTexts.append(renderedText(state.rows))
            return .rendered
        }
        manager.remoteWorkspaceRenderDiagnosticHandler = { diagnostic in
            guard let observedSurface else { return }
            renderEvents.append((diagnostic, renderedTexts.last ?? readVisibleText(from: observedSurface)))
        }

        defer {
            firstConnection.finish()
            secondConnection.finish()
        }

        let session = manager.createRemoteEngineSession(host: host, workspaceID: workspaceID)
        let expectedMaterialRequest = FakeRemoteEngineBootstrapper.MaterialRequest(
            workspaceID: workspaceID,
            host: host,
            tmuxSessionName: nil
        )
        await waitUntil { transport.materials == [firstMaterial] }

        firstConnection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: workspaceID)))
        await waitUntil {
            session.tabs.first?.surfaceTree?.root?.leaves().count == 1
                && firstConnection.keyframeRequests.count == 1
        }
        XCTAssertEqual(firstConnection.keyframeRequests, [
            FakeRemoteEngineConnection.KeyframeRequest(
                workspaceID: workspaceID,
                paneID: 7,
                reason: .noKeyframe
            )
        ])
        let originalTab = try XCTUnwrap(session.tabs.first)
        let originalSurface = try XCTUnwrap(originalTab.surfaceTree?.root?.leaves().first)
        observedSurface = originalSurface
        XCTAssertNotNil(originalSurface.remotePaneInputHandler)

        firstConnection.yield(.paneKeyframe(.singleRowFixture(
            workspaceID: workspaceID,
            keyframeID: 1,
            rowText: initialMarker
        )))
        await waitUntil {
            renderEvents.contains {
                $0.diagnostic.result == .rendered && $0.visibleText.contains(initialMarker)
            }
        }

        XCTAssertTrue(
            renderEvents.contains { $0.diagnostic.result == .rendered && $0.visibleText.contains(initialMarker) },
            describeRenderEvents(renderEvents)
        )
        XCTAssertTrue(renderEvents.allSatisfy { $0.diagnostic.hasSurface }, describeRenderEvents(renderEvents))

        let inputData = Data("echo from remote pane\n".utf8)
        originalSurface.remotePaneInputHandler?(7, RemotePaneInput(data: inputData, source: .directKey))
        await waitUntil { firstConnection.inputRequests.count == 1 }

        XCTAssertEqual(firstConnection.inputRequests, [
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: workspaceID,
                paneID: 7,
                data: inputData
            )
        ])

        firstConnection.finish(throwing: RemoteEngineError.remote("network down"))
        await waitUntil { transport.materials == [firstMaterial, secondMaterial] }

        XCTAssertEqual(bootstrapper.materialRequests, [expectedMaterialRequest, expectedMaterialRequest])
        XCTAssertEqual(transport.materials, [firstMaterial, secondMaterial])
        XCTAssertNotEqual(secondMaterial, firstMaterial)
        XCTAssertNotEqual(secondMaterial.session, firstMaterial.session)
        XCTAssertNotEqual(secondMaterial.key, firstMaterial.key)

        await waitUntil {
            secondConnection.keyframeRequests == [
                FakeRemoteEngineConnection.KeyframeRequest(
                    workspaceID: workspaceID,
                    paneID: 7,
                    reason: .noKeyframe
                )
            ]
        }
        XCTAssertEqual(secondConnection.keyframeRequests, [
            FakeRemoteEngineConnection.KeyframeRequest(
                workspaceID: workspaceID,
                paneID: 7,
                reason: .noKeyframe
            )
        ])
        XCTAssertEqual(
            attachedConnectionState(of: session),
            .reconnecting(reason: "remote engine error: network down")
        )

        secondConnection.yield(.paneKeyframe(.singleRowFixture(
            workspaceID: workspaceID,
            keyframeID: 2,
            rowText: freshMarker
        )))
        await waitUntil {
            renderEvents.contains {
                $0.diagnostic.result == .rendered && $0.visibleText.contains(freshMarker)
            }
        }

        XCTAssertTrue(
            renderEvents.contains {
                $0.diagnostic.result == .rendered && $0.visibleText.contains(freshMarker)
            },
            describeRenderEvents(renderEvents)
        )
        XCTAssertEqual(attachedConnectionState(of: session), .connected)

        let renderEventCountAfterFreshKeyframe = renderEvents.count
        secondConnection.yield(
            .paneDelta(.singleRowUpdateFixture(
                workspaceID: workspaceID,
                baseKeyframeID: 1,
                deltaSequence: 2,
                rowText: staleMarker
            )),
            delivery: .datagram
        )
        secondConnection.yield(
            .paneDelta(.singleRowUpdateFixture(
                workspaceID: workspaceID,
                baseKeyframeID: 2,
                deltaSequence: 1,
                rowText: validMarker
            )),
            delivery: .datagram
        )
        await waitUntil {
            renderEvents.dropFirst(renderEventCountAfterFreshKeyframe).contains {
                $0.diagnostic.result == .rendered && $0.visibleText.contains(validMarker)
            }
        }

        let postFreshRenderEvents = Array(renderEvents.dropFirst(renderEventCountAfterFreshKeyframe))
        XCTAssertEqual(postFreshRenderEvents.count, 1, describeRenderEvents(postFreshRenderEvents))
        XCTAssertTrue(
            postFreshRenderEvents.contains {
                $0.diagnostic.result == .rendered && $0.visibleText.contains(validMarker)
            },
            describeRenderEvents(postFreshRenderEvents)
        )
        XCTAssertFalse(
            postFreshRenderEvents.contains { $0.visibleText.contains(staleMarker) },
            describeRenderEvents(postFreshRenderEvents)
        )
        XCTAssertTrue(postFreshRenderEvents.allSatisfy { $0.diagnostic.hasSurface }, describeRenderEvents(postFreshRenderEvents))
        XCTAssertEqual(attachedConnectionState(of: session), .connected)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached remote engine mode")
        }
        XCTAssertEqual(attachedInfo.transport, .remoteEngine)
        XCTAssertEqual(attachedInfo.connectionState, .connected)
        XCTAssertEqual(session.tabs.map(\.id), [originalTab.id])
        XCTAssertTrue(session.tabs.first?.surfaceTree?.root?.leaves().first === originalSurface)

        XCTAssertEqual(metadataStore.metadata.keys.sorted(), [workspaceID])
        let storedMetadata = try XCTUnwrap(metadataStore.metadata[workspaceID])
        let storedAttachment = try XCTUnwrap(storedMetadata.attachment)
        XCTAssertEqual(storedAttachment.sessionName, "fantastty-remote-\(workspaceID)")
        XCTAssertEqual(storedAttachment.host, .ssh(host))
        XCTAssertEqual(storedAttachment.connectionState, .disconnected(reason: nil))
        XCTAssertEqual(storedAttachment.launchMode, .attach)
        XCTAssertEqual(storedAttachment.transport, .remoteEngine)

        let storedData = try JSONEncoder().encode(storedMetadata)
        let storedJSON = String(data: storedData, encoding: .utf8) ?? ""
        XCTAssertFalse(storedJSON.contains(firstMaterial.session))
        XCTAssertFalse(storedJSON.contains(firstMaterial.key))
        XCTAssertFalse(storedJSON.contains(secondMaterial.session))
        XCTAssertFalse(storedJSON.contains(secondMaterial.key))
        XCTAssertNil(SessionMetadataStore.shared.metadata[workspaceID])

        secondConnection.finish()
        await waitUntil { attachedConnectionState(of: session) == .disconnected(reason: nil) }
    }

    @MainActor
    func testClosingRemoteEngineTerminalTabDoesNotMutateLocalSessionTree() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(
            workspaceID: "remote-tab-close",
            appendSentinel: true
        )
        defer { remote.connection.finish() }

        remote.manager.closeTab(id: remote.tab.id)

        XCTAssertTrue(remote.manager.sessions.contains(where: { $0.id == remote.session.id }))
        XCTAssertEqual(remote.session.tabs.map(\.id), [remote.tab.id])
    }

    @MainActor
    func testClosingRemoteEnginePaneDoesNotMutateLocalSurfaceTree() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(
            workspaceID: "remote-pane-close",
            appendSentinel: true
        )
        defer { remote.connection.finish() }

        remote.manager.closeSurface(remote.surface)

        XCTAssertTrue(remote.manager.sessions.contains(where: { $0.id == remote.session.id }))
        XCTAssertEqual(remote.session.tabs.map(\.id), [remote.tab.id])
        XCTAssertTrue(remote.session.tabs.first?.surfaceTree?.root?.leaves().first === remote.surface)
    }

    @MainActor
    func testRemoteEnginePaneDoesNotAdvertiseSplitSupportWithoutRemoteLifecycleProtocol() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(workspaceID: "remote-split-affordance")
        defer { remote.connection.finish() }

        XCTAssertFalse(remote.manager.canPerformSplit(from: remote.surface, direction: .right))
    }

    @MainActor
    func testUnsupportedRemotePaneStateUpdatesAttachedConnectionState() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(workspaceID: "remote-unsupported-pane")
        defer { remote.connection.finish() }

        remote.connection.yield(.unsupportedPaneState(RemoteUnsupportedPaneState(
            workspaceID: remote.material.workspaceID,
            paneID: 7,
            paneGeneration: 1,
            reason: .imageProtocol,
            fallback: .blankWithDiagnostic
        )))
        await waitUntil {
            attachedConnectionState(of: remote.session) == .disconnected(
                reason: "remote pane 7 unsupported: imageProtocol"
            )
        }

        XCTAssertEqual(
            attachedConnectionState(of: remote.session),
            .disconnected(reason: "remote pane 7 unsupported: imageProtocol")
        )
    }

    @MainActor
    func testRestoreMetadataRemoteEngineSessionRestartsRemoteEngineClient() async {
        Fantastty.SessionManager.layoutURLOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-remote-engine-restore-\(UUID().uuidString).json")
        defer { Fantastty.SessionManager.layoutURLOverride = nil }

        let connection = FakeRemoteEngineConnection()
        let transport = FakeRemoteEngineTransport(connection: connection)
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "restored-remote")
        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let metadata = Fantastty.SessionMetadata(
            workspaceID: material.workspaceID,
            name: "Remote",
            attachment: Fantastty.TmuxAttachmentInfo(
                sessionName: "fantastty-remote-\(material.workspaceID)",
                host: .ssh(host),
                connectionState: .disconnected(reason: nil),
                transport: .remoteEngine
            )
        )
        let manager = SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [metadata] }
        manager.remoteEngineBootstrapper = FakeRemoteEngineBootstrapper(material: material)
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        var attachedReconnects: [Session] = []
        manager.attachedSessionReconnectStarter = { attachedReconnects.append($0) }

        XCTAssertTrue(manager.restoreTmuxSessions())
        await waitUntil { transport.materials == [material] }

        XCTAssertTrue(attachedReconnects.isEmpty)
        XCTAssertEqual(manager.sessions.count, 1)
        let session = manager.sessions[0]
        XCTAssertEqual(session.workspaceID, material.workspaceID)
        XCTAssertNil(session.controlClient)
        guard case .attached(let attachedInfo) = session.mode else {
            return XCTFail("Expected attached remote engine mode")
        }
        XCTAssertEqual(attachedInfo.host, .ssh(host))
        XCTAssertEqual(attachedInfo.transport, .remoteEngine)
        XCTAssertEqual(attachedInfo.connectionState, .connected)

        connection.finish()
    }

    @MainActor
    func testClosingRemoteEngineSessionRequestsRemoteHelperShutdown() async throws {
        let connection = FakeRemoteEngineConnection()
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "remote-close-\(UUID().uuidString.prefix(8).lowercased())")
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let transport = FakeRemoteEngineTransport(connection: connection)
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        let host = Fantastty.SSHHostInfo(user: nil, hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(
            host: host,
            workspaceID: material.workspaceID
        )
        manager.sessions.append(Session(title: "sentinel", type: .local, workspaceID: "sentinel-\(material.workspaceID)"))
        await waitUntil { transport.materials == [material] }

        manager.closeSession(id: session.id, killTmux: true)

        await waitUntil { bootstrapper.shutdowns.count == 1 }
        XCTAssertEqual(bootstrapper.shutdowns.first?.material, material)
        XCTAssertEqual(bootstrapper.shutdowns.first?.host, host)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.isArchived, false)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.isTrashed, true)
    }

    @MainActor
    func testArchivingRemoteEngineSessionRequestsRemoteHelperShutdownAndUsesInjectedMetadataStore() async throws {
        let connection = FakeRemoteEngineConnection()
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: "remote-archive-\(UUID().uuidString.prefix(8).lowercased())")
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let transport = FakeRemoteEngineTransport(connection: connection)
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        let host = Fantastty.SSHHostInfo(user: nil, hostname: "remote.example.invalid", port: nil)
        let session = manager.createRemoteEngineSession(
            host: host,
            workspaceID: material.workspaceID
        )
        manager.sessions.append(Session(title: "sentinel", type: .local, workspaceID: "sentinel-\(material.workspaceID)"))
        await waitUntil { transport.materials == [material] }

        manager.archiveSession(id: session.id)

        await waitUntil { bootstrapper.shutdowns.count == 1 }
        XCTAssertEqual(bootstrapper.shutdowns.first?.material, material)
        XCTAssertEqual(bootstrapper.shutdowns.first?.host, host)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.isArchived, true)
        XCTAssertEqual(metadataStore.metadata[session.workspaceID]?.isTrashed, false)
    }

    @MainActor
    func testUnarchivingRemoteEngineSessionPreservesRemoteAttachment() async throws {
        let firstConnection = FakeRemoteEngineConnection()
        let secondConnection = FakeRemoteEngineConnection()
        let workspaceID = "remote-unarchive-\(UUID().uuidString.prefix(8).lowercased())"
        let firstMaterial = RemoteEngineAttachMaterial.fixture(
            workspaceID: workspaceID,
            session: String(repeating: "1", count: 64),
            key: String(repeating: "2", count: 64)
        )
        let secondMaterial = RemoteEngineAttachMaterial.fixture(
            workspaceID: workspaceID,
            session: String(repeating: "3", count: 64),
            key: String(repeating: "4", count: 64)
        )
        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: 2222)
        let bootstrapper = FakeRemoteEngineBootstrapper(materials: [firstMaterial, secondMaterial])
        let transport = FakeRemoteEngineTransport(connections: [firstConnection, secondConnection])
        let manager = SessionManager()
        let metadataStore = makeIsolatedSessionMetadataStore()
        manager.sessionMetadataStore = metadataStore
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once

        let session = manager.createRemoteEngineSession(host: host, workspaceID: workspaceID)
        manager.sessions.append(Session(title: "sentinel", type: .local, workspaceID: "sentinel-\(workspaceID)"))
        await waitUntil { transport.materials == [firstMaterial] }
        manager.archiveSession(id: session.id)
        await waitUntil { metadataStore.metadata[workspaceID]?.isArchived == true }

        manager.unarchiveSession(workspaceID: workspaceID)
        await waitUntil { transport.materials == [firstMaterial, secondMaterial] }

        let restored = try XCTUnwrap(manager.sessions.first { $0.workspaceID == workspaceID })
        guard case .attached(let attachedInfo) = restored.mode else {
            return XCTFail("Expected unarchived remote engine session")
        }
        XCTAssertEqual(attachedInfo.host, .ssh(host))
        XCTAssertEqual(attachedInfo.transport, .remoteEngine)
        XCTAssertEqual(attachedInfo.launchMode, .attach)
        XCTAssertEqual(bootstrapper.materialRequests.map(\.workspaceID), [workspaceID, workspaceID])
        XCTAssertEqual(metadataStore.metadata[workspaceID]?.isArchived, false)
    }

    @MainActor
    func testReattachingRemoteEnginePlaceholderRestartsRemoteEngineClient() async throws {
        let connection = FakeRemoteEngineConnection()
        let workspaceID = "remote-reattach-placeholder-\(UUID().uuidString.prefix(8).lowercased())"
        let material = RemoteEngineAttachMaterial.fixture(workspaceID: workspaceID)
        let host = Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: 2222)
        let bootstrapper = FakeRemoteEngineBootstrapper(material: material)
        let transport = FakeRemoteEngineTransport(connection: connection)
        let manager = SessionManager()
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = .once
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-remote-\(workspaceID)",
            host: .ssh(host),
            connectionState: .disconnected(reason: "offline"),
            launchMode: .attach,
            transport: .remoteEngine
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: workspaceID)
        session.backingState = .missingAttachedBacking(reason: "offline")
        manager.sessions = [session]

        manager.reattachPlaceholderSession(session)
        await waitUntil { transport.materials == [material] }

        XCTAssertNil(session.controlClient)
        guard case .attached(let restoredInfo) = session.mode else {
            return XCTFail("Expected remote engine attached mode")
        }
        XCTAssertEqual(restoredInfo.host, .ssh(host))
        XCTAssertEqual(restoredInfo.transport, .remoteEngine)
        XCTAssertEqual(restoredInfo.connectionState, .connected)
        XCTAssertEqual(bootstrapper.materialRequests.map(\.workspaceID), [workspaceID])
    }

    @MainActor
    func testClearScreenRoutesControlLToRemoteEnginePane() async throws {
        let remote = try await makeRemoteEngineSessionWithSinglePane(
            workspaceID: "remote-clear-screen-\(UUID().uuidString.prefix(8).lowercased())",
            appendSentinel: true
        )
        defer {
            remote.connection.finish()
        }
        remote.manager.selectedSessionID = remote.session.id
        remote.session.selectedTabID = remote.tab.id
        remote.tab.focusedSurface = remote.surface

        remote.manager.clearScreen()
        await waitUntil { remote.connection.inputRequests.count == 1 }

        XCTAssertEqual(remote.connection.inputRequests, [
            FakeRemoteEngineConnection.InputRequest(
                workspaceID: remote.material.workspaceID,
                paneID: 7,
                data: Data([0x0c])
            )
        ])
    }
}

private struct RemoteEngineSessionFixture {
    let manager: SessionManager
    let connection: FakeRemoteEngineConnection
    let transport: FakeRemoteEngineTransport
    let material: RemoteEngineAttachMaterial
    let session: Session
    let tab: TerminalTab
    let surface: Ghostty.SurfaceView
}

@MainActor
private func makeRemoteEngineSessionWithSinglePane(
    workspaceID: String,
    appendSentinel: Bool = false
) async throws -> RemoteEngineSessionFixture {
    let connection = FakeRemoteEngineConnection()
    let transport = FakeRemoteEngineTransport(connection: connection)
    let material = RemoteEngineAttachMaterial.fixture(workspaceID: workspaceID)
    let manager = SessionManager()
    manager.ghosttyApp = RemoteEngineClientTestSupport.ghosttyApp
    manager.sessionMetadataStore = makeIsolatedSessionMetadataStore()
    manager.remoteEngineBootstrapper = FakeRemoteEngineBootstrapper(material: material)
    manager.remoteEngineTransport = transport
    manager.remoteEngineReconnectPolicy = .once

    let session = manager.createRemoteEngineSession(
        host: Fantastty.SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil),
        workspaceID: material.workspaceID
    )
    if appendSentinel {
        manager.sessions.append(Session(title: "sentinel", type: .local, workspaceID: "sentinel-\(material.workspaceID)"))
    }
    await waitUntil { transport.materials == [material] }
    connection.yield(.workspaceSnapshot(.singlePaneFixture(workspaceID: material.workspaceID)))
    await waitUntil { session.tabs.first?.surfaceTree?.root?.leaves().count == 1 }

    let tab = try XCTUnwrap(session.tabs.first)
    let surface = try XCTUnwrap(tab.surfaceTree?.root?.leaves().first)
    return RemoteEngineSessionFixture(
        manager: manager,
        connection: connection,
        transport: transport,
        material: material,
        session: session,
        tab: tab,
        surface: surface
    )
}

private func makeIsolatedSessionMetadataStore() -> SessionMetadataStore {
    SessionMetadataStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-test-metadata-\(UUID().uuidString).json")
    )
}

private struct RemoteEngineArtifactFixture {
    let rootURL: URL
    let helperURL: URL
    let libraryURL: URL
}

private func makeRemoteEngineArtifactFixture(
    version: String = "abc123",
    label: String = "linux-amd64",
    osName: String = "linux",
    libraryName: String = "libghostty-vt.so.0.1.0",
    manifestArch: String = "amd64",
    helperSHAOverride: String? = nil,
    librarySHAOverride: String? = nil
) throws -> RemoteEngineArtifactFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fantastty-remote-engine-artifacts-\(UUID().uuidString)")
    let artifactDir = root.appendingPathComponent("\(label)/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
    let helperURL = root.appendingPathComponent("\(label)/fantastty-helper")
    let libraryURL = root.appendingPathComponent("\(label)/lib/\(libraryName)")
    try Data("helper-binary".utf8).write(to: helperURL)
    try Data("ghostty-vt".utf8).write(to: libraryURL)

    let helperSHA: String
    if let helperSHAOverride {
        helperSHA = helperSHAOverride
    } else {
        helperSHA = try sha256Hex(of: helperURL)
    }
    let librarySHA: String
    if let librarySHAOverride {
        librarySHA = librarySHAOverride
    } else {
        librarySHA = try sha256Hex(of: libraryURL)
    }
    try """
    {
      "version": "\(version)",
      "artifacts": {
        "\(label)": {
          "os": "\(osName)",
          "arch": "\(manifestArch)",
          "helper": "\(label)/fantastty-helper",
          "helper_sha256": "\(helperSHA)",
          "library": "\(label)/lib/\(libraryName)",
          "library_sha256": "\(librarySHA)"
        }
      }
    }
    """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    return RemoteEngineArtifactFixture(
        rootURL: root,
        helperURL: helperURL,
        libraryURL: libraryURL
    )
}

private final class FakeRemoteEngineBootstrapper: Fantastty.RemoteEngineBootstrapper {
    struct MaterialRequest: Equatable {
        let workspaceID: String
        let host: Fantastty.SSHHostInfo
        let tmuxSessionName: String?
    }

    struct Shutdown: Equatable {
        let material: Fantastty.RemoteEngineAttachMaterial
        let host: Fantastty.SSHHostInfo
    }

    let material: Fantastty.RemoteEngineAttachMaterial
    private var materialQueue: [Fantastty.RemoteEngineAttachMaterial]
    private var lastMaterial: Fantastty.RemoteEngineAttachMaterial
    private let materialFactory: ((String) -> Fantastty.RemoteEngineAttachMaterial)?
    private(set) var materialRequests: [MaterialRequest] = []
    private(set) var shutdowns: [Shutdown] = []

    init(material: Fantastty.RemoteEngineAttachMaterial) {
        self.material = material
        self.materialQueue = []
        self.lastMaterial = material
        self.materialFactory = nil
    }

    init(materials: [Fantastty.RemoteEngineAttachMaterial]) {
        precondition(!materials.isEmpty)
        self.material = materials[0]
        self.materialQueue = materials
        self.lastMaterial = materials[0]
        self.materialFactory = nil
    }

    init(materialForWorkspaceID materialFactory: @escaping (String) -> Fantastty.RemoteEngineAttachMaterial) {
        let material = materialFactory("workspace-1")
        self.material = material
        self.materialQueue = []
        self.lastMaterial = material
        self.materialFactory = materialFactory
    }

    func attachMaterial(
        workspaceID: String,
        host: Fantastty.SSHHostInfo
    ) async throws -> Fantastty.RemoteEngineAttachMaterial {
        try await attachMaterial(workspaceID: workspaceID, host: host, tmuxSessionName: nil)
    }

    func attachMaterial(
        workspaceID: String,
        host: Fantastty.SSHHostInfo,
        tmuxSessionName: String?
    ) async throws -> Fantastty.RemoteEngineAttachMaterial {
        materialRequests.append(MaterialRequest(
            workspaceID: workspaceID,
            host: host,
            tmuxSessionName: tmuxSessionName
        ))
        if let materialFactory {
            lastMaterial = materialFactory(workspaceID)
            return lastMaterial
        }
        if !materialQueue.isEmpty {
            lastMaterial = materialQueue.removeFirst()
        }
        return lastMaterial
    }

    func shutdown(
        material: Fantastty.RemoteEngineAttachMaterial,
        host: Fantastty.SSHHostInfo
    ) async throws {
        shutdowns.append(Shutdown(material: material, host: host))
    }
}

private struct FailingRemoteEngineBootstrapper: Fantastty.RemoteEngineBootstrapper {
    func attachMaterial(
        workspaceID: String,
        host: Fantastty.SSHHostInfo
    ) async throws -> Fantastty.RemoteEngineAttachMaterial {
        throw RemoteEngineError.bootstrapFailed("missing helper")
    }

    func attachMaterial(
        workspaceID: String,
        host: Fantastty.SSHHostInfo,
        tmuxSessionName: String?
    ) async throws -> Fantastty.RemoteEngineAttachMaterial {
        throw RemoteEngineError.bootstrapFailed("missing helper")
    }

    func shutdown(
        material: Fantastty.RemoteEngineAttachMaterial,
        host: Fantastty.SSHHostInfo
    ) async throws {}
}

private final class RecordingRemoteEngineProcessRunner: RemoteEngineProcessRunning {
    struct Call {
        let executable: String
        let arguments: [String]
    }

    private var results: [Result<String, Error>]
    private(set) var calls: [Call] = []

    init(outputs: [String]) {
        self.results = outputs.map(Result.success)
    }

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    func run(_ executableURL: URL, arguments: [String]) async throws -> String {
        calls.append(Call(executable: executableURL.path, arguments: arguments))
        guard !results.isEmpty else {
            throw RemoteEngineError.bootstrapFailed("unexpected command: \(executableURL.path) \(arguments.joined(separator: " "))")
        }
        return try results.removeFirst().get()
    }
}

private final class MissingRemoteLibraryLinksProcessRunner: RemoteEngineProcessRunning {
    struct Call {
        let executable: String
        let arguments: [String]
    }

    let helperVersion: String
    private(set) var calls: [Call] = []

    init(helperVersion: String) {
        self.helperVersion = helperVersion
    }

    func run(_ executableURL: URL, arguments: [String]) async throws -> String {
        calls.append(Call(executable: executableURL.path, arguments: arguments))
        if executableURL.path == "/usr/bin/scp" {
            return ""
        }

        guard executableURL.path == "/usr/bin/ssh" else {
            throw RemoteEngineError.bootstrapFailed("unexpected command: \(executableURL.path)")
        }
        let remoteCommand = try XCTUnwrap(arguments.last)
        if remoteCommand == "uname -s && uname -m" {
            return "Linux\nx86_64\n"
        }
        if remoteCommand.contains("mkdir -p") {
            return ""
        }
        if remoteCommand.contains("fantastty-helper") && remoteCommand.contains("--version") {
            return "fantastty-helper version=\(helperVersion) arch=amd64\n"
        }
        if remoteCommand.contains("sha256sum -c -") && remoteCommand.contains("libghostty-vt.so") {
            if remoteCommand.contains("readlink") {
                throw RemoteEngineError.bootstrapFailed("remote library link missing")
            }
            return ""
        }
        return ""
    }
}

private final class FakeRemoteEngineTransport: RemoteEngineTransport {
    private var connections: [FakeRemoteEngineConnection]
    private(set) var materials: [RemoteEngineAttachMaterial] = []

    init(connection: FakeRemoteEngineConnection) {
        connections = [connection]
    }

    init(connections: [FakeRemoteEngineConnection]) {
        self.connections = connections
    }

    func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection {
        materials.append(material)
        guard !connections.isEmpty else {
            throw RemoteEngineError.remote("unexpected reconnect")
        }
        return connections.removeFirst()
    }
}

private actor ControlledAttachMaterialProvider {
    private var continuation: CheckedContinuation<RemoteEngineAttachMaterial, Error>?

    func nextMaterial() async throws -> RemoteEngineAttachMaterial {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingRequest() -> Bool {
        continuation != nil
    }

    func resume(returning material: RemoteEngineAttachMaterial) {
        continuation?.resume(returning: material)
        continuation = nil
    }
}

private actor ControlledRemoteEngineTransport: RemoteEngineTransport {
    private(set) var materials: [RemoteEngineAttachMaterial] = []
    private var continuation: CheckedContinuation<RemoteEngineConnection, Error>?

    func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection {
        materials.append(material)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingConnect() -> Bool {
        continuation != nil
    }

    func recordedMaterials() -> [RemoteEngineAttachMaterial] {
        materials
    }

    func resume(with connection: RemoteEngineConnection) {
        continuation?.resume(returning: connection)
        continuation = nil
    }
}

private final class ControlledFailingRemoteEngineTransport: RemoteEngineTransport {
    private(set) var materials: [RemoteEngineAttachMaterial] = []
    private var pendingConnect: CheckedContinuation<RemoteEngineConnection, Error>?

    var hasPendingConnect: Bool {
        pendingConnect != nil
    }

    func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection {
        materials.append(material)
        return try await withCheckedThrowingContinuation { continuation in
            pendingConnect = continuation
        }
    }

    func failPendingConnect(with error: Error) {
        pendingConnect?.resume(throwing: error)
        pendingConnect = nil
    }
}

private final class FakeRemoteEngineConnection: RemoteEngineConnection {
    struct KeyframeRequest: Equatable {
        let workspaceID: String
        let paneID: Int
        let reason: RemotePaneGridKeyframeRequestReason
    }

    struct InputRequest: Equatable {
        let workspaceID: String
        let paneID: Int
        let data: Data
    }

    struct ResizeRequest: Equatable {
        let workspaceID: String
        let paneID: Int
        let size: RemoteGridSize
    }

    struct SelectWindowRequest: Equatable {
        let workspaceID: String
        let windowID: Int
    }

    let messages: AsyncThrowingStream<RemoteEngineInboundMessage, Error>
    private let continuation: AsyncThrowingStream<RemoteEngineInboundMessage, Error>.Continuation
    private(set) var keyframeRequests: [KeyframeRequest] = []
    private(set) var inputRequests: [InputRequest] = []
    private(set) var resizeRequests: [ResizeRequest] = []
    private(set) var selectWindowRequests: [SelectWindowRequest] = []
    private(set) var newWindowRequests: [String] = []
    private(set) var blockedInputSendCount = 0
    private var shouldBlockNextInput = false
    private var blockedInputContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextKeyframeRequest = false
    private var blockedKeyframeRequestContinuation: CheckedContinuation<Void, Never>?
    private var nextKeyframeRequestError: Error?
    private var nextInputError: Error?
    private(set) var blockedKeyframeRequestCount = 0
    private(set) var closeCount = 0

    init() {
        var capturedContinuation: AsyncThrowingStream<RemoteEngineInboundMessage, Error>.Continuation!
        messages = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func yield(_ message: RemoteWorkspaceMessage, delivery: RemotePaneDeltaDelivery = .reliable) {
        continuation.yield(RemoteEngineInboundMessage(message, delivery: delivery))
    }

    func finish() {
        continuation.finish()
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }

    func requestKeyframe(workspaceID: String, paneID: Int, reason: RemotePaneGridKeyframeRequestReason) async throws {
        if let error = nextKeyframeRequestError {
            nextKeyframeRequestError = nil
            throw error
        }
        if shouldBlockNextKeyframeRequest {
            shouldBlockNextKeyframeRequest = false
            blockedKeyframeRequestCount += 1
            await withCheckedContinuation { continuation in
                blockedKeyframeRequestContinuation = continuation
            }
        }
        keyframeRequests.append(KeyframeRequest(workspaceID: workspaceID, paneID: paneID, reason: reason))
    }

    func sendKeys(workspaceID: String, paneID: Int, data: Data) async throws {
        if let error = nextInputError {
            nextInputError = nil
            throw error
        }
        if shouldBlockNextInput {
            shouldBlockNextInput = false
            blockedInputSendCount += 1
            await withCheckedContinuation { continuation in
                blockedInputContinuation = continuation
            }
        }
        inputRequests.append(InputRequest(workspaceID: workspaceID, paneID: paneID, data: data))
    }

    func resizePane(workspaceID: String, paneID: Int, size: RemoteGridSize) async throws {
        resizeRequests.append(ResizeRequest(workspaceID: workspaceID, paneID: paneID, size: size))
    }

    func selectWindow(workspaceID: String, windowID: Int) async throws {
        selectWindowRequests.append(SelectWindowRequest(workspaceID: workspaceID, windowID: windowID))
    }

    func newWindow(workspaceID: String) async throws {
        newWindowRequests.append(workspaceID)
    }

    func blockNextInputBeforeRecording() {
        shouldBlockNextInput = true
    }

    func blockNextKeyframeRequestBeforeRecording() {
        shouldBlockNextKeyframeRequest = true
    }

    func unblockNextInput() {
        blockedInputContinuation?.resume()
        blockedInputContinuation = nil
    }

    func unblockNextKeyframeRequest() {
        blockedKeyframeRequestContinuation?.resume()
        blockedKeyframeRequestContinuation = nil
    }

    func failNextKeyframeRequest(with error: Error) {
        nextKeyframeRequestError = error
    }

    func failNextInput(with error: Error) {
        nextInputError = error
    }

    func close() {
        closeCount += 1
        continuation.finish()
    }
}

private extension RemoteEngineAttachMaterial {
    static func fixture(
        workspaceID: String = "workspace-1",
        session: String = "\(RemoteEngineClientFixtureValues.sessionID)",
        key: String = "\(RemoteEngineClientFixtureValues.attachKey)"
    ) -> RemoteEngineAttachMaterial {
        RemoteEngineAttachMaterial(
            workspaceID: workspaceID,
            host: "remote.example.invalid",
            port: 33324,
            session: session,
            key: key,
            expires: Date(timeIntervalSince1970: 1_781_976_518),
            helperPID: 3_108_381,
            helperVersion: "84dfd78",
            helperArch: "amd64",
            certSHA256: "\(RemoteEngineClientFixtureValues.certificatePin)",
            alpn: "fantastty-remote-engine-v1"
        )
    }
}

private extension RemoteWorkspaceSnapshot {
    static func singlePaneFixture(workspaceID: String = "workspace-1") -> RemoteWorkspaceSnapshot {
        RemoteWorkspaceSnapshot(
            workspaceID: workspaceID,
            layoutGeneration: 1,
            windows: [RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 4, rows: 1)
                )
            ]
        )
    }
}

private extension RemotePaneKeyframe {
    static func singleRowFixture(
        workspaceID: String = "workspace-1",
        keyframeID: UInt64 = 1,
        rowText: String = "ok"
    ) -> RemotePaneKeyframe {
        let columns = 4
        return RemotePaneKeyframe(
            workspaceID: workspaceID,
            paneID: 7,
            paneGeneration: 1,
            keyframeID: keyframeID,
            gridSize: RemoteGridSize(columns: columns, rows: 1),
            rows: [
                RemoteGridRow(index: 0, rowVersion: 1, cells: remoteGridCells(rowText, columns: columns))
            ],
            cursor: RemoteCursorState(
                row: 0,
                column: cursorColumn(for: rowText, columns: columns),
                visible: true,
                shape: .block
            ),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
    }
}

private extension RemotePaneDelta {
    static func singleRowUpdateFixture(
        workspaceID: String = "workspace-1",
        baseKeyframeID: UInt64 = 1,
        deltaSequence: UInt64 = 1,
        rowText: String = "ok"
    ) -> RemotePaneDelta {
        let columns = 4
        return RemotePaneDelta(
            workspaceID: workspaceID,
            paneID: 7,
            paneGeneration: 1,
            baseKeyframeID: baseKeyframeID,
            deltaSequence: deltaSequence,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 2, update: .fullRow(remoteGridCells(rowText, columns: columns)))
            ],
            cursor: RemoteCursorState(
                row: 0,
                column: cursorColumn(for: rowText, columns: columns),
                visible: true,
                shape: .block,
                cursorVersion: 2
            )
        )
    }
}

private func remoteGridCells(_ text: String, columns: Int) -> [RemoteGridCell] {
    var cells = text.prefix(columns).map { RemoteGridCell.text(String($0)) }
    while cells.count < columns {
        cells.append(.blank)
    }
    return cells
}

private func cursorColumn(for text: String, columns: Int) -> Int {
    min(text.count, columns - 1)
}

private func readVisibleText(from surfaceView: Fantastty.Ghostty.SurfaceView) -> String {
    guard let surface = surfaceView.surface else { return "" }

    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
        top_left: ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0),
        bottom_right: ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0),
        rectangle: false)

    guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let textPointer = text.text else { return "" }

    let buffer = UnsafeRawBufferPointer(start: textPointer, count: Int(text.text_len))
    return String(decoding: buffer, as: UTF8.self)
}

private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func waitUntilAsync(
    timeout: TimeInterval = 2,
    _ condition: @escaping () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private enum RemoteEngineTimeoutResult<Success> {
    case success(Success)
    case failure(Error)
    case timedOut
}

private func withRemoteEngineTimeout<Success>(
    seconds: UInt64,
    operation: @escaping () async throws -> Success
) async -> RemoteEngineTimeoutResult<Success> {
    let task = Task {
        do {
            return RemoteEngineTimeoutResult.success(try await operation())
        } catch {
            return RemoteEngineTimeoutResult.failure(error)
        }
    }
    let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        task.cancel()
    }
    let result = await task.value
    timeoutTask.cancel()
    if task.isCancelled {
        return .timedOut
    }
    return result
}

private func attachedConnectionState(of session: Session) -> Fantastty.ConnectionState? {
    guard case .attached(let info) = session.mode else { return nil }
    return info.connectionState
}

private func assertRemoteEngineLaunchCommand(
    _ command: String,
    workspaceID: String,
    ttl: String,
    keyTTL: String,
    advertiseHost: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(command.contains("env -u XDG_RUNTIME_DIR"), file: file, line: line)
    XCTAssertTrue(command.contains("LD_LIBRARY_PATH='.cache/fantastty/remote-engine/lib'"), file: file, line: line)
    XCTAssertTrue(
        command.contains("'.cache/fantastty/remote-engine/fantastty-helper' launch-or-resume '\(workspaceID)'"),
        file: file,
        line: line
    )
    XCTAssertFalse(command.contains("launch-or-resume --workspace"), file: file, line: line)
    XCTAssertTrue(command.contains("--ttl '\(ttl)'"), file: file, line: line)
    XCTAssertTrue(command.contains("--key-ttl '\(keyTTL)'"), file: file, line: line)
    if let advertiseHost {
        XCTAssertTrue(
            command.contains("FANTASTTY_REMOTE_ADVERTISE_HOST='\(advertiseHost)'"),
            file: file,
            line: line
        )
    }

    let paddedCommand = " \(command) "
    for forbidden in ["sudo", "su", "doas", "launchctl", "systemd", "systemctl"] {
        XCTAssertFalse(
            paddedCommand.contains(" \(forbidden) "),
            "bootstrap command must not include \(forbidden): \(command)",
            file: file,
            line: line
        )
    }
}

private func assertRemoteEngineSSHOptions(
    _ arguments: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    func assertContainsOption(_ option: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let containsPair = arguments.indices.contains { index in
            arguments[index] == option
                && arguments.indices.contains(index + 1)
                && arguments[index + 1] == value
        }
        guard containsPair else {
            XCTFail("missing \(option) \(value) in \(arguments)", file: file, line: line)
            return
        }
    }

    assertContainsOption("-o", "BatchMode=yes", file: file, line: line)
    assertContainsOption("-o", "ConnectTimeout=10", file: file, line: line)
    assertContainsOption("-o", "ConnectionAttempts=1", file: file, line: line)
    assertContainsOption("-o", "ControlMaster=no", file: file, line: line)
    assertContainsOption("-o", "ControlPath=none", file: file, line: line)
}

private func assertRemoteEngineSSHCommand(
    _ arguments: [String],
    target: String,
    usesConfigDump: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if usesConfigDump {
        XCTAssertEqual(arguments.first, "-G", file: file, line: line)
    }
    assertRemoteEngineSSHOptions(arguments, file: file, line: line)
    guard let terminatorIndex = arguments.firstIndex(of: "--"),
          arguments.indices.contains(terminatorIndex + 1) else {
        XCTFail("missing SSH target after option terminator in \(arguments)", file: file, line: line)
        return
    }
    XCTAssertEqual(arguments[terminatorIndex + 1], target, file: file, line: line)
}

private func recursiveStringValues(in value: Any) -> Set<String> {
    var values = Set<String>()
    collectStringValues(in: value, into: &values)
    return values
}

private func collectStringValues(in value: Any, into values: inout Set<String>) {
    if let string = value as? String {
        values.insert(string)
        return
    }

    let mirror = Mirror(reflecting: value)
    for child in mirror.children {
        collectStringValues(in: child.value, into: &values)
    }
}

private func runTmux(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: TmuxManager.shared.tmuxPath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}
