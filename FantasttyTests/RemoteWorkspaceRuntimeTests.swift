import XCTest
@testable import Fantastty

final class RemoteWorkspaceRuntimeTests: XCTestCase {
    func testSnapshotAppliesNewLayoutAndRequestsKeyframesForUninitializedPanes() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let snapshot = makeSnapshot(layoutGeneration: 4, paneIDs: [7, 8])

        let actions = runtime.handle(.workspaceSnapshot(snapshot))

        XCTAssertEqual(actions, [
            .applyWorkspaceSnapshot(snapshot),
            .requestKeyframe(paneID: 7, reason: .noKeyframe),
            .requestKeyframe(paneID: 8, reason: .noKeyframe)
        ])
    }

    func testStaleSnapshotDoesNotReplaceCurrentLayout() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let current = makeSnapshot(layoutGeneration: 4, paneIDs: [7])
        XCTAssertFalse(runtime.handle(.workspaceSnapshot(current)).isEmpty)

        let stale = makeSnapshot(layoutGeneration: 3, paneIDs: [9])

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(stale)), [])
    }

    func testKeyframeForKnownPaneRendersGridState() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))

        let keyframe = makeKeyframe(keyframeID: 11, rowText: "ok")
        let actions = runtime.handle(.paneKeyframe(keyframe))

        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(keyframe), .applied)
        XCTAssertEqual(actions, [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testMalformedWideCellKeyframeRequestsReplacementWithoutRendering() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))

        let malformed = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: 2, rows: 1),
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [
                    .text("w", width: 2),
                    .continuation
                ])
            ],
            cursor: RemoteCursorState(row: 0, column: 0, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )

        XCTAssertEqual(runtime.handle(.paneKeyframe(malformed)), [
            .requestKeyframe(paneID: 7, reason: .malformedKeyframe)
        ])
    }

    func testKeyframeBeforeSnapshotIsBufferedUntilPaneAppears() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let keyframe = makeKeyframe(keyframeID: 11, rowText: "ok")

        XCTAssertEqual(runtime.handle(.paneKeyframe(keyframe)), [])

        let actions = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(keyframe), .applied)
        XCTAssertEqual(actions, [
            .applyWorkspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])),
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testSnapshotPrunesBufferedKeyframesForExcludedPanes() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")

        XCTAssertEqual(runtime.handle(.paneKeyframe(makeKeyframe(paneID: 9, keyframeID: 11, rowText: "st"))), [])
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7]))), [
            .applyWorkspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])

        let actions = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 5, paneIDs: [9])))

        XCTAssertEqual(actions, [
            .applyWorkspaceSnapshot(makeSnapshot(layoutGeneration: 5, paneIDs: [9])),
            .requestKeyframe(paneID: 9, reason: .noKeyframe)
        ])
    }

    func testMalformedSnapshotWithDuplicatePaneIDsIsIgnoredWithoutCrashing() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let snapshot = makeSnapshot(
            layoutGeneration: 4,
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 2, rows: 1)
                ),
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: false,
                    frame: RemotePaneFrame(x: 2, y: 0, columns: 2, rows: 1)
                )
            ]
        )

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(snapshot)), [])
    }

    func testMalformedSnapshotDoesNotAdvanceLayoutGeneration() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let malformed = makeSnapshot(
            layoutGeneration: 4,
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 2, rows: 1)
                ),
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: false,
                    frame: RemotePaneFrame(x: 2, y: 0, columns: 2, rows: 1)
                )
            ]
        )
        let valid = makeSnapshot(layoutGeneration: 4, paneIDs: [7])

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(malformed)), [])
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(valid)), [
            .applyWorkspaceSnapshot(valid),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])
    }

    func testMalformedSnapshotWithDuplicateWindowIDsDoesNotAdvanceLayoutGeneration() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let malformed = makeSnapshot(
            layoutGeneration: 4,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true),
                RemoteWorkspaceWindow(windowID: 1, title: "duplicate", index: 1, isActive: false)
            ],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 2, rows: 1)
                )
            ]
        )
        let valid = makeSnapshot(layoutGeneration: 4, paneIDs: [7])

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(malformed)), [])
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(valid)), [
            .applyWorkspaceSnapshot(valid),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])
    }

    func testMalformedSnapshotWithPaneForMissingWindowDoesNotAdvanceLayoutGeneration() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let malformed = makeSnapshot(
            layoutGeneration: 4,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
            ],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 2,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 2, rows: 1)
                )
            ]
        )
        let valid = makeSnapshot(layoutGeneration: 4, paneIDs: [7])

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(malformed)), [])
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(valid)), [
            .applyWorkspaceSnapshot(valid),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])
    }

    func testMalformedSnapshotWithNonPositivePaneSizeDoesNotAdvanceLayoutGeneration() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        let malformed = makeSnapshot(
            layoutGeneration: 4,
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 0, rows: 1)
                )
            ]
        )
        let valid = makeSnapshot(layoutGeneration: 4, paneIDs: [7])

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(malformed)), [])
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(valid)), [
            .applyWorkspaceSnapshot(valid),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])
    }

    func testSnapshotResizeRequestsKeyframeInsteadOfRenderingMismatchedGrid() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        _ = runtime.handle(.paneKeyframe(makeKeyframe(keyframeID: 11, rowText: "ok")))

        let resized = makeSnapshot(
            layoutGeneration: 5,
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 3, rows: 1)
                )
            ]
        )

        XCTAssertEqual(runtime.handle(.workspaceSnapshot(resized)), [
            .applyWorkspaceSnapshot(resized),
            .requestKeyframe(paneID: 7, reason: .resizeMismatch)
        ])
        XCTAssertEqual(runtime.handle(.paneDelta(makeDelta(deltaSequence: 1, rowVersion: 12, rowText: "hi"))), [
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])
    }

    func testDeltaForKnownPaneRendersAcceptedState() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        let keyframe = makeKeyframe(keyframeID: 11, rowText: "ok")
        _ = runtime.handle(.paneKeyframe(keyframe))

        let delta = makeDelta(deltaSequence: 1, rowVersion: 12, rowText: "hi")
        let actions = runtime.handle(.paneDelta(delta))

        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(keyframe), .applied)
        XCTAssertEqual(expectedState.apply(delta), .applied)
        XCTAssertEqual(actions, [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testDatagramViabilityOracleSeparatesDroppedDeltaFromReliableKeyframeRecovery() {
        func deliver(
            _ message: RemoteWorkspaceMessage,
            delivery: RemotePaneDeltaDelivery = .reliable,
            dropDatagrams: Bool = false,
            to runtime: inout RemoteWorkspaceRuntime
        ) -> [RemoteWorkspaceRuntimeAction] {
            if dropDatagrams, delivery == .datagram {
                return []
            }
            return runtime.handle(message, delivery: delivery)
        }

        let keyframe = makeKeyframe(keyframeID: 11, rowText: "ok")
        let datagramDelta = makeDelta(deltaSequence: 1, rowVersion: 12, rowText: "dg")

        var datagramRuntime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = deliver(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])), to: &datagramRuntime)
        _ = deliver(.paneKeyframe(keyframe), to: &datagramRuntime)

        var datagramState = RemotePaneGridState.empty
        XCTAssertEqual(datagramState.apply(keyframe), .applied)
        XCTAssertEqual(datagramState.apply(datagramDelta, delivery: .datagram), .applied)
        XCTAssertEqual(deliver(.paneDelta(datagramDelta), delivery: .datagram, to: &datagramRuntime), [
            .renderPaneGrid(paneID: 7, state: datagramState)
        ])

        var recoveryRuntime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = deliver(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])), to: &recoveryRuntime)
        _ = deliver(.paneKeyframe(keyframe), to: &recoveryRuntime)

        XCTAssertEqual(
            deliver(.paneDelta(datagramDelta), delivery: .datagram, dropDatagrams: true, to: &recoveryRuntime),
            []
        )

        let recoveryKeyframe = makeKeyframe(keyframeID: 12, rowVersion: 20, rowText: "rk")
        var recoveryState = RemotePaneGridState.empty
        XCTAssertEqual(recoveryState.apply(recoveryKeyframe), .applied)
        XCTAssertEqual(deliver(.paneKeyframe(recoveryKeyframe), to: &recoveryRuntime), [
            .renderPaneGrid(paneID: 7, state: recoveryState)
        ])
    }

    func testDeterministicLossyHarnessConvergesOnlyFromValidKeyframeBaseAtRuntime() {
        let script = makeRuntimeDeterministicLossyHarnessScript()
        let oracle = makeRuntimeStructuredStateOracle(for: script)
        let schedules = makeRuntimeDeterministicLossySchedules()

        for schedule in schedules {
            assertRuntimeLossySchedule(
                schedule,
                for: script,
                convergesFromValidBaseTo: oracle
            )

            assertRuntimeLossyScheduleDoesNotConvergeWithoutValidBase(
                schedule,
                for: script,
                oracle: oracle
            )
        }
    }

    func testReliableDeltaRendersWhenDatagramsAreDisabled() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        let keyframe = makeKeyframe(keyframeID: 11, rowText: "ok", datagramsEnabledAfterKeyframe: false)
        _ = runtime.handle(.paneKeyframe(keyframe))

        let delta = makeDelta(deltaSequence: 1, rowVersion: 12, rowText: "hi")
        let actions = runtime.handle(.paneDelta(delta), delivery: .reliable)

        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(keyframe), .applied)
        XCTAssertEqual(expectedState.apply(delta, delivery: .reliable), .applied)
        XCTAssertEqual(actions, [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testUnsafeDeltaRequestsKeyframeWithoutRendering() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        _ = runtime.handle(.paneKeyframe(makeKeyframe(keyframeID: 11, rowText: "ok")))

        let delta = makeDelta(baseKeyframeID: 10, deltaSequence: 1, rowVersion: 12, rowText: "hi")

        XCTAssertEqual(runtime.handle(.paneDelta(delta)), [
            .requestKeyframe(paneID: 7, reason: .baseKeyframeMismatch)
        ])
    }

    func testReconnectKeyframeReplacesPreviousDeltaState() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        _ = runtime.handle(.paneKeyframe(makeKeyframe(keyframeID: 11, rowText: "ok")))
        _ = runtime.handle(.paneDelta(makeDelta(deltaSequence: 1, rowVersion: 12, rowText: "hi")))

        let replacement = makeKeyframe(keyframeID: 12, rowVersion: 20, rowText: "re")
        let actions = runtime.handle(.paneKeyframe(replacement))

        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(replacement), .applied)
        XCTAssertEqual(actions, [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testReattachRequestsFreshKeyframeAndRejectsOldBaseDatagramsUntilKeyframeArrives() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        _ = runtime.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))
        _ = runtime.handle(.paneDelta(makeDelta(paneGeneration: 3, baseKeyframeID: 11, deltaSequence: 1, rowVersion: 12, rowText: "hi")))

        XCTAssertEqual(runtime.handleReattach(), [
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ])
        XCTAssertEqual(
            runtime.handle(.paneDelta(makeDelta(paneGeneration: 3, baseKeyframeID: 11, deltaSequence: 2, rowVersion: 13, rowText: "st"))),
            [.requestKeyframe(paneID: 7, reason: .noKeyframe)]
        )

        let keyframe = makeKeyframe(paneGeneration: 3, keyframeID: 11, rowVersion: 20, rowText: "re")
        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(keyframe), .applied)
        XCTAssertEqual(runtime.handle(.paneKeyframe(keyframe)), [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testReattachWithoutKnownPanesIsHarmless() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")

        XCTAssertEqual(runtime.handleReattach(), [])
    }

    func testWrongWorkspaceMessagesAreIgnored() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")

        XCTAssertEqual(
            runtime.handle(.workspaceSnapshot(makeSnapshot(workspaceID: "other", layoutGeneration: 4, paneIDs: [7]))),
            []
        )
        XCTAssertEqual(runtime.handle(.paneKeyframe(makeKeyframe(workspaceID: "other"))), [])
        XCTAssertEqual(runtime.handle(.paneDelta(makeDelta(workspaceID: "other"))), [])
        XCTAssertEqual(runtime.handle(.unsupportedPaneState(makeUnsupported(workspaceID: "other"))), [])
    }

    func testUnsupportedPaneStateForKnownPaneEmitsDiagnosticAction() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        let unsupported = makeUnsupported()

        XCTAssertEqual(runtime.handle(.unsupportedPaneState(unsupported)), [
            .showUnsupportedPaneState(unsupported)
        ])
    }

    func testUnsupportedPaneStateFencesDatagramsUntilFreshKeyframe() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        _ = runtime.handle(.paneKeyframe(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")))

        let unsupported = makeUnsupported(paneGeneration: 4)
        XCTAssertEqual(runtime.handle(.unsupportedPaneState(unsupported)), [
            .showUnsupportedPaneState(unsupported)
        ])
        XCTAssertEqual(
            runtime.handle(.paneDelta(makeDelta(paneGeneration: 3, deltaSequence: 1, rowVersion: 12, rowText: "st"))),
            []
        )
        XCTAssertEqual(
            runtime.handle(.paneDelta(makeDelta(paneGeneration: 4, deltaSequence: 1, rowVersion: 12, rowText: "st"))),
            []
        )

        let keyframe = makeKeyframe(paneGeneration: 4, keyframeID: 12, rowVersion: 20, rowText: "re")
        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(makeKeyframe(paneGeneration: 3, keyframeID: 11, rowText: "ok")), .applied)
        XCTAssertEqual(expectedState.apply(keyframe), .applied)
        XCTAssertEqual(runtime.handle(.paneKeyframe(keyframe)), [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }

    func testStaleUnsupportedPaneStateDoesNotFenceNewerValidPane() {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        _ = runtime.handle(.workspaceSnapshot(makeSnapshot(layoutGeneration: 4, paneIDs: [7])))
        _ = runtime.handle(.paneKeyframe(makeKeyframe(paneGeneration: 4, keyframeID: 11, rowText: "ok")))

        XCTAssertEqual(runtime.handle(.unsupportedPaneState(makeUnsupported(paneGeneration: 3))), [])

        let delta = makeDelta(paneGeneration: 4, deltaSequence: 1, rowVersion: 12, rowText: "hi")
        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(makeKeyframe(paneGeneration: 4, keyframeID: 11, rowText: "ok")), .applied)
        XCTAssertEqual(expectedState.apply(delta), .applied)
        XCTAssertEqual(runtime.handle(.paneDelta(delta)), [
            .renderPaneGrid(paneID: 7, state: expectedState)
        ])
    }
}

private extension RemoteWorkspaceRuntimeTests {
    struct RuntimeDeterministicLossyHarnessScript {
        let snapshot: RemoteWorkspaceSnapshot
        let keyframe: RemotePaneKeyframe
        let deltas: [RemotePaneDelta]
    }

    struct RuntimeDeterministicLossySchedule {
        let name: String
        let deliveredDeltaIndices: [Int]
    }

    func makeRuntimeDeterministicLossyHarnessScript() -> RuntimeDeterministicLossyHarnessScript {
        let emphasizedStyle = RemoteCellStyle(
            foreground: .indexed(2),
            background: .default,
            underlineColor: .default,
            bold: true,
            faint: false,
            italic: false,
            underline: .none,
            blink: false,
            inverse: false,
            invisible: false,
            strikethrough: false
        )
        let underlinedStyle = RemoteCellStyle(
            foreground: .rgb(red: 220, green: 80, blue: 20),
            background: .default,
            underlineColor: .indexed(4),
            bold: false,
            faint: false,
            italic: true,
            underline: .single,
            blink: false,
            inverse: false,
            invisible: false,
            strikethrough: false
        )
        let snapshot = makeSnapshot(
            layoutGeneration: 4,
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 3, rows: 2)
                )
            ]
        )
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: 3, rows: 2),
            rows: [
                RemoteGridRow(index: 0, rowVersion: 1, cells: [.text("a"), .text("b"), .blank]),
                RemoteGridRow(index: 1, rowVersion: 1, cells: [.text("c"), .text("d"), .blank])
            ],
            cursor: RemoteCursorState(row: 0, column: 0, visible: true, shape: .block, cursorVersion: 1),
            activeScreen: .alternate,
            datagramsEnabledAfterKeyframe: true
        )
        let deltas = [
            RemotePaneDelta(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                baseKeyframeID: 11,
                deltaSequence: 1,
                rowUpdates: [
                    RemoteRowUpdate(rowIndex: 0, rowVersion: 2, update: .fullRow([
                        .text("o"), .text("l"), .text("d")
                    ]))
                ],
                cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .bar, cursorVersion: 2)
            ),
            RemotePaneDelta(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                baseKeyframeID: 11,
                deltaSequence: 2,
                rowUpdates: [
                    RemoteRowUpdate(rowIndex: 1, rowVersion: 2, update: .fullRow([
                        .text("r", style: emphasizedStyle),
                        .text("o", style: emphasizedStyle),
                        .text("w", style: emphasizedStyle)
                    ]))
                ],
                cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .bar, cursorVersion: 3)
            ),
            RemotePaneDelta(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                baseKeyframeID: 11,
                deltaSequence: 3,
                rowUpdates: [
                    RemoteRowUpdate(rowIndex: 0, rowVersion: 3, update: .fullRow([
                        .text("n", style: underlinedStyle),
                        .text("e", style: underlinedStyle),
                        .text("w", style: underlinedStyle)
                    ]))
                ],
                cursor: RemoteCursorState(row: 1, column: 2, visible: true, shape: .underline, cursorVersion: 4)
            ),
            RemotePaneDelta(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                baseKeyframeID: 11,
                deltaSequence: 4,
                rowUpdates: [],
                cursor: RemoteCursorState(row: 1, column: 1, visible: true, shape: .block, cursorVersion: 5)
            )
        ]

        return RuntimeDeterministicLossyHarnessScript(snapshot: snapshot, keyframe: keyframe, deltas: deltas)
    }

    func makeRuntimeDeterministicLossySchedules() -> [RuntimeDeterministicLossySchedule] {
        [
            RuntimeDeterministicLossySchedule(name: "drop superseded row delta", deliveredDeltaIndices: [1, 2, 3]),
            RuntimeDeterministicLossySchedule(name: "duplicate latest cursor delta", deliveredDeltaIndices: [0, 1, 2, 3, 3]),
            RuntimeDeterministicLossySchedule(name: "reorder independent row deltas", deliveredDeltaIndices: [1, 0, 2, 3]),
            RuntimeDeterministicLossySchedule(name: "delay useful older row delta", deliveredDeltaIndices: [0, 2, 3, 1])
        ]
    }

    func makeRuntimeStructuredStateOracle(for script: RuntimeDeterministicLossyHarnessScript) -> RemotePaneGridState {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(script.keyframe), .applied)
        for delta in script.deltas {
            XCTAssertEqual(state.apply(delta, delivery: .datagram), .applied)
        }
        return state
    }

    func assertRuntimeLossySchedule(
        _ schedule: RuntimeDeterministicLossySchedule,
        for script: RuntimeDeterministicLossyHarnessScript,
        convergesFromValidBaseTo oracle: RemotePaneGridState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(script.snapshot)), [
            .applyWorkspaceSnapshot(script.snapshot),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ], schedule.name, file: file, line: line)

        var expectedState = RemotePaneGridState.empty
        XCTAssertEqual(expectedState.apply(script.keyframe), .applied, schedule.name, file: file, line: line)
        var lastRenderedState = onlyRenderedState(from: runtime.handle(.paneKeyframe(script.keyframe)))
        XCTAssertNotNil(lastRenderedState, schedule.name, file: file, line: line)

        for index in schedule.deliveredDeltaIndices {
            let expectedResult = expectedState.apply(script.deltas[index], delivery: .datagram)
            let actions = runtime.handle(.paneDelta(script.deltas[index]), delivery: .datagram)
            if actions.contains(where: { action in
                if case .requestKeyframe = action { return true }
                return false
            }) {
                XCTFail("\(schedule.name) requested a keyframe from a valid base: \(actions)", file: file, line: line)
            }
            switch expectedResult {
            case .applied:
                guard let renderedState = onlyRenderedState(from: actions) else {
                    XCTFail("\(schedule.name) did not render useful delta \(index): \(actions)", file: file, line: line)
                    continue
                }
                lastRenderedState = renderedState
                assertRuntimeStructuredState(renderedState, equals: expectedState, scheduleName: schedule.name, file: file, line: line)
            case .dropped(.staleDelta):
                XCTAssertEqual(actions, [], schedule.name, file: file, line: line)
            case .dropped, .needsKeyframe:
                XCTFail("\(schedule.name) expected oracle delta \(index) to be usable: \(expectedResult)", file: file, line: line)
            }
        }

        guard let lastRenderedState else {
            XCTFail("\(schedule.name) did not render", file: file, line: line)
            return
        }
        assertRuntimeStructuredState(lastRenderedState, equals: oracle, scheduleName: schedule.name, file: file, line: line)
    }

    func assertRuntimeLossyScheduleDoesNotConvergeWithoutValidBase(
        _ schedule: RuntimeDeterministicLossySchedule,
        for script: RuntimeDeterministicLossyHarnessScript,
        oracle: RemotePaneGridState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var runtime = RemoteWorkspaceRuntime(workspaceID: "workspace-1")
        XCTAssertEqual(runtime.handle(.workspaceSnapshot(script.snapshot)), [
            .applyWorkspaceSnapshot(script.snapshot),
            .requestKeyframe(paneID: 7, reason: .noKeyframe)
        ], schedule.name, file: file, line: line)

        for index in schedule.deliveredDeltaIndices {
            let actions = runtime.handle(.paneDelta(script.deltas[index]), delivery: .datagram)
            XCTAssertEqual(actions, [
                .requestKeyframe(paneID: 7, reason: .noKeyframe)
            ], schedule.name, file: file, line: line)
            XCTAssertNil(onlyRenderedState(from: actions), schedule.name, file: file, line: line)
        }

        XCTAssertNotEqual(runtime.paneState(paneID: 7), oracle, schedule.name, file: file, line: line)
        XCTAssertNil(runtime.paneState(paneID: 7), schedule.name, file: file, line: line)
    }

    func onlyRenderedState(from actions: [RemoteWorkspaceRuntimeAction]) -> RemotePaneGridState? {
        var renderedStates: [RemotePaneGridState] = []
        for action in actions {
            if case .renderPaneGrid(let paneID, let state) = action {
                XCTAssertEqual(paneID, 7)
                renderedStates.append(state)
            }
        }
        XCTAssertLessThanOrEqual(renderedStates.count, 1)
        return renderedStates.first
    }

    func assertRuntimeStructuredState(
        _ actual: RemotePaneGridState,
        equals expected: RemotePaneGridState,
        scheduleName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.rows, expected.rows, "\(scheduleName) rows", file: file, line: line)
        XCTAssertEqual(
            actual.rows.map { row in row.map(\.style) },
            expected.rows.map { row in row.map(\.style) },
            "\(scheduleName) cell styles",
            file: file,
            line: line
        )
        XCTAssertEqual(actual.cursor, expected.cursor, "\(scheduleName) cursor", file: file, line: line)
        XCTAssertEqual(actual.activeScreen, expected.activeScreen, "\(scheduleName) active screen", file: file, line: line)
        XCTAssertEqual(actual.paneGeneration, expected.paneGeneration, "\(scheduleName) pane generation", file: file, line: line)
        XCTAssertEqual(actual.keyframeID, expected.keyframeID, "\(scheduleName) keyframe id", file: file, line: line)
        XCTAssertEqual(actual.rowVersions, expected.rowVersions, "\(scheduleName) row versions", file: file, line: line)
        XCTAssertEqual(
            actual.lastDeltaSequence,
            expected.lastDeltaSequence,
            "\(scheduleName) delta sequence",
            file: file,
            line: line
        )
    }

    func makeSnapshot(
        workspaceID: String = "workspace-1",
        layoutGeneration: UInt64,
        paneIDs: [Int]
    ) -> RemoteWorkspaceSnapshot {
        makeSnapshot(
            workspaceID: workspaceID,
            layoutGeneration: layoutGeneration,
            panes: paneIDs.enumerated().map { offset, paneID in
                RemoteWorkspacePane(
                    paneID: paneID,
                    windowID: 1,
                    isActive: offset == 0,
                    frame: RemotePaneFrame(x: offset * 10, y: 0, columns: 2, rows: 1)
                )
            }
        )
    }

    func makeSnapshot(
        workspaceID: String = "workspace-1",
        layoutGeneration: UInt64,
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

    func makeKeyframe(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        keyframeID: UInt64 = 11,
        rowVersion: UInt64 = 10,
        rowText: String = "ok",
        datagramsEnabledAfterKeyframe: Bool = true
    ) -> RemotePaneKeyframe {
        RemotePaneKeyframe(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            keyframeID: keyframeID,
            gridSize: RemoteGridSize(columns: 2, rows: 1),
            rows: [
                RemoteGridRow(index: 0, rowVersion: rowVersion, cells: rowText.map { .text(String($0)) })
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: datagramsEnabledAfterKeyframe
        )
    }

    func makeDelta(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        baseKeyframeID: UInt64 = 11,
        deltaSequence: UInt64 = 1,
        rowVersion: UInt64 = 12,
        rowText: String = "hi"
    ) -> RemotePaneDelta {
        RemotePaneDelta(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            baseKeyframeID: baseKeyframeID,
            deltaSequence: deltaSequence,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: rowVersion, update: .fullRow(rowText.map { .text(String($0)) }))
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .bar)
        )
    }

    func makeUnsupported(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3
    ) -> RemoteUnsupportedPaneState {
        RemoteUnsupportedPaneState(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            reason: .snapshotExtractionFailure,
            fallback: .keepLastGoodKeyframe
        )
    }
}
