import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
private enum RemoteEngineLiveWorkspaceTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

@MainActor
final class RemoteEngineLiveWorkspaceSmokeTests: XCTestCase {
    func testLiveConfigurationReadsLaunchArgumentsWhenEnvironmentIsUnavailable() throws {
        let configuration = try XCTUnwrap(RemoteEngineLiveWorkspaceConfiguration(
            environment: [:],
            arguments: [
                "FantasttyTests",
                "--fantastty-remote-engine-e2e-host=remote.example.invalid",
                "--fantastty-remote-engine-e2e-advertise-host=198.51.100.96",
                "--fantastty-remote-engine-e2e-loopback-relay=true",
                "--fantastty-remote-engine-e2e-user=jesse",
                "--fantastty-remote-engine-e2e-port=2222"
            ]
        ))

        XCTAssertEqual(configuration.hostname, "remote.example.invalid")
        XCTAssertEqual(configuration.advertiseHost, "198.51.100.96")
        XCTAssertTrue(configuration.usesLoopbackRelay)
        XCTAssertEqual(configuration.user, "jesse")
        XCTAssertEqual(configuration.port, 2222)
    }

    func testLiveConfigurationReadsSoakGateArguments() throws {
        let configuration = try XCTUnwrap(RemoteEngineLiveWorkspaceConfiguration(
            environment: [:],
            arguments: [
                "FantasttyTests",
                "--fantastty-remote-engine-e2e-host=remote.example.invalid",
                "--fantastty-live-remote-engine-idle-seconds=28800",
                "--fantastty-live-remote-engine-idle-marker-interval-seconds=60",
                "--fantastty-live-remote-engine-drain-lines=5000",
                "--fantastty-live-remote-engine-drain-line-bytes=160",
                "--fantastty-live-remote-engine-helper-rss-max-kb=262144",
                "--fantastty-live-remote-engine-headless-evidence=true"
            ]
        ))

        XCTAssertEqual(configuration.longIdleSeconds, 28_800)
        XCTAssertEqual(configuration.idleMarkerIntervalSeconds, 60)
        XCTAssertEqual(configuration.highOutputDrainLines, 5_000)
        XCTAssertEqual(configuration.highOutputDrainLineBytes, 160)
        XCTAssertEqual(configuration.helperRSSMaxKB, 262_144)
        XCTAssertTrue(configuration.headlessEvidence)
    }

    func testLongIdleCommandSubmitsToRemoteShell() {
        let command = longIdleCommand(marker: "FTRIDLE-TEST", idleSeconds: 1, intervalSeconds: 1)

        XCTAssertTrue(command.hasSuffix("\n"))
        XCTAssertTrue(command.contains("FTRIDLE-TEST-%04d"))
        XCTAssertTrue(command.contains("FTRIDLE-TEST-DONE"))
    }

    func testHighOutputDrainCommandSubmitsToRemoteShell() {
        let command = highOutputDrainCommand(marker: "FTRDRAIN-TEST", lineCount: 1, lineByteCount: 8)

        XCTAssertTrue(command.hasSuffix("\n"))
        XCTAssertTrue(command.contains("FTRDRAIN-TEST-%05d"))
        XCTAssertTrue(command.contains("FTRDRAIN-TEST-DONE"))
    }

    func testLiveRemoteSessionStateParsesHelperIdentityAndSocketState() {
        let activeState = LiveRemoteSessionState(
            output: "remoteState=ok registry_present=true helper_alive=true helper_identity=true private_tmux_present=true private_tmux_clients=1 socket_exists=true helper_rss_kb=12345"
        )
        XCTAssertTrue(activeState.probeSucceeded)
        XCTAssertTrue(activeState.helperIdentityMatches)
        XCTAssertTrue(activeState.socketExists)
        XCTAssertEqual(activeState.helperRSSKB, 12_345)

        let cleanedState = LiveRemoteSessionState(
            output: "remoteState=ok registry_present=false helper_alive=false helper_identity=false private_tmux_present=false private_tmux_clients=0 socket_exists=false"
        )
        XCTAssertTrue(cleanedState.probeSucceeded)
        XCTAssertFalse(cleanedState.helperIdentityMatches)
        XCTAssertFalse(cleanedState.socketExists)

        let errorState = LiveRemoteSessionState(summary: "remoteState=error ssh timed out")
        XCTAssertFalse(errorState.probeSucceeded)
    }

    func testPrivateRemoteWorkspaceReconnectsWithFreshKeyframe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configuration = RemoteEngineLiveWorkspaceConfiguration(
            environment: environment,
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            throw XCTSkip("Set FANTASTTY_REMOTE_ENGINE_E2E_HOST or pass --fantastty-remote-engine-e2e-host to run the live remote-engine smoke test.")
        }

        let workspaceID = "live-\(UUID().uuidString.prefix(8).lowercased())"
        let host = Fantastty.SSHHostInfo(
            user: configuration.user,
            hostname: configuration.hostname,
            port: configuration.port
        )
        let diagnosticLog = LiveRemoteEngineDiagnosticLog()
        let bridgeRenderLog = LiveRemoteWorkspaceRenderDiagnosticLog()
        let liveProcessRunner = LiveRemoteEngineProcessRunner(timeout: 60)
        var baseBootstrapper = SSHRemoteEngineBootstrapper(advertiseHostOverride: configuration.advertiseHost)
        baseBootstrapper.ttl = "20s"
        baseBootstrapper.keyTTL = "3s"
        baseBootstrapper.processRunner = liveProcessRunner
        var helperDeployer = RemoteEngineHelperDeployer()
        helperDeployer.processRunner = liveProcessRunner
        baseBootstrapper.helperDeployer = helperDeployer
        let bootstrapper = LiveRemoteEngineBootstrapper(
            base: baseBootstrapper,
            usesLoopbackRelay: configuration.usesLoopbackRelay,
            processRunner: liveProcessRunner
        )
        let transport = LiveRecordingRemoteEngineTransport(
            base: RemoteEngineNWQUICTransport { event in
                Task {
                    await diagnosticLog.record(event)
                }
            }
        )
        let manager = makeLiveSessionManager(
            bootstrapper: bootstrapper,
            transport: transport,
            bridgeRenderLog: bridgeRenderLog
        )
        addTeardownBlock {
            await bootstrapper.shutdownRecordedMaterials(host: host)
            bootstrapper.stopRelays()
        }

        let session = manager.createRemoteEngineSession(host: host, workspaceID: workspaceID)

        try await waitUntilLive(
            "first QUIC connection",
            diagnostics: {
                [
                    self.connectionStateDescription(for: session),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.connectionCount() == 1 && self.isRemoteEngineConnected(session)
        }
        let surface = try await waitForRemoteSurface(in: session)
        let paneID = try XCTUnwrap(surface.tmuxPaneID)
        let inputHandler = try XCTUnwrap(surface.remotePaneInputHandler)

        try await waitUntilLive(
            "initial remote grid runtime state",
            diagnostics: {
                [
                    await transport.messageSummary(on: 0, containing: "<initial remote grid>"),
                    await bootstrapper.remoteQUICLogSummary(host: host),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.hasRuntimeRenderAction(on: 0)
        }
        try await waitUntilLive(
            "initial remote grid render",
            diagnostics: {
                [
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await bridgeRenderLog.hasRenderedGrid()
        }
        let firstMaterial = try await waitForAttachMaterial(
            bootstrapper,
            count: 1,
            description: "initial SSH bootstrap material"
        )
        let firstRemoteState = await bootstrapper.remoteSessionState(host: host, material: firstMaterial)
        XCTAssertTrue(firstRemoteState.probeSucceeded, firstRemoteState.summary)
        XCTAssertTrue(firstRemoteState.registryPresent, firstRemoteState.summary)
        XCTAssertTrue(firstRemoteState.helperAlive, firstRemoteState.summary)
        XCTAssertTrue(firstRemoteState.helperIdentityMatches, firstRemoteState.summary)
        XCTAssertTrue(firstRemoteState.privateTmuxPresent, firstRemoteState.summary)
        XCTAssertGreaterThanOrEqual(firstRemoteState.privateTmuxClients, 1, firstRemoteState.summary)

        let firstMarker = "FTRLIVE-\(String(UUID().uuidString.prefix(8)))"
        inputHandler(
            paneID,
            RemotePaneInput(data: Data("printf '\(firstMarker)\\n'\n".utf8), source: .directKey)
        )
        try await waitUntilLive(
            "remote grid runtime state containing first marker",
            diagnostics: {
                [
                    await transport.messageSummary(on: 0, containing: firstMarker),
                    await bootstrapper.remoteWorkspaceSummary(host: host, containing: firstMarker),
                    await bootstrapper.remoteQUICLogSummary(host: host),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.hasRuntimeRenderAction(on: 0, containing: firstMarker)
        }
        try await waitForVisibleText(containing: firstMarker, from: surface, in: session) {
            await bridgeRenderLog.summary()
        }

        await transport.closeConnection(at: 0)
        try await waitUntilLive("second QUIC connection") {
            await transport.connectionCount() == 2 && self.isRemoteEngineConnected(session)
        }
        try await waitUntilLive("fresh reconnect keyframe containing first marker") {
            await transport.hasKeyframe(on: 1, containing: firstMarker)
        }
        let reconnectKeyframePrecedesDatagram = await transport.hasMarkerKeyframeBeforeDatagram(
            on: 1,
            containing: firstMarker
        )
        let reconnectMessageSummary = await transport.messageSummary(on: 1, containing: firstMarker)
        XCTAssertTrue(reconnectKeyframePrecedesDatagram, reconnectMessageSummary)

        let reconnectedSurface = try await waitForRemoteSurface(in: session)
        XCTAssertTrue(reconnectedSurface === surface)
        let reconnectMaterial = try await waitForAttachMaterial(
            bootstrapper,
            count: 2,
            description: "forced reconnect SSH bootstrap material"
        )
        assertSameHelperResume(first: firstMaterial, resumed: reconnectMaterial)
        XCTAssertGreaterThan(reconnectMaterial.expires, Date())
        let reconnectRemoteState = await bootstrapper.remoteSessionState(host: host, material: reconnectMaterial)
        XCTAssertTrue(reconnectRemoteState.probeSucceeded, reconnectRemoteState.summary)
        XCTAssertTrue(reconnectRemoteState.helperAlive, reconnectRemoteState.summary)
        XCTAssertTrue(reconnectRemoteState.helperIdentityMatches, reconnectRemoteState.summary)
        XCTAssertTrue(reconnectRemoteState.privateTmuxPresent, reconnectRemoteState.summary)
        let reconnectedInputHandler = try XCTUnwrap(reconnectedSurface.remotePaneInputHandler)
        let secondMarker = "FTRLIVE-\(String(UUID().uuidString.prefix(8)))"
        reconnectedInputHandler(
            paneID,
            RemotePaneInput(data: Data("printf '\(secondMarker)\\n'\n".utf8), source: .directKey)
        )
        try await waitUntilLive(
            "remote grid runtime state containing second marker",
            diagnostics: {
                [
                    await transport.messageSummary(on: 1, containing: secondMarker),
                    await bootstrapper.remoteWorkspaceSummary(host: host, containing: secondMarker),
                    await bootstrapper.remoteQUICLogSummary(host: host),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.hasRuntimeRenderAction(on: 1, containing: secondMarker)
        }
        try await waitForVisibleText(containing: secondMarker, from: reconnectedSurface, in: session) {
            await bridgeRenderLog.summary()
        }

        manager.selectedSessionID = nil
        manager.closeSession(id: session.id, killTmux: false)
        try await sleepUntilAfter(reconnectMaterial.expires)

        let restartedManager = makeLiveSessionManager(
            bootstrapper: bootstrapper,
            transport: transport,
            bridgeRenderLog: bridgeRenderLog
        )
        let restartedSession = restartedManager.createRemoteEngineSession(host: host, workspaceID: workspaceID)
        try await waitUntilLive(
            "app restart QUIC connection",
            diagnostics: {
                [
                    self.connectionStateDescription(for: restartedSession),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.connectionCount() == 3 && self.isRemoteEngineConnected(restartedSession)
        }
        let restartMaterial = try await waitForAttachMaterial(
            bootstrapper,
            count: 3,
            description: "app restart SSH bootstrap material"
        )
        assertSameHelperResume(first: firstMaterial, resumed: restartMaterial)
        XCTAssertNotEqual(restartMaterial.key, reconnectMaterial.key)
        XCTAssertGreaterThan(restartMaterial.expires, Date())
        let restartRemoteState = await bootstrapper.remoteSessionState(host: host, material: restartMaterial)
        XCTAssertTrue(restartRemoteState.probeSucceeded, restartRemoteState.summary)
        XCTAssertTrue(restartRemoteState.helperAlive, restartRemoteState.summary)
        XCTAssertTrue(restartRemoteState.helperIdentityMatches, restartRemoteState.summary)
        XCTAssertTrue(restartRemoteState.privateTmuxPresent, restartRemoteState.summary)

        let restartedSurface = try await waitForRemoteSurface(in: restartedSession)
        let restartedPaneID = try XCTUnwrap(restartedSurface.tmuxPaneID)
        let restartedInputHandler = try XCTUnwrap(restartedSurface.remotePaneInputHandler)
        try await waitUntilLive("app restart fresh keyframe containing prior marker") {
            await transport.hasKeyframe(on: 2, containing: secondMarker)
        }
        let restartMarker = "FTRLIVE-\(String(UUID().uuidString.prefix(8)))"
        restartedInputHandler(
            restartedPaneID,
            RemotePaneInput(data: Data("printf '\(restartMarker)\\n'\n".utf8), source: .directKey)
        )
        try await waitUntilLive(
            "remote grid runtime state containing restart marker",
            diagnostics: {
                [
                    await transport.messageSummary(on: 2, containing: restartMarker),
                    await bootstrapper.remoteWorkspaceSummary(host: host, containing: restartMarker),
                    await bootstrapper.remoteQUICLogSummary(host: host),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.hasRuntimeRenderAction(on: 2, containing: restartMarker)
        }
        try await waitForVisibleText(containing: restartMarker, from: restartedSurface, in: restartedSession) {
            await bridgeRenderLog.summary()
        }

        restartedManager.selectedSessionID = nil
        restartedManager.closeSession(id: restartedSession.id, killTmux: true)
        try await waitUntilLive(
            "remote private workspace cleanup",
            timeout: 15,
            diagnostics: {
                await bootstrapper.remoteSessionState(host: host, material: restartMaterial).summary
            }
        ) {
            let state = await bootstrapper.remoteSessionState(host: host, material: restartMaterial)
            return state.probeSucceeded &&
            !state.registryPresent &&
            !state.helperAlive &&
            !state.privateTmuxPresent &&
            state.privateTmuxClients == 0 &&
            !state.socketExists
        }
    }

    func testPrivateRemoteWorkspacePredictiveEchoRendersBeforeAuthoritativeEcho() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configuration = RemoteEngineLiveWorkspaceConfiguration(
            environment: environment,
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            throw XCTSkip("Set FANTASTTY_REMOTE_ENGINE_E2E_HOST or pass --fantastty-remote-engine-e2e-host to run the live remote-engine smoke test.")
        }

        let workspaceID = "live-pe-\(UUID().uuidString.prefix(8).lowercased())"
        let host = Fantastty.SSHHostInfo(
            user: configuration.user,
            hostname: configuration.hostname,
            port: configuration.port
        )
        let diagnosticLog = LiveRemoteEngineDiagnosticLog()
        let bridgeRenderLog = LiveRemoteWorkspaceRenderDiagnosticLog()
        let inputDelay = LiveRemoteInputDelay()
        let liveProcessRunner = LiveRemoteEngineProcessRunner(timeout: 60)
        var baseBootstrapper = SSHRemoteEngineBootstrapper(advertiseHostOverride: configuration.advertiseHost)
        baseBootstrapper.ttl = "20s"
        baseBootstrapper.keyTTL = "3s"
        baseBootstrapper.processRunner = liveProcessRunner
        var helperDeployer = RemoteEngineHelperDeployer()
        helperDeployer.processRunner = liveProcessRunner
        baseBootstrapper.helperDeployer = helperDeployer
        let bootstrapper = LiveRemoteEngineBootstrapper(
            base: baseBootstrapper,
            usesLoopbackRelay: configuration.usesLoopbackRelay,
            processRunner: liveProcessRunner
        )
        let transport = LiveRecordingRemoteEngineTransport(
            base: RemoteEngineNWQUICTransport { event in
                Task {
                    await diagnosticLog.record(event)
                }
            },
            inputDelay: inputDelay
        )
        let manager = makeLiveSessionManager(
            bootstrapper: bootstrapper,
            transport: transport,
            bridgeRenderLog: bridgeRenderLog
        )
        addTeardownBlock {
            await bootstrapper.shutdownRecordedMaterials(host: host)
            bootstrapper.stopRelays()
        }

        let session = manager.createRemoteEngineSession(host: host, workspaceID: workspaceID)
        try await waitUntilLive(
            "predictive echo QUIC connection",
            diagnostics: {
                [
                    self.connectionStateDescription(for: session),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.connectionCount() == 1 && self.isRemoteEngineConnected(session)
        }
        let surface = try await waitForRemoteSurface(in: session)
        let paneID = try XCTUnwrap(surface.tmuxPaneID)
        let inputHandler = try XCTUnwrap(surface.remotePaneInputHandler)
        try await waitUntilLive(
            "predictive echo initial render",
            diagnostics: {
                [
                    await transport.messageSummary(on: 0, containing: "<initial remote grid>"),
                    await bridgeRenderLog.summary(),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await bridgeRenderLog.hasRenderedGrid()
        }
        let material = try await waitForAttachMaterial(
            bootstrapper,
            count: 1,
            description: "predictive echo SSH bootstrap material"
        )
        let remoteState = await bootstrapper.remoteSessionState(host: host, material: material)
        XCTAssertTrue(remoteState.probeSucceeded, remoteState.summary)
        XCTAssertTrue(remoteState.helperAlive, remoteState.summary)
        XCTAssertTrue(remoteState.helperIdentityMatches, remoteState.summary)
        XCTAssertTrue(remoteState.privateTmuxPresent, remoteState.summary)

        inputHandler(
            paneID,
            RemotePaneInput(data: Data("Q".utf8), source: .directKey)
        )
        try await waitUntilLive(
            "first live echo proves prediction confidence",
            diagnostics: {
                [
                    await transport.messageSummary(on: 0, containing: "Q"),
                    await bridgeRenderLog.summary(),
                    self.sessionSurfaceDiagnostics(session, expectedSurface: surface)
                ].joined(separator: "; ")
            }
        ) {
            await transport.completedInputSendCount(on: 0) >= 1 &&
            self.readVisibleText(from: surface).contains("Q")
        }

        let completedBeforePrediction = await transport.completedInputSendCount(on: 0)
        await inputDelay.setDelayNanoseconds(750_000_000)
        inputHandler(
            paneID,
            RemotePaneInput(data: Data("Z".utf8), source: .directKey)
        )
        try await waitUntilLive(
            "live predictive echo before authoritative ack",
            timeout: 2,
            diagnostics: {
                [
                    "completedBeforePrediction=\(completedBeforePrediction)",
                    "completedNow=\(await transport.completedInputSendCount(on: 0))",
                    "inputDelayPending=\(await inputDelay.isDelaying())",
                    await bridgeRenderLog.summary(),
                    self.sessionSurfaceDiagnostics(session, expectedSurface: surface)
                ].joined(separator: "; ")
            }
        ) {
            let isDelaying = await inputDelay.isDelaying()
            let completedNow = await transport.completedInputSendCount(on: 0)
            let renderedTentativeGrid = await bridgeRenderLog.hasRenderedTentativeGrid()
            return isDelaying &&
            completedNow == completedBeforePrediction &&
            renderedTentativeGrid &&
            self.readVisibleText(from: surface).contains("QZ")
        }
        try await waitUntilLive("delayed live predictive input reaches helper") {
            await transport.completedInputSendCount(on: 0) > completedBeforePrediction
        }
        try await waitForVisibleText(containing: "QZ", from: surface, in: session) {
            await bridgeRenderLog.summary()
        }

        manager.selectedSessionID = nil
        manager.closeSession(id: session.id, killTmux: true)
        try await waitUntilLive(
            "predictive echo private workspace cleanup",
            timeout: 15,
            diagnostics: {
                await bootstrapper.remoteSessionState(host: host, material: material).summary
            }
        ) {
            let state = await bootstrapper.remoteSessionState(host: host, material: material)
            return state.probeSucceeded &&
            !state.registryPresent &&
            !state.helperAlive &&
            !state.privateTmuxPresent &&
            state.privateTmuxClients == 0 &&
            !state.socketExists
        }
    }

    func testPrivateRemoteWorkspaceSurvivesReconnectLoop() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let reconnectCountText = environment["FANTASTTY_LIVE_REMOTE_ENGINE_RECONNECT_COUNT"],
              let reconnectCount = Int(reconnectCountText),
              reconnectCount > 0 else {
            throw XCTSkip("Set FANTASTTY_LIVE_REMOTE_ENGINE_RECONNECT_COUNT to run the live reconnect loop gate.")
        }
        guard let configuration = RemoteEngineLiveWorkspaceConfiguration(
            environment: environment,
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            throw XCTSkip("Set FANTASTTY_REMOTE_ENGINE_E2E_HOST or pass --fantastty-remote-engine-e2e-host to run the live remote-engine smoke test.")
        }
        if configuration.headlessEvidence {
            try await runHeadlessReconnectLoop(configuration: configuration, reconnectCount: reconnectCount)
            return
        }

        let workspaceID = "live-loop-\(UUID().uuidString.prefix(8).lowercased())"
        let host = Fantastty.SSHHostInfo(
            user: configuration.user,
            hostname: configuration.hostname,
            port: configuration.port
        )
        let diagnosticLog = LiveRemoteEngineDiagnosticLog()
        let bridgeRenderLog = LiveRemoteWorkspaceRenderDiagnosticLog()
        let liveProcessRunner = LiveRemoteEngineProcessRunner(timeout: 60)
        var baseBootstrapper = SSHRemoteEngineBootstrapper(advertiseHostOverride: configuration.advertiseHost)
        baseBootstrapper.ttl = "10m"
        baseBootstrapper.keyTTL = "30s"
        baseBootstrapper.processRunner = liveProcessRunner
        var helperDeployer = RemoteEngineHelperDeployer()
        helperDeployer.processRunner = liveProcessRunner
        baseBootstrapper.helperDeployer = helperDeployer
        let bootstrapper = LiveRemoteEngineBootstrapper(
            base: baseBootstrapper,
            usesLoopbackRelay: configuration.usesLoopbackRelay,
            processRunner: liveProcessRunner
        )
        let transport = LiveRecordingRemoteEngineTransport(
            base: RemoteEngineNWQUICTransport { event in
                Task {
                    await diagnosticLog.record(event)
                }
            }
        )
        let manager = makeLiveSessionManager(
            bootstrapper: bootstrapper,
            transport: transport,
            bridgeRenderLog: bridgeRenderLog,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: reconnectCount + 2, delayNanoseconds: 0)
        )
        addTeardownBlock {
            await bootstrapper.shutdownRecordedMaterials(host: host)
            bootstrapper.stopRelays()
        }

        let session = manager.createRemoteEngineSession(host: host, workspaceID: workspaceID)
        try await waitUntilLive("reconnect loop initial connection") {
            await transport.connectionCount() == 1 && self.isRemoteEngineConnected(session)
        }
        let surface = try await waitForRemoteSurface(in: session)
        let paneID = try XCTUnwrap(surface.tmuxPaneID)
        let inputHandler = try XCTUnwrap(surface.remotePaneInputHandler)
        let marker = "FTRLOOP-\(String(UUID().uuidString.prefix(8)))"
        inputHandler(
            paneID,
            RemotePaneInput(data: Data("printf '\(marker)\\n'\n".utf8), source: .directKey)
        )
        try await waitForLiveGridEvidence(
            containing: marker,
            on: 0,
            transport: transport,
            configuration: configuration,
            surface: surface,
            session: session
        ) {
            [
                await bridgeRenderLog.summary(),
                await bootstrapper.remoteQUICLogSummary(host: host),
                await bootstrapper.remoteWorkspaceSummary(host: host, containing: marker),
                await diagnosticLog.summary()
            ].joined(separator: "; ")
        }
        let firstMaterial = try await waitForAttachMaterial(
            bootstrapper,
            count: 1,
            description: "reconnect loop initial SSH bootstrap material"
        )

        for attempt in 0..<reconnectCount {
            await transport.closeConnection(at: attempt)
            try await waitUntilLive(
                "reconnect loop connection \(attempt + 1)",
                diagnostics: {
                    [
                        self.connectionStateDescription(for: session),
                        await transport.messageSummary(on: attempt + 1, containing: marker),
                        await bridgeRenderLog.summary(),
                        await diagnosticLog.summary()
                    ].joined(separator: "; ")
                }
            ) {
                let connectionCount = await transport.connectionCount()
                let hasFreshKeyframe = await transport.hasKeyframe(on: attempt + 1, containing: marker)
                return connectionCount == attempt + 2 &&
                self.isRemoteEngineConnected(session) &&
                hasFreshKeyframe
            }
            let loopMaterial = try await waitForAttachMaterial(
                bootstrapper,
                count: attempt + 2,
                description: "reconnect loop SSH bootstrap material \(attempt + 1)"
            )
            assertSameHelperResume(first: firstMaterial, resumed: loopMaterial)
            XCTAssertTrue(self.remoteSurface(in: session) === surface)
        }

        manager.selectedSessionID = nil
        manager.closeSession(id: session.id, killTmux: true)
        let finalMaterial = try XCTUnwrap(bootstrapper.attachMaterials().last)
        try await waitUntilLive(
            "reconnect loop private workspace cleanup",
            timeout: 15,
            diagnostics: {
                await bootstrapper.remoteSessionState(host: host, material: finalMaterial).summary
            }
        ) {
            let state = await bootstrapper.remoteSessionState(host: host, material: finalMaterial)
            return state.probeSucceeded &&
            !state.registryPresent &&
            !state.helperAlive &&
            !state.privateTmuxPresent &&
            state.privateTmuxClients == 0 &&
            !state.socketExists
        }
    }

    private func runHeadlessReconnectLoop(
        configuration: RemoteEngineLiveWorkspaceConfiguration,
        reconnectCount: Int
    ) async throws {
        let workspaceID = "live-loop-\(UUID().uuidString.prefix(8).lowercased())"
        let host = Fantastty.SSHHostInfo(
            user: configuration.user,
            hostname: configuration.hostname,
            port: configuration.port
        )
        let diagnosticLog = LiveRemoteEngineDiagnosticLog()
        let liveProcessRunner = LiveRemoteEngineProcessRunner(timeout: 60)
        var baseBootstrapper = SSHRemoteEngineBootstrapper(advertiseHostOverride: configuration.advertiseHost)
        baseBootstrapper.ttl = "10m"
        baseBootstrapper.keyTTL = "30s"
        baseBootstrapper.processRunner = liveProcessRunner
        var helperDeployer = RemoteEngineHelperDeployer()
        helperDeployer.processRunner = liveProcessRunner
        baseBootstrapper.helperDeployer = helperDeployer
        let bootstrapper = LiveRemoteEngineBootstrapper(
            base: baseBootstrapper,
            usesLoopbackRelay: configuration.usesLoopbackRelay,
            processRunner: liveProcessRunner
        )
        let transport = LiveRecordingRemoteEngineTransport(
            base: RemoteEngineNWQUICTransport { event in
                Task {
                    await diagnosticLog.record(event)
                }
            }
        )
        let client = RemoteEngineClient(
            workspaceID: workspaceID,
            materialProvider: {
                try await bootstrapper.attachMaterial(workspaceID: workspaceID, host: host)
            },
            transport: transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: reconnectCount + 2, delayNanoseconds: 0),
            messageHandler: { _ in }
        )
        addTeardownBlock {
            client.stop()
            await bootstrapper.shutdownRecordedMaterials(host: host)
            bootstrapper.stopRelays()
        }

        client.start()
        try await waitUntilLive(
            "headless reconnect loop initial connection",
            diagnostics: {
                [
                    "\(client.state)",
                    await transport.messageSummary(on: 0, containing: "<initial remote grid>"),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await transport.connectionCount() == 1 && client.state == .connected
        }
        let firstMaterial = try await waitForAttachMaterial(
            bootstrapper,
            count: 1,
            description: "headless reconnect loop initial SSH bootstrap material"
        )
        let paneID = try await waitForHeadlessPaneID(
            on: 0,
            transport: transport,
            diagnostics: {
                await transport.messageSummary(on: 0, containing: "<initial remote grid>")
            }
        )
        let marker = "FTRLOOP-\(String(UUID().uuidString.prefix(8)))"
        client.sendKeys(paneID: paneID, data: Data("printf '\(marker)\\n'\n".utf8))
        try await waitForHeadlessGridEvidence(
            containing: marker,
            on: 0,
            transport: transport,
            workspaceID: workspaceID,
            paneID: paneID,
            diagnostics: {
                [
                    await transport.messageSummary(on: 0, containing: marker),
                    await bootstrapper.remoteQUICLogSummary(host: host),
                    await bootstrapper.remoteWorkspaceSummary(host: host, containing: marker),
                    await diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        )

        for attempt in 0..<reconnectCount {
            await transport.closeConnection(at: attempt)
            try await waitUntilLive(
                "headless reconnect loop connection \(attempt + 1)",
                diagnostics: {
                    [
                        "\(client.state)",
                        await transport.messageSummary(on: attempt + 1, containing: marker),
                        await diagnosticLog.summary()
                    ].joined(separator: "; ")
                }
            ) {
                let connectionCount = await transport.connectionCount()
                let hasFreshKeyframe = await transport.hasKeyframe(on: attempt + 1, containing: marker)
                return connectionCount == attempt + 2 &&
                client.state == .connected &&
                hasFreshKeyframe
            }
            let loopMaterial = try await waitForAttachMaterial(
                bootstrapper,
                count: attempt + 2,
                description: "headless reconnect loop SSH bootstrap material \(attempt + 1)"
            )
            assertSameHelperResume(first: firstMaterial, resumed: loopMaterial)
        }

        client.stop()
        let finalMaterial = try XCTUnwrap(bootstrapper.attachMaterials().last)
        try? await bootstrapper.shutdown(material: finalMaterial, host: host)
        try await waitForPrivateWorkspaceCleanup(
            host: host,
            material: finalMaterial,
            bootstrapper: bootstrapper,
            description: "headless reconnect loop private workspace cleanup"
        )
    }

    private func runHeadlessLongIdleGate(
        configuration: RemoteEngineLiveWorkspaceConfiguration,
        idleSeconds: TimeInterval
    ) async throws {
        let workspaceID = "live-idle-\(UUID().uuidString.prefix(8).lowercased())"
        let harness = makeLiveHarness(
            configuration: configuration,
            ttl: "\(Int(idleSeconds) + 600)s",
            keyTTL: "30s",
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 4, delayNanoseconds: 0)
        )
        let client = RemoteEngineClient(
            workspaceID: workspaceID,
            materialProvider: {
                try await harness.bootstrapper.attachMaterial(workspaceID: workspaceID, host: harness.host)
            },
            transport: harness.transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 4, delayNanoseconds: 0),
            messageHandler: { _ in }
        )
        addTeardownBlock {
            client.stop()
            await harness.bootstrapper.shutdownRecordedMaterials(host: harness.host)
            harness.bootstrapper.stopRelays()
        }

        client.start()
        try await waitUntilLive(
            "headless long-idle initial connection",
            diagnostics: {
                [
                    "\(client.state)",
                    await harness.transport.messageSummary(on: 0, containing: "<initial remote grid>"),
                    await harness.diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await harness.transport.connectionCount() == 1 && client.state == .connected
        }
        let firstMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 1,
            description: "headless long-idle initial SSH bootstrap material"
        )
        await assertHelperRSS(firstMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)
        let paneID = try await waitForHeadlessPaneID(
            on: 0,
            transport: harness.transport,
            diagnostics: {
                await harness.transport.messageSummary(on: 0, containing: "<initial remote grid>")
            }
        )

        let marker = "FTRIDLE-\(String(UUID().uuidString.prefix(8)))"
        client.sendKeys(
            paneID: paneID,
            data: Data(longIdleCommand(marker: marker, idleSeconds: idleSeconds, intervalSeconds: configuration.idleMarkerIntervalSeconds).utf8)
        )
        try await waitForHeadlessGridEvidence(
            containing: "\(marker)-0000",
            on: 0,
            transport: harness.transport,
            workspaceID: workspaceID,
            paneID: paneID,
            diagnostics: {
                await harness.transport.messageSummary(on: 0, containing: "\(marker)-0000")
            }
        )
        try await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
        try await waitForHeadlessGridEvidence(
            containing: "\(marker)-DONE",
            on: 0,
            transport: harness.transport,
            workspaceID: workspaceID,
            paneID: paneID,
            timeout: 60,
            diagnostics: {
                await harness.transport.messageSummary(on: 0, containing: "\(marker)-DONE")
            }
        )

        await harness.transport.closeConnection(at: 0)
        try await waitUntilLive(
            "headless long-idle reconnect keyframe",
            diagnostics: {
                [
                    "\(client.state)",
                    await harness.transport.messageSummary(on: 1, containing: "\(marker)-DONE"),
                    await harness.diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            let connectionCount = await harness.transport.connectionCount()
            let hasFreshKeyframe = await harness.transport.hasKeyframe(on: 1, containing: "\(marker)-DONE")
            return connectionCount == 2 &&
            client.state == .connected &&
            hasFreshKeyframe
        }
        let reconnectMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 2,
            description: "headless long-idle reconnect SSH bootstrap material"
        )
        assertSameHelperResume(first: firstMaterial, resumed: reconnectMaterial)
        await assertHelperRSS(reconnectMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)

        client.stop()
        try? await harness.bootstrapper.shutdown(material: reconnectMaterial, host: harness.host)
        try await waitForPrivateWorkspaceCleanup(
            host: harness.host,
            material: reconnectMaterial,
            bootstrapper: harness.bootstrapper,
            description: "headless long-idle private workspace cleanup"
        )
    }

    private func runHeadlessHighOutputDrainGate(
        configuration: RemoteEngineLiveWorkspaceConfiguration,
        lineCount: Int
    ) async throws {
        let workspaceID = "live-drain-\(UUID().uuidString.prefix(8).lowercased())"
        let harness = makeLiveHarness(
            configuration: configuration,
            ttl: "10m",
            keyTTL: "30s",
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 4, delayNanoseconds: 0)
        )
        let client = RemoteEngineClient(
            workspaceID: workspaceID,
            materialProvider: {
                try await harness.bootstrapper.attachMaterial(workspaceID: workspaceID, host: harness.host)
            },
            transport: harness.transport,
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 4, delayNanoseconds: 0),
            messageHandler: { _ in }
        )
        addTeardownBlock {
            client.stop()
            await harness.bootstrapper.shutdownRecordedMaterials(host: harness.host)
            harness.bootstrapper.stopRelays()
        }

        client.start()
        try await waitUntilLive(
            "headless high-output initial connection",
            diagnostics: {
                [
                    "\(client.state)",
                    await harness.transport.messageSummary(on: 0, containing: "<initial remote grid>"),
                    await harness.diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            await harness.transport.connectionCount() == 1 && client.state == .connected
        }
        let firstMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 1,
            description: "headless high-output initial SSH bootstrap material"
        )
        await assertHelperRSS(firstMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)
        let paneID = try await waitForHeadlessPaneID(
            on: 0,
            transport: harness.transport,
            diagnostics: {
                await harness.transport.messageSummary(on: 0, containing: "<initial remote grid>")
            }
        )

        let marker = "FTRDRAIN-\(String(UUID().uuidString.prefix(8)))"
        client.sendKeys(
            paneID: paneID,
            data: Data(highOutputDrainCommand(marker: marker, lineCount: lineCount, lineByteCount: configuration.highOutputDrainLineBytes).utf8)
        )
        try await waitUntilLive("headless high-output command sent") {
            await harness.transport.completedInputSendCount(on: 0) >= 1
        }
        try await waitForHeadlessGridEvidence(
            containing: "\(marker)-00000",
            on: 0,
            transport: harness.transport,
            workspaceID: workspaceID,
            paneID: paneID,
            diagnostics: {
                await harness.transport.messageSummary(on: 0, containing: "\(marker)-00000")
            }
        )

        await harness.transport.closeConnection(at: 0)
        try await waitUntilLive(
            "headless high-output reconnect connection",
            timeout: 60,
            diagnostics: {
                [
                    "\(client.state)",
                    await harness.transport.messageSummary(on: 1, containing: "\(marker)-DONE"),
                    await harness.diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            let connectionCount = await harness.transport.connectionCount()
            return connectionCount == 2 && client.state == .connected
        }
        try await waitForHeadlessKeyframeEvidence(
            containing: "\(marker)-DONE",
            on: 1,
            transport: harness.transport,
            workspaceID: workspaceID,
            paneID: paneID,
            timeout: 900,
            keyframeRequestInterval: 5,
            diagnostics: {
                await harness.transport.messageSummary(on: 1, containing: "\(marker)-DONE")
            }
        )

        let reconnectMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 2,
            description: "headless high-output reconnect SSH bootstrap material"
        )
        assertSameHelperResume(first: firstMaterial, resumed: reconnectMaterial)
        await assertHelperRSS(reconnectMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)

        client.stop()
        try? await harness.bootstrapper.shutdown(material: reconnectMaterial, host: harness.host)
        try await waitForPrivateWorkspaceCleanup(
            host: harness.host,
            material: reconnectMaterial,
            bootstrapper: harness.bootstrapper,
            description: "headless high-output private workspace cleanup"
        )
    }

    func testPrivateRemoteWorkspaceSurvivesLongIdleWithPeriodicOutput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configuration = RemoteEngineLiveWorkspaceConfiguration(
            environment: environment,
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            throw XCTSkip("Set FANTASTTY_REMOTE_ENGINE_E2E_HOST or pass --fantastty-remote-engine-e2e-host to run the live remote-engine smoke test.")
        }
        guard let idleSeconds = configuration.longIdleSeconds, idleSeconds > 0 else {
            throw XCTSkip("Set FANTASTTY_LIVE_REMOTE_ENGINE_IDLE_SECONDS to run the live long-idle gate.")
        }
        if configuration.headlessEvidence {
            try await runHeadlessLongIdleGate(configuration: configuration, idleSeconds: idleSeconds)
            return
        }

        let workspaceID = "live-idle-\(UUID().uuidString.prefix(8).lowercased())"
        let harness = makeLiveHarness(
            configuration: configuration,
            ttl: "\(Int(idleSeconds) + 600)s",
            keyTTL: "30s",
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 4, delayNanoseconds: 0)
        )
        addTeardownBlock {
            await harness.bootstrapper.shutdownRecordedMaterials(host: harness.host)
            harness.bootstrapper.stopRelays()
        }

        let session = harness.manager.createRemoteEngineSession(host: harness.host, workspaceID: workspaceID)
        try await waitUntilLive("long-idle initial connection") {
            await harness.transport.connectionCount() == 1 && self.isRemoteEngineConnected(session)
        }
        let surface = try await waitForRemoteSurface(in: session)
        let paneID = try XCTUnwrap(surface.tmuxPaneID)
        let inputHandler = try XCTUnwrap(surface.remotePaneInputHandler)
        let firstMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 1,
            description: "long-idle initial SSH bootstrap material"
        )
        await assertHelperRSS(firstMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)

        let marker = "FTRIDLE-\(String(UUID().uuidString.prefix(8)))"
        inputHandler(
            paneID,
            RemotePaneInput(
                data: Data(longIdleCommand(marker: marker, idleSeconds: idleSeconds, intervalSeconds: configuration.idleMarkerIntervalSeconds).utf8),
                source: .directKey
            )
        )
        try await waitForLiveGridEvidence(
            containing: "\(marker)-0000",
            on: 0,
            transport: harness.transport,
            configuration: configuration,
            surface: surface,
            session: session
        ) {
            await harness.bridgeRenderLog.summary()
        }

        try await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
        try await waitForLiveGridEvidence(
            containing: "\(marker)-DONE",
            on: 0,
            transport: harness.transport,
            configuration: configuration,
            surface: surface,
            session: session,
            timeout: 60
        ) {
            await harness.bridgeRenderLog.summary()
        }

        await harness.transport.closeConnection(at: 0)
        try await waitUntilLive(
            "long-idle reconnect keyframe",
            diagnostics: {
                [
                    self.connectionStateDescription(for: session),
                    await harness.transport.messageSummary(on: 1, containing: "\(marker)-DONE"),
                    await harness.bridgeRenderLog.summary(),
                    await harness.diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            let connectionCount = await harness.transport.connectionCount()
            let hasFreshKeyframe = await harness.transport.hasKeyframe(on: 1, containing: "\(marker)-DONE")
            return connectionCount == 2 &&
            self.isRemoteEngineConnected(session) &&
            hasFreshKeyframe
        }
        let reconnectMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 2,
            description: "long-idle reconnect SSH bootstrap material"
        )
        assertSameHelperResume(first: firstMaterial, resumed: reconnectMaterial)
        await assertHelperRSS(reconnectMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)
        XCTAssertTrue(remoteSurface(in: session) === surface)

        harness.manager.selectedSessionID = nil
        harness.manager.closeSession(id: session.id, killTmux: true)
        try await waitForPrivateWorkspaceCleanup(host: harness.host, material: reconnectMaterial, bootstrapper: harness.bootstrapper, description: "long-idle private workspace cleanup")
    }

    func testPrivateRemoteWorkspaceDrainsHighOutputWhileDisconnected() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configuration = RemoteEngineLiveWorkspaceConfiguration(
            environment: environment,
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            throw XCTSkip("Set FANTASTTY_REMOTE_ENGINE_E2E_HOST or pass --fantastty-remote-engine-e2e-host to run the live remote-engine smoke test.")
        }
        guard let lineCount = configuration.highOutputDrainLines, lineCount > 0 else {
            throw XCTSkip("Set FANTASTTY_LIVE_REMOTE_ENGINE_DRAIN_LINES to run the live high-output drain gate.")
        }
        if configuration.headlessEvidence {
            try await runHeadlessHighOutputDrainGate(configuration: configuration, lineCount: lineCount)
            return
        }

        let workspaceID = "live-drain-\(UUID().uuidString.prefix(8).lowercased())"
        let harness = makeLiveHarness(
            configuration: configuration,
            ttl: "10m",
            keyTTL: "30s",
            reconnectPolicy: RemoteEngineReconnectPolicy(maxAttempts: 4, delayNanoseconds: 0)
        )
        addTeardownBlock {
            await harness.bootstrapper.shutdownRecordedMaterials(host: harness.host)
            harness.bootstrapper.stopRelays()
        }

        let session = harness.manager.createRemoteEngineSession(host: harness.host, workspaceID: workspaceID)
        try await waitUntilLive("high-output initial connection") {
            await harness.transport.connectionCount() == 1 && self.isRemoteEngineConnected(session)
        }
        let surface = try await waitForRemoteSurface(in: session)
        let paneID = try XCTUnwrap(surface.tmuxPaneID)
        let inputHandler = try XCTUnwrap(surface.remotePaneInputHandler)
        let firstMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 1,
            description: "high-output initial SSH bootstrap material"
        )
        await assertHelperRSS(firstMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)

        let marker = "FTRDRAIN-\(String(UUID().uuidString.prefix(8)))"
        inputHandler(
            paneID,
            RemotePaneInput(
                data: Data(highOutputDrainCommand(marker: marker, lineCount: lineCount, lineByteCount: configuration.highOutputDrainLineBytes).utf8),
                source: .directKey
            )
        )
        try await waitUntilLive("high-output command sent") {
            await harness.transport.completedInputSendCount(on: 0) >= 1
        }
        try await waitUntilLive("high-output stream started") {
            await harness.transport.hasMessage(on: 0, containing: "\(marker)-00000")
        }

        await harness.transport.closeConnection(at: 0)
        try await waitUntilLive(
            "high-output reconnect final keyframe",
            timeout: 60,
            diagnostics: {
                [
                    self.connectionStateDescription(for: session),
                    await harness.transport.messageSummary(on: 1, containing: "\(marker)-DONE"),
                    await harness.bridgeRenderLog.summary(),
                    await harness.diagnosticLog.summary()
                ].joined(separator: "; ")
            }
        ) {
            let connectionCount = await harness.transport.connectionCount()
            let hasFreshKeyframe = await harness.transport.hasKeyframe(on: 1, containing: "\(marker)-DONE")
            return connectionCount == 2 &&
            self.isRemoteEngineConnected(session) &&
            hasFreshKeyframe
        }
        try await waitForLiveGridEvidence(
            containing: "\(marker)-DONE",
            on: 1,
            transport: harness.transport,
            configuration: configuration,
            surface: surface,
            session: session,
            timeout: 20
        ) {
            await harness.bridgeRenderLog.summary()
        }

        let reconnectMaterial = try await waitForAttachMaterial(
            harness.bootstrapper,
            count: 2,
            description: "high-output reconnect SSH bootstrap material"
        )
        assertSameHelperResume(first: firstMaterial, resumed: reconnectMaterial)
        await assertHelperRSS(reconnectMaterial, within: configuration.helperRSSMaxKB, on: harness.host, using: harness.bootstrapper)
        XCTAssertTrue(remoteSurface(in: session) === surface)

        harness.manager.selectedSessionID = nil
        harness.manager.closeSession(id: session.id, killTmux: true)
        try await waitForPrivateWorkspaceCleanup(host: harness.host, material: reconnectMaterial, bootstrapper: harness.bootstrapper, description: "high-output private workspace cleanup")
    }

    private func makeLiveSessionManager(
        bootstrapper: RemoteEngineBootstrapper,
        transport: RemoteEngineTransport,
        bridgeRenderLog: LiveRemoteWorkspaceRenderDiagnosticLog,
        reconnectPolicy: RemoteEngineReconnectPolicy = RemoteEngineReconnectPolicy(maxAttempts: 2, delayNanoseconds: 0)
    ) -> SessionManager {
        let manager = SessionManager()
        manager.ghosttyApp = RemoteEngineLiveWorkspaceTestSupport.ghosttyApp
        manager.remoteEngineBootstrapper = bootstrapper
        manager.remoteEngineTransport = transport
        manager.remoteEngineReconnectPolicy = reconnectPolicy
        manager.remoteWorkspaceRenderDiagnosticHandler = { diagnostic in
            let description = diagnostic.description
            Task {
                await bridgeRenderLog.record(description)
            }
        }
        return manager
    }

    private func makeLiveHarness(
        configuration: RemoteEngineLiveWorkspaceConfiguration,
        ttl: String,
        keyTTL: String,
        reconnectPolicy: RemoteEngineReconnectPolicy
    ) -> LiveRemoteWorkspaceHarness {
        let host = Fantastty.SSHHostInfo(
            user: configuration.user,
            hostname: configuration.hostname,
            port: configuration.port
        )
        let diagnosticLog = LiveRemoteEngineDiagnosticLog()
        let bridgeRenderLog = LiveRemoteWorkspaceRenderDiagnosticLog()
        let liveProcessRunner = LiveRemoteEngineProcessRunner(timeout: 60)
        var baseBootstrapper = SSHRemoteEngineBootstrapper(advertiseHostOverride: configuration.advertiseHost)
        baseBootstrapper.ttl = ttl
        baseBootstrapper.keyTTL = keyTTL
        baseBootstrapper.processRunner = liveProcessRunner
        var helperDeployer = RemoteEngineHelperDeployer()
        helperDeployer.processRunner = liveProcessRunner
        baseBootstrapper.helperDeployer = helperDeployer
        let bootstrapper = LiveRemoteEngineBootstrapper(
            base: baseBootstrapper,
            usesLoopbackRelay: configuration.usesLoopbackRelay,
            processRunner: liveProcessRunner
        )
        let transport = LiveRecordingRemoteEngineTransport(
            base: RemoteEngineNWQUICTransport { event in
                Task {
                    await diagnosticLog.record(event)
                }
            }
        )
        let manager = makeLiveSessionManager(
            bootstrapper: bootstrapper,
            transport: transport,
            bridgeRenderLog: bridgeRenderLog,
            reconnectPolicy: reconnectPolicy
        )
        return LiveRemoteWorkspaceHarness(
            host: host,
            diagnosticLog: diagnosticLog,
            bridgeRenderLog: bridgeRenderLog,
            bootstrapper: bootstrapper,
            transport: transport,
            manager: manager
        )
    }

    private func assertHelperRSS(
        _ material: RemoteEngineAttachMaterial,
        within maxRSSKB: Int,
        on host: Fantastty.SSHHostInfo,
        using bootstrapper: LiveRemoteEngineBootstrapper,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = await bootstrapper.remoteSessionState(host: host, material: material)
        XCTAssertTrue(state.probeSucceeded, state.summary, file: file, line: line)
        guard let helperRSSKB = state.helperRSSKB, helperRSSKB >= 0 else {
            XCTFail("remote state did not report helper RSS: \(state.summary)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(helperRSSKB, maxRSSKB, state.summary, file: file, line: line)
    }

    private func waitForPrivateWorkspaceCleanup(
        host: Fantastty.SSHHostInfo,
        material: RemoteEngineAttachMaterial,
        bootstrapper: LiveRemoteEngineBootstrapper,
        description: String
    ) async throws {
        try await waitUntilLive(
            description,
            timeout: 15,
            diagnostics: {
                await bootstrapper.remoteSessionState(host: host, material: material).summary
            }
        ) {
            let state = await bootstrapper.remoteSessionState(host: host, material: material)
            return state.probeSucceeded &&
            !state.registryPresent &&
            !state.helperAlive &&
            !state.privateTmuxPresent &&
            state.privateTmuxClients == 0 &&
            !state.socketExists
        }
    }

    private func longIdleCommand(
        marker: String,
        idleSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) -> String {
        let totalSeconds = max(1, Int(idleSeconds.rounded(.up)))
        let interval = max(1, Int(intervalSeconds.rounded(.up)))
        return """
        i=0; end=$((SECONDS+\(totalSeconds))); while [ "$SECONDS" -lt "$end" ]; do printf '\(marker)-%04d\\n' "$i"; i=$((i+1)); sleep \(interval); done; printf '\(marker)-DONE\\n'
        """ + "\n"
    }

    private func highOutputDrainCommand(
        marker: String,
        lineCount: Int,
        lineByteCount: Int
    ) -> String {
        let payload = String(repeating: "x", count: max(1, lineByteCount))
        return """
        payload='\(payload)'; i=0; while [ "$i" -lt \(lineCount) ]; do printf '\(marker)-%05d-%s\\n' "$i" "$payload"; i=$((i+1)); if [ $((i % 100)) -eq 0 ]; then sleep 0.01; fi; done; printf '\(marker)-DONE\\n'
        """ + "\n"
    }

    private func waitForAttachMaterial(
        _ bootstrapper: LiveRemoteEngineBootstrapper,
        count: Int,
        description: String,
        timeout: TimeInterval = 20
    ) async throws -> RemoteEngineAttachMaterial {
        try await waitUntilLive(description, timeout: timeout) {
            bootstrapper.attachMaterials().count >= count
        }
        return try XCTUnwrap(bootstrapper.attachMaterials().dropFirst(count - 1).first)
    }

    private func assertSameHelperResume(
        first: RemoteEngineAttachMaterial,
        resumed: RemoteEngineAttachMaterial,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(resumed.workspaceID, first.workspaceID, file: file, line: line)
        XCTAssertEqual(resumed.session, first.session, file: file, line: line)
        XCTAssertEqual(resumed.helperPID, first.helperPID, file: file, line: line)
        XCTAssertNotEqual(resumed.key, first.key, file: file, line: line)
    }

    private func sleepUntilAfter(_ date: Date, grace: TimeInterval = 1) async throws {
        let delay = max(0, date.addingTimeInterval(grace).timeIntervalSinceNow)
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func waitForRemoteSurface(
        in session: Session,
        timeout: TimeInterval = 20
    ) async throws -> Fantastty.Ghostty.SurfaceView {
        try await waitUntilLive("remote pane surface", timeout: timeout) {
            self.remoteSurface(in: session)?.tmuxPaneID != nil &&
            self.remoteSurface(in: session)?.remotePaneInputHandler != nil
        }
        return try XCTUnwrap(remoteSurface(in: session))
    }

    private func remoteSurface(in session: Session) -> Fantastty.Ghostty.SurfaceView? {
        session.tabs
            .compactMap { $0.surfaceTree?.root?.leaves().first }
            .first
    }

    private func connectionStateDescription(for session: Session) -> String {
        guard case .attached(let info) = session.mode else {
            return "session mode is \(session.mode)"
        }
        return "transport=\(info.transport.rawValue) state=\(info.connectionState)"
    }

    private func isRemoteEngineConnected(_ session: Session) -> Bool {
        guard case .attached(let info) = session.mode else { return false }
        return info.transport == .remoteEngine && info.connectionState == .connected
    }

    private func waitForVisibleText(
        containing marker: String,
        from surface: Fantastty.Ghostty.SurfaceView,
        in session: Session,
        timeout: TimeInterval = 20,
        bridgeDiagnostics: (() async -> String)? = nil
    ) async throws {
        var lastVisibleText = ""
        try await waitUntilLive(
            "visible marker \(marker)",
            timeout: timeout,
            diagnostics: {
                var diagnostics = [
                    "lastVisibleText=\(self.visibleDiagnosticSnippet(lastVisibleText))",
                    self.sessionSurfaceDiagnostics(session, expectedSurface: surface)
                ]
                if let bridgeDiagnostics {
                    diagnostics.append(await bridgeDiagnostics())
                }
                return diagnostics.joined(separator: "; ")
            }
        ) {
            lastVisibleText = self.readVisibleText(from: surface)
            return lastVisibleText.contains(marker)
        }
    }

    private func waitForLiveGridEvidence(
        containing marker: String,
        on connectionIndex: Int,
        transport: LiveRecordingRemoteEngineTransport,
        configuration: RemoteEngineLiveWorkspaceConfiguration,
        surface: Fantastty.Ghostty.SurfaceView,
        session: Session,
        timeout: TimeInterval = 20,
        bridgeDiagnostics: (() async -> String)? = nil
    ) async throws {
        guard configuration.headlessEvidence else {
            try await waitForVisibleText(
                containing: marker,
                from: surface,
                in: session,
                timeout: timeout,
                bridgeDiagnostics: bridgeDiagnostics
            )
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        var lastKeyframeRequest = Date.distantPast
        while Date() < deadline {
            if await transport.hasMessage(on: connectionIndex, containing: marker) {
                return
            }
            if let paneID = surface.tmuxPaneID,
               Date().timeIntervalSince(lastKeyframeRequest) >= 1 {
                try await transport.requestKeyframe(
                    on: connectionIndex,
                    workspaceID: session.workspaceID,
                    paneID: paneID
                )
                lastKeyframeRequest = Date()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        var diagnostics = [
            await transport.messageSummary(on: connectionIndex, containing: marker),
            sessionSurfaceDiagnostics(session, expectedSurface: surface)
        ]
        if let bridgeDiagnostics {
            diagnostics.append(await bridgeDiagnostics())
        }
        let message = "Timed out waiting for headless structured-grid marker \(marker); \(diagnostics.joined(separator: "; "))"
        XCTFail(message)
        throw RemoteEngineLiveWaitTimeout(message: message)
    }

    private func waitForHeadlessPaneID(
        on connectionIndex: Int,
        transport: LiveRecordingRemoteEngineTransport,
        timeout: TimeInterval = 20,
        diagnostics: (() async -> String)? = nil
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let paneID = await transport.firstPaneID(on: connectionIndex) {
                return paneID
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        var details = [await transport.messageSummary(on: connectionIndex, containing: "<initial remote grid>")]
        if let diagnostics {
            details.append(await diagnostics())
        }
        let message = "Timed out waiting for headless remote pane ID; \(details.joined(separator: "; "))"
        XCTFail(message)
        throw RemoteEngineLiveWaitTimeout(message: message)
    }

    private func waitForHeadlessGridEvidence(
        containing marker: String,
        on connectionIndex: Int,
        transport: LiveRecordingRemoteEngineTransport,
        workspaceID: String,
        paneID: Int,
        timeout: TimeInterval = 20,
        diagnostics: (() async -> String)? = nil
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastKeyframeRequest = Date.distantPast
        while Date() < deadline {
            if await transport.hasMessage(on: connectionIndex, containing: marker) {
                return
            }
            if Date().timeIntervalSince(lastKeyframeRequest) >= 1 {
                try await transport.requestKeyframe(
                    on: connectionIndex,
                    workspaceID: workspaceID,
                    paneID: paneID
                )
                lastKeyframeRequest = Date()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        var details = [await transport.messageSummary(on: connectionIndex, containing: marker)]
        if let diagnostics {
            details.append(await diagnostics())
        }
        let message = "Timed out waiting for headless structured-grid marker \(marker); \(details.joined(separator: "; "))"
        XCTFail(message)
        throw RemoteEngineLiveWaitTimeout(message: message)
    }

    private func waitForHeadlessKeyframeEvidence(
        containing marker: String,
        on connectionIndex: Int,
        transport: LiveRecordingRemoteEngineTransport,
        workspaceID: String,
        paneID: Int,
        timeout: TimeInterval = 20,
        keyframeRequestInterval: TimeInterval = 1,
        diagnostics: (() async -> String)? = nil
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastKeyframeRequest = Date.distantPast
        while Date() < deadline {
            if await transport.hasKeyframe(on: connectionIndex, containing: marker) {
                return
            }
            if Date().timeIntervalSince(lastKeyframeRequest) >= keyframeRequestInterval {
                try await transport.requestKeyframe(
                    on: connectionIndex,
                    workspaceID: workspaceID,
                    paneID: paneID
                )
                lastKeyframeRequest = Date()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        var details = [await transport.messageSummary(on: connectionIndex, containing: marker)]
        if let diagnostics {
            details.append(await diagnostics())
        }
        let message = "Timed out waiting for headless structured-grid keyframe marker \(marker); \(details.joined(separator: "; "))"
        XCTFail(message)
        throw RemoteEngineLiveWaitTimeout(message: message)
    }

    private func readVisibleText(from surfaceView: Fantastty.Ghostty.SurfaceView) -> String {
        guard let surface = surfaceView.surface else { return "" }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let textPointer = text.text else { return "" }

        let buffer = UnsafeRawBufferPointer(start: textPointer, count: Int(text.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }

    private func sessionSurfaceDiagnostics(
        _ session: Session,
        expectedSurface: Fantastty.Ghostty.SurfaceView
    ) -> String {
        let tabSummaries = session.tabs.enumerated().map { tabIndex, tab in
            let leaves = tab.surfaceTree?.root?.leaves() ?? []
            let surfaceSummaries = leaves.enumerated().map { surfaceIndex, surface in
                [
                    "surface=\(tabIndex).\(surfaceIndex)",
                    "expected=\(surface === expectedSurface)",
                    "pane=\(surface.tmuxPaneID.map(String.init) ?? "nil")",
                    "hasRemoteInput=\(surface.remotePaneInputHandler != nil)",
                    "visible=\(visibleDiagnosticSnippet(readVisibleText(from: surface)))"
                ].joined(separator: ",")
            }
            return "tab=\(tabIndex),title=\(tab.title),surfaces=[\(surfaceSummaries.joined(separator: " | "))]"
        }
        return "sessionSurfaces=\(tabSummaries.joined(separator: " || "))"
    }

    private func visibleDiagnosticSnippet(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if normalized.count <= 160 {
            return normalized
        }
        return String(normalized.suffix(160))
    }
}

private struct LiveRemoteWorkspaceHarness {
    let host: Fantastty.SSHHostInfo
    let diagnosticLog: LiveRemoteEngineDiagnosticLog
    let bridgeRenderLog: LiveRemoteWorkspaceRenderDiagnosticLog
    let bootstrapper: LiveRemoteEngineBootstrapper
    let transport: LiveRecordingRemoteEngineTransport
    let manager: SessionManager
}

private struct RemoteEngineLiveWorkspaceConfiguration: Equatable {
    let hostname: String
    let advertiseHost: String?
    let usesLoopbackRelay: Bool
    let user: String?
    let port: Int?
    let longIdleSeconds: TimeInterval?
    let idleMarkerIntervalSeconds: TimeInterval
    let highOutputDrainLines: Int?
    let highOutputDrainLineBytes: Int
    let helperRSSMaxKB: Int
    let headlessEvidence: Bool

    init?(environment: [String: String], arguments: [String]) {
        let options = Self.options(from: arguments)
        guard let hostname = Self.nonEmpty(
            environment["FANTASTTY_REMOTE_ENGINE_E2E_HOST"] ??
            options["fantastty-remote-engine-e2e-host"]
        ) else {
            return nil
        }

        self.hostname = hostname
        advertiseHost = Self.nonEmpty(
            environment["FANTASTTY_REMOTE_ENGINE_E2E_ADVERTISE_HOST"] ??
            options["fantastty-remote-engine-e2e-advertise-host"]
        )
        usesLoopbackRelay = Self.isEnabled(
            environment["FANTASTTY_REMOTE_ENGINE_E2E_LOOPBACK_RELAY"] ??
            options["fantastty-remote-engine-e2e-loopback-relay"]
        )
        user = Self.nonEmpty(
            environment["FANTASTTY_REMOTE_ENGINE_E2E_USER"] ??
            options["fantastty-remote-engine-e2e-user"]
        )
        port = Self.nonEmpty(
            environment["FANTASTTY_REMOTE_ENGINE_E2E_PORT"] ??
            options["fantastty-remote-engine-e2e-port"]
        ).flatMap(Int.init)
        longIdleSeconds = Self.nonEmpty(
            environment["FANTASTTY_LIVE_REMOTE_ENGINE_IDLE_SECONDS"] ??
            options["fantastty-live-remote-engine-idle-seconds"]
        ).flatMap(TimeInterval.init)
        idleMarkerIntervalSeconds = Self.nonEmpty(
            environment["FANTASTTY_LIVE_REMOTE_ENGINE_IDLE_MARKER_INTERVAL_SECONDS"] ??
            options["fantastty-live-remote-engine-idle-marker-interval-seconds"]
        ).flatMap(TimeInterval.init) ?? 60
        highOutputDrainLines = Self.nonEmpty(
            environment["FANTASTTY_LIVE_REMOTE_ENGINE_DRAIN_LINES"] ??
            options["fantastty-live-remote-engine-drain-lines"]
        ).flatMap(Int.init)
        highOutputDrainLineBytes = Self.nonEmpty(
            environment["FANTASTTY_LIVE_REMOTE_ENGINE_DRAIN_LINE_BYTES"] ??
            options["fantastty-live-remote-engine-drain-line-bytes"]
        ).flatMap(Int.init) ?? 160
        helperRSSMaxKB = Self.nonEmpty(
            environment["FANTASTTY_LIVE_REMOTE_ENGINE_HELPER_RSS_MAX_KB"] ??
            options["fantastty-live-remote-engine-helper-rss-max-kb"]
        ).flatMap(Int.init) ?? 262_144
        headlessEvidence = Self.isEnabled(
            environment["FANTASTTY_LIVE_REMOTE_ENGINE_HEADLESS_EVIDENCE"] ??
            options["fantastty-live-remote-engine-headless-evidence"]
        )
    }

    private static func options(from arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        for argument in arguments {
            guard argument.hasPrefix("--") else { continue }
            let trimmed = argument.dropFirst(2)
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            options[String(parts[0])] = String(parts[1])
        }
        return options
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func isEnabled(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

private struct LiveRemoteSessionState {
    let summary: String
    let probeSucceeded: Bool
    let registryPresent: Bool
    let helperAlive: Bool
    let helperIdentityMatches: Bool
    let privateTmuxPresent: Bool
    let privateTmuxClients: Int
    let socketExists: Bool
    let helperRSSKB: Int?

    init(summary: String) {
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        probeSucceeded = false
        registryPresent = false
        helperAlive = false
        helperIdentityMatches = false
        privateTmuxPresent = false
        privateTmuxClients = 0
        socketExists = false
        helperRSSKB = nil
    }

    init(output: String) {
        summary = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = Dictionary(
            uniqueKeysWithValues: summary
                .split(whereSeparator: \.isWhitespace)
                .compactMap { field -> (String, String)? in
                    let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
        )
        probeSucceeded = fields["remoteState"] == "ok"
        registryPresent = fields["registry_present"] == "true"
        helperAlive = fields["helper_alive"] == "true"
        helperIdentityMatches = fields["helper_identity"] == "true"
        privateTmuxPresent = fields["private_tmux_present"] == "true"
        privateTmuxClients = fields["private_tmux_clients"].flatMap(Int.init) ?? 0
        socketExists = fields["socket_exists"] == "true"
        helperRSSKB = fields["helper_rss_kb"].flatMap(Int.init)
    }
}

private final class LiveRemoteEngineProcessRunner: RemoteEngineProcessRunning {
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func run(_ executableURL: URL, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let cancellation = LiveRemoteEngineProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = LiveRemoteEngineProcessCompletion(
                    process: process,
                    continuation: continuation
                )

                let timeoutWork = DispatchWorkItem {
                    let message = "\(executableURL.path) timed out after \(Int(self.timeout))s"
                    completion.complete(.failure(RemoteEngineError.bootstrapFailed(message)))
                }
                completion.setTimeoutWork(timeoutWork)
                cancellation.setCompletion(completion)

                process.terminationHandler = { process in
                    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    let errorText = String(data: stderrData, encoding: .utf8) ?? ""
                    if process.terminationStatus == 0 {
                        completion.complete(.success(output))
                    } else {
                        let message = errorText.isEmpty
                        ? "\(executableURL.path) exited with status \(process.terminationStatus)"
                        : errorText
                        completion.complete(.failure(RemoteEngineError.bootstrapFailed(message)))
                    }
                }

                let runWork = DispatchWorkItem {
                    completion.start()
                }
                completion.setRunWork(runWork)

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                DispatchQueue.global().async(execute: runWork)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class LiveRemoteEngineProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: LiveRemoteEngineProcessCompletion?
    private var didCancel = false

    func setCompletion(_ completion: LiveRemoteEngineProcessCompletion) {
        lock.lock()
        if didCancel {
            lock.unlock()
            completion.complete(.failure(CancellationError()))
            return
        }
        self.completion = completion
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        didCancel = true
        let completion = completion
        lock.unlock()
        completion?.complete(.failure(CancellationError()))
    }
}

private final class LiveRemoteEngineProcessCompletion: @unchecked Sendable {
    private let process: Process
    private let continuation: CheckedContinuation<String, Error>
    private let lock = NSLock()
    private var didComplete = false
    private var timeoutWork: DispatchWorkItem?
    private var runWork: DispatchWorkItem?

    init(process: Process, continuation: CheckedContinuation<String, Error>) {
        self.process = process
        self.continuation = continuation
    }

    func setTimeoutWork(_ timeoutWork: DispatchWorkItem) {
        lock.lock()
        self.timeoutWork = timeoutWork
        let shouldCancel = didComplete
        lock.unlock()

        if shouldCancel {
            timeoutWork.cancel()
        }
    }

    func setRunWork(_ runWork: DispatchWorkItem) {
        lock.lock()
        self.runWork = runWork
        let shouldCancel = didComplete
        lock.unlock()

        if shouldCancel {
            runWork.cancel()
        }
    }

    func start() {
        lock.lock()
        let shouldStart = !didComplete
        lock.unlock()
        guard shouldStart else { return }

        do {
            try process.run()
            lock.lock()
            let shouldTerminate = didComplete
            lock.unlock()
            if shouldTerminate && process.isRunning {
                process.terminate()
            }
        } catch {
            complete(.failure(error))
        }
    }

    func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let timeoutWork = timeoutWork
        let runWork = runWork
        lock.unlock()
        timeoutWork?.cancel()
        runWork?.cancel()

        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            if process.isRunning {
                process.terminate()
            }
            continuation.resume(throwing: error)
        }
    }
}

private final class LiveRemoteEngineBootstrapper: RemoteEngineBootstrapper {
    private let base: RemoteEngineBootstrapper
    private let usesLoopbackRelay: Bool
    private let processRunner: RemoteEngineProcessRunning
    private let lock = NSLock()
    private var relays: [UInt16: LiveLoopbackUDPRelay] = [:]
    private var lastRemoteMaterial: RemoteEngineAttachMaterial?
    private var remoteMaterials: [RemoteEngineAttachMaterial] = []

    init(
        base: RemoteEngineBootstrapper,
        usesLoopbackRelay: Bool,
        processRunner: RemoteEngineProcessRunning
    ) {
        self.base = base
        self.usesLoopbackRelay = usesLoopbackRelay
        self.processRunner = processRunner
    }

    func attachMaterial(workspaceID: String, host: Fantastty.SSHHostInfo) async throws -> RemoteEngineAttachMaterial {
        let material = try await base.attachMaterial(workspaceID: workspaceID, host: host)
        setLastRemoteMaterial(material)
        guard usesLoopbackRelay else { return material }

        try startRelayIfNeeded(remoteHost: material.host, port: material.port)
        return RemoteEngineAttachMaterial(
            workspaceID: material.workspaceID,
            host: "127.0.0.1",
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

    func shutdown(material: RemoteEngineAttachMaterial, host: Fantastty.SSHHostInfo) async throws {
        try await base.shutdown(material: material, host: host)
    }

    func stopRelays() {
        lock.lock()
        let activeRelays = relays.values
        relays.removeAll()
        lock.unlock()

        for relay in activeRelays {
            relay.stop()
        }
    }

    func remoteWorkspaceSummary(host: Fantastty.SSHHostInfo, containing marker: String) async -> String {
        let material = currentRemoteMaterial()
        guard let material else { return "remoteProbe=no-attach-material" }

        var arguments = sshArguments(for: host)
        arguments.append(remoteWorkspaceProbeCommand(session: material.session, marker: marker))
        do {
            let output = try await processRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "remoteProbe=error \(error.localizedDescription)"
        }
    }

    func remoteQUICLogSummary(host: Fantastty.SSHHostInfo) async -> String {
        let material = currentRemoteMaterial()
        guard let material else { return "remoteQUICLog=no-attach-material" }

        var arguments = sshArguments(for: host)
        arguments.append(remoteQUICLogCommand(session: material.session))
        do {
            let output = try await processRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "remoteQUICLog=error \(error.localizedDescription)"
        }
    }

    func remoteSessionState(
        host: Fantastty.SSHHostInfo,
        material: RemoteEngineAttachMaterial
    ) async -> LiveRemoteSessionState {
        var arguments = sshArguments(for: host)
        arguments.append(
            remoteSessionStateCommand(
                workspaceID: material.workspaceID,
                session: material.session,
                helperPID: material.helperPID
            )
        )
        do {
            let output = try await processRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments)
            return LiveRemoteSessionState(output: output)
        } catch {
            return LiveRemoteSessionState(summary: "remoteState=error \(error.localizedDescription)")
        }
    }

    func attachMaterials() -> [RemoteEngineAttachMaterial] {
        lock.lock()
        defer { lock.unlock() }
        return remoteMaterials
    }

    func shutdownRecordedMaterials(host: Fantastty.SSHHostInfo) async {
        for material in attachMaterials().reversed() {
            try? await shutdown(material: material, host: host)
        }
    }

    private func startRelayIfNeeded(remoteHost: String, port: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        if relays[port] != nil {
            return
        }

        let relay = try LiveLoopbackUDPRelay(remoteHost: remoteHost, port: port)
        relays[port] = relay
    }

    private func setLastRemoteMaterial(_ material: RemoteEngineAttachMaterial) {
        lock.lock()
        lastRemoteMaterial = material
        remoteMaterials.append(material)
        lock.unlock()
    }

    private func currentRemoteMaterial() -> RemoteEngineAttachMaterial? {
        lock.lock()
        defer { lock.unlock() }
        return lastRemoteMaterial
    }

    private func sshArguments(for host: Fantastty.SSHHostInfo) -> [String] {
        var arguments = ["-o", "BatchMode=yes"]
        if let port = host.port {
            arguments.append(contentsOf: ["-p", "\(port)"])
        }
        arguments.append(sshTarget(host))
        return arguments
    }

    private func sshTarget(_ host: Fantastty.SSHHostInfo) -> String {
        var target = ""
        if let user = host.user {
            target += "\(user)@"
        }
        target += host.hostname
        return target
    }

    private func remoteWorkspaceProbeCommand(session: String, marker: String) -> String {
        "python3 -c \(shellQuote(Self.remoteWorkspaceProbeScript)) \(shellQuote(session)) \(shellQuote(marker))"
    }

    private func remoteQUICLogCommand(session: String) -> String {
        "python3 -c \(shellQuote(Self.remoteQUICLogScript)) \(shellQuote(session))"
    }

    private func remoteSessionStateCommand(workspaceID: String, session: String, helperPID: Int) -> String {
        "python3 -c \(shellQuote(Self.remoteSessionStateScript)) \(shellQuote(workspaceID)) \(shellQuote(session)) \(helperPID)"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let remoteSessionStateScript = """
import hashlib
import json
import os
import subprocess
import sys

workspace = sys.argv[1]
session = sys.argv[2]
pid = int(sys.argv[3])
runtime = "/tmp/fantastty-remote-engine-%d" % os.getuid()
registry_present = False
try:
    with open(runtime + "/registry.json", "r", encoding="utf-8") as handle:
        registry = json.load(handle)
    registry_present = session in registry.get("sessions", {})
except Exception:
    pass

try:
    os.kill(pid, 0)
    helper_alive = True
except Exception:
    helper_alive = False
helper_identity = False
helper_rss_kb = -1
if helper_alive:
    commands = []
    try:
        with open("/proc/%d/comm" % pid, "r", encoding="utf-8", errors="replace") as handle:
            commands.append(handle.read().strip())
    except Exception:
        pass
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            commands.append(handle.read().replace(b"\\x00", b" ").decode("utf-8", "replace"))
    except Exception:
        pass
    helper_identity = any("fantastty-helper" in command for command in commands)
    try:
        with open("/proc/%d/status" % pid, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith("VmRSS:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        helper_rss_kb = int(parts[1])
                    break
    except Exception:
        pass

socket_hash = hashlib.sha256(workspace.encode("utf-8")).hexdigest()[:32]
socket_path = runtime + "/tmux-workspace-" + socket_hash + ".sock"
session_name = "fantastty-remote-" + workspace
has_session = subprocess.run(
    ["tmux", "-S", socket_path, "has-session", "-t", session_name],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
).returncode == 0
clients = 0
if has_session:
    result = subprocess.run(
        ["tmux", "-S", socket_path, "list-clients", "-F", "#{client_pid}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode == 0:
        clients = len([line for line in result.stdout.splitlines() if line.strip()])

print(
    "remoteState=ok registry_present=%s helper_alive=%s helper_identity=%s private_tmux_present=%s private_tmux_clients=%d socket_exists=%s helper_rss_kb=%d workspace=%s session=%s pid=%d" % (
        str(registry_present).lower(),
        str(helper_alive).lower(),
        str(helper_identity).lower(),
        str(has_session).lower(),
        clients,
        str(os.path.exists(socket_path)).lower(),
        helper_rss_kb,
        workspace,
        session,
        pid,
    )
)
"""

    private static let remoteWorkspaceProbeScript = """
import json
import os
import socket
import sys

session = sys.argv[1]
marker = sys.argv[2]
runtime = "/tmp/fantastty-remote-engine-%d" % os.getuid()
try:
    with open(runtime + "/registry.json", "r", encoding="utf-8") as handle:
        registry = json.load(handle)
except Exception as exc:
    print("remoteProbe=registry-error " + str(exc).replace("\\n", "_"))
    raise SystemExit(0)

record = registry.get("sessions", {}).get(session)
if not record:
    print("remoteProbe=no-session")
    raise SystemExit(0)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.settimeout(3)
    sock.connect(record["socket_path"])
    sock.sendall(("workspace-messages " + session + "\\n").encode("utf-8"))
    chunks = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
finally:
    sock.close()

payload = b"".join(chunks).decode("utf-8", "replace")
kinds = []
for line in payload.splitlines():
    try:
        kinds.append(json.loads(line).get("type", "?"))
    except Exception:
        kinds.append("?")

print(
    "remoteProbe=session-present bytes=%d containsMarker=%s kinds=%s" % (
        len(payload.encode("utf-8")),
        str(marker in payload).lower(),
        "|".join(kinds[-6:]),
    )
)
"""

    private static let remoteQUICLogScript = """
import os
import sys

session = sys.argv[1]
path = "/tmp/fantastty-remote-engine-%d/quic-%s.log" % (os.getuid(), session)
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        lines = [line.strip() for line in handle if line.strip()]
except FileNotFoundError:
    print("remoteQUICLog=missing")
    raise SystemExit(0)
except Exception as exc:
    print("remoteQUICLog=error " + str(exc).replace("\\n", "_"))
    raise SystemExit(0)

print("remoteQUICLog=" + " | ".join(lines[-60:]))
"""
}

private final class LiveLoopbackUDPRelay {
    private let process: Process
    private let errorPipe = Pipe()

    init(remoteHost: String, port: UInt16) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-u",
            "-c",
            Self.script,
            "127.0.0.1",
            "\(port)",
            remoteHost,
            "\(port)"
        ]
        process.standardError = errorPipe
        try process.run()

        Thread.sleep(forTimeInterval: 0.2)
        guard process.isRunning else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "relay failed to start"
            throw LiveLoopbackRelayError(message: message)
        }
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static let script = """
import socket
import sys
import select

listen_host = sys.argv[1]
listen_port = int(sys.argv[2])
remote = (sys.argv[3], int(sys.argv[4]))

client_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
client_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
client_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
client_sock.bind((listen_host, listen_port))

remote_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
remote_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
remote_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
remote_sock.connect(remote)

client = None

while True:
    readable, _, _ = select.select([client_sock, remote_sock], [], [])
    if client_sock in readable:
        data, address = client_sock.recvfrom(65535)
        client = address
        remote_sock.send(data)
    if remote_sock in readable:
        data = remote_sock.recv(65535)
        if client is not None:
            client_sock.sendto(data, client)
"""
}

private struct LiveLoopbackRelayError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor LiveRecordingRemoteEngineTransport: RemoteEngineTransport {
    private let base: RemoteEngineTransport
    private let inputDelay: LiveRemoteInputDelay?
    private var connections: [LiveRecordingRemoteEngineConnection] = []

    init(base: RemoteEngineTransport, inputDelay: LiveRemoteInputDelay? = nil) {
        self.base = base
        self.inputDelay = inputDelay
    }

    func connect(using material: RemoteEngineAttachMaterial) async throws -> RemoteEngineConnection {
        let connection = LiveRecordingRemoteEngineConnection(
            base: try await base.connect(using: material),
            inputDelay: inputDelay
        )
        connections.append(connection)
        return connection
    }

    func connectionCount() -> Int {
        connections.count
    }

    func closeConnection(at index: Int) {
        guard connections.indices.contains(index) else { return }
        connections[index].close()
    }

    func requestKeyframe(on index: Int, workspaceID: String, paneID: Int) async throws {
        guard connections.indices.contains(index) else { return }
        try await connections[index].requestKeyframe(workspaceID: workspaceID, paneID: paneID, reason: .noKeyframe)
    }

    func hasKeyframe(on index: Int, containing marker: String) -> Bool {
        guard connections.indices.contains(index) else { return false }
        return connections[index].hasKeyframe(containing: marker)
    }

    func hasMessage(on index: Int, containing marker: String) -> Bool {
        guard connections.indices.contains(index) else { return false }
        return connections[index].hasMessage(containing: marker)
    }

    func hasDatagramMessage(on index: Int, containing marker: String) -> Bool {
        guard connections.indices.contains(index) else { return false }
        return connections[index].hasDatagramMessage(containing: marker)
    }

    func hasMarkerKeyframeBeforeDatagram(on index: Int, containing marker: String) -> Bool {
        guard connections.indices.contains(index) else { return false }
        return connections[index].hasMarkerKeyframeBeforeDatagram(containing: marker)
    }

    func hasRuntimeRenderAction(on index: Int, containing marker: String) -> Bool {
        guard connections.indices.contains(index) else { return false }
        return connections[index].hasRuntimeRenderAction(containing: marker)
    }

    func hasRuntimeRenderAction(on index: Int) -> Bool {
        guard connections.indices.contains(index) else { return false }
        return connections[index].hasRuntimeRenderAction()
    }

    func firstPaneID(on index: Int) -> Int? {
        guard connections.indices.contains(index) else { return nil }
        return connections[index].firstPaneID()
    }

    func messageSummary(on index: Int, containing marker: String) -> String {
        guard connections.indices.contains(index) else { return "connection \(index) is missing" }
        return connections[index].messageSummary(containing: marker)
    }

    func completedInputSendCount(on index: Int) -> Int {
        guard connections.indices.contains(index) else { return 0 }
        return connections[index].completedInputSendCount()
    }
}

private actor LiveRemoteEngineDiagnosticLog {
    private var events: [RemoteEngineNWQUICDiagnosticEvent] = []

    func record(_ event: RemoteEngineNWQUICDiagnosticEvent) {
        events.append(event)
    }

    func summary() -> String {
        guard !events.isEmpty else { return "quic=no diagnostic events" }
        return "quic=" + events.suffix(12).map(\.description).joined(separator: " | ")
    }
}

private actor LiveRemoteWorkspaceRenderDiagnosticLog {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func summary() -> String {
        guard !events.isEmpty else { return "bridgeRender=no events" }
        return "bridgeRender=" + events.suffix(20).joined(separator: " | ")
    }

    func hasRenderedGrid() -> Bool {
        events.contains { $0.contains("result=rendered") }
    }

    func hasRenderedTentativeGrid() -> Bool {
        events.contains { $0.contains("result=rendered") && !$0.contains("tentativeRows=0") }
    }
}

private actor LiveRemoteInputDelay {
    private var delayNanoseconds: UInt64 = 0
    private var pendingDelays = 0

    func setDelayNanoseconds(_ delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func isDelaying() -> Bool {
        pendingDelays > 0
    }

    func waitIfNeeded() async throws {
        let delayNanoseconds = delayNanoseconds
        guard delayNanoseconds > 0 else { return }
        pendingDelays += 1
        defer { pendingDelays -= 1 }
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }
}

private final class LiveRecordingRemoteEngineConnection: RemoteEngineConnection {
    let messages: AsyncThrowingStream<RemoteEngineInboundMessage, Error>

    private let base: RemoteEngineConnection
    private let store = LiveRecordingRemoteEngineMessageStore()
    private let inputDelay: LiveRemoteInputDelay?

    init(base: RemoteEngineConnection, inputDelay: LiveRemoteInputDelay?) {
        self.base = base
        self.inputDelay = inputDelay
        let upstream = base.messages
        let store = store
        messages = AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await inbound in upstream {
                        store.record(inbound)
                        continuation.yield(inbound)
                    }
                    continuation.finish()
                } catch {
                    store.recordStreamFailure(error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func requestKeyframe(
        workspaceID: String,
        paneID: Int,
        reason: RemotePaneGridKeyframeRequestReason
    ) async throws {
        store.recordKeyframeRequest(workspaceID: workspaceID, paneID: paneID, reason: reason)
        do {
            try await base.requestKeyframe(workspaceID: workspaceID, paneID: paneID, reason: reason)
            store.recordKeyframeRequestCompletion()
        } catch {
            store.recordKeyframeRequestFailure(error)
            throw error
        }
    }

    func sendKeys(workspaceID: String, paneID: Int, data: Data) async throws {
        store.recordSendKeys(data)
        do {
            try await inputDelay?.waitIfNeeded()
            try await base.sendKeys(workspaceID: workspaceID, paneID: paneID, data: data)
            store.recordSendKeysCompletion()
        } catch {
            store.recordSendKeysFailure(error)
            throw error
        }
    }

    func resizePane(workspaceID: String, paneID: Int, size: RemoteGridSize) async throws {
        try await base.resizePane(workspaceID: workspaceID, paneID: paneID, size: size)
    }

    func newWindow(workspaceID: String) async throws {
        try await base.newWindow(workspaceID: workspaceID)
    }

    func selectWindow(workspaceID: String, windowID: Int) async throws {
        try await base.selectWindow(workspaceID: workspaceID, windowID: windowID)
    }

    func close() {
        base.close()
    }

    func hasKeyframe(containing marker: String) -> Bool {
        store.hasKeyframe(containing: marker)
    }

    func hasMessage(containing marker: String) -> Bool {
        store.hasMessage(containing: marker)
    }

    func hasDatagramMessage(containing marker: String) -> Bool {
        store.hasDatagramMessage(containing: marker)
    }

    func hasMarkerKeyframeBeforeDatagram(containing marker: String) -> Bool {
        store.hasMarkerKeyframeBeforeDatagram(containing: marker)
    }

    func hasRuntimeRenderAction(containing marker: String) -> Bool {
        store.hasRuntimeRenderAction(containing: marker)
    }

    func hasRuntimeRenderAction() -> Bool {
        store.hasRuntimeRenderAction()
    }

    func firstPaneID() -> Int? {
        store.firstPaneID()
    }

    func messageSummary(containing marker: String) -> String {
        store.summary(containing: marker)
    }

    func completedInputSendCount() -> Int {
        store.completedInputSendCount()
    }
}

private final class LiveRecordingRemoteEngineMessageStore {
    private struct RecordedGridMessage {
        let kind: String
        let delivery: RemotePaneDeltaDelivery
        let text: String
    }

    private let lock = NSLock()
    private var runtimes: [String: RemoteWorkspaceRuntime] = [:]
    private var messageKinds: [String] = []
    private var orderedGridMessages: [RecordedGridMessage] = []
    private var keyframeText: [String] = []
    private var messageText: [String] = []
    private var datagramMessageText: [String] = []
    private var runtimeRenderActionText: [String] = []
    private var paneIDs: [Int] = []
    private var sentInputText: [String] = []
    private var completedInputSends = 0
    private var inputSendFailures: [String] = []
    private var keyframeRequests: [String] = []
    private var completedKeyframeRequests = 0
    private var keyframeRequestFailures: [String] = []
    private var streamFailures: [String] = []

    func record(_ inbound: RemoteEngineInboundMessage) {
        let message = inbound.message
        let kind: String
        let text: String?
        let newPaneIDs: [Int]
        switch message {
        case .workspaceSnapshot(let snapshot):
            kind = "workspaceSnapshot"
            text = nil
            newPaneIDs = snapshot.panes.map(\.paneID)
        case .paneKeyframe(let keyframe):
            kind = "paneKeyframe"
            text = keyframe.rows
                .sorted { $0.index < $1.index }
                .map { row in row.cells.map(\.text).joined() }
                .joined(separator: "\n")
            newPaneIDs = [keyframe.paneID]
        case .paneDelta(let delta):
            kind = "paneDelta"
            text = delta.rowUpdates
                .sorted { $0.rowIndex < $1.rowIndex }
                .map { update in update.update.text }
                .joined(separator: "\n")
            newPaneIDs = [delta.paneID]
        case .unsupportedPaneState:
            kind = "unsupportedPaneState"
            text = nil
            newPaneIDs = []
        }

        lock.lock()
        messageKinds.append(kind)
        paneIDs.append(contentsOf: newPaneIDs)
        if let text {
            orderedGridMessages.append(RecordedGridMessage(kind: kind, delivery: inbound.delivery, text: text))
            messageText.append(text)
            if case .paneKeyframe = message {
                keyframeText.append(text)
            }
            if inbound.delivery == .datagram {
                datagramMessageText.append(text)
            }
        }
        var runtime = runtimes[message.liveWorkspaceID] ?? RemoteWorkspaceRuntime(workspaceID: message.liveWorkspaceID)
        for action in runtime.handle(message, delivery: inbound.delivery) {
            if case .renderPaneGrid(_, let state) = action {
                runtimeRenderActionText.append(Self.text(from: state))
            }
        }
        runtimes[message.liveWorkspaceID] = runtime
        lock.unlock()
    }

    func hasKeyframe(containing marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keyframeText.contains { $0.contains(marker) }
    }

    func hasMessage(containing marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return messageText.contains { $0.contains(marker) } ||
        runtimeRenderActionText.contains { $0.contains(marker) }
    }

    func hasDatagramMessage(containing marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return datagramMessageText.contains { $0.contains(marker) }
    }

    func hasMarkerKeyframeBeforeDatagram(containing marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let keyframeIndex = orderedGridMessages.firstIndex(where: {
            $0.kind == "paneKeyframe" && $0.text.contains(marker)
        }) else {
            return false
        }
        guard let datagramIndex = orderedGridMessages.firstIndex(where: {
            $0.delivery == .datagram && $0.text.contains(marker)
        }) else {
            return true
        }
        return keyframeIndex < datagramIndex
    }

    func hasRuntimeRenderAction(containing marker: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runtimeRenderActionText.contains { $0.contains(marker) }
    }

    func hasRuntimeRenderAction() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !runtimeRenderActionText.isEmpty
    }

    func firstPaneID() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return paneIDs.first
    }

    func recordSendKeys(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        lock.lock()
        sentInputText.append(text)
        lock.unlock()
    }

    func recordSendKeysCompletion() {
        lock.lock()
        completedInputSends += 1
        lock.unlock()
    }

    func completedInputSendCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completedInputSends
    }

    func recordSendKeysFailure(_ error: Error) {
        lock.lock()
        inputSendFailures.append(error.localizedDescription)
        lock.unlock()
    }

    func recordKeyframeRequest(
        workspaceID: String,
        paneID: Int,
        reason: RemotePaneGridKeyframeRequestReason
    ) {
        lock.lock()
        keyframeRequests.append("\(workspaceID):\(paneID):\(reason)")
        lock.unlock()
    }

    func recordKeyframeRequestCompletion() {
        lock.lock()
        completedKeyframeRequests += 1
        lock.unlock()
    }

    func recordKeyframeRequestFailure(_ error: Error) {
        lock.lock()
        keyframeRequestFailures.append(error.localizedDescription)
        lock.unlock()
    }

    func recordStreamFailure(_ error: Error) {
        lock.lock()
        streamFailures.append(error.localizedDescription)
        lock.unlock()
    }

    func summary(containing marker: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let sawMarker = messageText.contains { $0.contains(marker) }
        let sawDatagramMarker = datagramMessageText.contains { $0.contains(marker) }
        let sawRuntimeRenderMarker = runtimeRenderActionText.contains { $0.contains(marker) }
        let sentInputs = sentInputText
            .suffix(3)
            .map { $0.replacingOccurrences(of: "\n", with: "\\n") }
            .joined(separator: " | ")
        let lastGridText = messageText
            .suffix(3)
            .map(Self.diagnosticSnippet)
            .joined(separator: " | ")
        let lastDatagramText = datagramMessageText
            .suffix(3)
            .map(Self.diagnosticSnippet)
            .joined(separator: " | ")
        let lastRuntimeRenderText = runtimeRenderActionText
            .suffix(3)
            .map(Self.diagnosticSnippet)
            .joined(separator: " | ")
        return [
            "decodedMessages=\(messageKinds.count)",
            "lastKinds=\(messageKinds.suffix(8).joined(separator: " | "))",
            "gridTextMessages=\(messageText.count)",
            "datagramMessages=\(datagramMessageText.count)",
            "runtimeRenderActions=\(runtimeRenderActionText.count)",
            "keyframes=\(keyframeText.count)",
            "paneIDs=\(Array(paneIDs.prefix(3)))",
            "sawMarker=\(sawMarker)",
            "sawDatagramMarker=\(sawDatagramMarker)",
            "sawRuntimeRenderMarker=\(sawRuntimeRenderMarker)",
            "sentInputs=\(sentInputText.count)",
            "completedInputSends=\(completedInputSends)",
            "inputSendFailures=\(inputSendFailures.suffix(3).joined(separator: " | "))",
            "keyframeRequests=\(keyframeRequests.count)",
            "completedKeyframeRequests=\(completedKeyframeRequests)",
            "keyframeRequestFailures=\(keyframeRequestFailures.suffix(3).joined(separator: " | "))",
            "lastKeyframeRequests=\(keyframeRequests.suffix(3).joined(separator: " | "))",
            "streamFailures=\(streamFailures.suffix(3).joined(separator: " | "))",
            "lastSentInputs=\(sentInputs)",
            "lastGridText=\(lastGridText)",
            "lastDatagramText=\(lastDatagramText)",
            "lastRuntimeRenderText=\(lastRuntimeRenderText)"
        ].joined(separator: "; ")
    }

    private static func text(from state: RemotePaneGridState) -> String {
        state.rows
            .map { row in row.map(\.text).joined() }
            .joined(separator: "\n")
    }

    private static func diagnosticSnippet(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if normalized.count <= 160 {
            return normalized
        }
        return String(normalized.suffix(160))
    }
}

private extension RemoteWorkspaceMessage {
    var liveWorkspaceID: String {
        switch self {
        case .workspaceSnapshot(let snapshot):
            return snapshot.workspaceID
        case .paneKeyframe(let keyframe):
            return keyframe.workspaceID
        case .paneDelta(let delta):
            return delta.workspaceID
        case .unsupportedPaneState(let state):
            return state.workspaceID
        }
    }
}

private extension RemoteRowUpdateBody {
    var text: String {
        switch self {
        case .fullRow(let cells):
            return cells.map(\.text).joined()
        case .span(_, _, let cells, _):
            return cells.map(\.text).joined()
        }
    }
}

private func waitUntilLive(
    _ description: String,
    timeout: TimeInterval = 20,
    diagnostics: (() async -> String)? = nil,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let diagnosticText: String?
    if let diagnostics {
        diagnosticText = await diagnostics()
    } else {
        diagnosticText = nil
    }
    let message = [
        "Timed out waiting for \(description)",
        diagnosticText
    ]
        .compactMap { $0 }
        .joined(separator: "; ")
    XCTFail(message)
    throw RemoteEngineLiveWaitTimeout(message: message)
}

private struct RemoteEngineLiveWaitTimeout: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
