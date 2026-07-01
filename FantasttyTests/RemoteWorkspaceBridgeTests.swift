import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
private enum RemoteWorkspaceBridgeTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

@MainActor
final class RemoteWorkspaceBridgeTests: XCTestCase {
    func testRegisterSessionAndSnapshotCreateTabsAndSurfaces() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var createdPaneIDs: [Int] = []
        var requestedKeyframes: [(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)] = []

        bridge.surfaceFactory = { paneID in
            createdPaneIDs.append(paneID)
            return self.makeSurface()
        }
        bridge.keyframeRequestHandler = { _, paneID, reason in
            requestedKeyframes.append((paneID, reason))
            return nil
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: false)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true),
            makePane(paneID: 8, windowID: 2)
        ])))

        XCTAssertTrue(bridge.hasBinding(for: "workspace-1"))
        XCTAssertEqual(session.tabs.map(\.title), ["main", "logs"])
        XCTAssertEqual(session.selectedTabID, session.tabs.first?.id)
        XCTAssertEqual(createdPaneIDs, [7, 8])
        XCTAssertEqual(session.tabs.map { $0.surfaceTree?.root?.leaves().count }, [1, 1])
        XCTAssertEqual(session.tabs.map(\.tmuxWindowID), [1, 2])
        XCTAssertEqual(session.tabs.map(\.tmuxWindowIndex), [0, 1])
        XCTAssertEqual(requestedKeyframes.map(\.paneID), [7, 8])
        XCTAssertTrue(requestedKeyframes.allSatisfy { $0.reason == .noKeyframe })
    }

    func testSnapshotPreservesSelectedBrowserTabWhenRemoteTabsStillExist() throws {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let browserTab = TerminalTab(url: try XCTUnwrap(URL(string: "https://example.com/docs")))
        session.tabs = [browserTab]
        session.selectedTabID = browserTab.id

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: false)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true),
            makePane(paneID: 8, windowID: 2)
        ])))

        XCTAssertEqual(session.tabs.map(\.kind), [.terminal, .terminal, .browser])
        XCTAssertEqual(session.selectedTabID, browserTab.id)
    }

    func testSnapshotConfiguresRemotePaneInputHandler() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var routedInput: [(workspaceID: String, paneID: Int, data: Data)] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneInputHandler = { workspaceID, paneID, data in
            routedInput.append((workspaceID, paneID, data))
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))

        guard let surface = session.tabs.first?.surfaceTree?.root?.leaves().first else {
            return XCTFail("Expected remote pane surface")
        }
        XCTAssertEqual(surface.tmuxPaneID, 7)
        XCTAssertNil(surface.tmuxControlClient)

        surface.remotePaneInputHandler?(7, RemotePaneInput(data: Data("hi\n".utf8), source: .directKey))

        XCTAssertEqual(routedInput.count, 1)
        XCTAssertEqual(routedInput.first?.workspaceID, "workspace-1")
        XCTAssertEqual(routedInput.first?.paneID, 7)
        XCTAssertEqual(routedInput.first?.data, Data("hi\n".utf8))
    }

    func testSurfaceRemotePaneInputHandlerPreservesPasteSourceForPredictionGate() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var routedInput: [Data] = []
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneInputHandler = { _, _, data in routedInput.append(data) }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        let surface = session.tabs.first?.surfaceTree?.root?.leaves().first

        scheduler.now = 1.0
        surface?.remotePaneInputHandler?(7, RemotePaneInput(data: Data("c".utf8), source: .paste))
        scheduler.advance(to: 1.20)

        XCTAssertEqual(routedInput.map { String(decoding: $0, as: UTF8.self) }, ["b", "c"])
        XCTAssertNotEqual(renderedRows.last?[0][4].text, "c")
    }

    func testDirectKeyInputForwardsBytesAndRendersOverlayAfterLatencyGate() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var routedInput: [Data] = []
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneInputHandler = { _, _, data in routedInput.append(data) }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))

        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))

        XCTAssertEqual(routedInput.map { String(decoding: $0, as: UTF8.self) }, ["b", "c"])
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.advance(to: 1.20)

        XCTAssertEqual(renderedRows.last?[0][4].text, "c")
    }

    func testPredictiveEchoGlobalDisableForwardsBytesWithoutOverlay() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var routedInput: [Data] = []
        var renderedRows: [[[RemoteGridCell]]] = []
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneInputHandler = { _, _, data in routedInput.append(data) }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.isPredictiveEchoEnabled = false
        bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }

        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        scheduler.advance(to: 1.20)

        XCTAssertEqual(routedInput.map { String(decoding: $0, as: UTF8.self) }, ["b", "c"])
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertNotEqual(renderedRows.last?[0][4].text, "c")
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .suppressed(reason: .disabledByUser)
            )
        ])
    }

    func testPredictiveEchoGlobalDisableCancelsScheduledOverlay() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))

        XCTAssertEqual(scheduler.pendingCount, 1)

        bridge.isPredictiveEchoEnabled = false
        scheduler.advance(to: 1.20)

        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertNotEqual(renderedRows.last?[0][4].text, "c")
    }

    func testPredictiveEchoWorkspaceDisableDoesNotDisableOtherWorkspaces() {
        let bridge = RemoteWorkspaceBridge()
        let disabledSession = makeRemoteSession(workspaceID: "workspace-1")
        let enabledSession = makeRemoteSession(workspaceID: "workspace-2")
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        bridge.setPredictiveEchoEnabled(false, workspaceID: "workspace-1")
        var renderedRowsByWorkspace: [String: [[[RemoteGridCell]]]] = [:]

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedRowsByWorkspace[state.workspaceID ?? "unknown", default: []].append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(disabledSession)
        bridge.registerRemoteWorkspaceSession(enabledSession)
        for workspaceID in ["workspace-1", "workspace-2"] {
            bridge.handle(.workspaceSnapshot(makeSnapshot(
                workspaceID: workspaceID,
                panes: [makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))]
            )))
            bridge.handle(.paneKeyframe(makeKeyframe(
                workspaceID: workspaceID,
                gridSize: RemoteGridSize(columns: 6, rows: 1),
                rowText: "$ a",
                cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
            )))
            bridge.handleRemotePaneInput(workspaceID: workspaceID, paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
            bridge.handle(.paneDelta(makeDelta(
                workspaceID: workspaceID,
                rowText: "$ ab",
                columns: 6,
                cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
            )))
            scheduler.now = 1.0
            bridge.handleRemotePaneInput(workspaceID: workspaceID, paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        }

        scheduler.advance(to: 1.20)

        XCTAssertNotEqual(renderedRowsByWorkspace["workspace-1"]?.last?[0][4].text, "c")
        XCTAssertEqual(renderedRowsByWorkspace["workspace-2"]?.last?[0][4].text, "c")
    }

    func testPasteAndImeInputsForwardWithoutPrediction() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var routedInput: [Data] = []
        var renderCount = 0
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneInputHandler = { _, _, data in routedInput.append(data) }
        bridge.paneGridRenderer = { _, _ in
            renderCount += 1
            return .rendered
        }
        bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 4, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 4, rows: 1),
            rowText: "$  ",
            cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .block)
        )))

        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("secret-paste-value".utf8), source: .paste))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("ime-secret-value".utf8), source: .imeCommit))
        scheduler.advance(to: 1.0)

        XCTAssertEqual(routedInput, [Data("secret-paste-value".utf8), Data("ime-secret-value".utf8)])
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(renderCount, 1)
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .suppressed(reason: .paste)
            ),
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .suppressed(reason: .ime)
            )
        ])
        XCTAssertFalse(predictionDiagnostics.description.contains("secret-paste-value"))
        XCTAssertFalse(predictionDiagnostics.description.contains("ime-secret-value"))
    }

    func testAlternateScreenDirectKeyReportsAlternateScreenSuppression() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var routedInput: [Data] = []
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneInputHandler = { _, _, data in routedInput.append(data) }
        bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 4, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 4, rows: 1),
            rowText: "$  ",
            cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .block),
            activeScreen: .alternate
        )))

        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("a".utf8), source: .directKey))

        XCTAssertEqual(routedInput, [Data("a".utf8)])
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .suppressed(reason: .alternateScreen)
            )
        ])
    }

    func testScheduledPredictionRenderNoOpsAfterFocusLoss() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        bridge.handleRemotePaneFocus(workspaceID: "workspace-1", paneID: 7, focused: false)

        scheduler.advance(to: 1.20)

        XCTAssertNotEqual(renderedRows.last?[0][4].text, "c")
    }

    func testTentativeRenderRejectionFallsBackToAuthoritativeState() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var renderedTentativeRows: [Set<Int>] = []
        var unsupportedStates: [RemoteUnsupportedPaneState] = []
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedTentativeRows.append(state.tentativeRows)
            if !state.tentativeRows.isEmpty {
                return .rejectedBySurface(stage: .row(0))
            }
            return .rendered
        }
        bridge.unsupportedPaneStateHandler = { _, state in
            unsupportedStates.append(state)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }

        scheduler.advance(to: 1.20)

        XCTAssertEqual(renderedTentativeRows.suffix(2), [Set([0]), Set()])
        XCTAssertTrue(unsupportedStates.isEmpty)
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .rolledBack(reason: .authoritativeMismatch)
            )
        ])
    }

    func testAuthoritativeMismatchRollbackReportsDiagnostic() {
        let harness = makeRenderedPredictionHarness()
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []
        harness.bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }

        harness.bridge.handle(.paneDelta(makeDelta(
            deltaSequence: 2,
            rowVersion: 13,
            rowText: "$ abx",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 5, visible: true, shape: .block, cursorVersion: 3)
        )))

        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "x")
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .rolledBack(reason: .authoritativeMismatch)
            )
        ])
    }

    func testPredictiveRenderDiagnosticReportsTentativeRows() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var diagnostics: [RemoteWorkspaceRenderDiagnostic] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { _, _ in .rendered }
        bridge.renderDiagnosticHandler = { diagnostic in
            diagnostics.append(diagnostic)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))

        scheduler.advance(to: 1.20)

        XCTAssertTrue(diagnostics.contains { $0.description.contains("tentativeRows=1") })
    }

    func testRapidDirectKeyInputsDoNotPostponeEarlierPredictionDeadline() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 8, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 8, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 8,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))

        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        scheduler.now = 1.04
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("d".utf8), source: .directKey))

        XCTAssertEqual(scheduler.pendingFireTimes.count, 1)
        XCTAssertEqual(scheduler.pendingFireTimes[0], 1.05, accuracy: 0.0001)

        scheduler.advance(to: 1.051)

        XCTAssertEqual(renderedRows.last?[0][4].text, "c")
        XCTAssertNotEqual(renderedRows.last?[0][5].text, "d")
        XCTAssertEqual(scheduler.pendingFireTimes.count, 1)
        XCTAssertEqual(scheduler.pendingFireTimes[0], 1.09, accuracy: 0.0001)

        scheduler.advance(to: 1.091)

        XCTAssertEqual(renderedRows.last?[0][5].text, "d")
    }

    func testBackspaceAfterTwoRenderedPredictionsKeepsRemainingOverlay() {
        let harness = makeRenderedPredictionHarness(columns: 8, initialRenderTime: 1.06)
        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")

        harness.scheduler.now = 1.07
        harness.bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("d".utf8), source: .directKey))
        harness.scheduler.advance(to: 1.13)
        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")
        XCTAssertEqual(harness.renderedRows().last?[0][5].text, "d")

        harness.bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data([0x7F]), source: .plainEraseByte))

        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")
        XCTAssertNotEqual(harness.renderedRows().last?[0][5].text, "d")
    }

    func testAuthoritativeMismatchDropsOverlayWithoutRequestingKeyframe() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var keyframeRequests: [RemotePaneGridKeyframeRequestReason] = []
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.keyframeRequestHandler = { _, _, reason in
            keyframeRequests.append(reason)
            return nil
        }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(
                paneID: 7,
                windowID: 1,
                isActive: true,
                frame: RemotePaneFrame(x: 0, y: 0, columns: 5, rows: 1)
            )
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 5, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(
            workspaceID: "workspace-1",
            paneID: 7,
            input: RemotePaneInput(data: Data("b".utf8), source: .directKey)
        )
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ax",
            columns: 5,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))

        XCTAssertFalse(renderedRows.last?[0].contains { $0.text == "b" } ?? true)
        XCTAssertEqual(keyframeRequests, [.noKeyframe])
    }

    func testRenderedPredictionIsClearedImmediatelyAfterLocalBarrierInput() {
        let barriers = [
            RemotePaneInput(data: Data([0x7F]), source: .plainEraseByte),
            RemotePaneInput(data: Data("\n".utf8), source: .directKey),
            RemotePaneInput(data: Data("paste".utf8), source: .paste),
            RemotePaneInput(data: Data([0x1B]), source: .escapeSequence)
        ]

        for barrier in barriers {
            let harness = makeRenderedPredictionHarness()
            XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")

            harness.bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: barrier)

            XCTAssertNotEqual(harness.renderedRows().last?[0][4].text, "c", "\(barrier.source)")
        }
    }

    func testRenderedPredictionIsClearedImmediatelyAfterFocusLoss() {
        let harness = makeRenderedPredictionHarness()
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []
        harness.bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }
        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")

        harness.bridge.handleRemotePaneFocus(workspaceID: "workspace-1", paneID: 7, focused: false)

        XCTAssertNotEqual(harness.renderedRows().last?[0][4].text, "c")
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .suppressed(reason: .focusLost)
            )
        ])
    }

    func testConfiguredSurfaceFocusLossClearsRenderedPrediction() {
        let harness = makeRenderedPredictionHarness()
        let surface = harness.session.tabs.first?.surfaceTree?.root?.leaves().first
        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")

        surface?.focusDidChange(false)

        XCTAssertNotEqual(harness.renderedRows().last?[0][4].text, "c")
    }

    func testConfiguredSurfaceFocusGainEnablesPrediction() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: false, frame: RemotePaneFrame(x: 0, y: 0, columns: 6, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: 6, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        let surface = session.tabs.first?.surfaceTree?.root?.leaves().first

        surface?.focusDidChange(true)
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: 6,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        scheduler.advance(to: 1.20)

        XCTAssertEqual(renderedRows.last?[0][4].text, "c")
    }

    func testRenderedPredictionIsClearedImmediatelyBeforeReattachDropsGridState() async {
        let harness = makeRenderedPredictionHarness()
        var predictionDiagnostics: [RemoteWorkspacePredictionDiagnostic] = []
        var authoritativeRenders: [(workspaceID: String, paneID: Int)] = []
        harness.bridge.predictionDiagnosticHandler = { diagnostic in
            predictionDiagnostics.append(diagnostic)
        }
        harness.bridge.authoritativePaneRenderHandler = { workspaceID, paneID in
            authoritativeRenders.append((workspaceID, paneID))
        }
        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")

        await harness.bridge.handleReattach(workspaceID: "workspace-1")

        XCTAssertNotEqual(harness.renderedRows().last?[0][4].text, "c")
        XCTAssertTrue(authoritativeRenders.isEmpty)
        XCTAssertEqual(predictionDiagnostics, [
            RemoteWorkspacePredictionDiagnostic(
                workspaceID: "workspace-1",
                paneID: 7,
                state: .suppressed(reason: .reattach)
            )
        ])
    }

    func testRenderedPredictionExpiresAtNoAckTimeoutWithoutAuthoritativeEcho() {
        let harness = makeRenderedPredictionHarness()
        XCTAssertEqual(harness.renderedRows().last?[0][4].text, "c")

        harness.scheduler.advance(to: 1.51)

        XCTAssertNotEqual(harness.renderedRows().last?[0][4].text, "c")
    }

    func testRenderDiagnosticHandlerReportsRenderResult() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var diagnostics: [RemoteWorkspaceRenderDiagnostic] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridRenderer = { _, _ in
            .rendered
        }
        bridge.renderDiagnosticHandler = { diagnostic in
            diagnostics.append(diagnostic)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneID: 7, rowText: "ok")))

        XCTAssertEqual(diagnostics.map(\.workspaceID), ["workspace-1"])
        XCTAssertEqual(diagnostics.map(\.paneID), [7])
        XCTAssertEqual(diagnostics.map(\.result), [.rendered])
        XCTAssertEqual(diagnostics.map(\.hasSurface), [true])
    }

    func testNotReadyAuthoritativeRenderRetriesUntilSurfaceCanRender() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var renderAttempts = 0
        var authoritativeRenders: [(workspaceID: String, paneID: Int)] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridRenderer = { _, _ in
            renderAttempts += 1
            return renderAttempts == 1 ? .notReady : .rendered
        }
        bridge.authoritativePaneRenderHandler = { workspaceID, paneID in
            authoritativeRenders.append((workspaceID, paneID))
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneID: 7, rowText: "ok")))

        XCTAssertEqual(renderAttempts, 1)
        await waitUntilRemoteWorkspaceBridge {
            renderAttempts == 2 && authoritativeRenders.count == 1
        }

        XCTAssertEqual(renderAttempts, 2)
        XCTAssertEqual(authoritativeRenders.map(\.workspaceID), ["workspace-1"])
        XCTAssertEqual(authoritativeRenders.map(\.paneID), [7])
    }

    func testRemoteSurfaceSizeChangeSendsPaneResizeIntent() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var resizeIntents: [(workspaceID: String, paneID: Int, size: RemoteGridSize)] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneResizeHandler = { workspaceID, paneID, size in
            resizeIntents.append((workspaceID, paneID, size))
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))

        guard let surface = session.tabs.first?.surfaceTree?.root?.leaves().first else {
            return XCTFail("Expected remote pane surface")
        }

        surface.surfaceSize = ghostty_surface_size_s(
            columns: 100,
            rows: 30,
            width_px: 1000,
            height_px: 600,
            cell_width_px: 10,
            cell_height_px: 20
        )
        await waitUntilRemoteWorkspaceBridge {
            resizeIntents.count == 1
        }

        XCTAssertEqual(resizeIntents.count, 1)
        XCTAssertEqual(resizeIntents.first?.workspaceID, "workspace-1")
        XCTAssertEqual(resizeIntents.first?.paneID, 7)
        XCTAssertEqual(resizeIntents.first?.size, RemoteGridSize(columns: 100, rows: 30))
    }

    func testSnapshotSizesCreatedRemoteSurfaceToPaneFrame() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var createdSurface: Ghostty.SurfaceView?
        var resized: [RemoteGridSize] = []

        bridge.surfaceFactory = { _ in
            let surface = self.makeSurface()
            createdSurface = surface
            return surface
        }
        bridge.paneGridResizeOperation = { surface, size in
            resized.append(size)
            return surface.resizeRemoteGrid(columns: size.columns, rows: size.rows)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(
                paneID: 7,
                windowID: 1,
                isActive: true,
                frame: RemotePaneFrame(x: 0, y: 0, columns: 17, rows: 3)
            )
        ])))

        XCTAssertNotNil(createdSurface)
        XCTAssertEqual(resized, [RemoteGridSize(columns: 17, rows: 3)])
    }

    func testNewerSnapshotUpdatesTabsReusesSurfacesAndPrunesRemovedPanes() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var surfacesByPaneID: [Int: Ghostty.SurfaceView] = [:]
        var createdPaneIDs: [Int] = []

        bridge.surfaceFactory = { paneID in
            createdPaneIDs.append(paneID)
            let surface = self.makeSurface()
            surfacesByPaneID[paneID] = surface
            return surface
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: false)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true),
            makePane(paneID: 8, windowID: 2)
        ])))

        let originalSurface = surfacesByPaneID[7]

        bridge.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 2, windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "renamed", index: 0, isActive: true)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 2, rows: 1)),
            makePane(paneID: 9, windowID: 1, frame: RemotePaneFrame(x: 2, y: 0, columns: 2, rows: 1))
        ])))

        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.tabs.first?.title, "renamed")
        XCTAssertEqual(createdPaneIDs, [7, 8, 9])
        let leaves = session.tabs.first?.surfaceTree?.root?.leaves() ?? []
        XCTAssertEqual(leaves.count, 2)
        XCTAssertTrue(leaves.contains { $0 === originalSurface })
        XCTAssertTrue(leaves.contains { $0 === surfacesByPaneID[9] })
        XCTAssertFalse(leaves.contains { $0 === surfacesByPaneID[8] })
    }

    func testSnapshotUsesPaneRowsForVerticalSplitRatio() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: 4, rows: 1)),
            makePane(paneID: 8, windowID: 1, frame: RemotePaneFrame(x: 0, y: 1, columns: 4, rows: 3))
        ])))

        guard case .split(let split) = session.tabs.first?.surfaceTree?.root else {
            return XCTFail("Expected a split root")
        }
        guard case .vertical = split.direction else {
            return XCTFail("Expected top/bottom panes to create a vertical split")
        }
        XCTAssertEqual(split.ratio, 0.25, accuracy: 0.001)
    }

    func testSnapshotPrefersTmuxLayoutStringForNestedSplitTree() throws {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var surfacesByPaneID: [Int: Ghostty.SurfaceView] = [:]

        bridge.surfaceFactory = { paneID in
            let surface = self.makeSurface()
            surfacesByPaneID[paneID] = surface
            return surface
        }

        bridge.registerRemoteWorkspaceSession(session)
        let layout = "abcd,120x30,0,0[120x14,0,0{60x14,0,0,%7,59x14,61,0,%8},120x15,0,15,%9]"
        let messageJSON = """
        {
          "workspaceSnapshot": {
            "_0": {
              "workspaceID": "workspace-1",
              "layoutGeneration": 1,
              "windows": [
                { "windowID": 1, "title": "main", "index": 0, "isActive": true, "layout": "\(layout)" }
              ],
              "panes": [
                {
                  "paneID": 7,
                  "windowID": 1,
                  "isActive": true,
                  "frame": { "x": 0, "y": 0, "columns": 60, "rows": 14 }
                },
                {
                  "paneID": 8,
                  "windowID": 1,
                  "isActive": false,
                  "frame": { "x": 61, "y": 0, "columns": 59, "rows": 14 }
                },
                {
                  "paneID": 9,
                  "windowID": 1,
                  "isActive": false,
                  "frame": { "x": 0, "y": 15, "columns": 120, "rows": 15 }
                }
              ]
            }
          }
        }
        """
        let message = try JSONDecoder().decode(RemoteWorkspaceMessage.self, from: Data(messageJSON.utf8))

        bridge.handle(message)

        guard case .split(let rootSplit) = session.tabs.first?.surfaceTree?.root else {
            return XCTFail("Expected a split root")
        }
        guard case .vertical = rootSplit.direction else {
            return XCTFail("Expected tmux layout string to make the root split top/bottom")
        }
        guard case .split(let topSplit) = rootSplit.left else {
            return XCTFail("Expected top row to be split left/right")
        }
        guard case .horizontal = topSplit.direction else {
            return XCTFail("Expected top row split to be horizontal")
        }
        XCTAssertEqual(paneID(for: topSplit.left, in: surfacesByPaneID), 7)
        XCTAssertEqual(paneID(for: topSplit.right, in: surfacesByPaneID), 8)
        XCTAssertEqual(paneID(for: rootSplit.right, in: surfacesByPaneID), 9)
    }

    func testSnapshotFallsBackToPaneFramesWhenTmuxLayoutStringIsMalformed() throws {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }

        bridge.registerRemoteWorkspaceSession(session)
        let messageJSON = """
        {
          "workspaceSnapshot": {
            "_0": {
              "workspaceID": "workspace-1",
              "layoutGeneration": 1,
              "windows": [
                { "windowID": 1, "title": "main", "index": 0, "isActive": true, "layout": "not-a-layout" }
              ],
              "panes": [
                {
                  "paneID": 7,
                  "windowID": 1,
                  "isActive": true,
                  "frame": { "x": 0, "y": 0, "columns": 4, "rows": 1 }
                },
                {
                  "paneID": 8,
                  "windowID": 1,
                  "isActive": false,
                  "frame": { "x": 0, "y": 1, "columns": 4, "rows": 3 }
                }
              ]
            }
          }
        }
        """
        let message = try JSONDecoder().decode(RemoteWorkspaceMessage.self, from: Data(messageJSON.utf8))

        bridge.handle(message)

        guard case .split(let split) = session.tabs.first?.surfaceTree?.root else {
            return XCTFail("Expected a split root")
        }
        guard case .vertical = split.direction else {
            return XCTFail("Expected malformed layout string to fall back to pane-frame split")
        }
        XCTAssertEqual(split.ratio, 0.25, accuracy: 0.001)
    }

    func testKeyframeBeforeSnapshotRendersAfterSurfaceExists() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var surfacesByPaneID: [Int: Ghostty.SurfaceView] = [:]
        var renderedPaneIDs: [Int] = []

        bridge.surfaceFactory = { paneID in
            let surface = self.makeSurface()
            surfacesByPaneID[paneID] = surface
            return surface
        }
        bridge.paneGridRenderer = { state, surface in
            let paneID = surfacesByPaneID.first { $0.value === surface }?.key
            renderedPaneIDs.append(paneID ?? -1)
            XCTAssertEqual(state.rows, [[.text("o"), .text("k")]])
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.paneKeyframe(makeKeyframe(rowText: "ok")))
        XCTAssertTrue(renderedPaneIDs.isEmpty)

        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))

        XCTAssertEqual(renderedPaneIDs, [7])
    }

    func testKeyframeAndDeltaRenderToTheExistingPaneSurface() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var surfacesByPaneID: [Int: Ghostty.SurfaceView] = [:]
        var rendered: [(paneID: Int, rows: [[RemoteGridCell]])] = []

        bridge.surfaceFactory = { paneID in
            let surface = self.makeSurface()
            surfacesByPaneID[paneID] = surface
            return surface
        }
        bridge.paneGridRenderer = { state, surface in
            let paneID = surfacesByPaneID.first { $0.value === surface }?.key ?? -1
            rendered.append((paneID, state.rows))
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(rowText: "ok")))
        bridge.handle(.paneDelta(makeDelta(rowText: "hi")))

        XCTAssertEqual(rendered.map(\.paneID), [7, 7])
        XCTAssertEqual(rendered.map(\.rows), [
            [[.text("o"), .text("k")]],
            [[.text("h"), .text("i")]]
        ])
        XCTAssertTrue(session.tabs.first?.surfaceTree?.root?.leaves().first === surfacesByPaneID[7])
    }

    func testSameSizeDeltaRendersWithoutDestructiveGridReset() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var renderPlans: [(resetGrid: Bool, rowsToRender: Set<Int>?)] = []
        var resized: [RemoteGridSize] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridResizeOperation = { surface, size in
            resized.append(size)
            return surface.resizeRemoteGrid(columns: size.columns, rows: size.rows)
        }
        bridge.paneGridRenderOperation = { _, _, resetGrid, rowsToRender in
            renderPlans.append((resetGrid, rowsToRender))
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(rowText: "ok")))
        bridge.handle(.paneDelta(makeDelta(deltaSequence: 1, rowVersion: 12, rowText: "hi")))
        bridge.handle(.paneDelta(makeDelta(deltaSequence: 2, rowVersion: 13, rowText: "st")))

        XCTAssertEqual(renderPlans.map(\.resetGrid), [true, false, false])
        XCTAssertNil(renderPlans[0].rowsToRender)
        XCTAssertEqual(renderPlans[1].rowsToRender, [0])
        XCTAssertEqual(renderPlans[2].rowsToRender, [0])
        XCTAssertEqual(resized.first, RemoteGridSize(columns: 2, rows: 1))
        XCTAssertTrue(resized.allSatisfy { $0 == RemoteGridSize(columns: 2, rows: 1) })
    }

    func testSameSizeKeyframeRendersFullGridResetEvenWhenRowVersionsMatch() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var renderPlans: [(resetGrid: Bool, rowsToRender: Set<Int>?)] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridRenderOperation = { _, _, resetGrid, rowsToRender in
            renderPlans.append((resetGrid, rowsToRender))
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowVersion: 10, rowText: "ok")))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 12, rowVersion: 10, rowText: "re")))

        XCTAssertEqual(renderPlans.map(\.resetGrid), [true, true])
        XCTAssertNil(renderPlans[0].rowsToRender)
        XCTAssertNil(renderPlans[1].rowsToRender)
    }

    func testPaneVisibilityRerendersAuthoritativeGridWithFullReset() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var renderPlans: [(resetGrid: Bool, rowsToRender: Set<Int>?)] = []
        var renderedRows: [[[RemoteGridCell]]] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridRenderOperation = { state, _, resetGrid, rowsToRender in
            renderPlans.append((resetGrid, rowsToRender))
            renderedRows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))
        bridge.handle(.paneDelta(makeDelta(paneGeneration: 3, baseKeyframeID: 11, deltaSequence: 1, rowVersion: 12, rowText: "hi")))

        bridge.handleRemotePaneBecameVisible(workspaceID: "workspace-1", paneID: 7)

        XCTAssertEqual(renderPlans.map(\.resetGrid), [true, false, true])
        XCTAssertNil(renderPlans[0].rowsToRender)
        XCTAssertEqual(renderPlans[1].rowsToRender, [0])
        XCTAssertNil(renderPlans[2].rowsToRender)
        XCTAssertEqual(renderedRows.last, [[.text("h"), .text("i")]])
    }

    func testRemoteWindowSelectionSurvivesInactiveSnapshotAfterUserSelectsRemoteTab() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: false)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true),
            makePane(paneID: 8, windowID: 2)
        ])))

        let logsTabID = session.tabs[1].id
        session.selectedTabID = logsTabID

        bridge.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 2, windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: false)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true),
            makePane(paneID: 8, windowID: 2)
        ])))

        XCTAssertEqual(session.selectedTabID, logsTabID)
    }

    func testRemoteActiveWindowSnapshotChangesSelectionWithoutUserOverride() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: false)
        ], panes: [
            makePane(paneID: 7, windowID: 1, isActive: true),
            makePane(paneID: 8, windowID: 2)
        ])))

        let logsTabID = session.tabs[1].id

        bridge.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 2, windows: [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: false),
            RemoteWorkspaceWindow(windowID: 2, title: "logs", index: 1, isActive: true)
        ], panes: [
            makePane(paneID: 7, windowID: 1),
            makePane(paneID: 8, windowID: 2, isActive: true)
        ])))

        XCTAssertEqual(session.selectedTabID, logsTabID)
    }

    func testReattachForcesFreshKeyframeFullGridReset() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var renderPlans: [(resetGrid: Bool, rowsToRender: Set<Int>?)] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridRenderOperation = { _, _, resetGrid, rowsToRender in
            renderPlans.append((resetGrid, rowsToRender))
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))
        bridge.handle(.paneDelta(makeDelta(paneGeneration: 3, baseKeyframeID: 11, deltaSequence: 1, rowVersion: 12, rowText: "hi")))

        await bridge.handleReattach(workspaceID: "workspace-1")
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 12, rowVersion: 20, rowText: "re")))

        XCTAssertEqual(renderPlans.map(\.resetGrid), [true, false, true])
        XCTAssertNil(renderPlans[0].rowsToRender)
        XCTAssertEqual(renderPlans[1].rowsToRender, [0])
        XCTAssertNil(renderPlans[2].rowsToRender)
    }

    func testReattachRequestsKeyframeAndKeepsExistingSurfaceUntilFreshKeyframeRenders() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var surfacesByPaneID: [Int: Ghostty.SurfaceView] = [:]
        var requestedKeyframes: [(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)] = []
        var rendered: [(paneID: Int, rows: [[RemoteGridCell]])] = []

        bridge.surfaceFactory = { paneID in
            let surface = self.makeSurface()
            surfacesByPaneID[paneID] = surface
            return surface
        }
        bridge.keyframeRequestHandler = { _, paneID, reason in
            requestedKeyframes.append((paneID, reason))
            return nil
        }
        bridge.paneGridRenderer = { state, surface in
            let paneID = surfacesByPaneID.first { $0.value === surface }?.key ?? -1
            rendered.append((paneID, state.rows))
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))
        bridge.handle(.paneDelta(makeDelta(paneGeneration: 3, baseKeyframeID: 11, deltaSequence: 1, rowVersion: 12, rowText: "hi")))
        let originalSurface = surfacesByPaneID[7]
        var authoritativeRenders: [(workspaceID: String, paneID: Int)] = []
        bridge.authoritativePaneRenderHandler = { workspaceID, paneID in
            authoritativeRenders.append((workspaceID, paneID))
        }

        await bridge.handleReattach(workspaceID: "workspace-1")
        bridge.handle(.paneDelta(makeDelta(paneGeneration: 3, baseKeyframeID: 11, deltaSequence: 2, rowVersion: 13, rowText: "st")))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowVersion: 20, rowText: "re")))

        XCTAssertEqual(requestedKeyframes.map(\.paneID), [7, 7])
        XCTAssertTrue(requestedKeyframes.allSatisfy { $0.reason == .noKeyframe })
        XCTAssertEqual(rendered.map(\.rows), [
            [[.text("o"), .text("k")]],
            [[.text("h"), .text("i")]],
            [[.text("r"), .text("e")]]
        ])
        XCTAssertEqual(authoritativeRenders.map(\.paneID), [7])
        XCTAssertTrue(session.tabs.first?.surfaceTree?.root?.leaves().first === originalSurface)
    }

    func testReattachCancelsPendingRenderRetryBeforeFreshKeyframeRenders() async throws {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var renderAttempts = 0
        var authoritativeRenders: [(workspaceID: String, paneID: Int)] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { _, _ in
            renderAttempts += 1
            if renderAttempts == 1 {
                return .rejectedBySurface(stage: .resetGrid)
            }
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))
        bridge.authoritativePaneRenderHandler = { workspaceID, paneID in
            authoritativeRenders.append((workspaceID, paneID))
        }

        await bridge.handleReattach(workspaceID: "workspace-1")
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(authoritativeRenders.isEmpty)

        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 12, rowVersion: 20, rowText: "re")))

        XCTAssertEqual(authoritativeRenders.map(\.paneID), [7])
    }

    func testReattachSendsFreshRequestEvenWhenOldConnectionHadPendingKeyframeRequest() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var requestedKeyframes: [(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.keyframeRequestHandler = { _, paneID, reason in
            requestedKeyframes.append((paneID, reason))
            return nil
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))

        await bridge.handleReattach(workspaceID: "workspace-1")

        XCTAssertEqual(requestedKeyframes.map(\.paneID), [7, 7])
        XCTAssertEqual(requestedKeyframes.map(\.reason), [.noKeyframe, .noKeyframe])
    }

    func testDeltaMismatchRecoveryRequestRetriesUntilFreshKeyframeRenders() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var requestedKeyframes: [(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { _, _ in .rendered }
        bridge.keyframeRequestHandler = { _, paneID, reason in
            requestedKeyframes.append((paneID, reason))
            return nil
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowVersion: 10, rowText: "ok")))
        bridge.handle(.paneDelta(makeSpanDelta(
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            baseRowVersion: 9,
            rowVersion: 12,
            text: "x"
        )))

        await waitUntilRemoteWorkspaceBridge {
            requestedKeyframes.count >= 3
        }
        XCTAssertGreaterThanOrEqual(requestedKeyframes.count, 3)
        XCTAssertEqual(requestedKeyframes.map(\.paneID).prefix(3), [7, 7, 7])
        XCTAssertEqual(requestedKeyframes.map(\.reason).prefix(3), [.noKeyframe, .rowVersionMismatch, .rowVersionMismatch])

        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 12, rowVersion: 20, rowText: "re")))
        let countAfterFreshKeyframe = requestedKeyframes.count
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(requestedKeyframes.count, countAfterFreshKeyframe)
    }

    func testRuntimeResizeMismatchReplacesPendingNoKeyframeRequest() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var requestedKeyframes: [(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.keyframeRequestHandler = { _, paneID, reason in
            requestedKeyframes.append((paneID, reason))
            return Task {}
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: 4, rows: 1),
            rowText: "wide"
        )))
        bridge.handle(.paneKeyframe(makeKeyframe(
            paneGeneration: 3,
            keyframeID: 12,
            rowVersion: 20,
            gridSize: RemoteGridSize(columns: 4, rows: 1),
            rowText: "wide"
        )))

        XCTAssertEqual(requestedKeyframes.map(\.paneID), [7, 7])
        XCTAssertEqual(requestedKeyframes.map(\.reason), [.noKeyframe, .resizeMismatch])
    }

    func testResizeMismatchDoesNotRenderUntilFreshKeyframeMatchesSurfaceSize() async {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var requestedKeyframes: [(paneID: Int, reason: RemotePaneGridKeyframeRequestReason)] = []
        var resizeIntents: [(paneID: Int, size: RemoteGridSize)] = []
        var surfaceResizes: [RemoteGridSize] = []
        var diagnostics: [RemoteWorkspaceRenderDiagnostic] = []

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridResizeOperation = { surface, size in
            surfaceResizes.append(size)
            return surface.resizeRemoteGrid(columns: size.columns, rows: size.rows)
        }
        bridge.paneGridRenderer = { _, _ in
            .rendered
        }
        bridge.keyframeRequestHandler = { _, paneID, reason in
            requestedKeyframes.append((paneID, reason))
            return Task {}
        }
        bridge.paneResizeHandler = { _, paneID, size in
            resizeIntents.append((paneID, size))
        }
        bridge.renderDiagnosticHandler = { diagnostic in
            diagnostics.append(diagnostic)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        guard let surface = session.tabs.first?.surfaceTree?.root?.leaves().first else {
            return XCTFail("Expected remote pane surface")
        }
        surface.surfaceSize = ghostty_surface_size_s(
            columns: 4,
            rows: 1,
            width_px: 40,
            height_px: 10,
            cell_width_px: 10,
            cell_height_px: 10
        )

        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))
        bridge.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 12, rowVersion: 20, rowText: "hi")))

        XCTAssertEqual(requestedKeyframes.map(\.paneID), [7, 7])
        XCTAssertEqual(requestedKeyframes.map(\.reason), [.noKeyframe, .resizeMismatch])
        XCTAssertEqual(resizeIntents.map(\.paneID), [7])
        XCTAssertEqual(resizeIntents.map(\.size), [
            RemoteGridSize(columns: 4, rows: 1)
        ])
        XCTAssertEqual(remoteGridSize(from: surface.surfaceSize), RemoteGridSize(columns: 4, rows: 1))
        XCTAssertEqual(Array(surfaceResizes.prefix(2)), [
            RemoteGridSize(columns: 2, rows: 1),
            RemoteGridSize(columns: 4, rows: 1)
        ])
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertFalse(diagnostics.contains { $0.result == .rendered })
        XCTAssertEqual(diagnostics.map(\.requestedResizeKeyframe), [true, false])

        bridge.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 2, panes: [
            makePane(
                paneID: 7,
                windowID: 1,
                isActive: true,
                frame: RemotePaneFrame(x: 0, y: 0, columns: 4, rows: 1)
            )
        ])))
        XCTAssertEqual(requestedKeyframes.map(\.paneID), [7, 7, 7])
        XCTAssertEqual(requestedKeyframes.map(\.reason), [.noKeyframe, .resizeMismatch, .resizeMismatch])

        bridge.handle(.paneKeyframe(makeKeyframe(
            paneGeneration: 3,
            keyframeID: 13,
            rowVersion: 30,
            gridSize: RemoteGridSize(columns: 4, rows: 1),
            rowText: "done"
        )))
        await waitUntilRemoteWorkspaceBridge {
            diagnostics.last?.result == .rendered
        }

        guard let renderedDiagnostic = diagnostics.last else {
            return XCTFail("Expected render diagnostic for compatible keyframe")
        }
        XCTAssertEqual(renderedDiagnostic.result, .rendered)
        XCTAssertFalse(renderedDiagnostic.requestedResizeKeyframe)
        XCTAssertEqual(renderedDiagnostic.surfaceSize, RemoteGridSize(columns: 4, rows: 1))
        XCTAssertEqual(renderedDiagnostic.stateSize, RemoteGridSize(columns: 4, rows: 1))
    }

    func testRenderRejectionReportsUnsupportedPaneState() {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        var unsupportedStates: [RemoteUnsupportedPaneState] = []

        bridge.surfaceFactory = { _ in
            self.makeSurface()
        }
        bridge.paneGridRenderer = { _, _ in
            .rejectedBySurface
        }
        bridge.unsupportedPaneStateHandler = { _, state in
            unsupportedStates.append(state)
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true)
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(rowText: "ok")))

        XCTAssertEqual(unsupportedStates, [
            RemoteUnsupportedPaneState(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                reason: .unsupportedCellAttribute,
                fallback: .keepLastGoodKeyframe
            )
        ])
    }
}

private func waitUntilRemoteWorkspaceBridge(
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

@MainActor
private extension RemoteWorkspaceBridgeTests {
    struct RenderedPredictionHarness {
        let bridge: RemoteWorkspaceBridge
        let session: Session
        let scheduler: ManualPredictionScheduler
        let renderedRows: () -> [[[RemoteGridCell]]]
    }

    final class RenderedRowsCapture {
        var rows: [[[RemoteGridCell]]] = []
    }

    func makeRenderedPredictionHarness(columns: Int = 6, initialRenderTime: TimeInterval = 1.20) -> RenderedPredictionHarness {
        let bridge = RemoteWorkspaceBridge()
        let session = makeRemoteSession()
        let scheduler = ManualPredictionScheduler()
        bridge.predictionClock = { scheduler.now }
        bridge.predictionScheduler = scheduler.schedule
        let renderedRows = RenderedRowsCapture()

        bridge.surfaceFactory = { _ in self.makeSurface() }
        bridge.paneGridRenderer = { state, _ in
            renderedRows.rows.append(state.rows)
            return .rendered
        }

        bridge.registerRemoteWorkspaceSession(session)
        bridge.handle(.workspaceSnapshot(makeSnapshot(panes: [
            makePane(paneID: 7, windowID: 1, isActive: true, frame: RemotePaneFrame(x: 0, y: 0, columns: columns, rows: 1))
        ])))
        bridge.handle(.paneKeyframe(makeKeyframe(
            gridSize: RemoteGridSize(columns: columns, rows: 1),
            rowText: "$ a",
            cursor: RemoteCursorState(row: 0, column: 3, visible: true, shape: .block)
        )))
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("b".utf8), source: .directKey))
        bridge.handle(.paneDelta(makeDelta(
            rowText: "$ ab",
            columns: columns,
            cursor: RemoteCursorState(row: 0, column: 4, visible: true, shape: .block, cursorVersion: 2)
        )))
        scheduler.now = 1.0
        bridge.handleRemotePaneInput(workspaceID: "workspace-1", paneID: 7, input: RemotePaneInput(data: Data("c".utf8), source: .directKey))
        scheduler.advance(to: initialRenderTime)

        return RenderedPredictionHarness(
            bridge: bridge,
            session: session,
            scheduler: scheduler,
            renderedRows: { renderedRows.rows }
        )
    }

    func makeRemoteSession(workspaceID: String = "workspace-1") -> Session {
        Session(title: "Remote", type: .local, workspaceID: workspaceID)
    }

    func makeSurface() -> Ghostty.SurfaceView {
        Ghostty.SurfaceView(RemoteWorkspaceBridgeTestSupport.ghosttyApp.app!, baseConfig: nil)
    }

    func makeSnapshot(
        workspaceID: String = "workspace-1",
        layoutGeneration: UInt64 = 1,
        windows: [RemoteWorkspaceWindow] = [
            RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
        ],
        panes: [RemoteWorkspacePane]
    ) -> RemoteWorkspaceSnapshot {
        RemoteWorkspaceSnapshot(
            workspaceID: workspaceID,
            layoutGeneration: layoutGeneration,
            windows: windows,
            panes: panes
        )
    }

    func makePane(
        paneID: Int,
        windowID: Int,
        isActive: Bool = false,
        frame: RemotePaneFrame = RemotePaneFrame(x: 0, y: 0, columns: 2, rows: 1)
    ) -> RemoteWorkspacePane {
        RemoteWorkspacePane(
            paneID: paneID,
            windowID: windowID,
            isActive: isActive,
            frame: frame
        )
    }

    func paneID(
        for node: Fantastty.SplitTree<Fantastty.Ghostty.SurfaceView>.Node,
        in surfacesByPaneID: [Int: Fantastty.Ghostty.SurfaceView]
    ) -> Int? {
        guard case .leaf(let surface) = node else { return nil }
        return surfacesByPaneID.first { $0.value === surface }?.key
    }

    func remoteGridSize(from size: ghostty_surface_size_s?) -> RemoteGridSize? {
        guard let size else { return nil }
        let columns = Int(size.columns)
        let rows = Int(size.rows)
        guard columns > 0, rows > 0 else { return nil }
        return RemoteGridSize(columns: columns, rows: rows)
    }

    func nativeRemoteGridSize(from surfaceView: Ghostty.SurfaceView?) -> RemoteGridSize? {
        guard let surface = surfaceView?.surface else { return nil }
        return remoteGridSize(from: ghostty_surface_size(surface))
    }

    func makeKeyframe(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        keyframeID: UInt64 = 11,
        rowVersion: UInt64 = 10,
        gridSize: RemoteGridSize? = nil,
        rowText: String,
        cursor: RemoteCursorState? = nil,
        activeScreen: RemoteActiveScreen = .primary
    ) -> RemotePaneKeyframe {
        let cursorColumns = cursor.map { $0.column + 1 } ?? 0
        let resolvedSize = gridSize ?? RemoteGridSize(columns: max(rowText.count, cursorColumns, 1), rows: 1)
        return RemotePaneKeyframe(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            keyframeID: keyframeID,
            gridSize: resolvedSize,
            rows: [
                RemoteGridRow(index: 0, rowVersion: rowVersion, cells: paddedCells(rowText, columns: resolvedSize.columns))
            ],
            cursor: cursor ?? RemoteCursorState(row: 0, column: min(rowText.count, resolvedSize.columns - 1), visible: true, shape: .block),
            activeScreen: activeScreen,
            datagramsEnabledAfterKeyframe: true
        )
    }

    func makeDelta(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        baseKeyframeID: UInt64 = 11,
        deltaSequence: UInt64 = 1,
        rowVersion: UInt64 = 12,
        rowText: String,
        columns: Int? = nil,
        cursor: RemoteCursorState? = nil
    ) -> RemotePaneDelta {
        let cursorColumns = cursor.map { $0.column + 1 } ?? 0
        let resolvedColumns = max(columns ?? rowText.count, cursorColumns, 1)
        return RemotePaneDelta(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            baseKeyframeID: baseKeyframeID,
            deltaSequence: deltaSequence,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: rowVersion,
                    update: .fullRow(paddedCells(rowText, columns: resolvedColumns))
                )
            ],
            cursor: cursor ?? RemoteCursorState(row: 0, column: max(rowText.count - 1, 0), visible: true, shape: .bar)
        )
    }

    func makeSpanDelta(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        baseKeyframeID: UInt64 = 11,
        deltaSequence: UInt64 = 1,
        baseRowVersion: UInt64,
        rowVersion: UInt64,
        text: String
    ) -> RemotePaneDelta {
        RemotePaneDelta(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            baseKeyframeID: baseKeyframeID,
            deltaSequence: deltaSequence,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: rowVersion,
                    update: .span(
                        baseRowVersion: baseRowVersion,
                        startColumn: 0,
                        cells: text.map { RemoteGridCell.text(String($0)) },
                        clearToColumn: nil
                    )
                )
            ],
            cursor: nil
        )
    }

    func paddedCells(_ text: String, columns: Int) -> [RemoteGridCell] {
        var cells = text.map { RemoteGridCell.text(String($0)) }
        while cells.count < columns {
            cells.append(.blank)
        }
        return Array(cells.prefix(columns))
    }
}

@MainActor
private final class ManualPredictionScheduler {
    var now: TimeInterval = 0
    private var callbacks: [(fireAt: TimeInterval, callback: @MainActor () -> Void, token: ManualPredictionTimer)] = []

    var pendingCount: Int {
        callbacks.filter { !$0.token.cancelled }.count
    }

    var pendingFireTimes: [TimeInterval] {
        callbacks
            .filter { !$0.token.cancelled }
            .map(\.fireAt)
            .sorted()
    }

    func schedule(delay: TimeInterval, _ callback: @escaping @MainActor () -> Void) -> RemotePredictionTimer {
        let token = ManualPredictionTimer()
        callbacks.append((now + delay, callback, token))
        return token
    }

    func advance(to time: TimeInterval) {
        now = time
        let ready = callbacks.filter { $0.fireAt <= time && !$0.token.cancelled }
        callbacks.removeAll { $0.fireAt <= time }
        for item in ready {
            item.callback()
        }
    }
}

private final class ManualPredictionTimer: RemotePredictionTimer {
    var cancelled = false

    func cancel() {
        cancelled = true
    }
}
